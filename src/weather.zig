//! The weather: how cloudy it is and how hard it rains, changing at
//! random but smoothly, the same for everyone in a game (it comes from the
//! island's seed and the time: the day and the time of day). Clouds dim
//! the sun and grey the sky (see renderer.Environment.withWeather), and
//! rain darkens it more and brings the fog in.
//!
//! Clouds are drawn as blocks of cloud high over the island, drifting on
//! the wind, each growing and shrinking with how cloudy it is (so none
//! appears or goes all at once); rain as streaks falling around the eye,
//! stopping on whatever is below them. Both are quads of
//! `mesher.Vertex`, from the colour strip, drawn with the creatures.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const mesher = @import("mesher.zig");
const math = @import("math.zig");

const World = world_mod.World;
const Vertex = mesher.Vertex;
const Face = blocks.Face;
const V3 = math.V3;

pub const Weather = struct {
    /// 0 clear to 1 overcast.
    clouds: f32 = 0,
    /// 0 dry to 1 pouring.
    rain: f32 = 0,

    /// The weather on day `day` at time of day `t` (0 to 1). It changes
    /// about every fifth of a day, smoothly.
    pub fn at(seed: u32, day: u32, t: f32) Weather {
        const x = (@as(f32, @floatFromInt(day % 100000)) + t) * 5;
        const c = smoothNoise(seed ^ 0x2c1b3c6d, x);
        const cover = smoothstep(0.3, 0.85, c);
        const r = smoothNoise(seed ^ 0x297a2d39, x * 0.8 + 3.7);
        return .{ .clouds = cover, .rain = smoothstep(0.5, 1.0, cover) * smoothstep(0.3, 0.7, r) };
    }
};

