//! Palms and plants, as the mesher makes them: shapes of their own rather
//! than cubes, drawn see-through (their tiles have clear pixels) with the
//! lamps' flames.
//!
//! - A palm's trunk is a round pole (eight sides) up its block, thinner
//!   higher up and leaning more the higher it is, as palms do. Its top
//!   block has a crown: fronds arching out and drooping, folded a little
//!   along their ribs, and coconuts under them. The fronds reach well
//!   past the block, into nothing's way: they are only drawn.
//! - Leafy plants: big arrow-shaped leaves held out on tall stalks.
//! - Tall grass: blades on two planes crossing; flowers, a fan of blades
//!   with flowers among them.
//! - Paving stones: flat and round on the ground, which join up into
//!   paths.
//! - A banana plant: a stem, big paddle leaves arching out and drooping,
//!   a bunch of bananas under them.
//! - A mangrove: roots arching down from a short trunk, leaves over them.
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
    /// See-through, and in the water (drawn before its surface).
    under: bool = false,

    pub fn quad(o: Out, tile: Tile, face: Face, c: [4]V, uv: [4][2]f32, anims: [4]Anim) !void {
        const list = o.mesh.list(if (o.solid) .solid(tile.strip()) else if (o.under) .under(tile.strip()) else .clear(tile.strip()));
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
pub fn frond(o: Out, base: V, a: f32, rise: f32, length: f32, droop: f32, half: f32, comptime segs: usize) !void {
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

/// Paving stones, on the ground at the bottom of block `p`: flat and
/// round, two by two a block. They are spaced alike across the world, so
/// the stones beside carry on from them; beside a block without them they
/// keep in from the edge, with the ground round them. Solid (they are
/// put with the solid faces that look up), though not in the way.
pub fn paving(gpa: std.mem.Allocator, w: *const World, p: [3]i32, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1], p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .solid = true };
    const y: f32 = @floatFromInt(p[1]);
    // Which sides have stones too (-x, +x, -z, +z).
    const joined = [4]bool{
        w.get(p[0] - 1, p[1], p[2]) == .stones,
        w.get(p[0] + 1, p[1], p[2]) == .stones,
        w.get(p[0], p[1], p[2] - 1) == .stones,
        w.get(p[0], p[1], p[2] + 1) == .stones,
    };
    for (0..2) |j| for (0..2) |i| {
        // The stone's place in the world, for its own size and jitter.
        const gx = p[0] * 2 + @as(i32, @intCast(i));
        const gz = p[2] * 2 + @as(i32, @intCast(j));
        var cx = @as(f32, @floatFromInt(gx)) * 0.5 + 0.25 + (hash(51, gx, gz) - 0.5) * 0.1;
        var cz = @as(f32, @floatFromInt(gz)) * 0.5 + 0.25 + (hash(52, gx, gz) - 0.5) * 0.1;
        var r = 0.19 + hash(53, gx, gz) * 0.05;
        // Away from an edge with no stones beyond it.
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
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .under = blk == .seagrass };
    const seed: u32 = @bitCast(p[0] *% 73856093 ^ p[2] *% 19349663 ^ p[1] *% 83492791);
    const turn = hash(seed, 0, 0) * 2 * std.math.pi;
    const base: V = .{ @as(f32, @floatFromInt(p[0])) + 0.5, @floatFromInt(p[1]), @as(f32, @floatFromInt(p[2])) + 0.5 };
    if (blk == .leafy_plant) return leafyPlant(o, base, seed, turn);
    if (blk == .banana) return banana(o, base, seed, turn);
    if (blk == .mangrove) return mangrove(o, w, p, base, seed, turn);
    if (blk == .frangipani) return frangipani(o, w, p, base, seed, turn);
    if (blk == .tall_grass or blk == .seagrass) {
        // Two planes crossing on the block's diagonals.
        const x = base[0] - 0.5;
        const y = base[1];
        const z = base[2] - 0.5;
        const planes = [2][2][2]f32{ .{ .{ x, z }, .{ x + 1, z + 1 } }, .{ .{ x + 1, z }, .{ x, z + 1 } } };
        for (planes) |pl| {
            const c = [4]V{ .{ pl[0][0], y, pl[0][1] }, .{ pl[1][0], y, pl[1][1] }, .{ pl[1][0], y + 1, pl[1][1] }, .{ pl[0][0], y + 1, pl[0][1] } };
            try o.twoSided(blk.tile(.north), .up, .up, c, .{ .{ lo, 1 }, .{ hi, 1 }, .{ hi, 0 }, .{ lo, 0 } }, .{ .none, .none, .plant, .plant });
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

test "paving stones keep in from the edge, and carry on into the next" {
    const testing = std.testing;
    const w = try World.create(testing.allocator);
    defer w.destroy();
    _ = w.set(4, 21, 4, .stones);
    _ = w.set(9, 21, 4, .stones);
    _ = w.set(10, 21, 4, .stones);
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
    const lone = try centres(testing.allocator, w, .{ 4, 21, 4 }, &m);
    for (lone) |x| try testing.expect(x > 4.25 and x < 4.75);
    // Joined: the stones beside the joint are as far apart as any.
    const a = try centres(testing.allocator, w, .{ 9, 21, 4 }, &m);
    const b = try centres(testing.allocator, w, .{ 10, 21, 4 }, &m);
    try testing.expect(b[0] - a[1] > 0.38 and b[0] - a[1] < 0.62);
    try testing.expect(a[0] > 9.25);
}

/// Leafy plants: three to five leaves, each held out on a stalk from the
/// middle of the block, big and arrow-shaped, their points drooping.
fn leafyPlant(o_in: Out, base: V, seed: u32, turn: f32) !void {
    // Solid: its leaves are their own shape, not a picture of one with
    // clear around it, so they hide what is behind them as blocks do
    // (drawn with the solid faces that look up).
    var o = o_in;
    o.solid = true;
    const n = 3 + @as(u32, @intFromFloat(hash(seed, 7, 7) * 3));
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(n)) + (hash(seed, ki, 1) - 0.5) * 0.5;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const side: V = .{ -dir[2], 0, dir[0] };
        const tall = 0.95 + hash(seed, ki, 2) * 0.55;
        const foot = add(base, .{ 0, 0.02, 0 });
        const top = add(base, add(mul(dir, 0.2 + hash(seed, ki, 3) * 0.1), mul(up, tall)));
        // The stalk: two narrow strips crossing, coloured as the leaf's
        // rib.
        const w = 0.035;
        const across = [2]V{ side, .{ dir[0], 0, dir[2] } };
        for (across) |acr| {
            const c = [4]V{ add(foot, mul(acr, -w)), add(foot, mul(acr, w)), add(top, mul(acr, w)), add(top, mul(acr, -w)) };
            // Lit as the way each side faces.
            const front = faceAt(std.math.atan2(acr[0], -acr[2]));
            const back = faceAt(std.math.atan2(-acr[0], acr[2]));
            try o.twoSided(.leafy_plant, front, back, c, .{ .{ 0.49, 0.7 }, .{ 0.51, 0.7 }, .{ 0.51, 0.3 }, .{ 0.49, 0.3 } }, .{ .none, .none, .sway, .sway });
        }
        // The leaf: out and a little down, then down more to its point,
        // its lobes reaching back past the stalk. Its outline is the
        // tile's leaf's (see textures.zig), a little inside it, in rows
        // from its base to its point, each side of the rib.
        const len = 1.05 + hash(seed, ki, 4) * 0.3;
        const half = len * 0.46;
        const d1 = add(mul(dir, @cos(0.2)), mul(up, -@sin(0.2)));
        const d2 = add(mul(dir, @cos(0.85)), mul(up, -@sin(0.85)));
        const start = add(top, mul(d1, -0.14 * len));
        const mid = add(start, mul(d1, 0.5 * len));
        const tip = add(mid, mul(d2, 0.5 * len));
        const rows = [_]f32{ 0, 0.1, 0.2, 0.35, 0.55, 0.78, 1 };
        const at = struct {
            fn f(s0: V, m: V, e: V, t: f32) V {
                return if (t < 0.5) add(s0, mul(sub(m, s0), t * 2)) else add(m, mul(sub(e, m), t * 2 - 1));
            }
        }.f;
        // Across the tile (0.5 the rib), out to the edge and in to the
        // notch between the lobes.
        const edge = struct {
            fn f(t: f32) f32 {
                // (A sliver wide at the point, not none.)
                return @max(0.01, 0.47 * 0.94 * std.math.pow(f32, @max(0, @sin(std.math.pi * (0.25 + 0.75 * t))), 0.7));
            }
        }.f;
        const notch = struct {
            fn f(t: f32) f32 {
                return if (t < 0.2) 0.22 * (1 - t / 0.2) + 0.01 else 0;
            }
        }.f;
        const anim = struct {
            fn f(t: f32) Anim {
                return if (t < 0.3) .sway else .plant;
            }
        }.f;
        for (0..rows.len - 1) |j| {
            const t0 = rows[j];
            const t1 = rows[j + 1];
            const p0 = at(start, mid, tip, t0);
            const p1 = at(start, mid, tip, t1);
            for ([2]f32{ 1, -1 }) |sgn| {
                // A point on the leaf, `u` across the tile from its rib,
                // its edges cupped up a little.
                const pt = struct {
                    fn f(p: V, sd: V, hf: f32, sg: f32, u: f32) V {
                        const x = u / 0.5 * hf;
                        return add(add(p, mul(sd, sg * x)), mul(up, 0.18 * x * x / hf));
                    }
                }.f;
                const in0 = notch(t0);
                const in1 = notch(t1);
                const out0 = @max(edge(t0), in0);
                const out1 = @max(edge(t1), in1);
                const c = [4]V{ pt(p0, side, half, sgn, in0), pt(p0, side, half, sgn, out0), pt(p1, side, half, sgn, out1), pt(p1, side, half, sgn, in1) };
                const uv = [4][2]f32{ .{ 0.5 + sgn * in0, t0 }, .{ 0.5 + sgn * out0, t0 }, .{ 0.5 + sgn * out1, t1 }, .{ 0.5 + sgn * in1, t1 } };
                const an = [4]Anim{ anim(t0), anim(t0), anim(t1), anim(t1) };
                // Wound to face up on either side of the rib.
                if (sgn > 0) {
                    try o.twoSided(.leafy_plant, .up, .down, c, uv, an);
                } else {
                    try o.twoSided(.leafy_plant, .up, .down, .{ c[0], c[3], c[2], c[1] }, .{ uv[0], uv[3], uv[2], uv[1] }, .{ an[0], an[3], an[2], an[1] });
                }
            }
        }
    }
}

fn cross(a: V, b: V) V {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

fn dot(a: V, b: V) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

fn normalize(a: V) V {
    return mul(a, 1 / @max(@sqrt(dot(a, a)), 1e-6));
}

/// The cube face nearest to facing `n`: for lighting.
fn nearestFace(n: V) Face {
    const ax = @abs(n[0]);
    const ay = @abs(n[1]);
    const az = @abs(n[2]);
    if (ay >= ax and ay >= az) return if (n[1] >= 0) .up else .down;
    if (ax >= az) return if (n[0] >= 0) .east else .west;
    return if (n[2] >= 0) .south else .north;
}

/// A quad, wound to face `out`, lit as the cube face nearest it. A quad
/// a little twisted is split (into its two triangles, 0 1 2 and 0 2 3)
/// along the diagonal that keeps both facing out.
pub fn facing(o: Out, tile: Tile, c_in: [4]V, uv_in: [4][2]f32, out: V, anims_in: [4]Anim) !void {
    var c = c_in;
    var uv = uv_in;
    var anims = anims_in;
    if (dot(cross(sub(c[1], c[0]), sub(c[2], c[0])), out) < 0) {
        c = .{ c_in[0], c_in[3], c_in[2], c_in[1] };
        uv = .{ uv_in[0], uv_in[3], uv_in[2], uv_in[1] };
        anims = .{ anims_in[0], anims_in[3], anims_in[2], anims_in[1] };
    }
    const both = struct {
        fn f(q: [4]V, n: V) bool {
            return dot(cross(sub(q[1], q[0]), sub(q[2], q[0])), n) > 0 and dot(cross(sub(q[2], q[0]), sub(q[3], q[0])), n) > 0;
        }
    }.f;
    if (!both(c, out)) {
        const r = [4]usize{ 1, 2, 3, 0 };
        const c2 = [4]V{ c[r[0]], c[r[1]], c[r[2]], c[r[3]] };
        if (both(c2, out)) {
            c = c2;
            uv = .{ uv[r[0]], uv[r[1]], uv[r[2]], uv[r[3]] };
            anims = .{ anims[r[0]], anims[r[1]], anims[r[2]], anims[r[3]] };
        }
    }
    try o.quad(tile, nearestFace(out), c, uv, anims);
}

/// A square beam from `a` to `b`, `w` from its middle to its sides, its
/// four sides `tile`'s middle (u from `ua` to `ub`).
fn beam(o: Out, a: V, b: V, w: f32, tile: Tile, ua: f32, ub: f32, an_a: Anim, an_b: Anim) !void {
    const axis = normalize(sub(b, a));
    const ref: V = if (@abs(axis[1]) > 0.9) .{ 1, 0, 0 } else up;
    const s1 = normalize(cross(axis, ref));
    const s2 = cross(axis, s1);
    const sides = [4]V{ s1, s2, mul(s1, -1), mul(s2, -1) };
    for (0..4) |k| {
        const c0 = sides[k];
        const c1 = sides[(k + 1) % 4];
        const out = normalize(add(c0, c1));
        const c = [4]V{ add(a, mul(c0, w)), add(a, mul(c1, w)), add(b, mul(c1, w)), add(b, mul(c0, w)) };
        try facing(o, tile, c, .{ .{ ua, 1 }, .{ ub, 1 }, .{ ub, 0 }, .{ ua, 0 } }, out, .{ an_a, an_a, an_b, an_b });
    }
}

/// A box from `lo` to `hi`, every face `tile` (the block's part of it),
/// but its bottom if `bottom` is false.
fn leafBox(o: Out, lo_v: V, hi_v: V, tile: Tile, bottom: bool, anim: Anim) !void {
    for (Face.all) |face| {
        if (face == .down and !bottom) continue;
        const n = face.normal();
        const ax: usize = @intFromEnum(face) / 2;
        const b = (ax + 1) % 3;
        const c = (ax + 2) % 3;
        var corners: [4]V = undefined;
        const q = [4][2]bool{ .{ false, false }, .{ true, false }, .{ true, true }, .{ false, true } };
        var uv: [4][2]f32 = undefined;
        for (q, 0..) |e, k| {
            corners[k][ax] = if (n[ax] > 0) hi_v[ax] else lo_v[ax];
            corners[k][b] = if (e[0]) hi_v[b] else lo_v[b];
            corners[k][c] = if (e[1]) hi_v[c] else lo_v[c];
            // Across by one corner's place, down within the tile.
            uv[k] = .{ corners[k][b] + corners[k][c] * 0.37, if (e[1]) 0.98 else 0.02 };
        }
        const out: V = .{ @floatFromInt(n[0]), @floatFromInt(n[1]), @floatFromInt(n[2]) };
        try facing(o, tile, corners, uv, out, @splat(anim));
    }
}

/// A big paddle leaf from `start`, out along `dir` rising at `rise`,
/// drooping to its tip: its outline in rows each side of its rib (the
/// tile's leaf's middle, which is green the whole way).
fn paddleLeaf(o: Out, start: V, dir: V, len: f32, half: f32, rise: f32, droop: f32) !void {
    const side: V = normalize(.{ -dir[2], 0, dir[0] });
    const rows = [_]f32{ 0, 0.12, 0.3, 0.5, 0.7, 0.88, 1 };
    const at = struct {
        fn f(s0: V, d: V, l: f32, r: f32, dr: f32, t: f32) V {
            return add(s0, add(mul(d, l * t * @cos(r)), mul(up, l * t * @sin(r) - dr * t * t)));
        }
    }.f;
    const width = struct {
        fn f(t: f32) f32 {
            return @max(0.03, std.math.pow(f32, @max(0, @sin(std.math.pi * @min(1, 0.08 + t))), 0.6));
        }
    }.f;
    for (0..rows.len - 1) |j| {
        const t0 = rows[j];
        const t1 = rows[j + 1];
        const p0 = at(start, dir, len, rise, droop, t0);
        const p1 = at(start, dir, len, rise, droop, t1);
        const an: [4]Anim = if (t0 < 0.3) .{ .sway, .sway, .plant, .plant } else @splat(.plant);
        for ([2]f32{ 1, -1 }) |sgn| {
            const e0 = mul(side, sgn * half * width(t0));
            const e1 = mul(side, sgn * half * width(t1));
            const lift = mul(up, 0.08 * half);
            const c = [4]V{ p0, add(add(p0, e0), lift), add(add(p1, e1), lift), p1 };
            const uv = [4][2]f32{ .{ 0.5, t0 * 0.8 + 0.1 }, .{ 0.5 + sgn * 0.2 * width(t0), t0 * 0.8 + 0.1 }, .{ 0.5 + sgn * 0.2 * width(t1), t1 * 0.8 + 0.1 }, .{ 0.5, t1 * 0.8 + 0.1 } };
            const n = cross(sub(c[1], c[0]), sub(c[3], c[0]));
            const upish: V = if (dot(n, up) >= 0) n else mul(n, -1);
            try facing(o, .leafy_plant, c, uv, upish, an);
            try facing(o, .leafy_plant, c, uv, mul(upish, -1), an);
        }
    }
}

/// A banana plant: a stem, six or so big paddle leaves from its top
/// arching out and drooping, a bunch of bananas under them. Solid, as
/// the leafy plant is.
fn banana(o_in: Out, base: V, seed: u32, turn: f32) !void {
    var o = o_in;
    o.solid = true;
    const tall = 1.5 + hash(seed, 5, 5) * 0.4;
    const top = add(base, mul(up, tall));
    try beam(o, base, top, 0.14, .bamboo, 0.35, 0.65, .none, .sway);
    const n = 5 + @as(u32, @intFromFloat(hash(seed, 7, 7) * 3));
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(n)) + (hash(seed, ki, 1) - 0.5) * 0.4;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const len = 1.7 + hash(seed, ki, 2) * 0.5;
        try paddleLeaf(o, add(top, mul(dir, 0.05)), dir, len, 0.4, 0.8 + (hash(seed, ki, 3) - 0.5) * 0.4, 0.75);
    }
    // The bunch, hanging from under the leaves.
    const bunch = add(top, .{ @cos(turn + 0.6) * 0.18, -0.35, @sin(turn + 0.6) * 0.18 });
    try leafBox(o, sub(bunch, .{ 0.09, 0.2, 0.09 }), add(bunch, .{ 0.09, 0.2, 0.09 }), .coconut, true, .sway);
    try beam(o, add(bunch, .{ 0, 0.18, 0 }), add(top, .{ 0, -0.05, 0 }), 0.025, .bamboo, 0.4, 0.6, .sway, .sway);
}

