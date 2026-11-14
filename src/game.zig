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
//!     Space twice, quickly                  fly, or walk
//!     Shift                                 flying: sink
//!     the mouse                             look around
//!     click                                 place a block
//!     right click                           take a block away
//!     middle click                          take that kind of block
//!     1 to 9, or the wheel                  choose a block from the hotbar
//!     E                                     all the blocks
//!     Esc                                   the menu (the game goes on)
//!     Y, N                                  let someone join, or not
//!
//! The game starts in the menu, which has the options; leaving it takes
//! the mouse (it turns the view), and Esc gives it back with the menu.
//! Where the mouse cannot be taken, dragging looks around, a click builds
//! and pressing and holding takes away.
//!
//! Every change to the world goes through `edit`, which also queues it for
//! the others when playing together (see net.zig, and `Net`).

const std = @import("std");
const kete = @import("kete");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const player_mod = @import("player.zig");
const math = @import("math.zig");

const Block = blocks.Block;
const World = world_mod.World;
const Player = player_mod.Player;
const V3 = math.V3;

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
/// Seconds between two presses of Space that fly (or walk).
const double_tap: f32 = 0.3;

/// A change to the world, as sent to the others.
pub const Edit = struct {
    cell: world_mod.Pos,
    block: Block,
};

/// A game nearby, on the network: its computer's name and where to join it.
pub const Nearby = struct {
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    addr: [4]u8,
    port: u16,

    pub fn name(n: *const Nearby) []const u8 {
        return n.name_buf[0..n.name_len];
    }

    pub fn setName(n: *Nearby, s: []const u8) void {
        n.name_len = @intCast(@min(s.len, n.name_buf.len));
        @memcpy(n.name_buf[0..n.name_len], s[0..n.name_len]);
    }
};

