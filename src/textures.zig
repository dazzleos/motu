//! The blocks' looks, drawn here rather than loaded: each tile is 64 by 64
//! pixels, made from noise that wraps at the tile's edges (so tiles join
//! without seams), cells for stones and pebbles, bevels for bricks and
//! boards, and a little light and shade drawn in. They are laid out in
//! strips of 16 tiles, one tile across (see blocks.Tile), which the GPU
//! samples with mipmaps: smooth up close, and without shimmering far off.
//! Icons for the hotbar are small cubes drawn from the same tiles.

const std = @import("std");
const blocks = @import("blocks.zig");

const Block = blocks.Block;
const Tile = blocks.Tile;

pub const tile_size = 64;
pub const strip_width = tile_size;
pub const strip_height = tile_size * Tile.per_strip;

/// 0xAARRGGBB.
const Pixel = u32;

// --- Colour ----------------------------------------------------------------------------

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
    const k = std.math.clamp(t, 0, 1);
    return .{ a[0] + (b[0] - a[0]) * k, a[1] + (b[1] - a[1]) * k, a[2] + (b[2] - a[2]) * k };
}

fn smoothstep(lo: f32, hi: f32, x: f32) f32 {
    const t = std.math.clamp((x - lo) / (hi - lo), 0, 1);
    return t * t * (3 - 2 * t);
}

// --- Noise that wraps at the tile's edges -------------------------------------------------

fn hash(x: i32, y: i32, salt: u32) f32 {
    var h: u32 = @as(u32, @bitCast(x)) *% 0x27d4eb2d ^ @as(u32, @bitCast(y)) *% 0x165667b1 ^ salt *% 0x9e3779b9;
    h ^= h >> 15;
    h *%= 0x85ebca6b;
    h ^= h >> 13;
    h *%= 0xc2b2ae35;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777216.0;
}

/// Smooth noise from 0 to 1 at (u, v) (0 to 1 across the tile), with
/// `cells` cells across, wrapping.
fn noise(u: f32, v: f32, cells: i32, salt: u32) f32 {
    const c: f32 = @floatFromInt(cells);
    const x = u * c;
    const y = v * c;
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    const fx = x - @floor(x);
    const fy = y - @floor(y);
    const sx = fx * fx * (3 - 2 * fx);
    const sy = fy * fy * (3 - 2 * fy);
    const a = hash(@mod(ix, cells), @mod(iy, cells), salt);
    const b = hash(@mod(ix + 1, cells), @mod(iy, cells), salt);
    const d = hash(@mod(ix, cells), @mod(iy + 1, cells), salt);
    const e = hash(@mod(ix + 1, cells), @mod(iy + 1, cells), salt);
    return (a + (b - a) * sx) * (1 - sy) + (d + (e - d) * sx) * sy;
}

/// Noise at several scales, from `cells` across up.
fn fbm(u: f32, v: f32, cells: i32, octaves: u32, salt: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var total: f32 = 0;
    var c = cells;
    for (0..octaves) |o| {
        sum += noise(u, v, c, salt +% @as(u32, @intCast(o)) *% 31) * amp;
        total += amp;
        amp *= 0.5;
        c *= 2;
    }
    return sum / total;
}

/// The cells around scattered points (one in each of `cells` by `cells`
/// squares, wrapping): how far the nearest is, and the next, and which.
const Cell = struct { d1: f32, d2: f32, id: u32, cx: f32, cy: f32 };

fn cellsAt(u: f32, v: f32, cells: i32, salt: u32) Cell {
    const c: f32 = @floatFromInt(cells);
    const x = u * c;
    const y = v * c;
    const ix: i32 = @intFromFloat(@floor(x));
    const iy: i32 = @intFromFloat(@floor(y));
    var out: Cell = .{ .d1 = 9, .d2 = 9, .id = 0, .cx = 0, .cy = 0 };
    var dy: i32 = -1;
    while (dy <= 1) : (dy += 1) {
        var dx: i32 = -1;
        while (dx <= 1) : (dx += 1) {
            const gx = ix + dx;
            const gy = iy + dy;
            const wx = @mod(gx, cells);
            const wy = @mod(gy, cells);
            const px = @as(f32, @floatFromInt(gx)) + 0.15 + 0.7 * hash(wx, wy, salt);
            const py = @as(f32, @floatFromInt(gy)) + 0.15 + 0.7 * hash(wx, wy, salt +% 1);
            const d = @sqrt((x - px) * (x - px) + (y - py) * (y - py));
            if (d < out.d1) {
                out.d2 = out.d1;
                out.d1 = d;
                out.id = @bitCast(wy * cells + wx);
                out.cx = x - px;
                out.cy = y - py;
            } else if (d < out.d2) out.d2 = d;
        }
    }
    return out;
}

