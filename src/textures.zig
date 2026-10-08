//! The blocks' looks, drawn here rather than loaded: each tile is 16 by
//! 16 pixels of pixel art, made from a few colours and noise, laid out 8
//! by 8 in a 128-pixel atlas the GPU samples (nearest, so they stay
//! crisp). Icons for the hotbar are small isometric cubes drawn from the
//! same tiles.

const std = @import("std");
const blocks = @import("blocks.zig");

const Block = blocks.Block;
const Tile = blocks.Tile;

pub const tile_size = 16;
pub const tiles_across = 8;
pub const atlas_size = tile_size * tiles_across;

/// 0xAARRGGBB.
const Pixel = u32;

/// Where a tile is in the atlas, in texture coordinates (0 to 1): its top
/// left corner.
pub fn tileOrigin(t: Tile) [2]f32 {
    const i: u32 = @intFromEnum(t);
    return .{ @as(f32, @floatFromInt(i % tiles_across)) / tiles_across, @as(f32, @floatFromInt(i / tiles_across)) / tiles_across };
}

// --- Colour helpers -----------------------------------------------------------------

const Rgb = [3]f32;

fn rgb(hex: u24) Rgb {
    return .{ @floatFromInt(hex >> 16), @floatFromInt(hex >> 8 & 0xff), @floatFromInt(hex & 0xff) };
}

fn pack(c: Rgb, a: f32) Pixel {
    var out: Pixel = @as(Pixel, @intFromFloat(std.math.clamp(a, 0, 1) * 255 + 0.5)) << 24;
    for (c, 0..) |v, i| out |= @as(Pixel, @intFromFloat(std.math.clamp(v, 0, 255) + 0.5)) << @intCast(16 - i * 8);
    return out;
}

fn scale(c: Rgb, k: f32) Rgb {
    return .{ c[0] * k, c[1] * k, c[2] * k };
}

fn mix(a: Rgb, b: Rgb, t: f32) Rgb {
    return .{ a[0] + (b[0] - a[0]) * t, a[1] + (b[1] - a[1]) * t, a[2] + (b[2] - a[2]) * t };
}

/// A number from 0 to 1 for a pixel of a tile (the same every time).
fn hash(x: i32, y: i32, salt: u32) f32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x27d4eb2d ^ @as(u32, @bitCast(y)) *% 0x165667b1 ^ salt *% 0x9e3779b9;
    h ^= h >> 15;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777216.0;
}

/// Smooth noise across a tile, wrapping at its edges (so tiles join).
fn smooth(x: i32, y: i32, cell: i32, salt: u32) f32 {
    const n = @divTrunc(tile_size, cell);
    const fx = @as(f32, @floatFromInt(@mod(x, cell))) / @as(f32, @floatFromInt(cell));
    const fy = @as(f32, @floatFromInt(@mod(y, cell))) / @as(f32, @floatFromInt(cell));
    const cx = @divFloor(x, cell);
    const cy = @divFloor(y, cell);
    const a = hash(@mod(cx, n), @mod(cy, n), salt);
    const b = hash(@mod(cx + 1, n), @mod(cy, n), salt);
    const c = hash(@mod(cx, n), @mod(cy + 1, n), salt);
    const d = hash(@mod(cx + 1, n), @mod(cy + 1, n), salt);
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    return (a + (b - a) * sx) * (1 - sy) + (c + (d - c) * sx) * sy;
}

/// A colour varied a little, pixel by pixel.
fn speckle(base: Rgb, x: i32, y: i32, salt: u32, amount: f32) Rgb {
    return scale(base, 1 + (hash(x, y, salt) - 0.5) * 2 * amount);
}

// --- The tiles ------------------------------------------------------------------------

