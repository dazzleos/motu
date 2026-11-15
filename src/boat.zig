//! A canoe being paddled. Right-clicking a canoe takes it (and the
//! canoes in a row with it: one canoe) out of the world, the player in
//! it; W and S paddle it forward and back, A and D turn it, and Shift
//! gets out, the canoe put back as blocks, the way it is pointing most.
//!
//! It moves at the level of the blocks it was in: quickly over water
//! (sitting down in it), slowly over level ground (dragged), and not at
//! all where there is something in the way or nothing under it.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const furniture = @import("furniture.zig");
const player_mod = @import("player.zig");
const math = @import("math.zig");

const Block = blocks.Block;
const World = world_mod.World;
const V3 = math.V3;

/// Top speeds (blocks a second): on water, and dragged over land.
pub const water_speed: f32 = 5;
pub const land_speed: f32 = 1.2;
/// How quickly it gets up to speed, or slows (blocks a second, each
/// second).
const pull: f32 = 4;
/// How quickly it turns (radians a second).
const turn_speed: f32 = 1.5;

/// How far below the hull's bottom the player's feet are taken to be, as
/// they sit in it (so their eyes are a little over its sides).
pub const seat_drop: f32 = player_mod.eye_height - 0.95;

/// A canoe as drawn: the middle of its hull's bottom, its way and length.
pub const Shown = struct {
    pos: V3,
    yaw: f32,
    len: u8,
};

pub const Boat = struct {
    /// The middle of the hull, at the bottom of the blocks it moves in.
    pos: V3,
    /// The way its bow points (as the player's yaw: 0 is -z, turning to
    /// +x).
    yaw: f32,
    len: u8,
    speed: f32 = 0,
    /// How far down it sits (in water).
    sink: f32 = 0,

    /// The canoe a canoe block is part of, as a boat (its blocks still
    /// to be taken away: `row`).
    pub fn of(w: *const World, cell: world_mod.Pos) Boat {
        const r = furniture.canoeRow(w, cell);
        const half = @as(f32, @floatFromInt(r.len)) / 2;
        const s: [3]f32 = .{ @floatFromInt(r.start[0]), @floatFromInt(r.start[1]), @floatFromInt(r.start[2]) };
        // Raised to the water's surface, if it was in the water.
        const y = @max(s[1], world_mod.sea_level);
        const pos: V3 = if (r.along_x) .{ s[0] + half, y, s[2] + furniture.canoe_centre } else .{ s[0] + furniture.canoe_centre, y, s[2] + half };
        var b: Boat = .{ .pos = pos, .yaw = if (r.along_x) std.math.pi / 2.0 else 0, .len = @intCast(r.len) };
        b.sink = if (b.onWater(w)) furniture.float_depth else 0;
        return b;
    }

    pub fn forward(b: Boat) V3 {
        return .{ @sin(b.yaw), 0, -@cos(b.yaw) };
    }

    fn right(b: Boat) V3 {
        return .{ @cos(b.yaw), 0, @sin(b.yaw) };
    }

    fn level(b: Boat) i32 {
        return @intFromFloat(@floor(b.pos[1] + 0.01));
    }

    pub fn onWater(b: Boat, w: *const World) bool {
        const c = cellAt(b.pos);
        return w.wateryAt(c[0], b.level() - 1, c[2]);
    }

    /// Whether it fits at `pos`, pointing `yaw`: nothing solid where its
    /// hull and outrigger are, and water or ground under them.
    pub fn fits(b: Boat, w: *const World, pos: V3, yaw: f32) bool {
        var at = b;
        at.pos = pos;
        at.yaw = yaw;
        const y = b.level();
        const half = @as(f32, @floatFromInt(b.len)) / 2 - 0.2;
        var along = -half;
        while (along <= half + 0.01) : (along += 0.5) {
            for ([_]f32{ -0.22, 0, 0.5 }) |across| {
                const p = pos + at.forward() * math.splat(along) + at.right() * math.splat(across);
                const c = cellAt(p);
                if (w.get(c[0], y, c[2]).isSolid()) return false;
                const under = w.get(c[0], y - 1, c[2]);
                if (!w.wateryAt(c[0], y - 1, c[2]) and !under.isSolid()) return false;
            }
        }
        return true;
    }

    /// Paddles on by `dt` seconds.
    pub fn update(b: *Boat, w: *const World, c: player_mod.Controls, dt: f32) void {
        const wet = b.onWater(w);
        const top: f32 = if (wet) water_speed else land_speed;
        const want = std.math.clamp(c.forward, -0.5, 1) * top;
        b.speed += std.math.clamp(want - b.speed, -pull * dt, pull * dt);
        // Turning: more slowly on land.
        const yaw = b.yaw + c.strafe * turn_speed * dt * @as(f32, if (wet) 1 else 0.5);
        if (b.fits(w, b.pos, yaw)) b.yaw = yaw;
        const next = b.pos + b.forward() * math.splat(b.speed * dt);
        if (b.fits(w, next, b.yaw)) b.pos = next else b.speed = 0;
        // Settling into the water, or rising out of it.
        const sink: f32 = if (b.onWater(w)) furniture.float_depth else 0;
        b.sink += std.math.clamp(sink - b.sink, -dt, dt);
    }

    pub fn shown(b: Boat) Shown {
        return .{ .pos = .{ b.pos[0], b.pos[1] - b.sink, b.pos[2] }, .yaw = b.yaw, .len = b.len };
    }

    /// Where the player's feet are, sitting in it.
    pub fn seat(b: Boat) V3 {
        return .{ b.pos[0], b.pos[1] - b.sink - seat_drop, b.pos[2] };
    }

    /// The blocks it would be as a canoe here: along the way it points
    /// most, its middle where it is.
    pub fn row(b: Boat) furniture.Row {
        const along_x = @abs(@sin(b.yaw)) > @abs(@cos(b.yaw));
        const half = @as(f32, @floatFromInt(b.len)) / 2;
        const y = b.level();
        const start: [3]i32 = if (along_x)
            .{ @intFromFloat(@round(b.pos[0] - half)), y, @intFromFloat(@floor(b.pos[2] - furniture.canoe_centre + 0.5)) }
        else
            .{ @intFromFloat(@floor(b.pos[0] - furniture.canoe_centre + 0.5)), y, @intFromFloat(@round(b.pos[2] - half)) };
        return .{ .start = start, .along_x = along_x, .len = b.len };
    }

    /// Whether it can be put back as blocks where it is.
    pub fn canLeave(b: Boat, w: *const World) bool {
        const r = b.row();
        var k: i32 = 0;
        while (k < r.len) : (k += 1) {
            const c = r.cell(k);
            if (w.get(c[0], c[1], c[2]) != .air or !World.inBounds(c[0], c[1], c[2])) return false;
        }
        return true;
    }
};