/// Light and shade at the edges of a raised rectangle `w` by `h`, at (x,
/// y) in it: lit along the top and left, shaded along the bottom and
/// right, `width` pixels in.
fn bevel(x: f32, y: f32, w: f32, h: f32, width: f32) f32 {
    const top = 1 - smoothstep(0, width, y);
    const left = 1 - smoothstep(0, width, x);
    const bottom = 1 - smoothstep(0, width, h - 1 - y);
    const right = 1 - smoothstep(0, width, w - 1 - x);
    return 1 + 0.22 * @max(top, left) - 0.3 * @max(bottom, right);
}

// --- The tiles ------------------------------------------------------------------------------

/// A pixel of a tile, at (x, y) in pixels (0 to 63).
pub fn pixel(t: Tile, xi: u32, yi: u32) Pixel {
    const n: f32 = tile_size;
    const x = @as(f32, @floatFromInt(xi)) + 0.5;
    const y = @as(f32, @floatFromInt(yi)) + 0.5;
    const u = x / n;
    const v = y / n;
    const s: u32 = @as(u32, @intFromEnum(t)) *% 7919 +% 13;
    return switch (t) {
        .grass_top => grass(u, v),
        .grass_side => blk: {
            // Grass hanging over the dirt: a ragged edge, with strands
            // further down, and a shadow under it.
            const edge = 10 + 6 * fbm(u, 0.3, 8, 2, 77) + 7 * smoothstep(0.72, 1, hash(@intFromFloat(@floor(u * 32)), 0, 78));
            if (y < edge) break :blk grass(u, v);
            const shade = 0.7 + 0.3 * smoothstep(edge, edge + 6, y);
            break :blk pack(scale(dirtColour(u, v), shade), 1);
        },
        .dirt => pack(dirtColour(u, v), 1),
        .stone => pack(stoneColour(u, v, rgb(0x8a8a8e), s), 1),
        .sand => blk: {
            const ripple = noise(u + v * 0.25, v * 0.25, 8, s) * 0.5 + 0.5 * noise(u, v, 16, s +% 1);
            const grain = hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5;
            break :blk pack(scale(rgb(0xdccda0), 0.92 + ripple * 0.1 + grain * 0.08), 1);
        },
        .sandstone_top => pack(scale(rgb(0xd8c48f), 0.9 + fbm(u, v, 4, 3, s) * 0.18 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.04), 1),
        .sandstone_side => blk: {
            // Layers of different thickness, worn unevenly.
            const layer = fbm(0.1, v + noise(u, v, 4, s) * 0.03, 8, 2, s +% 2);
            const line = smoothstep(0.03, 0, @abs(@mod(v * 5 + noise(u, v, 4, s) * 0.3, 1) - 0.02));
            break :blk pack(scale(mix(rgb(0xc9b07c), rgb(0xe0cc98), layer), 1 - line * 0.18 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.04), 1);
        },
        .gravel => blk: {
            const c = cellsAt(u, v, 10, s);
            const tone = hash(@intCast(c.id), 0, s);
            const base = mix(rgb(0x6f6a62), rgb(0xb0a99e), tone);
            const lit = 1 + 0.25 * (-c.cx - c.cy) * 0.7;
            const gap = smoothstep(0.08, 0, c.d2 - c.d1);
            break :blk pack(scale(base, lit * (1 - gap * 0.45)), 1);
        },
        .clay => pack(scale(mix(rgb(0x949aa8), rgb(0xadb2be), fbm(u, v, 4, 3, s)), 0.97 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.04), 1),
        .snow => blk: {
            const drift = fbm(u, v, 4, 3, s);
            const sparkle: f32 = if (hash(@intFromFloat(x), @intFromFloat(y), s) > 0.985) 0.08 else 0;
            break :blk pack(scale(mix(rgb(0xdbe6f2), rgb(0xf8fbff), drift), 1 + sparkle), 1);
        },
        .log_side => blk: {
            // Bark: eight furrows running up, wandering and widening and
            // narrowing, with rounded ridges between.
            var nearest: f32 = 99;
            var width: f32 = 1;
            for (0..8) |k| {
                const kk: i32 = @intCast(k);
                const wander = (noise(@as(f32, @floatFromInt(k)) / 8, v, 4, s +% 1) - 0.5) * 5;
                const centre = @as(f32, @floatFromInt(k)) * 8 + 4 + (hash(kk, 0, s) - 0.5) * 3 + wander;
                // The nearest way round (the tile repeats across).
                const d = @abs(@mod(x - centre + 32, 64) - 32);
                if (d < nearest) {
                    nearest = d;
                    width = 0.3 + 1.3 * noise(@as(f32, @floatFromInt(k)) / 8, v, 8, s +% 2);
                }
            }
            const furrow = smoothstep(width + 0.8, width - 0.4, nearest);
            const ridge = 1 - (nearest / 4) * (nearest / 4) * 0.25;
            const base = mix(rgb(0x7a5c3a), rgb(0x2b1e10), furrow);
            break :blk pack(scale(base, ridge * (0.9 + noise(u, v, 32, s +% 3) * 0.18)), 1);
        },
        .log_top => blk: {
            const dx = u - 0.5;
            const dy = v - 0.5;
            const r = @sqrt(dx * dx + dy * dy) + (noise(u, v, 8, s) - 0.5) * 0.03;
            if (r > 0.44) break :blk pack(scale(rgb(0x4f3b23), 0.85 + noise(u, v, 16, s) * 0.3), 1);
            const ring = 0.5 + 0.5 * @cos(r * 70);
            const crack = smoothstep(0.012, 0, @abs(@mod(std.math.atan2(dy, dx) * 2.5 + 0.3, 2 * std.math.pi) - 1)) * smoothstep(0.1, 0.3, r);
            break :blk pack(scale(mix(rgb(0xa47d4c), rgb(0xc89e68), ring), (0.92 + 0.08 * (1 - r)) * (1 - crack * 0.4)), 1);
        },
        .leaves => blk: {
            // Leaves in clumps, each lit from above, darker deeper in.
            const c = cellsAt(u, v, 9, s);
            const depth = noise(u, v, 4, s +% 3);
            const tone = hash(@intCast(c.id), 1, s);
            const base = mix(mix(rgb(0x1f4a18), rgb(0x4e9a36), depth), rgb(0x76b84e), tone * 0.35);
            const lit = 1.1 - c.d1 * 0.5 - c.cy * 0.25;
            const gap = smoothstep(0.1, 0, c.d2 - c.d1);
            break :blk pack(scale(base, lit * (1 - gap * 0.55)), 1);
        },
        .tall_grass => blk: {
            // Blades curving up from the bottom.
            var best: f32 = 0;
            var tone: f32 = 0;
            for (0..9) |i| {
                const bx = 0.08 + 0.84 * hash(@intCast(i), 0, s);
                const top = 0.15 + 0.45 * hash(@intCast(i), 1, s);
                const lean = (hash(@intCast(i), 2, s) - 0.5) * 0.25;
                if (v < top) continue;
                const along = (1 - v) / (1 - top);
                const cx = bx + lean * along * along;
                const width = 0.035 * (1 - along * 0.8);
                const d = @abs(u - cx);
                if (d < width and along > best) {
                    best = @max(best, 1 - d / width * 0.3);
                    tone = along;
                }
            }
            if (best == 0) break :blk 0;
            break :blk pack(scale(mix(rgb(0x2f6a22), rgb(0x8fd05a), tone), 0.85 + best * 0.2), 1);
        },
        .red_flower => flower(u, v, rgb(0xd42a24), rgb(0x2a120a), s),
        .yellow_flower => flower(u, v, rgb(0xf6d02e), rgb(0xd08018), s),
        .cobblestone => blk: {
            const c = cellsAt(u, v, 4, s);
            const gap = smoothstep(0.12, 0.02, c.d2 - c.d1);
            if (gap > 0.95) break :blk pack(scale(rgb(0x3e3e40), 0.8 + noise(u, v, 32, s) * 0.4), 1);
            const tone = 0.78 + hash(@intCast(c.id), 2, s) * 0.32;
            // Rounded: lit towards the top left of each stone.
            const lit = 1.05 - 0.35 * c.d1 - 0.3 * (c.cx + c.cy);
            const base = stoneColour(u, v, rgb(0x8c8c8c), s +% 5);
            break :blk pack(scale(base, tone * lit * (1 - gap * 0.6)), 1);
        },
        .planks => planks(u, v, x, y, rgb(0xa9814c), s),
        .dark_planks => planks(u, v, x, y, rgb(0x5e412a), s),
        .glass => blk: {
            const edge = @min(@min(x, y), @min(n - x, n - y));
            if (edge < 3) break :blk pack(scale(rgb(0xd8e8ee), if (x < 3 or y < 3) 1.05 else 0.8), 0.95);
            // Reflections: two bright streaks.
            const d = @mod(x + y, 64);
            const streak = smoothstep(3, 0, @abs(d - 18)) * 0.6 + smoothstep(1.5, 0, @abs(d - 26)) * 0.4;
            break :blk pack(mix(rgb(0xbfdfeb), rgb(0xffffff), streak), 0.1 + streak * 0.45);
        },
        .bricks => blk: {
            const row = @floor(y / 16);
            const off: f32 = if (@mod(row, 2) == 0) 0 else 16;
            const bx = @mod(x + off, 32);
            const by = @mod(y, 16);
            const mortar = bx < 2 or by < 2;
            if (mortar) break :blk pack(scale(rgb(0xc4bcae), 0.85 + noise(u, v, 32, s) * 0.2), 1);
            const id: i32 = @intFromFloat(@floor((x + off) / 32) + row * 3);
            const tone = 0.82 + hash(@mod(id, 64), 3, s) * 0.3;
            const grain = (noise(u, v, 32, s +% 1) - 0.5) * 0.15 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.08;
            break :blk pack(scale(mix(rgb(0x9a3d2c), rgb(0xb3583e), noise(u, v, 8, s)), tone * bevel(bx - 2, by - 2, 30, 14, 3) + grain), 1);
        },
        .stone_bricks => blk: {
            const row = @floor(y / 32);
            const off: f32 = if (@mod(row, 2) == 0) 0 else 16;
            const bx = @mod(x + off, 32);
            const by = @mod(y, 32);
            if (bx < 2 or by < 2) break :blk pack(rgb(0x4a4a4c), 1);
            const id: i32 = @intFromFloat(@floor((x + off) / 32) + row * 2);
            const crack = smoothstep(0.02, 0, @abs(noise(u, v, 4, s +% @as(u32, @intCast(id))) - 0.5)) * 0.35;
            break :blk pack(scale(stoneColour(u, v, rgb(0x8e8e92), s), (0.88 + hash(id, 4, s) * 0.2) * bevel(bx - 2, by - 2, 30, 30, 4) - crack), 1);
        },
        .roof => blk: {
            // Overlapping clay tiles: rows, each tile rounded at its foot.
            const row = @floor(y / 16);
            const off: f32 = if (@mod(row, 2) == 0) 0 else 8;
            const tx = @mod(x + off, 16) / 16;
            const ty = @mod(y, 16) / 16;
            const round = ty - (1 - 0.25 * @sqrt(@max(0, 1 - (tx * 2 - 1) * (tx * 2 - 1))));
            const shade = if (round > 0) 0.55 else 0.8 + 0.4 * ty;
            const side = 1 - 0.25 * @abs(tx * 2 - 1);
            break :blk pack(scale(mix(rgb(0xa8452e), rgb(0xc8603e), noise(u, v, 8, s)), shade * side), 1);
        },
        .plaster => pack(scale(rgb(0xece6d6), 0.94 + fbm(u, v, 4, 3, s) * 0.08 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.03), 1),
        .iron => metal(u, v, x, y, rgb(0xc9ccd2), s),
        .gold => metal(u, v, x, y, rgb(0xf2c23c), s),
        .lamp => blk: {
            // A frame of four panes, glowing brightest in the middle.
            const fx = @mod(x, 32);
            const fy = @mod(y, 32);
            const frame = fx < 4 or fy < 4;
            if (frame) break :blk pack(scale(rgb(0x5a4128), bevel(@mod(x, 4), @mod(y, 4), 4, 4, 1.5)), 1);
            const dx = (fx - 18) / 14;
            const dy = (fy - 18) / 14;
            const glow = 1 - @min(dx * dx + dy * dy, 1);
            break :blk pack(mix(rgb(0xffbf5a), rgb(0xfff8e6), glow * 0.8 + noise(u, v, 8, s) * 0.2), 1);
        },
        .bookshelf => bookshelf(u, v, x, y, s),
        .water => blk: {
            const ripple = fbm(u + noise(u, v, 4, s) * 0.1, v, 4, 3, s +% 1);
            break :blk pack(mix(rgb(0x1f5fa8), rgb(0x6ab8ea), ripple * ripple * 1.5), 0.85);
        },
        .white => fabric(u, v, x, y, rgb(0xefefef), s),
        .black => fabric(u, v, x, y, rgb(0x27272b), s),
        .red => fabric(u, v, x, y, rgb(0xb52e2b), s),
        .orange => fabric(u, v, x, y, rgb(0xe8802a), s),
        .yellow => fabric(u, v, x, y, rgb(0xf2cc33), s),
        .green => fabric(u, v, x, y, rgb(0x5a9a30), s),
        .blue => fabric(u, v, x, y, rgb(0x334ea6), s),
        .purple => fabric(u, v, x, y, rgb(0x7d3db0), s),
        .pink => fabric(u, v, x, y, rgb(0xee8ab2), s),
        .cyan => fabric(u, v, x, y, rgb(0x27969c), s),
    };
}