fn pixel(t: Tile, x: i32, y: i32) Pixel {
    const s: u32 = @intFromEnum(t) + 1;
    return switch (t) {
        .grass_top => grassTop(x, y),
        .grass_side => blk: {
            // Grass hanging over the top of dirt, raggedly.
            const depth: i32 = 3 + @as(i32, @intFromFloat(hash(x, 0, 77) * 3));
            break :blk if (y < depth) grassTop(x, y) else dirt(x, y);
        },
        .dirt => dirt(x, y),
        .stone => pack(scale(rgb(0x8a8a8c), 0.82 + smooth(x, y, 4, s) * 0.3 + (hash(x, y, s) - 0.5) * 0.08), 1),
        .cobblestone => cobble(x, y, rgb(0x8c8c8c), s),
        .sand => pack(speckle(rgb(0xdccf9c), x, y, s, 0.06), 1),
        .sandstone_top => pack(scale(rgb(0xd8c690), 0.95 + smooth(x, y, 8, s) * 0.08), 1),
        .sandstone_side => blk: {
            const band: f32 = if (@mod(y, 5) == 4) 0.86 else 1;
            break :blk pack(scale(speckle(rgb(0xd5c08a), x, y, s, 0.04), band), 1);
        },
        .gravel => blk: {
            const pebble = smooth(x, y, 2, s);
            const tone = mix(rgb(0x7a756e), rgb(0xa49e95), pebble);
            break :blk pack(speckle(tone, x, y, s + 1, 0.12), 1);
        },
        .clay => pack(scale(rgb(0xa2a7b4), 0.95 + smooth(x, y, 8, s) * 0.1), 1),
        .snow => pack(scale(rgb(0xf2f6fb), 0.96 + hash(x, y, s) * 0.05), 1),
        .log_side => blk: {
            // Bark: dark furrows running up and down.
            const furrow = hash(x, @divFloor(y, 5), s) < 0.25 or @mod(x, 4) == 0;
            break :blk pack(speckle(if (furrow) rgb(0x4e3b24) else rgb(0x6e5434), x, y, s, 0.08), 1);
        },
        .log_top => blk: {
            const dx = @as(f32, @floatFromInt(x)) - 7.5;
            const dy = @as(f32, @floatFromInt(y)) - 7.5;
            const r = @sqrt(dx * dx + dy * dy);
            if (r > 6.8) break :blk pack(speckle(rgb(0x5a4429), x, y, s, 0.08), 1);
            const ring = @mod(r, 2.2) < 1.1;
            break :blk pack(speckle(if (ring) rgb(0xb89466) else rgb(0x9c784c), x, y, s, 0.05), 1);
        },
        .planks => planks(x, y, rgb(0xa8834e), s),
        .dark_planks => planks(x, y, rgb(0x6a4a2e), s),
        .leaves => blk: {
            // Clumps of leaves with darker gaps (the gaps are not holes:
            // leaves are drawn solid).
            const clump = smooth(x, y, 4, s) * 0.6 + hash(x, y, s) * 0.4;
            const base = if (clump < 0.35) rgb(0x24521d) else if (clump > 0.7) rgb(0x5ea543) else rgb(0x3f7d2f);
            break :blk pack(base, 1);
        },
        .glass => blk: {
            const edge = x == 0 or y == 0 or x == 15 or y == 15;
            if (edge) break :blk pack(rgb(0xdbeaf0), 0.95);
            // Streaks of reflection.
            const streak = @mod(x + y, 16) == 5 or @mod(x + y, 16) == 6 or @mod(x + y, 16) == 12;
            break :blk if (streak) pack(rgb(0xffffff), 0.45) else pack(rgb(0xc8e4f0), 0.12);
        },
        .bricks => blk: {
            const row = @divFloor(y, 4);
            const off: i32 = if (@mod(row, 2) == 0) 0 else 4;
            const mortar = @mod(y, 4) == 3 or @mod(x + off, 8) == 7;
            if (mortar) break :blk pack(speckle(rgb(0xbdb6a8), x, y, s, 0.05), 1);
            const brick = hash(@divFloor(x + off, 8), row, s);
            break :blk pack(speckle(scale(rgb(0x9a4434), 0.85 + brick * 0.3), x, y, s + 1, 0.06), 1);
        },
        .stone_bricks => blk: {
            const row = @divFloor(y, 8);
            const off: i32 = if (@mod(row, 2) == 0) 0 else 4;
            const grout = @mod(y, 8) == 7 or @mod(x + off, 8) == 7;
            if (grout) break :blk pack(rgb(0x5a5a5c), 1);
            const lit = @mod(y, 8) == 0 or @mod(x + off, 8) == 0;
            break :blk pack(speckle(scale(rgb(0x8e8e90), if (lit) 1.12 else 1), x, y, s, 0.07), 1);
        },
        .roof => blk: {
            // Overlapping terracotta tiles, in staggered rows.
            const row = @divFloor(y, 4);
            const off: i32 = if (@mod(row, 2) == 0) 0 else 2;
            const u = @mod(x + off, 4);
            const v = @mod(y, 4);
            const shade: f32 = if (v == 3 or u == 3) 0.66 else if (v == 0) 1.12 else 1;
            break :blk pack(speckle(scale(rgb(0xb5533a), shade), x, y, s, 0.05), 1);
        },
        .plaster => pack(scale(rgb(0xebe5d4), 0.96 + smooth(x, y, 4, s) * 0.06), 1),
        .iron => metal(x, y, rgb(0xd2d4d8), s),
        .gold => metal(x, y, rgb(0xf4c542), s),
        .lamp => blk: {
            const frame = x == 0 or y == 0 or x == 15 or y == 15 or x == 7 or x == 8 or y == 7 or y == 8;
            if (frame) break :blk pack(rgb(0x5c4630), 1);
            const glow = smooth(x, y, 4, s);
            break :blk pack(mix(rgb(0xffd27a), rgb(0xfff6d8), glow), 1);
        },
        .bookshelf => blk: {
            if (y < 2 or y > 13 or y == 7 or y == 8) break :blk planks(x, y, rgb(0xa8834e), 99);
            // Books: a colour each, some leaning short.
            const book = @divFloor(x, 2) + (if (y > 7) @as(i32, 11) else 0);
            const colours = [_]u24{ 0x8c2f2a, 0x2f5a8c, 0x3c7a3a, 0xc4a43a, 0x6a3a7a, 0x7a4a2a };
            const c = colours[@intFromFloat(hash(book, 0, s) * colours.len)];
            const top: i32 = if (y > 7) 9 else 2;
            const short = hash(book, 1, s) < 0.3 and y == top;
            if (short) break :blk pack(rgb(0x3a2a1a), 1);
            break :blk pack(scale(rgb(c), if (@mod(x, 2) == 1) 0.8 else 1), 1);
        },
        .white => wool(x, y, rgb(0xeeeeee), s),
        .black => wool(x, y, rgb(0x2a2a2e), s),
        .red => wool(x, y, rgb(0xb8312f), s),
        .orange => wool(x, y, rgb(0xe8822a), s),
        .yellow => wool(x, y, rgb(0xf2cd34), s),
        .green => wool(x, y, rgb(0x5a9c32), s),
        .blue => wool(x, y, rgb(0x3550a8), s),
        .purple => wool(x, y, rgb(0x7f3fb2), s),
        .pink => wool(x, y, rgb(0xf08cb4), s),
        .cyan => wool(x, y, rgb(0x2b9aa0), s),
        .tall_grass => blk: {
            // Blades: each column has one, of its own height.
            const height: i32 = 5 + @as(i32, @intFromFloat(hash(x, 0, s) * 10));
            const blade = hash(x, 1, s) < 0.6 and y >= 16 - height;
            if (!blade) break :blk 0;
            break :blk pack(scale(mix(rgb(0x3d7a2a), rgb(0x7cc04e), @as(f32, @floatFromInt(16 - y)) / 16), 0.9 + hash(x, 2, s) * 0.2), 1);
        },
        .red_flower => flower(x, y, rgb(0xd8302a), rgb(0x3a1a10), s),
        .yellow_flower => flower(x, y, rgb(0xf4d232), rgb(0xd8941e), s),
        .water => blk: {
            const ripple = smooth(x, y + @divFloor(x, 3), 4, s);
            break :blk pack(mix(rgb(0x2a6fb8), rgb(0x6ab4e8), ripple * ripple), 0.85);
        },
    };
}

