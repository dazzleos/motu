//! The player: a box 0.6 blocks across and 1.8 high that walks (with
//! gravity, jumping, swimming and climbing ladders) or flies, stepping up
//! onto what is half a block high, and does not go through solid blocks
//! (or their solid part: a slab's lower half); and picking the block a ray
//! from the eye meets.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const math = @import("math.zig");

const World = world_mod.World;
const V3 = math.V3;

pub const half_width: f32 = 0.3;
pub const height: f32 = 1.8;
pub const eye_height: f32 = 1.62;

const gravity: f32 = 28;
const jump_speed: f32 = 8.6;
const walk_speed: f32 = 4.5;
const sprint_speed: f32 = 7.5;
const fly_speed: f32 = 11;
const swim_speed: f32 = 3;
const climb_speed: f32 = 3;
const creep_speed: f32 = 1.4;
/// How high a step it walks up without jumping.
const step_up: f32 = 0.55;

/// What the player is asked to do, this moment.
pub const Controls = struct {
    /// Forward (+1) or back (-1), and right (+1) or left (-1).
    forward: f32 = 0,
    strafe: f32 = 0,
    /// Jump (or, flying, rise), and (flying) sink.
    up: bool = false,
    down: bool = false,
    sprint: bool = false,
};

/// Colours players are told apart by (one for each in a game).
pub const colours = 8;

/// Another player (on the network), as drawn: their feet, the way they
/// face (as `Player.yaw`) and their colour.
pub const Other = struct {
    pos: V3,
    yaw: f32,
    colour: u3,
};