/// Playing together: what net.zig tells the game, and what the game (the
/// menu, the keys) asks of it.
pub const Net = struct {
    status: Status = .alone,
    /// Games nearby, for the menu.
    nearby: []const Nearby = &.{},
    /// One the menu chose to ask to join.
    join: ?Nearby = null,
    /// Leave the game joined (or stop asking).
    leave: bool = false,
    /// Someone asking to join this game (their name), and the answer.
    request: ?[]const u8 = null,
    answer: ?bool = null,
    /// Changes made here, for the others.
    outbox: std.ArrayList(Edit) = .empty,
    /// The others playing, as drawn.
    others: []const player_mod.Other = &.{},

    pub const Status = union(enum) {
        alone,
        /// Others (this many) have joined this game.
        hosting: u8,
        /// Asking the game with this name to join it.
        asking: []const u8,
        /// Playing in the game with this name (its world, not this one).
        joined: []const u8,
    };

    /// Whether changes here go to others.
    pub fn sharing(n: *const Net) bool {
        return switch (n.status) {
            .hosting => |count| count > 0,
            .joined => true,
            else => false,
        };
    }
};

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
    /// Keys held.
    held: std.EnumSet(kete.KeyboardKey) = .empty,
    /// When Space was last pressed, if a second press now would be a
    /// double tap.
    space_at: ?f32 = null,
    palette_open: bool = false,
    /// The menu: the game's options, over the game, which goes on behind
    /// it (the player standing still). The game starts in it, so the mouse
    /// is not taken before it is wanted.
    menu_open: bool = true,
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
    /// The mouse can be taken (the shell can lock the pointer), and is:
    /// it turns the view, and its buttons act on the block in the middle.
    can_capture: bool = false,
    captured: bool = false,
    /// For the window: take the mouse (true) or give it back (false).
    capture_wanted: ?bool = null,
    /// What happened, shown for a moment.
    message: []const u8 = "",
    message_until: f32 = 0,
    /// The world changed since it was saved.
    unsaved: bool = false,
    /// Playing together.
    net: Net = .{},

    pub fn init(gpa: std.mem.Allocator, w: *World) Game {
        return .{ .gpa = gpa, .world = w, .player = .{ .pos = w.spawn, .yaw = w.spawn_yaw } };
    }

    pub fn deinit(g: *Game) void {
        g.net.outbox.deinit(g.gpa);
    }

    pub fn selected(g: *const Game) Block {
        return g.hotbar[g.slot];
    }

    pub fn camera(g: *const Game) math.Camera {
        return g.player.camera();
    }

    pub fn say(g: *Game, text: []const u8) void {
        g.message = text;
        g.message_until = g.clock + 2;
    }

    pub fn messageShown(g: *const Game) ?[]const u8 {
        return if (g.clock < g.message_until and g.message.len > 0) g.message else null;
    }

    // --- Input -----------------------------------------------------------------------

    /// A key went down or up (where it is on the keyboard, whatever the
    /// layout: WASD are where they are).
    pub fn key(g: *Game, code: kete.KeyboardKey, pressed: bool) void {
        const was_held = g.held.contains(code);
        g.held.setPresent(code, pressed);
        if (!pressed or was_held) return;
        // Someone asking to join: Y lets them, N does not (in the menu
        // too).
        if (g.net.request != null and (code == .y or code == .n)) {
            g.net.answer = code == .y;
            return;
        }
        // In the menu, only Esc (back to the game) does anything.
        if (g.menu_open) {
            if (code == .escape) g.closeMenu();
            return;
        }
        switch (code) {
            .digit_1, .digit_2, .digit_3, .digit_4, .digit_5, .digit_6, .digit_7, .digit_8, .digit_9 => g.choose(@intCast(@intFromEnum(code) - @intFromEnum(kete.KeyboardKey.digit_1))),
            .space => {
                if (g.space_at) |at| if (g.clock - at <= double_tap) {
                    g.player.flying = !g.player.flying;
                    g.player.vel[1] = 0;
                    g.say(if (g.player.flying) "Flying" else "Walking");
                    // A third press starts again.
                    g.space_at = null;
                    return;
                };
                g.space_at = g.clock;
            },
            .e => if (g.palette_open) g.closePalette() else {
                g.palette_open = true;
                // Its blocks are chosen with the pointer.
                if (g.captured) g.capture_wanted = false;
            },
            .escape => if (g.palette_open) g.closePalette() else g.openMenu(),
            else => {},
        }
    }

    /// The menu, over the game (which goes on): the mouse is given back to
    /// use the menu with.
    pub fn openMenu(g: *Game) void {
        g.menu_open = true;
        g.palette_open = false;
        g.press = null;
        if (g.captured) g.capture_wanted = false;
    }

    /// Back to the game, which takes the mouse.
    pub fn closeMenu(g: *Game) void {
        g.menu_open = false;
        g.takeMouse();
    }

    fn closePalette(g: *Game) void {
        g.palette_open = false;
        g.takeMouse();
    }

    /// In the game, the mouse is taken if it can be.
    fn takeMouse(g: *Game) void {
        if (g.can_capture and !g.captured) g.capture_wanted = true;
    }

    /// The window took the mouse, or gave it back. Given back while
    /// playing (the shell took it): the menu, as Esc would.
    pub fn pointerLocked(g: *Game, locked: bool) void {
        g.captured = locked;
        if (!locked and !g.menu_open and !g.palette_open) g.openMenu();
    }

    // Playing together (from the menu and the request shown).

    /// Lets the player asking join (Y).
    pub fn allowJoin(g: *Game) void {
        if (g.net.request != null) g.net.answer = true;
    }

    /// Does not (N).
    pub fn denyJoin(g: *Game) void {
        if (g.net.request != null) g.net.answer = false;
    }

    /// Asks the game `n` (from the menu) to join it.
    pub fn joinNearby(g: *Game, n: Nearby) void {
        g.net.join = n;
    }

    /// Leaves the game joined, back to this island.
    pub fn leaveGame(g: *Game) void {
        g.net.leave = true;
    }

    /// Joined: plays in the host's world (`data`, as `World.encode` wrote
    /// it), standing at `pos`; back to the game, from the menu.
    pub fn joinWorld(g: *Game, data: []const u8, pos: V3, yaw: f32, time: f32) !void {
        _ = try g.world.decode(data);
        g.player = .{ .pos = pos, .yaw = yaw };
        g.time_of_day = @mod(time, 1);
        g.target = null;
        g.unsaved = false;
        g.closeMenu();
    }

    /// Whether there are changes to save here: only in this computer's
    /// own world (alone, or hosting, with the guests' changes too), not in
    /// a game joined (its host saves that).
    pub fn wantsSave(g: *const Game) bool {
        return g.unsaved and g.net.status != .joined;
    }

    /// A change another player made.
    pub fn editFromNetwork(g: *Game, e: Edit) void {
        if (g.world.set(e.cell[0], e.cell[1], e.cell[2], e.block)) g.unsaved = true;
    }

    // The options, set from the menu (and only there: they have no keys).

    pub fn setAntialias(g: *Game, on: bool) void {
        g.antialias = on;
    }

    pub fn setBump(g: *Game, on: bool) void {
        g.bump = on;
    }

    pub fn setHelp(g: *Game, on: bool) void {
        g.help = on;
    }

    pub fn setStats(g: *Game, on: bool) void {
        g.stats = on;
    }

    /// Through the day, 0 (midnight) to 1.
    pub fn setTimeOfDay(g: *Game, t: f32) void {
        g.time_of_day = @mod(t, 1);
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
        g.closePalette();
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
    }

    /// The press let go: a click (not a drag) takes the mouse, if it can
    /// be; otherwise builds.
    pub fn pointerUp(g: *Game) void {
        const pr = g.press orelse return;
        g.press = null;
        if (pr.dragging) return;
        if (g.can_capture and !g.captured) {
            g.capture_wanted = true;
            return;
        }
        g.updateTarget();
        _ = g.place();
    }

    /// The mouse moved by (`dx`, `dy`) pixels while taken: the view turns.
    pub fn mouseMoved(g: *Game, dx: f32, dy: f32) void {
        g.player.look(dx * look_speed, -dy * look_speed);
    }

    /// A button pressed while the mouse is taken: on the block in the
    /// middle, the left builds, the right takes away, the middle picks.
    pub fn mouseButton(g: *Game, code: kete.PointerButton, pressed: bool) void {
        if (!pressed) return;
        g.updateTarget();
        switch (code) {
            .left => _ = g.place(),
            .right => _ = g.remove(),
            .middle => g.pickAtPointer(),
            else => {},
        }
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
        if (g.net.sharing()) g.net.outbox.append(g.gpa, .{ .cell = cell, .block = b }) catch {};
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

    /// What the pointer is over (with the mouse taken, what is in the
    /// middle of the view).
    pub fn updateTarget(g: *Game) void {
        const middle: [2]f32 = .{ g.view_size[0] / 2, g.view_size[1] / 2 };
        const p = (if (g.captured) middle else g.pointer) orelse {
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
            fn f(set: *const std.EnumSet(kete.KeyboardKey), a: kete.KeyboardKey, b: kete.KeyboardKey) bool {
                return set.contains(a) or set.contains(b);
            }
        }.f;
        var c: player_mod.Controls = .{
            .up = h.contains(.space),
            .down = on(h, .left_shift, .right_shift),
            .sprint = on(h, .left_ctrl, .right_ctrl),
        };
        if (on(h, .w, .up)) c.forward += 1;
        if (on(h, .s, .down)) c.forward -= 1;
        if (h.contains(.d)) c.strafe += 1;
        if (h.contains(.a)) c.strafe -= 1;
        return c;
    }

    /// Moves everything on by `dt` seconds.
    /// The game goes on behind the menu, but the keys held do not move the
    /// player there.
    pub fn tick(g: *Game, dt: f32) void {
        g.clock += dt;
        g.time_of_day = @mod(g.time_of_day + dt / day_length, 1);
        var turn: f32 = 0;
        if (!g.menu_open) {
            if (g.held.contains(.left)) turn -= 1;
            if (g.held.contains(.right)) turn += 1;
        }
        if (turn != 0) g.player.look(turn * turn_speed * dt, 0);
        g.player.update(g.world, if (g.menu_open) .{} else g.controls(), dt);
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
    // Playing, not in the menu it starts in.
    g.menu_open = false;
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

test "with the mouse taken, it turns the view and builds on the middle of it" {
    var g = try testGame();
    defer g.world.destroy();
    g.player.pitch = -0.8;
    // A click asks for the mouse, and builds nothing.
    g.can_capture = true;
    g.pointerDown(.{ 10, 10 });
    g.pointerUp();
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    try testing.expect(!g.unsaved);
    // Taken: the pointer's place no longer matters, the middle does.
    g.capture_wanted = null;
    g.captured = true;
    g.pointer = .{ 10, 10 };
    g.mouseButton(.left, true);
    const t = g.target.?;
    try testing.expectEqual(Block.grass, g.world.get(t.before[0], t.before[1], t.before[2]));
    g.mouseButton(.right, true);
    try testing.expectEqual(Block.air, g.world.get(t.before[0], t.before[1], t.before[2]));
    // Moving it turns the view; Esc gives it back (and opens the menu).
    const yaw = g.player.yaw;
    g.mouseMoved(100, 0);
    try testing.expect(g.player.yaw > yaw);
    g.key(.escape, true);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
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
    g.key(.w, true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    g.key(.w, false);
    try testing.expect(g.player.pos[2] < z - 2);
    g.key(.digit_4, true);
    try testing.expectEqual(@as(u8, 3), g.slot);
    try testing.expectEqualStrings("Log", g.messageShown().?);
    g.scroll(1);
    try testing.expectEqual(@as(u8, 4), g.slot);
    g.slot = 8;
    g.scroll(1);
    try testing.expectEqual(@as(u8, 0), g.slot);
    // Space twice, quickly, flies.
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(!g.player.flying);
    g.tick(0.1);
    g.key(.space, true);
    try testing.expect(g.player.flying);
    // Holding it (repeat presses) does not toggle it back off.
    g.key(.space, true);
    try testing.expect(g.player.flying);
    g.key(.space, false);
    // A third press soon after is the first of the next double tap.
    g.tick(0.1);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(g.player.flying);
    // Twice, but slowly: still flying.
    g.tick(0.5);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(g.player.flying);
    // Then twice quickly: walking again.
    g.tick(0.1);
    g.key(.space, true);
    g.key(.space, false);
    try testing.expect(!g.player.flying);
    g.key(.e, true);
    try testing.expect(g.palette_open);
    g.pickFromPalette(.gold);
    try testing.expect(!g.palette_open);
    try testing.expectEqual(Block.gold, g.selected());
    // A day goes by.
    const t = g.time_of_day;
    g.tick(day_length / 4);
    try testing.expectApproxEqAbs(@mod(t + 0.25, 1), g.time_of_day, 1e-3);
}

test "the game starts in the menu; leaving it takes the mouse, and Esc gives it back with the menu" {
    var g = try testGame();
    defer g.world.destroy();
    const fresh = Game.init(testing.allocator, g.world);
    try testing.expect(fresh.menu_open);
    g.can_capture = true;
    g.menu_open = true;
    // Esc on the menu: back to the game, which takes the mouse.
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(!g.menu_open);
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    // Esc in the game: the menu, and the mouse given back.
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(g.menu_open);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(false);
    // The game goes on (time passes), but keys do nothing: the player
    // stands still, and the palette stays shut.
    const t = g.time_of_day;
    const pos = g.player.pos;
    g.key(.w, true);
    g.key(.e, true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    try testing.expect(g.time_of_day != t);
    try testing.expectApproxEqAbs(pos[0], g.player.pos[0], 1e-4);
    try testing.expectApproxEqAbs(pos[2], g.player.pos[2], 1e-4);
    try testing.expect(!g.palette_open);
    // Resume: W still held walks again.
    g.closeMenu();
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    for (0..30) |_| g.tick(1.0 / 30.0);
    try testing.expect(g.player.pos[2] < pos[2] - 1);
    g.key(.w, false);
    g.key(.e, false);
    // The palette gives the mouse back to pick with; Esc closes it (not
    // opening the menu) and takes the mouse again.
    g.key(.e, true);
    g.key(.e, false);
    try testing.expectEqual(@as(?bool, false), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(false);
    try testing.expect(g.palette_open and !g.menu_open);
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(!g.palette_open and !g.menu_open);
    try testing.expectEqual(@as(?bool, true), g.capture_wanted);
    g.capture_wanted = null;
    g.pointerLocked(true);
    // The mouse taken away while playing (by the shell): the menu.
    g.pointerLocked(false);
    try testing.expect(g.menu_open);
}

test "the host saves, the guests' changes too; a game joined is not saved here" {
    var g = try testGame();
    defer g.world.destroy();
    defer g.deinit();
    g.net.status = .{ .hosting = 1 };
    g.editFromNetwork(.{ .cell = .{ 10, 31, 10 }, .block = .bricks });
    try testing.expect(g.wantsSave());
    g.unsaved = false;
    _ = g.edit(.{ 11, 31, 10 }, .lamp);
    try testing.expect(g.wantsSave());
    // Joined: changes, but not this computer's world to save.
    g.net.status = .{ .joined = "host-pi" };
    _ = g.edit(.{ 12, 31, 10 }, .gold);
    try testing.expect(g.unsaved and !g.wantsSave());
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