fn grassTop(x: i32, y: i32) Pixel {
    const blade = hash(x, y, 3);
    const tone = mix(rgb(0x5f9e3c), rgb(0x79b84a), smooth(x, y, 4, 4));
    return pack(scale(tone, 0.9 + blade * 0.2), 1);
}

fn dirt(x: i32, y: i32) Pixel {
    const n = hash(x, y, 5);
    const base = if (n > 0.92) rgb(0x6d4c33) else if (n < 0.08) rgb(0x9a7552) else rgb(0x86613f);
    return pack(scale(base, 0.92 + smooth(x, y, 4, 6) * 0.16), 1);
}

fn cobble(x: i32, y: i32, base: Rgb, s: u32) Pixel {
    // The nearest of a few scattered points (wrapping) picks the stone;
    // close to two of them is the mortar between.
    var best: f32 = 1e9;
    var second: f32 = 1e9;
    var which: u32 = 0;
    var i: u32 = 0;
    while (i < 7) : (i += 1) {
        const px = hash(@intCast(i), 0, s) * 16;
        const py = hash(@intCast(i), 1, s) * 16;
        var ox: i32 = -1;
        while (ox <= 1) : (ox += 1) {
            var oy: i32 = -1;
            while (oy <= 1) : (oy += 1) {
                const dx = @as(f32, @floatFromInt(x)) + 0.5 - (px + @as(f32, @floatFromInt(ox * 16)));
                const dy = @as(f32, @floatFromInt(y)) + 0.5 - (py + @as(f32, @floatFromInt(oy * 16)));
                const d = @sqrt(dx * dx + dy * dy);
                if (d < best) {
                    second = best;
                    best = d;
                    which = i;
                } else if (d < second) second = d;
            }
        }
    }
    if (second - best < 1.2) return pack(scale(base, 0.5), 1);
    const tone = 0.8 + hash(@intCast(which), 2, s) * 0.35;
    return pack(speckle(scale(base, tone * (1.1 - best / 12)), x, y, s, 0.05), 1);
}

