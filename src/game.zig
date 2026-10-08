//! The game, apart from drawing it: the world and the player in it, the
//! keys held, the blocks to hand (the hotbar) and the time of day; what
//! the pointer is over, and building with it. Saved and loaded as one
//! file.
//!
//! Controls:
//!
//!     W A S D (or the arrows up and down)   walk (Ctrl: faster)
//!     the arrows left and right             turn
//!     Space                                 jump (flying: rise)
//!     Shift                                 flying: sink
//!     F                                     fly, or walk
//!     drag                                  look around
//!     click                                 place a block
//!     right click, or press and hold        take a block away
//!     middle click                          take that kind of block
//!     1 to 9, or the wheel                  choose a block from the hotbar
//!     E                                     all the blocks
//!     T                                     later in the day
//!     M                                     antialiasing on or off
//!     N                                     bump mapping and ripples on or off
//!     F1                                    help;  F3: what is drawn
//!
//! Every change to the world goes through `edit`, the one place a future
//! network game would send and receive changes.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const player_mod = @import("player.zig");
const math = @import("math.zig");

const Block = blocks.Block;
const World = world_mod.World;
const Player = player_mod.Player;
const V3 = math.V3;

/// Linux key codes (the keys' places, whatever the layout).
pub const keys = struct {
    pub const esc = 1;
    pub const digit_1 = 2;
    pub const digit_9 = 10;
    pub const w = 17;
    pub const e = 18;
    pub const t = 20;
    pub const left_ctrl = 29;
    pub const a = 30;
    pub const s = 31;
    pub const d = 32;
    pub const f = 33;
    pub const m = 50;
    pub const n = 49;
    pub const left_shift = 42;
    pub const right_shift = 54;
    pub const space = 57;
    pub const f1 = 59;
    pub const f3 = 61;
    pub const right_ctrl = 97;
    pub const up = 103;
    pub const left = 105;
    pub const right = 106;
    pub const down = 108;
};

/// How far away blocks can be built on.
pub const reach: f32 = 24;
/// Seconds a day lasts.
pub const day_length: f32 = 600;
/// Radians the view turns for a pixel dragged.
const look_speed: f32 = 0.006;
/// Radians a second the arrow keys turn it.
const turn_speed: f32 = 2.2;
/// Pixels a press can move and still be a click.
const click_slop: f32 = 8;

