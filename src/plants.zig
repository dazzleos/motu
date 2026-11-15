//! Palms and plants, as the mesher makes them: shapes of their own rather
//! than cubes, drawn see-through (their tiles have clear pixels) with the
//! glass.
//!
//! - A palm's trunk is a round pole (eight sides) up its block, thinner
//!   higher up and leaning more the higher it is, as palms do. Its top
//!   block has a crown: fronds arching out and drooping, folded a little
//!   along their ribs, and coconuts under them. The fronds reach well
//!   past the block, into nothing's way: they are only drawn.
//! - Elephant ears: big arrow-shaped leaves held out on tall stalks.
//! - Tall grass: blades on two planes crossing; flowers, a fan of blades
//!   with flowers among them.
//! - Paving: flat round stones on grass, which join up into paths.
//!
//! Fronds and blades are drawn both ways round (back faces are culled),
//! their tops and tips swaying in the wind.

const std = @import("std");
const blocks = @import("blocks.zig");
const mesher = @import("mesher.zig");
const world_mod = @import("world.zig");

const Block = blocks.Block;
const Face = blocks.Face;
const Tile = blocks.Tile;
const World = world_mod.World;
const Anim = mesher.Anim;
const Vertex = mesher.Vertex;
pub const V = [3]f32;

fn add(a: V, b: V) V {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn sub(a: V, b: V) V {
    return .{ a[0] - b[0], a[1] - b[1], a[2] - b[2] };
}

fn mul(a: V, k: f32) V {
    return .{ a[0] * k, a[1] * k, a[2] * k };
}

const up: V = .{ 0, 1, 0 };

/// Where vertices go, and the light they have.
pub const Out = struct {
    gpa: std.mem.Allocator,
    mesh: *mesher.Mesh,
    sky: u4,
    lamp: u4,
    /// Into the solid meshes (drawn first, hiding what is behind), not
    /// the see-through ones.
    solid: bool = false,

    pub fn quad(o: Out, tile: Tile, face: Face, c: [4]V, uv: [4][2]f32, anims: [4]Anim) !void {
        const list = o.mesh.list(if (o.solid) .solid(tile.strip()) else .clear(tile.strip()));
        for (c, uv, anims) |p, t, a| try list.append(o.gpa, .{
            .pos = p,
            .uv = .{ t[0], mesher.stripT(tile, t[1]) },
            .info = (mesher.Info{ .tile = @intFromEnum(tile), .face = face, .sky = o.sky, .lamp = o.lamp, .anim = a }).pack(),
        });
    }

    /// Both ways round: the front lit as `front`, the back as `back`.
    pub fn twoSided(o: Out, tile: Tile, front: Face, back: Face, c: [4]V, uv: [4][2]f32, anims: [4]Anim) !void {
        try o.quad(tile, front, c, uv, anims);
        const r = [4]usize{ 1, 0, 3, 2 };
        try o.quad(tile, back, .{ c[r[0]], c[r[1]], c[r[2]], c[r[3]] }, .{ uv[r[0]], uv[r[1]], uv[r[2]], uv[r[3]] }, .{ anims[r[0]], anims[r[1]], anims[r[2]], anims[r[3]] });
    }
};

/// Across a tile, kept off its very edges (the strip repeats across).
const lo: f32 = 0.002;
const hi: f32 = 0.998;

fn hash(seed: u32, x: i32, z: i32) f32 {
    return world_mod.hash(seed, x, z);
}

// --- Palms -----------------------------------------------------------------------------

/// How far a palm's trunk has leaned `h` blocks up: more, the higher.
fn lean(h: f32) f32 {
    return 0.3 * h * h / (h * h + 14);
}

/// Its radius `h` blocks up: thinner higher up.
fn radius(h: f32) f32 {
    return @max(0.15, 0.21 - 0.012 * h);
}

/// The middle of a palm's trunk at (x, z), `h` blocks above its foot.
fn trunkCentre(x: i32, z: i32, foot: i32, h: f32) V {
    const a = hash(41, x, z) * 2 * std.math.pi;
    const l = lean(h);
    return .{ @as(f32, @floatFromInt(x)) + 0.5 + @cos(a) * l, @as(f32, @floatFromInt(foot)) + h, @as(f32, @floatFromInt(z)) + 0.5 + @sin(a) * l };
}

/// The cube face nearest to facing out at angle `a` (round the y axis,
/// from +x towards +z): for lighting.
fn faceAt(a: f32) Face {
    const c = @cos(a);
    const s = @sin(a);
    if (@abs(c) >= @abs(s)) return if (c > 0) .east else .west;
    return if (s > 0) .south else .north;
}

/// Where a palm's trunk is, at block `p`: the middle and radius of its
/// bottom and its top.
const Trunk = struct { c0: V, c1: V, r0: f32, r1: f32 };

fn trunkAt(w: *const World, p: [3]i32) Trunk {
    // How far up the trunk this block is.
    var foot = p[1];
    while (foot > 0 and p[1] - foot < 24 and w.get(p[0], foot - 1, p[2]) == .palm) foot -= 1;
    const h: f32 = @floatFromInt(p[1] - foot);
    return .{ .c0 = trunkCentre(p[0], p[2], foot, h), .c1 = trunkCentre(p[0], p[2], foot, h + 1), .r0 = radius(h), .r1 = radius(h + 1) };
}

/// A palm's trunk at block `p`, and its coconuts if it is the top: solid
/// (they hide what is behind them, as cubes do). The mesher puts them
/// with the solid faces that look up, which are drawn from (almost)
/// anywhere, as the trunk's sides look every way.
pub fn trunk(gpa: std.mem.Allocator, w: *const World, p: [3]i32, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1], p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .solid = true };
    const t = trunkAt(w, p);
    const sides = 8;
    var ring0: [sides]V = undefined;
    var ring1: [sides]V = undefined;
    for (0..sides) |i| {
        const a = (@as(f32, @floatFromInt(i)) + 0.5) * 2 * std.math.pi / sides;
        ring0[i] = add(t.c0, .{ @cos(a) * t.r0, 0, @sin(a) * t.r0 });
        ring1[i] = add(t.c1, .{ @cos(a) * t.r1, 0, @sin(a) * t.r1 });
    }
    for (0..sides) |i| {
        const j = (i + 1) % sides;
        const a = (@as(f32, @floatFromInt(i)) + 1) * 2 * std.math.pi / sides;
        const s0 = @as(f32, @floatFromInt(i)) / sides;
        const s1 = s0 + 1.0 / @as(f32, sides);
        // Wound to face out.
        try o.quad(.palm_bark, faceAt(a), .{ ring0[j], ring0[i], ring1[i], ring1[j] }, .{ .{ s1, 1 }, .{ s0, 1 }, .{ s0, 0 }, .{ s1, 0 } }, @splat(.none));
    }
    const below = w.get(p[0], p[1] - 1, p[2]);
    if (below != .palm and !below.isOpaque()) try cap(o, ring0, .down);
    if (w.get(p[0], p[1] + 1, p[2]) == .palm) return;
    try cap(o, ring1, .up);
    // Coconuts, under the fronds.
    const seed = crownSeed(p);
    const turn = crownTurn(seed);
    const top = add(t.c1, .{ 0, 0.04, 0 });
    const cn = 3 + @as(u32, @intFromFloat(hash(seed, 9, 9) * 2));
    for (0..cn) |k| {
        const a = turn + 0.4 + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(cn));
        const at = add(top, .{ @cos(a) * 0.24, -0.22 - hash(seed, @intCast(k), 7) * 0.1, @sin(a) * 0.24 });
        try coconut(o, at, 0.12);
    }
}