fn cellAt(p: V3) world_mod.Pos {
    return .{ @intFromFloat(@floor(p[0])), @intFromFloat(@floor(p[1])), @intFromFloat(@floor(p[2])) };
}

const testing = std.testing;

/// Sea at y < sea_level everywhere but a beach (sand, to the sea's
/// level) at x >= 40.
fn bayWorld() !*World {
    const w = try World.create(testing.allocator);
    for (0..world_mod.size_z) |zu| for (0..world_mod.size_x) |xu| for (0..world_mod.sea_level) |yu| {
        const beach = xu >= 40;
        w.blocks[World.index(@intCast(xu), @intCast(yu), @intCast(zu))] = if (beach or yu < world_mod.sea_level - 4) .sand else .water;
    };
    try w.computeLight();
    return w;
}

test "a canoe on the beach: taken as a boat, paddled out over the water, quicker there" {
    const w = try bayWorld();
    defer w.destroy();
    const y = world_mod.sea_level;
    for ([_]i32{ 41, 42, 43 }) |x| _ = w.set(x, y, 50, .canoe);
    var b = Boat.of(w, .{ 42, y, 50 });
    try testing.expectEqual(@as(u8, 3), b.len);
    try testing.expectApproxEqAbs(@as(f32, 42.5), b.pos[0], 0.001);
    for ([_]i32{ 41, 42, 43 }) |x| _ = w.set(x, y, 50, .air);
    // Turned to face the sea (-x), on land: slowly.
    b.yaw = -std.math.pi / 2.0;
    try testing.expect(!b.onWater(w));
    for (0..30) |_| b.update(w, .{ .forward = 1 }, 1.0 / 30.0);
    try testing.expect(b.speed <= land_speed + 0.001);
    // On the water: faster, and down in it.
    for (0..90) |_| b.update(w, .{ .forward = 1 }, 1.0 / 30.0);
    try testing.expect(b.onWater(w));
    try testing.expect(b.speed > land_speed + 1);
    try testing.expect(b.pos[0] < 40);
    try testing.expect(b.sink > 0);
    // Out again, back on the sand: blocks along x.
    b.yaw = std.math.pi / 2.0 + 0.1;
    try testing.expect(b.canLeave(w));
    const r = b.row();
    try testing.expect(r.along_x and r.len == 3 and r.start[1] == y);
}

test "a boat stops at what is in its way" {
    const w = try bayWorld();
    defer w.destroy();
    const y = world_mod.sea_level;
    _ = w.set(20, y, 50, .canoe);
    var b = Boat.of(w, .{ 20, y, 50 });
    _ = w.set(20, y, 50, .air);
    b.yaw = 0;
    // A wall ahead (-z).
    for (0..5) |k| _ = w.set(18 + @as(i32, @intCast(k)), y, 46, .volcanic_wall);
    for (0..120) |_| b.update(w, .{ .forward = 1 }, 1.0 / 30.0);
    try testing.expect(b.pos[2] > 46.5);
    try testing.expect(b.pos[2] < 49);
}