fn grass(u: f32, v: f32) Pixel {
    const patch = fbm(u, v, 4, 3, 3);
    const blades = noise(u * 1.0, v * 0.5, 32, 4);
    const base = mix(rgb(0x4f8f30), rgb(0x86c050), patch * 0.8 + blades * 0.4);
    const speck = hash(@intFromFloat(u * 64), @intFromFloat(v * 64), 5);
    return pack(scale(base, 0.88 + speck * 0.18), 1);
}

fn dirtColour(u: f32, v: f32) Rgb {
    // Soil, with small stones in it.
    const c = cellsAt(u, v, 12, 9);
    const stone = smoothstep(0.32, 0.22, c.d1) * @as(f32, if (hash(@intCast(c.id), 0, 9) > 0.6) 1 else 0);
    const soil = mix(rgb(0x6b4a30), rgb(0x92683f), fbm(u, v, 4, 4, 6));
    const pebble = scale(rgb(0x9a8c7a), 1.05 - c.cy * 0.4);
    return scale(mix(soil, pebble, stone), 0.94 + hash(@intFromFloat(u * 64), @intFromFloat(v * 64), 7) * 0.1);
}

fn stoneColour(u: f32, v: f32, base: Rgb, s: u32) Rgb {
    const body = fbm(u, v, 4, 4, s);
    // Cracks: where a smooth noise passes through its middle.
    const crack = smoothstep(0.018, 0, @abs(noise(u, v, 3, s +% 9) - 0.5)) * smoothstep(0.4, 0.6, noise(u, v, 4, s +% 10));
    const speck = hash(@intFromFloat(u * 64), @intFromFloat(v * 64), s) - 0.5;
    return scale(base, 0.78 + body * 0.38 + speck * 0.06 - crack * 0.3);
}