pub const Game = struct {
    gpa: std.mem.Allocator,
    world: *World,
    player: Player,
    hotbar: [9]Block = blocks.starting_hotbar,
    slot: u8 = 0,
    /// Through the day, from 0 (midnight) to 1; 0.5 is noon.
    time_of_day: f32 = 0.34,
    /// Seconds since the game started (for things that move).
    clock: f32 = 0,
    /// Keys held, by code.
    held: std.StaticBitSet(256) = .initEmpty(),
    palette_open: bool = false,
    help: bool = true,
    stats: bool = false,
    /// Edges antialiased (the GPU's 4x multisampling).
    antialias: bool = true,
    /// Solid blocks lit per pixel from their normal maps.
    bump: bool = true,
    /// The view's size, and the pointer in it (if it is there).
    view_size: [2]f32 = .{ 1, 1 },
    pointer: ?[2]f32 = null,
    /// The block the pointer is over.
    target: ?player_mod.Hit = null,
    /// A press in the view: where, and whether it has become a drag.
    press: ?struct { at: [2]f32, last: [2]f32, dragging: bool } = null,
    /// What happened, shown for a moment.
    message: []const u8 = "",
    message_until: f32 = 0,
    /// The world changed since it was saved.
    unsaved: bool = false,

    pub fn init(gpa: std.mem.Allocator, w: *World) Game {
        return .{ .gpa = gpa, .world = w, .player = .{ .pos = w.spawn, .yaw = w.spawn_yaw } };
    }

    pub fn selected(g: *const Game) Block {
        return g.hotbar[g.slot];
    }

    pub fn camera(g: *const Game) math.Camera {
        return g.player.camera();
    }

    fn say(g: *Game, text: []const u8) void {
        g.message = text;
        g.message_until = g.clock + 2;
    }

    pub fn messageShown(g: *const Game) ?[]const u8 {
        return if (g.clock < g.message_until and g.message.len > 0) g.message else null;
    }

    // --- Input -----------------------------------------------------------------------

    pub fn key(g: *Game, code: u32, pressed: bool) void {
        if (code >= 256) return;
        g.held.setValue(code, pressed);
        if (!pressed) return;
        g.help = g.help and (code == keys.f1);
        switch (code) {
            keys.digit_1...keys.digit_9 => g.choose(@intCast(code - keys.digit_1)),
            keys.f => {
                g.player.flying = !g.player.flying;
                g.player.vel[1] = 0;
                g.say(if (g.player.flying) "Flying" else "Walking");
            },
            keys.e => g.palette_open = !g.palette_open,
            keys.esc => g.palette_open = false,
            keys.t => {
                g.time_of_day = @mod(g.time_of_day + 0.125, 1);
                g.say(timeName(g.time_of_day));
            },
            keys.f1 => g.help = !g.help,
            keys.f3 => g.stats = !g.stats,
            keys.m => {
                g.antialias = !g.antialias;
                g.say(if (g.antialias) "Antialiasing on" else "Antialiasing off");
            },
            keys.n => {
                g.bump = !g.bump;
                g.say(if (g.bump) "Bump mapping and ripples on" else "Bump mapping and ripples off");
            },
            else => {},
        }
    }

    pub fn choose(g: *Game, slot: u8) void {
        g.slot = slot % 9;
        g.say(g.selected().name());
    }

    /// The wheel: the next slot (or the one before).
    pub fn scroll(g: *Game, dy: f32) void {
        const n: i32 = @intCast(g.hotbar.len);
        const step: i32 = if (dy > 0) 1 else -1;
        g.choose(@intCast(@mod(@as(i32, g.slot) + step, n)));
    }

    /// From the palette: puts `b` in the hotbar's slot chosen.
    pub fn pickFromPalette(g: *Game, b: Block) void {
        g.hotbar[g.slot] = b;
        g.palette_open = false;
        g.say(b.name());
    }

    pub fn pointerAt(g: *Game, pos: ?[2]f32) void {
        g.pointer = pos;
        const p = pos orelse return;
        if (g.press) |*pr| {
            const dx = p[0] - pr.last[0];
            const dy = p[1] - pr.last[1];
            if (!pr.dragging and @abs(p[0] - pr.at[0]) + @abs(p[1] - pr.at[1]) > click_slop) pr.dragging = true;
            if (pr.dragging) g.player.look(dx * look_speed, -dy * look_speed);
            pr.last = p;
        }
    }

    pub fn pointerDown(g: *Game, pos: [2]f32) void {
        g.press = .{ .at = pos, .last = pos, .dragging = false };
        g.pointer = pos;
        g.help = false;
    }

    /// The press let go: a click (not a drag) builds.
    pub fn pointerUp(g: *Game) void {
        const pr = g.press orelse return;
        g.press = null;
        if (pr.dragging) return;
        g.updateTarget();
        _ = g.place();
    }

    /// Right click, or a long press.
    pub fn removeAtPointer(g: *Game) void {
        g.press = null;
        g.updateTarget();
        _ = g.remove();
    }

    /// Middle click: the block pointed at goes in the hotbar.
    pub fn pickAtPointer(g: *Game) void {
        g.updateTarget();
        const t = g.target orelse return;
        const b = g.world.get(t.cell[0], t.cell[1], t.cell[2]);
        // Already to hand: just choose it.
        for (g.hotbar, 0..) |h, i| if (h == b) return g.choose(@intCast(i));
        g.hotbar[g.slot] = b;
        g.say(b.name());
    }

    // --- Building -----------------------------------------------------------------------

    /// Changes a block (the one way the world changes).
    pub fn edit(g: *Game, cell: world_mod.Pos, b: Block) bool {
        if (!g.world.set(cell[0], cell[1], cell[2], b)) return false;
        g.unsaved = true;
        return true;
    }

    /// Puts the block chosen against the face pointed at.
    pub fn place(g: *Game) bool {
        const t = g.target orelse return false;
        const b = g.selected();
        if (b.isSolid() and player_mod.blocksPlayer(&g.player, t.before)) return false;
        // Plants need ground.
        if (b.shape() == .plant) {
            const below = g.world.get(t.before[0], t.before[1] - 1, t.before[2]);
            if (!below.isOpaque()) return false;
        }
        const there = g.world.get(t.before[0], t.before[1], t.before[2]);
        if (there != .air and there != .water) return false;
        return g.edit(t.before, b);
    }

    /// Takes away the block pointed at (and a plant on top of it).
    pub fn remove(g: *Game) bool {
        const t = g.target orelse return false;
        const c = t.cell;
        // Water flows in from beside (still water: just its level).
        const fill: Block = if (c[1] < world_mod.sea_level and g.besideWater(c)) .water else .air;
        if (!g.edit(c, fill)) return false;
        const above = g.world.get(c[0], c[1] + 1, c[2]);
        if (above.shape() == .plant) _ = g.edit(.{ c[0], c[1] + 1, c[2] }, .air);
        return true;
    }

    fn besideWater(g: *const Game, c: world_mod.Pos) bool {
        for ([_][3]i32{ .{ 1, 0, 0 }, .{ -1, 0, 0 }, .{ 0, 0, 1 }, .{ 0, 0, -1 }, .{ 0, 1, 0 } }) |d| {
            if (g.world.get(c[0] + d[0], c[1] + d[1], c[2] + d[2]) == .water) return true;
        }
        return false;
    }

    /// What the pointer is over.
    pub fn updateTarget(g: *Game) void {
        const p = g.pointer orelse {
            g.target = null;
            return;
        };
        const cam = g.camera();
        const aspect = g.view_size[0] / @max(g.view_size[1], 1);
        const x = p[0] / @max(g.view_size[0], 1) * 2 - 1;
        const y = 1 - p[1] / @max(g.view_size[1], 1) * 2;
        g.target = player_mod.pick(g.world, cam.eye, cam.ray(aspect, x, y), reach);
    }

    // --- Time ------------------------------------------------------------------------------

    pub fn controls(g: *const Game) player_mod.Controls {
        const h = &g.held;
        const on = struct {
            fn f(set: *const std.StaticBitSet(256), a: u32, b: u32) bool {
                return set.isSet(a) or set.isSet(b);
            }
        }.f;
        var c: player_mod.Controls = .{
            .up = h.isSet(keys.space),
            .down = on(h, keys.left_shift, keys.right_shift),
            .sprint = on(h, keys.left_ctrl, keys.right_ctrl),
        };
        if (on(h, keys.w, keys.up)) c.forward += 1;
        if (on(h, keys.s, keys.down)) c.forward -= 1;
        if (h.isSet(keys.d)) c.strafe += 1;
        if (h.isSet(keys.a)) c.strafe -= 1;
        return c;
    }

    /// Moves everything on by `dt` seconds.
    pub fn tick(g: *Game, dt: f32) void {
        g.clock += dt;
        g.time_of_day = @mod(g.time_of_day + dt / day_length, 1);
        var turn: f32 = 0;
        if (g.held.isSet(keys.left)) turn -= 1;
        if (g.held.isSet(keys.right)) turn += 1;
        if (turn != 0) g.player.look(turn * turn_speed * dt, 0);
        g.player.update(g.world, g.controls(), dt);
        g.updateTarget();
    }

    // --- Saving ---------------------------------------------------------------------------

    const magic = "DZBG";
    const version = 1;

    /// The world, then the player and the hotbar.
    pub fn encode(g: *const Game, out: *std.ArrayList(u8)) !void {
        try g.world.encode(out, g.gpa);
        try out.appendSlice(g.gpa, magic);
        try out.append(g.gpa, version);
        const p = g.player;
        for ([_]f32{ p.pos[0], p.pos[1], p.pos[2], p.yaw, p.pitch, g.time_of_day }) |v| {
            var b: [4]u8 = undefined;
            std.mem.writeInt(u32, &b, @bitCast(v), .little);
            try out.appendSlice(g.gpa, &b);
        }
        try out.append(g.gpa, @intFromBool(p.flying));
        for (g.hotbar) |b| try out.append(g.gpa, @intFromEnum(b));
        try out.append(g.gpa, g.slot);
    }

    /// Reads what `encode` wrote.
    pub fn decode(g: *Game, data: []const u8) !void {
        const at = try g.world.decode(data);
        const rest = data[at..];
        if (rest.len < 5 + 6 * 4 + 1 + 9 + 1 or !std.mem.eql(u8, rest[0..4], magic) or rest[4] != version) return error.Corrupt;
        var f: [6]f32 = undefined;
        for (&f, 0..) |*v, i| v.* = @bitCast(std.mem.readInt(u32, rest[5 + i * 4 ..][0..4], .little));
        for (f) |v| if (!std.math.isFinite(v)) return error.Corrupt;
        g.player = .{ .pos = .{ f[0], f[1], f[2] }, .yaw = f[3], .pitch = std.math.clamp(f[4], -1.55, 1.55), .flying = rest[29] != 0 };
        g.time_of_day = @mod(f[5], 1);
        for (&g.hotbar, rest[30..39]) |*h, b| {
            const blk: Block = @enumFromInt(b);
            h.* = if (blk.isValid() and blk != .air) blk else .stone;
        }
        g.slot = rest[39] % 9;
        g.unsaved = false;
    }
};