fn smoothstep(lo: f32, hi: f32, x: f32) f32 {
    const t = std.math.clamp((x - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}

fn hash(seed: u32, i: i32) f32 {
    return world_mod.hash(seed, i, 0);
}

/// Noise along one line, from 0 to 1, smooth (its slope too) between
/// random values at each whole number.
fn smoothNoise(seed: u32, x: f32) f32 {
    const i: i32 = @intFromFloat(@floor(x));
    const f = x - @floor(x);
    const s = f * f * f * (f * (f * 6 - 15) + 10);
    return hash(seed, i) + (hash(seed, i + 1) - hash(seed, i)) * s;
}

/// How high the clouds are, and how big each of their cells is.
pub const cloud_y: f32 = 60;
const cloud_cell: f32 = 8;
/// How far round the eye clouds are drawn (beyond, the fog has them).
const cloud_reach: f32 = 132;
/// The wind, in blocks a second.
const wind: [2]f32 = .{ 0.6, 0.25 };
const max_drops = 400;

/// Room for the most clouds and rain there can be.
pub const max_quads = cells * cells * 6 + max_drops;
const cells: usize = @as(usize, @intFromFloat(2 * cloud_reach / cloud_cell)) + 2;

fn put(out: []Vertex, at: *usize, c: [4]V3, face: Face, tile: blocks.Tile, ao: u2, sky: u4) void {
    if (at.* + 4 > out.len) return;
    // One small spot of the tile, so it is a plain colour (not the
    // paint's weave).
    const t0 = mesher.stripT(tile, 0.49);
    const t1 = mesher.stripT(tile, 0.51);
    const uvs = [4][2]f32{ .{ 0.49, t0 }, .{ 0.51, t0 }, .{ 0.51, t1 }, .{ 0.49, t1 } };
    const info = (mesher.Info{ .tile = @intFromEnum(tile), .ao = ao, .face = face, .sky = sky, .lamp = 0 }).pack();
    for (c, uvs, 0..) |p, uv, k| out[at.* + k] = .{ .pos = .{ p[0], p[1], p[2] }, .uv = uv, .info = info };
    at.* += 4;
}

/// Writes the clouds and rain around `eye` at `time` (seconds) into
/// `out`; returns how many quads.
pub fn buildMesh(wx: Weather, seed: u32, w: *const World, eye: V3, time: f32, out: []Vertex) u32 {
    var at: usize = 0;
    if (wx.clouds > 0.01) clouds(wx, seed, eye, time, out, &at);
    if (wx.rain > 0.01) rain(wx, w, eye, time, out, &at);
    return @intCast(at / 4);
}

fn clouds(wx: Weather, seed: u32, eye: V3, time: f32, out: []Vertex, at: *usize) void {
    // The cloud field drifts with the wind; cells are fixed in it.
    const ox = @mod(time * wind[0], 100000);
    const oz = @mod(time * wind[1], 100000);
    const c0x: i32 = @intFromFloat(@floor((eye[0] - ox - cloud_reach) / cloud_cell));
    const c0z: i32 = @intFromFloat(@floor((eye[2] - oz - cloud_reach) / cloud_cell));
    // Darker the more it rains.
    const ao: u2 = if (wx.rain > 0.5) 2 else if (wx.rain > 0.1) 1 else 0;
    const below = eye[1] < cloud_y;
    for (0..cells) |j| for (0..cells) |i| {
        const cx = c0x + @as(i32, @intCast(i));
        const cz = c0z + @as(i32, @intCast(j));
        const fx = @as(f32, @floatFromInt(cx));
        const fz = @as(f32, @floatFromInt(cz));
        const amount = cloudAt(seed, wx, cx, cz);
        if (amount <= 0.01) continue;
        // Most of a cloud's cells are whole, so they join up; at its
        // edges they are smaller, growing as it gets cloudier.
        const size = @min(1, @sqrt(amount / 0.5));
        const half = cloud_cell * 0.5 * size;
        const mid = V3{ (fx + 0.5) * cloud_cell + ox, cloud_y, (fz + 0.5) * cloud_cell + oz };
        const d = mid - eye;
        if (d[0] * d[0] + d[2] * d[2] > cloud_reach * cloud_reach) continue;
        const h = 1.8 * size;
        const lo = V3{ mid[0] - half, mid[1], mid[2] - half };
        const hi = V3{ mid[0] + half, mid[1] + h, mid[2] + half };
        // Not the eye's far side, nor sides against a whole cell beside.
        var skip: std.EnumSet(Face) = .initOne(if (below) .up else .down);
        if (size >= 1) {
            const beside = [4]struct { Face, i32, i32 }{ .{ .west, -1, 0 }, .{ .east, 1, 0 }, .{ .north, 0, -1 }, .{ .south, 0, 1 } };
            for (beside) |b| if (cloudAt(seed, wx, cx + b[1], cz + b[2]) >= 0.5) skip.insert(b[0]);
        }
        box(out, at, lo, hi, ao, skip);
    };
}

/// How much cloud is in cell (cx, cz), 0 to 1: clouds in patches,
/// smooth noise over the cells, a little rough.
fn cloudAt(seed: u32, wx: Weather, cx: i32, cz: i32) f32 {
    const fx = @as(f32, @floatFromInt(cx));
    const fz = @as(f32, @floatFromInt(cz));
    const n = 0.85 * valueNoise(seed, fx / 6, fz / 6) + 0.15 * world_mod.hash(seed ^ 0x51, cx, cz);
    return std.math.clamp((n - (1 - wx.clouds * 0.95)) * 6, 0, 1);
}

/// A cloud's box, but its faces in `skip`.
fn box(out: []Vertex, at: *usize, lo_v: V3, hi_v: V3, ao: u2, skip: std.EnumSet(Face)) void {
    const lo: [3]f32 = lo_v;
    const hi: [3]f32 = hi_v;
    for (Face.all) |face| {
        if (skip.contains(face)) continue;
        const n = face.normal();
        const ax: usize = @intFromEnum(face) / 2;
        const b = (ax + 1) % 3;
        const c = (ax + 2) % 3;
        var corners: [4][3]f32 = undefined;
        const q = [4][2]bool{ .{ false, false }, .{ true, false }, .{ true, true }, .{ false, true } };
        for (q, 0..) |e, k| {
            corners[k][ax] = if (n[ax] > 0) hi[ax] else lo[ax];
            corners[k][b] = if (e[0]) hi[b] else lo[b];
            corners[k][c] = if (e[1]) hi[c] else lo[c];
        }
        if (@intFromEnum(face) % 2 == 1) {
            const c0 = corners;
            corners = .{ c0[0], c0[3], c0[2], c0[1] };
        }
        put(out, at, .{ corners[0], corners[1], corners[2], corners[3] }, face, .white, ao, 15);
    }
}

/// Smooth noise over a plane, from 0 to 1.
fn valueNoise(seed: u32, x: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    const fx = x - @floor(x);
    const fz = z - @floor(z);
    const sx = fx * fx * (3 - 2 * fx);
    const sz = fz * fz * (3 - 2 * fz);
    const a = world_mod.hash(seed, ix, iz);
    const b = world_mod.hash(seed, ix + 1, iz);
    const c = world_mod.hash(seed, ix, iz + 1);
    const d = world_mod.hash(seed, ix + 1, iz + 1);
    return (a + (b - a) * sx) * (1 - sz) + (c + (d - c) * sx) * sz;
}

fn rain(wx: Weather, w: *const World, eye: V3, time: f32, out: []Vertex, at: *usize) void {
    const count: usize = @intFromFloat(@as(f32, max_drops) * wx.rain);
    const radius: f32 = 12;
    const top = eye[1] + 10;
    const fall: f32 = 18;
    const speed: f32 = 14;
    // Each drop has its place, in blocks round the eye (so it stays put
    // as the eye moves within a block), and its own start.
    const ex = @floor(eye[0]);
    const ez = @floor(eye[2]);
    for (0..count) |i| {
        const ii: i32 = @intCast(i);
        const a = hash(0x7f4a7c15, ii) * 2 * std.math.pi;
        const r = @sqrt(hash(0x165667b1, ii)) * radius;
        const x = ex + @cos(a) * r;
        const z = ez + @sin(a) * r;
        const y = top - @mod(time * speed + hash(0x27d4eb2f, ii) * fall, fall);
        // Not under a roof, and not into the ground or the sea.
        const ground = w.top(@intFromFloat(@floor(x)), @intFromFloat(@floor(z)));
        if (y - 0.5 < @as(f32, @floatFromInt(ground)) + 1) continue;
        // A thin streak, turned to the eye.
        const to = V3{ eye[0] - x, 0, eye[2] - z };
        const len = @max(@sqrt(to[0] * to[0] + to[2] * to[2]), 0.01);
        const side = V3{ -to[2] / len * 0.02, 0, to[0] / len * 0.02 };
        const p = V3{ x, y, z };
        const tail = V3{ x, y - 0.7, z };
        const face: Face = if (@abs(to[0]) > @abs(to[2])) (if (to[0] > 0) .east else .west) else (if (to[2] > 0) .south else .north);
        // Wound to face the eye.
        put(out, at, .{ tail + side, tail - side, p - side, p + side }, face, .white, 0, 15);
    }
}

const testing = std.testing;

test "the weather changes, but smoothly, and it rains only when it is cloudy" {
    var prev = Weather.at(5, 0, 0);
    var cloudy: u32 = 0;
    var clear: u32 = 0;
    var rained: u32 = 0;
    const steps = 120000;
    for (1..steps) |i| {
        const x = @as(f32, @floatFromInt(i)) / steps * 20;
        const wx = Weather.at(5, @intFromFloat(@floor(x)), x - @floor(x));
        // A step here is a tenth of a second in the game.
        try testing.expect(@abs(wx.clouds - prev.clouds) < 0.01 and @abs(wx.rain - prev.rain) < 0.01);
        if (wx.rain > 0.05) try testing.expect(wx.clouds > 0.5);
        if (wx.clouds > 0.8) cloudy += 1;
        if (wx.clouds < 0.1) clear += 1;
        if (wx.rain > 0.5) rained += 1;
        prev = wx;
    }
    // Over twenty days, some of each.
    try testing.expect(cloudy > 0 and clear > 0 and rained > 0);
}

test "clouds and rain: more of them the cloudier and wetter, within the room for them" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    const out = try testing.allocator.alloc(Vertex, max_quads * 4);
    defer testing.allocator.free(out);
    const eye = V3{ 64, 30, 64 };
    try testing.expectEqual(@as(u32, 0), buildMesh(.{}, 1, w, eye, 10, out));
    const some = buildMesh(.{ .clouds = 0.4 }, 1, w, eye, 10, out);
    const lots = buildMesh(.{ .clouds = 1 }, 1, w, eye, 10, out);
    try testing.expect(some > 0 and lots > some);
    const wet = buildMesh(.{ .clouds = 1, .rain = 1 }, 1, w, eye, 10, out);
    try testing.expect(wet > lots and wet <= max_quads);
    for (out[0 .. lots * 4]) |v| try testing.expect(v.pos[1] >= cloud_y);
}