fn planks(u: f32, v: f32, x: f32, y: f32, base: Rgb, s: u32) Pixel {
    const board = @floor(y / 16);
    const by = @mod(y, 16);
    // Each board's own grain, tone and end.
    const salt = s +% @as(u32, @intFromFloat(board)) *% 17;
    const end = hash(@intFromFloat(board), 0, s) * 64;
    const ex = @mod(x - end, 64);
    if (by < 1.5 or ex < 1.5) return pack(scale(base, 0.45), 1);
    const grain = noise(u * 0.25, v * 3 + noise(u, v, 4, salt) * 0.6, 16, salt);
    const streak = 0.5 + 0.5 * @cos((v * 16 + grain * 3) * std.math.pi * 2);
    const tone = 0.86 + hash(@intFromFloat(board), 1, s) * 0.18;
    // A nail at each end.
    const nail = (@abs(ex - 5) < 1.2 or @abs(ex - 58) < 1.2) and @abs(by - 8) < 1.2;
    if (nail) return pack(scale(rgb(0x3a3430), 1.2), 1);
    return pack(scale(base, tone * (0.88 + streak * 0.16) * bevel(ex - 1.5, by - 1.5, 61, 14.5, 2)), 1);
}

fn metal(u: f32, v: f32, x: f32, y: f32, base: Rgb, s: u32) Pixel {
    // Brushed across, a sheen, bevelled edges and rivets.
    const brushed = noise(u * 0.0625, v, 64, s) * 0.08;
    const sheen = 0.5 + 0.5 * @cos((u + v - 0.6) * 4);
    const rivet_x = @min(@abs(x - 7), @abs(x - 57));
    const rivet_y = @min(@abs(y - 7), @abs(y - 57));
    const rd = @sqrt(rivet_x * rivet_x + rivet_y * rivet_y);
    if (rd < 3) return pack(scale(base, 0.75 + 0.5 * smoothstep(2.5, 0, rd + (x - 7 + y - 7) * 0.0)), 1);
    return pack(scale(base, (0.8 + sheen * 0.22 + brushed) * bevel(x - 0.5, y - 0.5, 64, 64, 4)), 1);
}