pub fn timeName(t: f32) []const u8 {
    return if (t < 0.2) "Night" else if (t < 0.3) "Dawn" else if (t < 0.45) "Morning" else if (t < 0.55) "Noon" else if (t < 0.7) "Afternoon" else if (t < 0.8) "Dusk" else "Night";
}

const testing = std.testing;

fn testGame() !Game {
    const w = try World.create(testing.allocator);
    errdefer w.destroy();
    for (0..world_mod.size_z) |z| for (0..world_mod.size_x) |x| {
        w.blocks[World.index(@intCast(x), 30, @intCast(z))] = .grass;
    };
    try w.computeLight();
    w.spawn = .{ 64.5, 31, 64.5 };
    var g = Game.init(testing.allocator, w);
    g.view_size = .{ 800, 600 };
    return g;
}

test "clicking places the block chosen on the face pointed at; right click takes it away" {
    var g = try testGame();
    defer g.world.destroy();
    // Looking down at the ground ahead.
    g.player.pitch = -0.8;
    g.pointerDown(.{ 400, 300 });
    g.pointerUp();
    const t = g.target.?;
    try testing.expectEqual(blocks.Face.up, t.face);
    try testing.expectEqual(Block.grass, g.world.get(t.before[0], t.before[1], t.before[2]));
    try testing.expect(g.unsaved);
    // Now pointing at the new block: take it away.
    g.removeAtPointer();
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
    // A drag looks around instead.
    const yaw = g.player.yaw;
    g.pointerDown(.{ 400, 300 });
    g.pointerAt(.{ 500, 300 });
    g.pointerUp();
    try testing.expect(g.player.yaw > yaw);
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
}