fn planks(x: i32, y: i32, base: Rgb, s: u32) Pixel {
    const board = @divFloor(y, 4);
    if (@mod(y, 4) == 3) return pack(scale(base, 0.6), 1);
    // Each board's end is somewhere of its own.
    const end: i32 = @intFromFloat(hash(board, 0, s) * 16);
    if (x == end) return pack(scale(base, 0.65), 1);
    const grain = smooth(x, board * 7, 4, s) * 0.12;
    return pack(speckle(scale(base, 0.92 + grain + hash(board, 1, s) * 0.1), x, y, s, 0.03), 1);
}

fn metal(x: i32, y: i32, base: Rgb, s: u32) Pixel {
    if (x == 0 or y == 0) return pack(scale(base, 1.15), 1);
    if (x == 15 or y == 15) return pack(scale(base, 0.7), 1);
    const rivet = (x == 2 or x == 13) and (y == 2 or y == 13);
    if (rivet) return pack(scale(base, 0.75), 1);
    // A sheen across it.
    const sheen = 1 - @abs(@as(f32, @floatFromInt(x + y)) - 15) / 30;
    return pack(scale(base, 0.88 + sheen * 0.18 + (hash(x, y, s) - 0.5) * 0.03), 1);
}

fn wool(x: i32, y: i32, base: Rgb, s: u32) Pixel {
    const fibre = smooth(x, y, 2, s) * 0.08 + hash(x, y, s) * 0.06;
    return pack(scale(base, 0.93 + fibre), 1);
}

fn flower(x: i32, y: i32, petal: Rgb, centre: Rgb, s: u32) Pixel {
    const fx = @as(f32, @floatFromInt(x)) - 7.5;
    const fy = @as(f32, @floatFromInt(y)) - 5;
    const r = @sqrt(fx * fx + fy * fy);
    if (r < 1.2) return pack(centre, 1);
    if (r < 3.3) return pack(scale(petal, 0.9 + hash(x, y, s) * 0.2), 1);
    // The stem, and a leaf.
    if ((x == 7 or x == 8) and y > 7) return pack(rgb(0x3d7a2a), 1);
    if (y == 11 and x > 8 and x < 12) return pack(rgb(0x4c8c34), 1);
    if (y == 12 and x > 3 and x < 7) return pack(rgb(0x4c8c34), 1);
    return 0;
}

/// The whole atlas, `atlas_size` square, row by row.
pub fn atlas(out: *[atlas_size * atlas_size]Pixel) void {
    @memset(out, 0xff000000);
    for (std.enums.values(Tile)) |t| {
        const i: u32 = @intFromEnum(t);
        const ox = (i % tiles_across) * tile_size;
        const oy = (i / tiles_across) * tile_size;
        for (0..tile_size) |y| for (0..tile_size) |x| {
            out[(oy + y) * atlas_size + ox + x] = pixel(t, @intCast(x), @intCast(y));
        };
    }
}

// --- Icons ------------------------------------------------------------------------------

pub const icon_size = 48;