/// A palm's crown of fronds, on its top block `p` (see-through).
pub fn crown(gpa: std.mem.Allocator, w: *const World, p: [3]i32, mesh: *mesher.Mesh) !void {
    if (w.get(p[0], p[1] + 1, p[2]) == .palm) return;
    // Lit as the air above.
    const l = w.lightAt(p[0], p[1] + 1, p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l) };
    const top = add(trunkAt(w, p).c1, .{ 0, 0.04, 0 });
    const seed = crownSeed(p);
    const turn = crownTurn(seed);
    const n = 10;
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / n + (hash(seed, ki, 1) - 0.5) * 0.5;
        // Every other frond rises higher before it droops.
        const rise: f32 = (if (k % 2 == 0) @as(f32, 0.2) else 0.65) + (hash(seed, ki, 2) - 0.5) * 0.3;
        const length = 2.4 + hash(seed, ki, 3) * 0.6;
        try frond(o, top, a, rise, length, 1.7, 0.55, 4);
    }
}

fn crownSeed(p: [3]i32) u32 {
    return @bitCast(p[0] *% 73856093 ^ p[2] *% 19349663 ^ p[1]);
}

fn crownTurn(seed: u32) f32 {
    return hash(seed, 1, 0) * 2 * std.math.pi;
}