/// A frangipani: a short pale trunk forking into three or four stubby
/// branches, rising and spreading, each ending in a cluster of leaves and
/// flowers (with room above for them; otherwise a bush of them). Solid,
/// as the leafy plant is.
fn frangipani(o_in: Out, w: *const World, p: [3]i32, base: V, seed: u32, turn: f32) !void {
    var o = o_in;
    o.solid = true;
    const room = w.get(p[0], p[1] + 1, p[2]) == .air and w.get(p[0], p[1] + 2, p[2]) == .air;
    const fork = add(base, mul(up, if (room) @as(f32, 1.2) else 0.3));
    try beam(o, base, fork, 0.11, .palm_bark, 0.3, 0.7, .none, .none);
    const n: usize = 3 + @as(usize, @intFromFloat(hash(seed, 3, 3) * 2));
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / @as(f32, @floatFromInt(n)) + (hash(seed, ki, 1) - 0.5) * 0.6;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const reach = 0.55 + hash(seed, ki, 2) * 0.3;
        const rise = if (room) 0.7 + hash(seed, ki, 4) * 0.5 else 0.25;
        // Up and out, bending once on the way.
        const knee = add(fork, add(mul(dir, reach * 0.4), mul(up, rise * 0.6)));
        const tip = add(fork, add(mul(dir, reach), mul(up, rise)));
        try beam(o, fork, knee, 0.07, .palm_bark, 0.35, 0.65, .none, .none);
        try beam(o, knee, tip, 0.055, .palm_bark, 0.35, 0.65, .none, .sway);
        // The leaves and flowers at its end.
        const half: f32 = 0.36 + hash(seed, ki, 5) * 0.1;
        try leafBox(o, .{ tip[0] - half, tip[1] - 0.1, tip[2] - half }, .{ tip[0] + half, tip[1] + 0.34, tip[2] + half }, .frangipani, true, .sway);
    }
}