fn fabric(u: f32, v: f32, x: f32, y: f32, base: Rgb, s: u32) Pixel {
    // A soft weave.
    const weave = 0.5 + 0.25 * @cos(x * std.math.pi / 2) + 0.25 * @cos(y * std.math.pi / 2);
    const fuzz = fbm(u, v, 8, 2, s);
    return pack(scale(base, 0.9 + weave * 0.06 + fuzz * 0.1), 1);
}

fn flower(u: f32, v: f32, petal: Rgb, centre: Rgb, s: u32) Pixel {
    const dx = u - 0.5;
    const dy = v - 0.3;
    const r = @sqrt(dx * dx + dy * dy);
    const a = std.math.atan2(dy, dx);
    // Five petals: a wavy edge.
    const edge = 0.15 + 0.05 * @cos(a * 5);
    if (r < 0.05) return pack(scale(centre, 1.1 - r * 4), 1);
    if (r < edge) return pack(scale(petal, 0.8 + 0.35 * (1 - r / edge) + noise(u, v, 16, s) * 0.1), 1);
    // The stem, and two leaves.
    if (@abs(u - 0.5 - (v - 0.45) * 0.08) < 0.02 and v > 0.4) return pack(scale(rgb(0x3d7a2a), 0.9 + v * 0.2), 1);
    const leaf1 = (u - 0.62) * (u - 0.62) / 0.012 + (v - 0.72) * (v - 0.72) / 0.002;
    const leaf2 = (u - 0.38) * (u - 0.38) / 0.012 + (v - 0.8) * (v - 0.8) / 0.002;
    if (leaf1 < 1 or leaf2 < 1) return pack(rgb(0x4c8c34), 1);
    return 0;
}