test "no block inside the player; plants only on the ground" {
    var g = try testGame();
    defer g.world.destroy();
    g.target = .{ .cell = .{ 64, 30, 64 }, .before = .{ 64, 31, 64 }, .face = .up };
    try testing.expect(!g.place());
    g.target = .{ .cell = .{ 70, 30, 64 }, .before = .{ 70, 31, 64 }, .face = .up };
    g.hotbar[0] = .red_flower;
    try testing.expect(g.place());
    // Taking the ground away takes the flower too.
    try testing.expect(g.remove());
    try testing.expectEqual(Block.air, g.world.get(70, 31, 64));
    // A flower in the air: no.
    g.target = .{ .cell = .{ 70, 29, 64 }, .before = .{ 70, 30, 64 }, .face = .up };
    try testing.expect(!g.place());
}

test "keys: walking, choosing, flying, the palette" {
    var g = try testGame();
    defer g.world.destroy();
    const z = g.player.pos[2];
    g.key(keys.w, true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    g.key(keys.w, false);
    try testing.expect(g.player.pos[2] < z - 2);
    g.key(keys.digit_1 + 3, true);
    try testing.expectEqual(@as(u8, 3), g.slot);
    try testing.expectEqualStrings("Log", g.messageShown().?);
    g.scroll(1);
    try testing.expectEqual(@as(u8, 4), g.slot);
    g.slot = 8;
    g.scroll(1);
    try testing.expectEqual(@as(u8, 0), g.slot);
    g.key(keys.f, true);
    try testing.expect(g.player.flying);
    g.key(keys.e, true);
    try testing.expect(g.palette_open);
    g.pickFromPalette(.gold);
    try testing.expect(!g.palette_open);
    try testing.expectEqual(Block.gold, g.selected());
    // A day goes by.
    const t = g.time_of_day;
    g.tick(day_length / 4);
    try testing.expectApproxEqAbs(@mod(t + 0.25, 1), g.time_of_day, 1e-3);
}

test "saving and loading keep the world, the player and the hotbar" {
    var g = try testGame();
    defer g.world.destroy();
    _ = g.edit(.{ 10, 31, 10 }, .lamp);
    g.player.pos = .{ 20.5, 31, 40.5 };
    g.player.yaw = 1.25;
    g.player.flying = true;
    g.hotbar[2] = .cyan;
    g.slot = 2;
    g.time_of_day = 0.8;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try g.encode(&out);
    var h = try testGame();
    defer h.world.destroy();
    try h.decode(out.items);
    try testing.expectEqual(Block.lamp, h.world.get(10, 31, 10));
    try testing.expectEqual(g.player.pos, h.player.pos);
    try testing.expectEqual(@as(f32, 1.25), h.player.yaw);
    try testing.expect(h.player.flying);
    try testing.expectEqual(Block.cyan, h.selected());
    try testing.expectEqual(@as(f32, 0.8), h.time_of_day);
    try testing.expectError(error.Corrupt, h.decode(out.items[0 .. out.items.len - 3]));
}