/// The top of a stone: an octagon, in three quads, its texture as the
/// ground's (by its place).
fn capAt(o: Out, ring: [8]V, face: Face, at: V, r: f32) !void {
    _ = r;
    const quads = [3][4]usize{ .{ 0, 1, 2, 3 }, .{ 0, 3, 4, 7 }, .{ 4, 5, 6, 7 } };
    for (quads) |q| {
        var c: [4]V = undefined;
        var uv: [4][2]f32 = undefined;
        for (0..4) |n| {
            const kk = if (face == .up) q[3 - n] else q[n];
            c[n] = ring[kk];
            // Across the tile by x; down it by z, kept within the tile.
            uv[n] = .{ ring[kk][0], 0.5 + (ring[kk][2] - at[2]) * 0.9 };
        }
        try o.quad(.sandstone_top, face, c, uv, @splat(.none));
    }
}

/// The end of a trunk: an octagon, in three quads.
fn cap(o: Out, ring: [8]V, face: Face) !void {
    const quads = [3][4]usize{ .{ 0, 1, 2, 3 }, .{ 0, 3, 4, 7 }, .{ 4, 5, 6, 7 } };
    for (quads) |q| {
        var c: [4]V = undefined;
        var uv: [4][2]f32 = undefined;
        for (q, 0..) |k, n| {
            const kk = if (face == .up) q[3 - n] else k;
            c[n] = ring[kk];
            const a = (@as(f32, @floatFromInt(kk)) + 0.5) * std.math.pi / 4;
            uv[n] = .{ 0.5 + @cos(a) * 0.3, 0.5 + @sin(a) * 0.3 };
        }
        try o.quad(.palm_bark, face, c, uv, @splat(.none));
    }
}

/// A frond from `base`, out at angle `a`, rising at `rise` radians and
/// drooping by `droop` blocks over its `length`; `half` its half-width;
/// in `segs` pieces. Folded a little along its rib.
fn frond(o: Out, base: V, a: f32, rise: f32, length: f32, droop: f32, half: f32, comptime segs: usize) !void {
    const dir: V = .{ @cos(a), 0, @sin(a) };
    const side: V = .{ -dir[2], 0, dir[0] };
    const fold = 0.35;
    var mid: [segs + 1]V = undefined;
    var left: [segs + 1]V = undefined;
    var right: [segs + 1]V = undefined;
    for (0..segs + 1) |j| {
        const t = @as(f32, @floatFromInt(j)) / segs;
        const out = length * t * @cos(rise);
        const y = length * t * @sin(rise) - droop * t * t;
        mid[j] = add(base, add(mul(dir, out), mul(up, y)));
        const drop = mul(up, -fold * half);
        right[j] = add(mid[j], add(mul(side, half), drop));
        left[j] = add(mid[j], add(mul(side, -half), drop));
    }
    for (0..segs) |j| {
        const t0 = @as(f32, @floatFromInt(j)) / segs;
        const t1 = @as(f32, @floatFromInt(j + 1)) / segs;
        const a0: Anim = if (j == 0) .none else if (j == 1) .sway else .plant;
        const a1: Anim = if (j + 1 == 1) .sway else .plant;
        const anims = [4]Anim{ a0, a0, a1, a1 };
        try o.twoSided(.frond, .up, .down, .{ mid[j], right[j], right[j + 1], mid[j + 1] }, .{ .{ 0.5, t0 }, .{ hi, t0 }, .{ hi, t1 }, .{ 0.5, t1 } }, anims);
        try o.twoSided(.frond, .up, .down, .{ mid[j], mid[j + 1], left[j + 1], left[j] }, .{ .{ 0.5, t0 }, .{ 0.5, t1 }, .{ lo, t1 }, .{ lo, t0 } }, .{ anims[0], anims[3], anims[2], anims[1] });
    }
}