fn bookshelf(u: f32, v: f32, x: f32, y: f32, s: u32) Pixel {
    // Two shelves of books between boards.
    const board = y < 4 or y >= 60 or (y >= 30 and y < 34);
    if (board) return planks(u, v, x, y + 8, rgb(0xa9814c), 99);
    const shelf: u32 = if (y < 32) 0 else 1;
    const top: f32 = if (shelf == 0) 4 else 34;
    // Books of different widths, colours and heights.
    var bx: f32 = 1;
    var i: u32 = 0;
    while (bx < 64) : (i += 1) {
        const w = 5 + @floor(hash(@intCast(i), @intCast(shelf), s) * 5);
        if (x < bx + w) {
            const colours = [_]u24{ 0x8c2f2a, 0x2f5a8c, 0x3c7a3a, 0xc4a43a, 0x6a3a7a, 0x7a4a2a, 0x2a6a6a };
            const c = rgb(colours[@intFromFloat(hash(@intCast(i), @intCast(shelf + 7), s) * colours.len)]);
            const height = 18 + hash(@intCast(i), @intCast(shelf + 3), s) * 8;
            if (y < top + 26 - height) return pack(rgb(0x241a10), 1);
            const lx = x - bx;
            // A band across the spine, and the round of it.
            const band = @abs(y - (top + 26 - height * 0.3)) < 1.2;
            const round = 1 - 0.35 * @abs(lx / w * 2 - 1);
            return pack(scale(if (band) rgb(0xd8c070) else c, round * (0.9 + noise(u, v, 16, s) * 0.15)), 1);
        }
        bx += w;
    }
    return pack(rgb(0x241a10), 1);
}