pub const Player = struct {
    /// Feet, in the middle.
    pos: V3,
    vel: V3 = .{ 0, 0, 0 },
    yaw: f32 = 0,
    pitch: f32 = -0.15,
    flying: bool = false,
    on_ground: bool = false,

    pub fn eye(p: *const Player) V3 {
        return p.pos + V3{ 0, eye_height, 0 };
    }

    pub fn camera(p: *const Player) math.Camera {
        return .{ .eye = p.eye(), .yaw = p.yaw, .pitch = p.pitch };
    }

    /// Turns by dx (right) and dy (up), in radians.
    pub fn look(p: *Player, dx: f32, dy: f32) void {
        p.yaw = @mod(p.yaw + dx, 2 * std.math.pi);
        p.pitch = std.math.clamp(p.pitch + dy, -1.55, 1.55);
    }

    /// Whether the eye is in water.
    pub fn underwater(p: *const Player, w: *const World) bool {
        const e = p.eye();
        const ex: i32 = @intFromFloat(@floor(e[0]));
        const ey: i32 = @intFromFloat(@floor(e[1]));
        const ez: i32 = @intFromFloat(@floor(e[2]));
        if (!w.wateryAt(ex, ey, ez)) return false;
        // Above a surface block's surface is out of the water.
        return w.wateryAt(ex, ey + 1, ez) or e[1] - @floor(e[1]) < 0.875;
    }

    fn inWater(p: *const Player, w: *const World) bool {
        const x: i32 = @intFromFloat(@floor(p.pos[0]));
        const z: i32 = @intFromFloat(@floor(p.pos[2]));
        return w.wateryAt(x, @intFromFloat(@floor(p.pos[1] + 0.4)), z);
    }

    /// Whether it is at a ladder (its feet or its middle in one).
    fn onLadder(p: *const Player, w: *const World) bool {
        const x: i32 = @intFromFloat(@floor(p.pos[0]));
        const z: i32 = @intFromFloat(@floor(p.pos[2]));
        return w.get(x, @intFromFloat(@floor(p.pos[1] + 0.1)), z) == .ladder or w.get(x, @intFromFloat(@floor(p.pos[1] + 1)), z) == .ladder;
    }

    /// Moves the player on by `dt` seconds.
    pub fn update(p: *Player, w: *const World, c: Controls, dt_in: f32) void {
        const dt = @min(dt_in, 0.1);
        // Which way the controls push, on the level.
        const fwd = V3{ @sin(p.yaw), 0, -@cos(p.yaw) };
        const right = V3{ @cos(p.yaw), 0, @sin(p.yaw) };
        var wish = fwd * math.splat(c.forward) + right * math.splat(c.strafe);
        const len = math.length(wish);
        if (len > 1) wish /= math.splat(len);
        const swimming = !p.flying and p.inWater(w);
        const climbing = !p.flying and p.onLadder(w);
        const was_on_ground = p.on_ground;
        const speed: f32 = if (p.flying) fly_speed * @as(f32, if (c.sprint) 1.6 else 1) else if (swimming) swim_speed * @as(f32, if (c.sprint) 1.4 else 1) else if (c.down) creep_speed else if (c.sprint) sprint_speed else walk_speed;
        // Speed up quickly towards what is wanted (slower in the air).
        const target = wish * math.splat(speed);
        const grip: f32 = if (p.flying or p.on_ground) 14 else if (swimming) 6 else 3;
        const k = @min(1, grip * dt);
        p.vel[0] += (target[0] - p.vel[0]) * k;
        p.vel[2] += (target[2] - p.vel[2]) * k;
        if (p.flying) {
            const vy: f32 = (if (c.up) speed else 0) - (if (c.down) speed else 0);
            p.vel[1] += (vy - p.vel[1]) * k;
        } else if (climbing) {
            // Up a ladder going on (or jumping), down it backing off (or
            // sinking); else, holding on, slowly down.
            const vy: f32 = if (c.up or c.forward > 0) climb_speed else if (c.down or c.forward < 0) -climb_speed else -0.5;
            p.vel[1] = vy;
        } else if (swimming) {
            // Sink slowly; swim up, or (Shift) down.
            p.vel[1] -= gravity * 0.2 * dt;
            if (c.up) p.vel[1] = @max(p.vel[1], 3.5);
            if (c.down) p.vel[1] = @min(p.vel[1], -3);
            p.vel[1] = @max(p.vel[1], -3.5);
        } else {
            p.vel[1] -= gravity * dt;
            if (c.up and p.on_ground) p.vel[1] = jump_speed;
            p.vel[1] = @max(p.vel[1], -40);
        }
        p.on_ground = false;
        // Each axis on its own, stopping at what is solid.
        inline for (.{ 0, 2, 1 }) |axis| {
            const d = p.vel[axis] * dt;
            if (d != 0) {
                p.pos[axis] += d;
                // A step up onto something low, walking into it.
                if (axis != 1 and p.collides(w) and (was_on_ground or climbing) and !p.flying) {
                    p.pos[1] += step_up;
                    if (p.collides(w)) p.pos[1] -= step_up;
                }
                if (p.collides(w)) {
                    p.pos[axis] -= d;
                    // Up to the block, nearly touching it.
                    p.pos[axis] += p.approach(w, axis, d);
                    if (axis == 1 and d < 0) p.on_ground = true;
                    p.vel[axis] = 0;
                }
            }
        }
        // In the world, across.
        const margin = half_width + 0.01;
        p.pos[0] = std.math.clamp(p.pos[0], margin, world_mod.size_x - margin);
        p.pos[2] = std.math.clamp(p.pos[2], margin, world_mod.size_z - margin);
        if (p.pos[1] < 0) {
            p.pos[1] = 0;
            p.vel[1] = 0;
            p.on_ground = true;
        }
    }

    /// How far along `axis` it can go of `d` before it meets something.
    fn approach(p: *Player, w: *const World, comptime axis: usize, d: f32) f32 {
        var lo: f32 = 0;
        var hi: f32 = 1;
        for (0..8) |_| {
            const mid = (lo + hi) / 2;
            p.pos[axis] += d * mid;
            if (p.collides(w)) hi = mid else lo = mid;
            p.pos[axis] -= d * mid;
        }
        return d * lo;
    }

    pub fn collides(p: *const Player, w: *const World) bool {
        return boxHitsSolid(w, p.pos - V3{ half_width, 0, half_width }, p.pos + V3{ half_width, height, half_width });
    }
};

fn boxHitsSolid(w: *const World, min: V3, max: V3) bool {
    const x0: i32 = @intFromFloat(@floor(min[0]));
    const y0: i32 = @intFromFloat(@floor(min[1]));
    const z0: i32 = @intFromFloat(@floor(min[2]));
    const x1: i32 = @intFromFloat(@floor(max[0] - 1e-4));
    const y1: i32 = @intFromFloat(@floor(max[1] - 1e-4));
    const z1: i32 = @intFromFloat(@floor(max[2] - 1e-4));
    var y = y0;
    while (y <= y1) : (y += 1) {
        var z = z0;
        while (z <= z1) : (z += 1) {
            var x = x0;
            while (x <= x1) : (x += 1) {
                // Only its solid part: a slab's lower half.
                const h = w.get(x, y, z).solidHeight();
                if (h > 0 and min[1] < @as(f32, @floatFromInt(y)) + h) return true;
            }
        }
    }
    return false;
}