/// A coconut: a small cube, `r` from its middle to its faces.
fn coconut(o: Out, at: V, r: f32) !void {
    for (Face.all) |face| {
        const n = face.normal();
        const ax: usize = @intFromEnum(face) / 2;
        const b = (ax + 1) % 3;
        const c = (ax + 2) % 3;
        var corners: [4]V = undefined;
        const uv = [4][2]f32{ .{ 0.2, 0.8 }, .{ 0.8, 0.8 }, .{ 0.8, 0.2 }, .{ 0.2, 0.2 } };
        const d = [4][2]f32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
        for (d, 0..) |q, k| {
            corners[k] = at;
            corners[k][ax] += @as(f32, @floatFromInt(n[ax])) * r;
            corners[k][b] += q[0] * r;
            corners[k][c] += q[1] * r;
        }
        // Facing the other way: round the other way.
        if (@intFromEnum(face) % 2 == 1) {
            const c0 = corners;
            corners = .{ c0[0], c0[3], c0[2], c0[1] };
        }
        try o.quad(.coconut, face, corners, uv, @splat(.none));
    }
}

// --- Paving -----------------------------------------------------------------------------

/// Paving's stones, on the grass of block `p`: flat and round, two by two
/// a block, set a little above the grass. They are spaced alike across
/// the world, so the next paving's carry on from them; beside a block
/// that is not paving they keep in from the edge, with grass round them.
/// Solid (they are put with the solid faces that look up).
pub fn paving(gpa: std.mem.Allocator, w: *const World, p: [3]i32, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1] + 1, p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .solid = true };
    const y: f32 = @as(f32, @floatFromInt(p[1])) + 1;
    // Which sides are paving too (-x, +x, -z, +z).
    const joined = [4]bool{
        w.get(p[0] - 1, p[1], p[2]) == .paving,
        w.get(p[0] + 1, p[1], p[2]) == .paving,
        w.get(p[0], p[1], p[2] - 1) == .paving,
        w.get(p[0], p[1], p[2] + 1) == .paving,
    };
    for (0..2) |j| for (0..2) |i| {
        // The stone's place in the world, for its own size and jitter.
        const gx = p[0] * 2 + @as(i32, @intCast(i));
        const gz = p[2] * 2 + @as(i32, @intCast(j));
        var cx = @as(f32, @floatFromInt(gx)) * 0.5 + 0.25 + (hash(51, gx, gz) - 0.5) * 0.1;
        var cz = @as(f32, @floatFromInt(gz)) * 0.5 + 0.25 + (hash(52, gx, gz) - 0.5) * 0.1;
        var r = 0.19 + hash(53, gx, gz) * 0.05;
        // Away from an edge with no paving beyond it.
        const pull = 0.07;
        if (i == 0 and !joined[0]) cx += pull;
        if (i == 1 and !joined[1]) cx -= pull;
        if (j == 0 and !joined[2]) cz += pull;
        if (j == 1 and !joined[3]) cz -= pull;
        if ((i == 0 and !joined[0]) or (i == 1 and !joined[1]) or (j == 0 and !joined[2]) or (j == 1 and !joined[3])) r -= 0.025;
        try flatStone(o, .{ cx, y, cz }, r, 0.035, hash(54, gx, gz) * std.math.pi);
    };
}

/// A flat round stone (eight sides) on the ground at `at`, `r` across
/// from its middle and `h` high, turned by `turn`.
fn flatStone(o: Out, at: V, r: f32, h: f32, turn: f32) !void {
    var ring0: [8]V = undefined;
    var ring1: [8]V = undefined;
    for (0..8) |k| {
        const a = turn + (@as(f32, @floatFromInt(k)) + 0.5) * std.math.pi / 4;
        // A little uneven, as stones are.
        const rr = r * (0.92 + 0.08 * @cos(a * 3 + turn));
        ring0[k] = add(at, .{ @cos(a) * rr, 0, @sin(a) * rr });
        ring1[k] = add(at, .{ @cos(a) * rr * 0.93, h, @sin(a) * rr * 0.93 });
    }
    for (0..8) |k| {
        const n = (k + 1) % 8;
        const a = turn + (@as(f32, @floatFromInt(k)) + 1) * std.math.pi / 4;
        const s0 = @as(f32, @floatFromInt(k)) / 8;
        try o.quad(.sandstone_top, faceAt(a), .{ ring0[n], ring0[k], ring1[k], ring1[n] }, .{ .{ s0 + 0.125, 0.9 }, .{ s0, 0.9 }, .{ s0, 0.8 }, .{ s0 + 0.125, 0.8 } }, @splat(.none));
    }
    try capAt(o, ring1, .up, at, r);
}