/// Strip `strip`, `strip_width` by `strip_height`, row by row (tiles not
/// used left clear).
pub fn stripPixels(strip: u2, out: *[strip_width * strip_height]Pixel) void {
    @memset(out, 0);
    for (std.enums.values(Tile)) |t| {
        if (t.strip() != strip) continue;
        const oy = @as(u32, t.slot()) * tile_size;
        for (0..tile_size) |y| for (0..tile_size) |x| {
            out[(oy + y) * strip_width + x] = pixel(t, @intCast(x), @intCast(y));
        };
    }
}

// --- Icons ------------------------------------------------------------------------------

pub const icon_size = 48;

/// A block's icon: a cube seen from above at an angle, lit from the left
/// (a plant as it is).
pub fn icon(b: Block, out: *[icon_size * icon_size]Pixel) void {
    @memset(out, 0);
    const n: f32 = icon_size;
    if (b.shape() == .plant) {
        const t = b.tile(.north);
        for (0..icon_size) |y| for (0..icon_size) |x| {
            out[y * icon_size + x] = pixel(t, @intCast(x * tile_size / icon_size), @intCast(y * tile_size / icon_size));
        };
        return;
    }
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
            out[y * icon_size + x] = pack(scale(col, f.light), @max(alpha / 255, 0.35));
            break;
        }
    };
}

test "every tile is in its strip, opaque except where things are see-through, and joins its own edges" {
    const px = try std.testing.allocator.create([strip_width * strip_height]Pixel);
    defer std.testing.allocator.destroy(px);
    for (0..Tile.strips) |strip| {
        stripPixels(@intCast(strip), px);
        for (std.enums.values(Tile)) |t| {
            if (t.strip() != strip) continue;
            const oy = @as(u32, t.slot()) * tile_size;
            const see_through = t == .glass or t == .water or t == .tall_grass or t == .red_flower or t == .yellow_flower;
            var clear: u32 = 0;
            for (0..tile_size) |y| for (0..tile_size) |x| {
                if (px[(oy + y) * strip_width + x] >> 24 != 0xff) clear += 1;
            };
            try std.testing.expect((clear > 0) == see_through);
        }
    }
    // Wrapping noise: the left and right edges of grass are close in
    // colour (they meet when the tile repeats).
    stripPixels(0, px);
    var diff: i32 = 0;
    for (0..tile_size) |y| {
        const a = px[y * strip_width];
        const b = px[y * strip_width + tile_size - 1];
        diff += @as(i32, @intCast(a >> 8 & 0xff)) - @as(i32, @intCast(b >> 8 & 0xff));
    }
    try std.testing.expect(@abs(diff) < 64 * 12);
}

test "icons show the cube's three faces, or the plant" {
    var px: [icon_size * icon_size]Pixel = undefined;
    icon(.bricks, &px);
    try std.testing.expect(px[10 * icon_size + 24] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 10] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 38] >> 24 == 0xff);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
    icon(.red_flower, &px);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
}