/// Whether a block at `cell` would be where the player is.
pub fn blocksPlayer(p: *const Player, cell: world_mod.Pos) bool {
    const min: [3]f32 = p.pos - V3{ half_width, 0, half_width };
    const max: [3]f32 = p.pos + V3{ half_width, height, half_width };
    for (0..3) |i| {
        const c: f32 = @floatFromInt(cell[i]);
        if (c + 1 <= min[i] or c >= max[i]) return false;
    }
    return true;
}

pub const Hit = struct {
    /// The block met.
    cell: world_mod.Pos,
    /// The empty place before it, where a block would go.
    before: world_mod.Pos,
    /// The face it was met on.
    face: blocks.Face,
};

/// The first block (not air or water) along a ray, within `reach`.
pub fn pick(w: *const World, origin_v: V3, dir_v: V3, reach: f32) ?Hit {
    const origin: [3]f32 = origin_v;
    const dir: [3]f32 = dir_v;
    var cell = world_mod.Pos{ @intFromFloat(@floor(origin[0])), @intFromFloat(@floor(origin[1])), @intFromFloat(@floor(origin[2])) };
    var step: [3]i32 = undefined;
    var t_max: [3]f32 = undefined;
    var t_delta: [3]f32 = undefined;
    for (0..3) |i| {
        if (dir[i] > 0) {
            step[i] = 1;
            t_max[i] = (@as(f32, @floatFromInt(cell[i] + 1)) - origin[i]) / dir[i];
        } else if (dir[i] < 0) {
            step[i] = -1;
            t_max[i] = (origin[i] - @as(f32, @floatFromInt(cell[i]))) / -dir[i];
        } else {
            step[i] = 0;
            t_max[i] = std.math.inf(f32);
        }
        t_delta[i] = if (dir[i] != 0) @abs(1 / dir[i]) else std.math.inf(f32);
    }
    var before = cell;
    var face: blocks.Face = .up;
    var t: f32 = 0;
    while (t <= reach) {
        const b = w.get(cell[0], cell[1], cell[2]);
        if (b != .air and b != .water and World.inBounds(cell[0], cell[1], cell[2])) return .{ .cell = cell, .before = before, .face = face };
        // Into the next cell, across the nearest boundary.
        const axis: usize = if (t_max[0] < t_max[1]) (if (t_max[0] < t_max[2]) 0 else 2) else (if (t_max[1] < t_max[2]) 1 else 2);
        before = cell;
        cell[axis] += step[axis];
        t = t_max[axis];
        t_max[axis] += t_delta[axis];
        // The face met is the one facing back along the step.
        face = switch (axis) {
            0 => if (step[0] > 0) .west else .east,
            1 => if (step[1] > 0) .down else .up,
            else => if (step[2] > 0) .north else .south,
        };
        if (cell[1] < -1 or cell[1] > world_mod.size_y) return null;
    }
    return null;
}

const testing = std.testing;

fn flatWorld() !*World {
    const w = try World.create(testing.allocator);
    for (0..world_mod.size_z) |z| for (0..world_mod.size_x) |x| {
        w.blocks[World.index(@intCast(x), 30, @intCast(z))] = .volcanic_rock;
    };
    try w.computeLight();
    return w;
}

test "falling, landing, walking, jumping, and walls" {
    const w = try flatWorld();
    defer w.destroy();
    var p: Player = .{ .pos = .{ 20.5, 40, 20.5 } };
    for (0..120) |_| p.update(w, .{}, 1.0 / 60.0);
    try testing.expect(p.on_ground);
    try testing.expectApproxEqAbs(@as(f32, 31), p.pos[1], 0.01);
    // Walking north (yaw 0 faces -z).
    const z0 = p.pos[2];
    for (0..60) |_| p.update(w, .{ .forward = 1 }, 1.0 / 60.0);
    try testing.expect(z0 - p.pos[2] > 3.5);
    // A jump goes up over a block's height, then lands again.
    var top: f32 = 0;
    p.update(w, .{ .up = true }, 1.0 / 60.0);
    for (0..90) |_| {
        p.update(w, .{}, 1.0 / 60.0);
        top = @max(top, p.pos[1]);
    }
    try testing.expect(top > 32.1 and top < 32.8);
    try testing.expect(p.on_ground);
    // A wall two high stops the player.
    _ = w.set(20, 31, 10, .volcanic_rock);
    _ = w.set(20, 32, 10, .volcanic_rock);
    p = .{ .pos = .{ 20.5, 31, 14.5 } };
    for (0..120) |_| p.update(w, .{ .forward = 1 }, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 11 + half_width), p.pos[2], 0.02);
    // Not out of the world.
    p = .{ .pos = .{ 1, 31, 64 }, .yaw = -std.math.pi / 2.0 };
    for (0..120) |_| p.update(w, .{ .forward = 1 }, 1.0 / 60.0);
    try testing.expect(p.pos[0] >= half_width);
}