// --- Plants on the ground ---------------------------------------------------------------

pub fn plant(gpa: std.mem.Allocator, w: *const World, p: [3]i32, blk: Block, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1], p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l) };
    const seed: u32 = @bitCast(p[0] *% 73856093 ^ p[2] *% 19349663 ^ p[1] *% 83492791);
    const turn = hash(seed, 0, 0) * 2 * std.math.pi;
    const base: V = .{ @as(f32, @floatFromInt(p[0])) + 0.5, @floatFromInt(p[1]), @as(f32, @floatFromInt(p[2])) + 0.5 };
    if (blk == .elephant_ear) return elephantEar(o, base, seed, turn);
    if (blk == .tall_grass) {
        // Two planes crossing on the block's diagonals.
        const x = base[0] - 0.5;
        const y = base[1];
        const z = base[2] - 0.5;
        const planes = [2][2][2]f32{ .{ .{ x, z }, .{ x + 1, z + 1 } }, .{ .{ x + 1, z }, .{ x, z + 1 } } };
        for (planes) |pl| {
            const c = [4]V{ .{ pl[0][0], y, pl[0][1] }, .{ pl[1][0], y, pl[1][1] }, .{ pl[1][0], y + 1, pl[1][1] }, .{ pl[0][0], y + 1, pl[0][1] } };
            try o.twoSided(.tall_grass, .up, .up, c, .{ .{ lo, 1 }, .{ hi, 1 }, .{ hi, 0 }, .{ lo, 0 } }, .{ .none, .none, .plant, .plant });
        }
        return;
    }
    // Flowers: a fan of blades, every other one with flowers.
    const n = 7;
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / n + (hash(seed, ki, 1) - 0.5) * 0.5;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const side: V = .{ -dir[2], 0, dir[0] };
        const blooms = k % 2 == 0;
        const tile: Tile = if (blooms) blk.tile(.north) else .tall_grass;
        const height = (if (blooms) @as(f32, 0.78) else 0.6) + hash(seed, ki, 2) * 0.2;
        const out: f32 = (if (blooms) @as(f32, 0.22) else 0.2) + hash(seed, ki, 3) * 0.12;
        const half: f32 = if (blooms) 0.3 else 0.28;
        const foot = add(base, add(mul(dir, 0.06), .{ (hash(seed, ki, 4) - 0.5) * 0.2, 0, (hash(seed, ki, 5) - 0.5) * 0.2 }));
        const tip = add(foot, add(mul(dir, out), mul(up, height)));
        const c = [4]V{ add(foot, mul(side, -half)), add(foot, mul(side, half)), add(tip, mul(side, half)), add(tip, mul(side, -half)) };
        // Both grow from the tile's bottom.
        try o.twoSided(tile, .up, .up, c, .{ .{ lo, 1 }, .{ hi, 1 }, .{ hi, 0 }, .{ lo, 0 } }, .{ .none, .none, .plant, .plant });
    }
}