/// A block's icon: a cube seen from above at an angle, lit from the left
/// (a plant or flat tile as it is, larger).
pub fn icon(b: Block, out: *[icon_size * icon_size]Pixel) void {
    @memset(out, 0);
    const n: f32 = icon_size;
    if (b.shape() == .plant) {
        const t = b.tile(.north);
        for (0..icon_size) |y| for (0..icon_size) |x| {
            const tx: i32 = @intCast(x * tile_size / icon_size);
            const ty: i32 = @intCast(y * tile_size / icon_size);
            out[y * icon_size + x] = pixel(t, tx, ty);
        };
        return;
    }
    // The faces' corners (top, left, right), and how bright each is.
    const Face = struct { o: [2]f32, e1: [2]f32, e2: [2]f32, tile: Tile, light: f32 };
    const top_y = n * 0.04;
    const faces = [_]Face{
        .{ .o = .{ n / 2, top_y }, .e1 = .{ n / 2, n * 0.24 }, .e2 = .{ -n / 2, n * 0.24 }, .tile = b.tile(.up), .light = 1 },
        .{ .o = .{ 0, top_y + n * 0.24 }, .e1 = .{ n / 2, n * 0.24 }, .e2 = .{ 0, n * 0.48 }, .tile = b.tile(.north), .light = 0.78 },
        .{ .o = .{ n / 2, top_y + n * 0.48 }, .e1 = .{ n / 2, -n * 0.24 }, .e2 = .{ 0, n * 0.48 }, .tile = b.tile(.east), .light = 0.6 },
    };
    for (0..icon_size) |y| for (0..icon_size) |x| {
        const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
        for (faces) |f| {
            // p = o + a·e1 + b·e2.
            const det = f.e1[0] * f.e2[1] - f.e1[1] * f.e2[0];
            const dx = p[0] - f.o[0];
            const dy = p[1] - f.o[1];
            const a = (dx * f.e2[1] - dy * f.e2[0]) / det;
            const c = (f.e1[0] * dy - f.e1[1] * dx) / det;
            if (a < 0 or a >= 1 or c < 0 or c >= 1) continue;
            const texel = pixel(f.tile, @intFromFloat(a * tile_size), @intFromFloat(c * tile_size));
            const alpha: f32 = @floatFromInt(texel >> 24);
            if (alpha == 0) continue;
            const col = Rgb{ @floatFromInt(texel >> 16 & 0xff), @floatFromInt(texel >> 8 & 0xff), @floatFromInt(texel & 0xff) };
            // Glass shows as its frame and a pale fill.
            out[y * icon_size + x] = pack(scale(col, f.light), @max(alpha / 255, 0.35));
            break;
        }
    };
}

test "the atlas holds every tile, opaque except where things are see-through" {
    var px: [atlas_size * atlas_size]Pixel = undefined;
    atlas(&px);
    const at = struct {
        fn f(p: []const Pixel, t: Tile, x: u32, y: u32) Pixel {
            const i: u32 = @intFromEnum(t);
            return p[((i / tiles_across) * tile_size + y) * atlas_size + (i % tiles_across) * tile_size + x];
        }
    }.f;
    for (std.enums.values(Tile)) |t| {
        const see_through = t == .glass or t == .water or t == .tall_grass or t == .red_flower or t == .yellow_flower;
        var clear: u32 = 0;
        for (0..tile_size) |y| for (0..tile_size) |x| {
            if (at(&px, t, @intCast(x), @intCast(y)) >> 24 != 0xff) clear += 1;
        };
        try std.testing.expect((clear > 0) == see_through);
    }
    // Grass is green, sand is pale.
    const g = at(&px, .grass_top, 5, 5);
    try std.testing.expect((g >> 8 & 0xff) > (g >> 16 & 0xff));
    try std.testing.expectEqual([2]f32{ 0.125, 0 }, tileOrigin(.grass_side));
    try std.testing.expectEqual([2]f32{ 0, 0.125 }, tileOrigin(.gravel));
}

test "icons show the cube's three faces, or the plant" {
    var px: [icon_size * icon_size]Pixel = undefined;
    icon(.bricks, &px);
    // Middle of the top, left and right faces; corners empty.
    try std.testing.expect(px[10 * icon_size + 24] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 10] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 38] >> 24 == 0xff);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
    try std.testing.expectEqual(@as(Pixel, 0), px[47 * icon_size]);
    icon(.red_flower, &px);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
}