test "flying goes up and down and stays up" {
    const w = try flatWorld();
    defer w.destroy();
    var p: Player = .{ .pos = .{ 20.5, 31, 20.5 }, .flying = true };
    for (0..60) |_| p.update(w, .{ .up = true }, 1.0 / 60.0);
    try testing.expect(p.pos[1] > 37);
    const y = p.pos[1];
    for (0..60) |_| p.update(w, .{}, 1.0 / 60.0);
    try testing.expectApproxEqAbs(y, p.pos[1], 1.5);
    for (0..240) |_| p.update(w, .{ .down = true }, 1.0 / 60.0);
    try testing.expectApproxEqAbs(@as(f32, 31), p.pos[1], 0.01);
}

test "picking: the block met, the place before it and the face" {
    const w = try flatWorld();
    defer w.destroy();
    // Looking straight down at the floor.
    const h = pick(w, .{ 10.5, 35, 10.5 }, .{ 0, -1, 0 }, 10).?;
    try testing.expectEqual(world_mod.Pos{ 10, 30, 10 }, h.cell);
    try testing.expectEqual(world_mod.Pos{ 10, 31, 10 }, h.before);
    try testing.expectEqual(blocks.Face.up, h.face);
    // Out of reach.
    try testing.expect(pick(w, .{ 10.5, 45, 10.5 }, .{ 0, -1, 0 }, 10) == null);
    // Sideways into a block.
    _ = w.set(15, 31, 10, .volcanic_wall);
    const s = pick(w, .{ 10.5, 31.5, 10.5 }, math.normalize(.{ 1, 0, 0 }), 10).?;
    try testing.expectEqual(world_mod.Pos{ 15, 31, 10 }, s.cell);
    try testing.expectEqual(world_mod.Pos{ 14, 31, 10 }, s.before);
    try testing.expectEqual(blocks.Face.west, s.face);
    // A block where the player stands would be in the way.
    const p: Player = .{ .pos = .{ 14.5, 31, 10.5 } };
    try testing.expect(blocksPlayer(&p, .{ 14, 31, 10 }));
    try testing.expect(blocksPlayer(&p, .{ 14, 32, 10 }));
    try testing.expect(!blocksPlayer(&p, .{ 14, 33, 10 }));
    try testing.expect(!blocksPlayer(&p, .{ 15, 31, 10 }));
}

test "slabs are walked up onto, half a block; ladders are climbed" {
    const w = try flatWorld();
    defer w.destroy();
    // A slab in the way, north: walked onto, standing half a block up.
    _ = w.set(20, 31, 17, .rock_slab);
    var p: Player = .{ .pos = .{ 20.5, 31, 20.5 } };
    for (0..30) |_| p.update(w, .{}, 1.0 / 60.0);
    for (0..50) |_| p.update(w, .{ .forward = 1 }, 1.0 / 60.0);
    for (0..30) |_| p.update(w, .{}, 1.0 / 60.0);
    try testing.expect(p.pos[2] < 18);
    try testing.expectApproxEqAbs(@as(f32, 31.5), p.pos[1], 0.02);
    // A ladder up a wall, three high: climbed to the top of it.
    for (0..3) |k| {
        _ = w.set(30, @intCast(31 + k), 29, .volcanic_rock);
        _ = w.set(30, @intCast(31 + k), 30, .ladder);
    }
    p = .{ .pos = .{ 30.5, 31, 30.5 } };
    for (0..30) |_| p.update(w, .{}, 1.0 / 60.0);
    for (0..60) |_| p.update(w, .{ .forward = 1 }, 1.0 / 60.0);
    try testing.expect(p.pos[1] > 32.5);
}