/// A mangrove: roots arching down from a short trunk to the ground (or
/// the shallows' floor) round it, and, with nothing above, leaves over
/// it, wider than its block. Solid, as the leafy plant is.
fn mangrove(o_in: Out, w: *const World, p: [3]i32, base: V, seed: u32, turn: f32) !void {
    var o = o_in;
    o.solid = true;
    const trunk_foot = add(base, mul(up, 0.7));
    // The trunk, up out of its block (the leaves are high over the water).
    try beam(o, trunk_foot, add(base, mul(up, 1.9)), 0.1, .palm_bark, 0.3, 0.7, .none, .none);
    const n = 5;
    for (0..n) |k| {
        const ki: i32 = @intCast(k);
        const a = turn + @as(f32, @floatFromInt(k)) * 2 * std.math.pi / n + (hash(seed, ki, 1) - 0.5) * 0.5;
        const dir: V = .{ @cos(a), 0, @sin(a) };
        const reach = 0.36 + hash(seed, ki, 2) * 0.1;
        const knee = add(trunk_foot, add(mul(dir, reach * 0.55), mul(up, 0.12)));
        const foot = add(base, mul(dir, reach));
        try beam(o, trunk_foot, knee, 0.045, .palm_bark, 0.4, 0.6, .none, .none);
        try beam(o, knee, foot, 0.045, .palm_bark, 0.4, 0.6, .none, .none);
    }
    if (w.get(p[0], p[1] + 1, p[2]) != .air or w.get(p[0], p[1] + 2, p[2]) != .air) return;
    const lo_y = base[1] + 1.75;
    const c = add(base, .{ 0, 0, 0 });
    try leafBox(o, .{ c[0] - 0.85, lo_y, c[2] - 0.85 }, .{ c[0] + 0.85, lo_y + 0.55, c[2] + 0.85 }, .mangrove_leaf, true, .sway);
    const ox = (hash(seed, 9, 1) - 0.5) * 0.5;
    const oz = (hash(seed, 9, 2) - 0.5) * 0.5;
    try leafBox(o, .{ c[0] - 0.5 + ox, lo_y + 0.55, c[2] - 0.5 + oz }, .{ c[0] + 0.5 + ox, lo_y + 0.85, c[2] + 0.5 + oz }, .mangrove_leaf, false, .sway);
}