test "paving's stones keep in from grass, and carry on into the next paving" {
    const testing = std.testing;
    const w = try World.create(testing.allocator);
    defer w.destroy();
    _ = w.set(4, 20, 4, .paving);
    _ = w.set(9, 20, 4, .paving);
    _ = w.set(10, 20, 4, .paving);
    var m: mesher.Mesh = .{};
    defer m.deinit(testing.allocator);
    // The stones' middles, along x: each stone is 8 sides and 3 quads on
    // top, all of it on the grass.
    const centres = struct {
        fn of(gpa: std.mem.Allocator, world: *const World, p: [3]i32, mesh: *mesher.Mesh) ![4]f32 {
            mesh.clearRetainingCapacity();
            try paving(gpa, world, p, mesh);
            const v = mesh.items(.solid0);
            try testing.expectEqual(@as(usize, 4 * 11 * 4), v.len);
            var out: [4]f32 = undefined;
            for (0..4) |k| {
                var sum: f32 = 0;
                for (v[k * 44 ..][0..32]) |x| sum += x.pos[0];
                out[k] = sum / 32;
                for (v[k * 44 ..][0..44]) |x| try testing.expect(x.pos[1] >= 21 and x.pos[1] < 21.05);
            }
            return out;
        }
    }.of;
    // Alone: well in from both sides.
    const lone = try centres(testing.allocator, w, .{ 4, 20, 4 }, &m);
    for (lone) |x| try testing.expect(x > 4.25 and x < 4.75);
    // Joined: the stones beside the joint are as far apart as any.
    const a = try centres(testing.allocator, w, .{ 9, 20, 4 }, &m);
    const b = try centres(testing.allocator, w, .{ 10, 20, 4 }, &m);
    try testing.expect(b[0] - a[1] > 0.38 and b[0] - a[1] < 0.62);
    try testing.expect(a[0] > 9.25);
}

/// Elephant ears: three to five leaves, each held out on a stalk from the
/// middle of the block, big and arrow-shaped, their points drooping.
fn elephantEar(o: Out, base: V, seed: u32, turn: f32) !void {
    const n = 3 + @as(u32, @intFromFloat(hash(seed, 7, 7) * 3));
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(n)) + (hash(seed, ki, 1) - 0.5) * 0.5;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const side: V = .{ -dir[2], 0, dir[0] };
        const tall = 0.95 + hash(seed, ki, 2) * 0.55;
        const foot = add(base, .{ 0, 0.02, 0 });
        const top = add(base, add(mul(dir, 0.2 + hash(seed, ki, 3) * 0.1), mul(up, tall)));
        // The stalk: two narrow strips crossing, from the leaf's rib.
        const w = 0.035;
        const across = [2]V{ side, .{ dir[0], 0, dir[2] } };
        for (across) |acr| {
            const c = [4]V{ add(foot, mul(acr, -w)), add(foot, mul(acr, w)), add(top, mul(acr, w)), add(top, mul(acr, -w)) };
            try o.twoSided(.elephant_ear, .up, .up, c, .{ .{ 0.485, 0.7 }, .{ 0.515, 0.7 }, .{ 0.515, 0.3 }, .{ 0.485, 0.3 } }, .{ .none, .none, .sway, .sway });
        }
        // The leaf, in two pieces: out and a little down, then down more
        // to its point. Its lobes reach back past the stalk.
        const len = 1.05 + hash(seed, ki, 4) * 0.3;
        const half = len * 0.46;
        const d1 = add(mul(dir, @cos(0.2)), mul(up, -@sin(0.2)));
        const d2 = add(mul(dir, @cos(0.85)), mul(up, -@sin(0.85)));
        const start = add(top, mul(d1, -0.14 * len));
        const mid = add(start, mul(d1, 0.5 * len));
        const tip = add(mid, mul(d2, 0.5 * len));
        const cup = mul(up, half * 0.18);
        const pts = [3]V{ start, mid, tip };
        const ts = [3]f32{ 0, 0.5, 1 };
        const anims = [3]Anim{ .sway, .plant, .plant };
        for (0..2) |j| {
            const l0 = add(add(pts[j], mul(side, -half)), cup);
            const r0 = add(add(pts[j], mul(side, half)), cup);
            const l1 = add(add(pts[j + 1], mul(side, -half)), cup);
            const r1 = add(add(pts[j + 1], mul(side, half)), cup);
            // Up the middle, the rib; out to each edge.
            try o.twoSided(.elephant_ear, .up, .down, .{ pts[j], r0, r1, pts[j + 1] }, .{ .{ 0.5, ts[j] }, .{ hi, ts[j] }, .{ hi, ts[j + 1] }, .{ 0.5, ts[j + 1] } }, .{ anims[j], anims[j], anims[j + 1], anims[j + 1] });
            try o.twoSided(.elephant_ear, .up, .down, .{ pts[j], pts[j + 1], l1, l0 }, .{ .{ 0.5, ts[j] }, .{ 0.5, ts[j + 1] }, .{ lo, ts[j + 1] }, .{ lo, ts[j] } }, .{ anims[j], anims[j + 1], anims[j + 1], anims[j] });
        }
    }
}
