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

// --- The tiles ------------------------------------------------------------------------------

/// A texel: its colour as it is (no light or shade from any direction,
/// though grooves and gaps are darker, as little light gets in), how
/// opaque it is, and how high it stands, in texels (from which its normal
/// is worked out: see `normals`).
pub const Texel = struct {
    c: Rgb,
    a: f32 = 1,
    h: f32 = 0,
};

fn tx(c: Rgb, h: f32) Texel {
    return .{ .c = c, .h = h };
}

const nothing: Texel = .{ .c = .{ 0, 0, 0 }, .a = 0 };

/// A texel of a tile, at (x, y) in pixels (0 to 63).
pub fn texel(t: Tile, xi: u32, yi: u32) Texel {
    const n: f32 = tile_size;
    const x = @as(f32, @floatFromInt(xi)) + 0.5;
    const y = @as(f32, @floatFromInt(yi)) + 0.5;
    const u = x / n;
    const v = y / n;
    const s: u32 = @as(u32, @intFromEnum(t)) *% 7919 +% 13;
    return switch (t) {
        .grass_top => grass(u, v),
        .grass_side => blk: {
            // Grass hanging over the dirt: a ragged edge, standing out a
            // little, with a shadow under it.
            const edge = 10 + 6 * fbm(u, 0.3, 8, 2, 77) + 7 * smoothstep(0.72, 1, hash(@intFromFloat(@floor(u * 32)), 0, 78));
            if (y < edge) {
                var g = grass(u, v);
                g.h += 1.2;
                break :blk g;
            }
            var d = dirt(u, v);
            d.c = scale(d.c, 0.7 + 0.3 * smoothstep(edge, edge + 6, y));
            break :blk d;
        },
        .dirt => dirt(u, v),
        .volcanic_rock => volcanic(u, v, s),
        .sand => blk: {
            const ripple = noise(u + v * 0.25, v * 0.25, 8, s) * 0.5 + 0.5 * noise(u, v, 16, s +% 1);
            const grain = hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5;
            break :blk tx(scale(rgb(0xdccda0), 0.94 + ripple * 0.06 + grain * 0.08), ripple * 2.2 + grain * 0.3);
        },
        .sandstone_top => blk: {
            const body = fbm(u, v, 4, 3, s);
            break :blk tx(scale(rgb(0xd8c48f), 0.9 + body * 0.18 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.04), body * 1.5);
        },
        .sandstone_side => blk: {
            // Layers of different thickness and tone, their edges soft
            // and wandering, worn here and there.
            const wander = noise(u, v, 4, s) * 0.05;
            const layer = fbm(0.1, v + wander, 8, 2, s +% 2);
            const band = smoothstep(0.08, 0, @abs(@mod(v * 4 + wander * 6, 1) - 0.5)) * 0.5;
            const wear = fbm(u, v, 8, 3, s +% 4);
            const c = mix(rgb(0xc9ae78), rgb(0xe3cd98), layer);
            break :blk tx(scale(c, 0.95 - band * 0.12 + (wear - 0.5) * 0.1 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.04), layer * 1.5 - band + wear);
        },
        .sticks_side => blk: {
            // Straight poles standing side by side, eight a block, round
            // (lit across), each its own tone, with dark gaps between, and
            // two bands of rope lashing them together.
            const pole = @floor(x / 8);
            const across = (@mod(x, 8) - 4) / 4;
            const round = @sqrt(@max(0, 1 - across * across));
            const id: i32 = @intFromFloat(pole);
            const tone = hash(id, 0, s);
            const knot = smoothstep(0.03, 0, @abs(v - hash(id, 1, s))) * 0.25;
            const grain = noise(u * 0.5, v * 4, 16, s +% @as(u32, @intCast(id)));
            const wood = scale(mix(rgb(0x7a5a34), rgb(0xa88452), tone), (0.55 + 0.45 * round) * (0.92 + grain * 0.12) * (1 - knot));
            const band = @abs(y - 14) < 2.5 or @abs(y - 50) < 2.5;
            if (band) {
                const twist = 0.85 + 0.15 * @sin((x + y) * 1.6);
                break :blk tx(scale(rgb(0xb89a62), twist * (0.75 + 0.25 * round)), 4 + round);
            }
            if (round < 0.35) break :blk tx(scale(rgb(0x2a1e12), 0.8 + round), -1);
            break :blk tx(wood, 3 * round + grain * 0.3);
        },
        .coral => blk: {
            // Colonies of living coral side by side, each its own colour
            // and kind: brain coral (wandering ridges), polyps (dots in
            // a mesh) or branching (the ends of its branches), domed,
            // with shadow between them.
            const c = cellsAt(u, v, 3, s);
            const id: u32 = c.id;
            const gap = smoothstep(0.1, 0.02, c.d2 - c.d1);
            if (gap > 0.95) break :blk tx(rgb(0x2a2030), -2);
            const colours = [_]u24{ 0xe86a8a, 0xf08a4a, 0x9a6ad0, 0xe8c44a, 0x5ac0b0, 0xd8506a, 0xf4a0c0 };
            const base = rgb(colours[@intFromFloat(hash(@intCast(id), 1, s) * colours.len)]);
            const dome = @max(0, 1 - c.d1 / 0.7);
            const kind = hash(@intCast(id), 2, s);
            var detail: f32 = 0;
            if (kind < 0.34) {
                // Ridges wandering over it.
                detail = smoothstep(0.25, 0, @abs(@mod(noise(u, v, 6, s +% id) * 9, 1) - 0.5) - 0.2);
            } else if (kind < 0.67) {
                // Polyps.
                const p = cellsAt(u, v, 14, s +% id);
                detail = smoothstep(0.32, 0.18, p.d1);
            } else {
                // Branch ends: round tips, lighter, with dark between.
                const p = cellsAt(u, v, 8, s +% id +% 9);
                detail = -smoothstep(0.3, 0.45, p.d1) + smoothstep(0.2, 0, p.d1) * 0.6;
            }
            const col = scale(mix(base, rgb(0xffffff), @max(detail, 0) * 0.25), (0.7 + 0.35 * dome) * (1 - gap * 0.6) * (1 + @min(detail, 0) * 0.45));
            break :blk tx(col, 3 * @sqrt(dome) + detail * 1.5 - gap * 2);
        },
        .sticks_top => blk: {
            // The poles' ends: rings of wood, in rows.
            const cx = @mod(x, 8) - 4;
            const cy = @mod(y, 8) - 4;
            const r = @sqrt(cx * cx + cy * cy) / 4;
            if (r > 0.92) break :blk tx(rgb(0x2a1e12), -1);
            if (r > 0.75) break :blk tx(scale(rgb(0x5a4026), 0.9), 1.5);
            const id: i32 = @intFromFloat(@floor(x / 8) + @floor(y / 8) * 8);
            const ring = 0.5 + 0.5 * @cos(r * 14);
            break :blk tx(scale(mix(rgb(0xa47d4c), rgb(0xc89e68), ring), 0.88 + hash(id, 2, s) * 0.18), 2 - r);
        },
        .palm_bark => blk: {
            // A palm's trunk: grey-brown, ringed where old fronds fell,
            // two rings a block, with fibres running up between.
            const ring_v = @mod(v * 2 + noise(u, v, 4, s) * 0.08, 1);
            const ring = smoothstep(0.16, 0, @abs(ring_v - 0.12));
            const fibre = noise(u * 0.5, v, 32, s +% 1);
            const body = mix(rgb(0x8a7a64), rgb(0xa8977a), noise(u, v, 8, s +% 2));
            const c = scale(mix(body, rgb(0x4f4232), ring * 0.75), 0.9 + fibre * 0.18);
            break :blk tx(c, 2.5 * smoothstep(0.35, 0.05, @abs(ring_v - 0.3)) + fibre * 0.6 - ring * 1.5);
        },
        .frond => frond(u, v, rgb(0x3f8a2a), rgb(0xa6dc62), 1.0, 17, s),
        .coconut => blk: {
            const husk = fbm(u, v, 8, 3, s);
            const c = mix(rgb(0x7a6a2a), rgb(0xa8a040), husk);
            break :blk tx(scale(c, 0.85 + hash(@intFromFloat(x), @intFromFloat(y), s) * 0.15), husk * 2);
        },
        .tall_grass => blades(u, v, s),
        .leafy_plant => blk: {
            // A big leaf like an arrowhead, its base (two round lobes, a
            // notch between them where the stalk meets it) at the top of
            // the tile and its point at the bottom: a pale rib down the
            // middle, veins out from it towards the edges, glossy.
            const a = @abs(u - 0.5);
            // The rib, the whole way down (a stalk is drawn from it).
            if (a < 0.022) break :blk tx(scale(rgb(0x8cbc5a), 0.9 + v * 0.1), 1);
            const half = 0.47 * std.math.pow(f32, @max(0, @sin(std.math.pi * (0.25 + 0.75 * v))), 0.7);
            if (a > half) break :blk nothing;
            if (v < 0.2 and a < 0.22 * (1 - v / 0.2)) break :blk nothing;
            const vein_phase = (v - a * 0.9) * 7;
            const vein = smoothstep(0.08, 0, @abs(vein_phase - @round(vein_phase)));
            const edge = smoothstep(half - 0.04, half, a);
            const shine = smoothstep(0.3, 0, @abs(a - 0.16)) * 0.15;
            const c = mix(rgb(0x3c8430), rgb(0x68b44a), fbm(u, v, 4, 2, s));
            break :blk tx(scale(mix(c, rgb(0x86b85a), vein * 0.45), (0.95 + shine) * (1 - edge * 0.35)), vein * 0.6 - edge);
        },
        .red_flower => flowers(u, v, rgb(0xe0352c), rgb(0xffd23a), s),
        .yellow_flower => flowers(u, v, rgb(0xf8d42c), rgb(0xd07a10), s),
        .pink_flower => flowers(u, v, rgb(0xf27ab4), rgb(0xffe38a), s),
        .purple_flower => flowers(u, v, rgb(0x9a5ad8), rgb(0xffe070), s),
        .blue_flower => flowers(u, v, rgb(0x4a8af0), rgb(0xfff2a0), s),
        .white_flower => flowers(u, v, rgb(0xf6f6ee), rgb(0xf2c020), s),
        .orange_flower => flowers(u, v, rgb(0xf6862a), rgb(0x8a3a10), s),
        .volcanic_wall => blk: {
            // A dry-stone wall: rounded stones fitted together, dark gaps
            // between them.
            const c = cellsAt(u, v, 4, s);
            const gap = smoothstep(0.1, 0.02, c.d2 - c.d1);
            if (gap > 0.95) break :blk tx(scale(rgb(0x1c1a18), 0.8 + noise(u, v, 32, s) * 0.4), -1);
            const tone = 0.8 + hash(@intCast(c.id), 2, s) * 0.35;
            const st = volcanic(u, v, s +% 5);
            const dome = @max(0, 1 - (c.d1 / 0.62) * (c.d1 / 0.62));
            break :blk tx(scale(st.c, tone * (1.05 - 0.25 * c.d1) * (1 - gap * 0.7)), 5 * @sqrt(dome) * (1 - gap) + st.h * 0.3);
        },
        .glass => blk: {
            const edge = @min(@min(x, y), @min(n - x, n - y));
            if (edge < 3) break :blk .{ .c = rgb(0xd8e8ee), .a = 0.95, .h = 1.5 };
            // Reflections: two bright streaks.
            const d = @mod(x + y, 64);
            const streak = smoothstep(3, 0, @abs(d - 18)) * 0.6 + smoothstep(1.5, 0, @abs(d - 26)) * 0.4;
            break :blk .{ .c = mix(rgb(0xbfdfeb), rgb(0xffffff), streak), .a = 0.1 + streak * 0.45 };
        },
        .thatch => blk: {
            // Bundles of dried palm and grass laid in rows, each row
            // hanging over the one below: straws running down, their
            // ends ragged, in shadow under the row above.
            const row = @floor(y / 16);
            const ry = @mod(y, 16);
            // Each straw: its own tone, length and a little lean.
            const sx = x + ry * (hash(@intFromFloat(@floor(x / 2)), @intFromFloat(row), s) - 0.5) * 0.3;
            const straw: i32 = @intFromFloat(@floor(sx / 1.5));
            const tone = hash(straw, @intFromFloat(row), s);
            const end = 13 + 3 * hash(straw, @intFromFloat(row + 7), s);
            if (ry > end) break :blk tx(scale(rgb(0x4a3a1e), 0.7), -2);
            const shade = 0.62 + 0.38 * smoothstep(0, 6, ry);
            const strand = 0.85 + 0.15 * @sin(sx * 4.2);
            const c = mix(rgb(0x9a7a3e), rgb(0xd8b866), tone);
            break :blk tx(scale(mix(c, rgb(0x7a6a4a), smoothstep(0.7, 1, noise(u, v, 4, s)) * 0.4), shade * strand), ry * 0.25 + tone * 0.6);
        },
        .plaster => blk: {
            const body = fbm(u, v, 4, 3, s);
            break :blk tx(scale(rgb(0xece6d6), 0.94 + body * 0.08 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.03), body * 1.2);
        },
        .lamp => blk: {
            // A flame, from its point at the top: white-yellow at its
            // heart, orange, red at its edge.
            const h = std.math.pow(f32, v, 0.75);
            const half = 0.36 * @sin(std.math.pi * h) * (0.75 + 0.25 * v) + (noise(u, v, 6, s) - 0.5) * 0.04;
            const a = @abs(u - 0.5);
            if (a > half or v > 0.97) break :blk nothing;
            const heat = (1 - a / @max(half, 0.01)) * smoothstep(0.1, 0.8, v);
            const c = mix(mix(rgb(0xd83a10), rgb(0xff9a20), smoothstep(0, 0.5, heat)), rgb(0xfff2b0), smoothstep(0.5, 1, heat));
            break :blk .{ .c = c, .a = std.math.clamp((half - a) * 30, 0, 1) };
        },
        .bamboo => blk: {
            // A stem of bamboo, lit across, a node part way up.
            const across = (u - 0.5) * 2;
            const round = @sqrt(@max(0, 1 - across * across * 0.8));
            const node = smoothstep(0.035, 0, @abs(v - 0.55));
            const streak = 0.94 + 0.06 * noise(u * 4, v * 0.5, 16, s);
            const c = mix(rgb(0x9a9a3a), rgb(0xd0c470), fbm(u, v, 4, 2, s) * 0.5 + round * 0.4);
            break :blk tx(scale(mix(c, rgb(0x6a6a2a), node), (0.6 + 0.4 * round) * streak), node * 2 + round);
        },
        .bed_cover => blk: {
            // Bark cloth: pale, with dark brown patterns in bands:
            // triangles, zigzags and lines.
            const base = scale(mix(rgb(0xe2cfa6), rgb(0xf0e2c2), fbm(u, v, 8, 2, s)), 0.95 + (hash(@intFromFloat(x), @intFromFloat(y), s) - 0.5) * 0.06);
            const ink = rgb(0x5a3018);
            const band = @mod(y, 32);
            const line = band < 2 or (band >= 14 and band < 16);
            const tri = band >= 3 and band < 13 and @abs(@mod(x, 10) - 5) < (band - 3) * 0.5;
            const zig = band >= 18 and band < 30 and @abs(@mod(x + @abs(band - 24) * 1.2, 8) - 4) < 1.2;
            if (line or tri or zig) break :blk tx(scale(ink, 0.9 + fbm(u, v, 16, 1, s) * 0.2), 0);
            break :blk tx(base, 0.3);
        },
        .chest_side => blk: {
            // Dark boards, two bands of iron round them, and a gold lock.
            if (@abs(x - 32) < 7 and y >= 18 and y < 34) {
                const keyhole = @abs(x - 32) < 1.5 and y >= 23 and y < 30;
                if (keyhole) break :blk tx(rgb(0x20140a), -1);
                break :blk tx(scale(rgb(0xe8b83a), 0.85 + 0.25 * (1 - @abs(x - 32) / 7)), 2.5);
            }
            if (@abs(x - 12) < 3 or @abs(x - 52) < 3 or (y >= 22 and y < 26)) {
                const rivet = @mod(y, 10) < 2 and (@abs(x - 12) < 1 or @abs(x - 52) < 1);
                break :blk tx(scale(rgb(0x4a4a50), if (rivet) 1.4 else 0.9 + noise(u, v, 16, s) * 0.2), if (rivet) 3 else 1.8);
            }
            break :blk planks(u, v, x, y, rgb(0x6a4424), s);
        },
        .chest_top => blk: {
            if (@abs(x - 12) < 3 or @abs(x - 52) < 3) break :blk tx(scale(rgb(0x4a4a50), 0.9 + noise(u, v, 16, s) * 0.2), 1.8);
            break :blk planks(u, v, y, x, rgb(0x6a4424), s);
        },
        .water => blk: {
            const ripple = fbm(u + noise(u, v, 4, s) * 0.1, v, 4, 3, s +% 1);
            break :blk .{ .c = mix(rgb(0x1f5fa8), rgb(0x6ab8ea), ripple * ripple * 1.5), .a = 0.85 };
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
        .grey => fabric(u, v, x, y, rgb(0x7a8590), s),
    };
}

fn grass(u: f32, v: f32) Texel {
    const patch = fbm(u, v, 4, 3, 3);
    const streaks = noise(u * 1.0, v * 0.5, 32, 4);
    const speck = hash(@intFromFloat(u * 64), @intFromFloat(v * 64), 5);
    return tx(scale(mix(rgb(0x4f8f30), rgb(0x86c050), patch * 0.8 + streaks * 0.4), 0.88 + speck * 0.18), streaks * 1.6 + patch + speck * 0.4);
}

fn dirt(u: f32, v: f32) Texel {
    // Soil, with small stones in it.
    const c = cellsAt(u, v, 12, 9);
    const stone_here = smoothstep(0.32, 0.22, c.d1) * @as(f32, if (hash(@intCast(c.id), 0, 9) > 0.6) 1 else 0);
    const body = fbm(u, v, 4, 4, 6);
    const soil = mix(rgb(0x6b4a30), rgb(0x92683f), body);
    const colour = scale(mix(soil, rgb(0x9a8c7a), stone_here), 0.94 + hash(@intFromFloat(u * 64), @intFromFloat(v * 64), 7) * 0.1);
    const dome = @max(0, 1 - c.d1 / 0.32);
    return tx(colour, body * 1.5 + stone_here * 2 * @sqrt(dome));
}

/// Basalt: dark, grey-brown, with small round pits where gas was, specks,
/// and rust-red patches.
fn volcanic(u: f32, v: f32, s: u32) Texel {
    const body = fbm(u, v, 4, 4, s);
    const rust = smoothstep(0.55, 0.75, fbm(u, v, 3, 2, s +% 3));
    const base = mix(mix(rgb(0x3e3a37), rgb(0x5e5852), body), rgb(0x6e4636), rust * 0.6);
    // Pits in some places only, of different sizes.
    const pit = cellsAt(u, v, 11, s +% 7);
    const some = hash(@intCast(pit.id), 6, s) < 0.35;
    const r = 0.06 + 0.14 * hash(@intCast(pit.id), 5, s);
    const in_pit = if (some) smoothstep(r, r * 0.5, pit.d1) else 0;
    const speck = hash(@intFromFloat(u * 64), @intFromFloat(v * 64), s) - 0.5;
    return tx(scale(base, (0.85 + speck * 0.12) * (1 - in_pit * 0.45)), body * 2.5 + speck * 0.4 - in_pit * 1.5);
}

fn planks(u: f32, v: f32, x: f32, y: f32, base: Rgb, s: u32) Texel {
    const board = @floor(y / 16);
    const by = @mod(y, 16);
    // Each board's own grain, tone and end.
    const salt = s +% @as(u32, @intFromFloat(board)) *% 17;
    const end = hash(@intFromFloat(board), 0, s) * 64;
    const ex = @mod(x - end, 64);
    if (by < 1.5 or ex < 1.5) return tx(scale(base, 0.45), 0);
    const grain = noise(u * 0.25, v * 3 + noise(u, v, 4, salt) * 0.6, 16, salt);
    const streak = 0.5 + 0.5 * @cos((v * 16 + grain * 3) * std.math.pi * 2);
    const tone = 0.86 + hash(@intFromFloat(board), 1, s) * 0.18;
    const edge = @min(@min(ex - 1.5, 62.5 - ex), @min(by - 1.5, 14.5 - by));
    const h = 2.5 * smoothstep(0, 2, edge) + streak * 0.35;
    // A nail at each end.
    const nd = @sqrt(@min((ex - 5) * (ex - 5), (ex - 58) * (ex - 58)) + (by - 8) * (by - 8));
    if (nd < 1.6) return tx(rgb(0x45403a), h + 0.8 * (1 - nd / 1.6));
    return tx(scale(base, tone * (0.88 + streak * 0.16)), h);
}

fn fabric(u: f32, v: f32, x: f32, y: f32, base: Rgb, s: u32) Texel {
    // A soft weave.
    const weave = 0.5 + 0.25 * @cos(x * std.math.pi / 2) + 0.25 * @cos(y * std.math.pi / 2);
    const fuzz = fbm(u, v, 8, 2, s);
    return tx(scale(base, 0.9 + weave * 0.06 + fuzz * 0.1), weave * 0.7 + fuzz * 0.4);
}

/// A frond, base at the top of the tile and tip at the bottom: a rib
/// down the middle with leaflets either side, swept towards the tip,
/// widest a third of the way along. `reach` is how wide, `n` how many
/// leaflets a side.
fn frond(u: f32, v: f32, dark: Rgb, light: Rgb, reach: f32, n: f32, s: u32) Texel {
    const across = u - 0.5;
    const a = @abs(across);
    // The rib, narrowing to the tip.
    const rib_w = 0.035 * (1 - v * 0.7);
    if (a < rib_w and v < 0.98) return tx(scale(mix(rgb(0x6a6a2a), rgb(0x8a9a3a), v), 0.95), 0);
    // Which leaflet: they leave the rib and sweep back, so along a
    // leaflet v grows with distance from the rib.
    const sweep = 0.55;
    const along_rib = v - a * sweep;
    if (along_rib < 0.02 or along_rib > 0.96) return nothing;
    // How long the leaflets are where they leave the rib.
    const env = 0.48 * reach * std.math.pow(f32, @sin(std.math.pi * std.math.pow(f32, along_rib, 0.7)), 0.8);
    if (a > env) return nothing;
    const side: i32 = if (across < 0) 0 else 1;
    const phase = along_rib * n;
    const k: i32 = @intFromFloat(@floor(phase));
    const f = phase - @floor(phase);
    // Each leaflet narrows to its tip; a little gap between them.
    const t = a / @max(env, 0.001);
    const width = 0.82 * (1 - t * 0.6);
    if (f > width) return nothing;
    const tone = hash(k, side, s);
    const c = mix(dark, light, 0.25 + t * 0.55 + tone * 0.25);
    // A crease down each leaflet's middle.
    const crease = smoothstep(0.12, 0, @abs(f - width * 0.5) / @max(width, 0.01));
    return tx(scale(c, 0.85 + crease * 0.2), 0);
}

/// Small wildflowers among little fronds: blossoms of five petals on
/// thin stalks at different heights.
fn flowers(u: f32, v: f32, petal: Rgb, centre: Rgb, s: u32) Texel {
    const blooms = [_][3]f32{ .{ 0.28, 0.2, 0.11 }, .{ 0.68, 0.12, 0.12 }, .{ 0.5, 0.42, 0.1 }, .{ 0.18, 0.55, 0.08 }, .{ 0.82, 0.48, 0.09 } };
    for (blooms, 0..) |bl, i| {
        const dx = u - bl[0];
        const dy = v - bl[1];
        const r = @sqrt(dx * dx + dy * dy);
        const ang = std.math.atan2(dy, dx) + @as(f32, @floatFromInt(i));
        const edge = bl[2] * (0.75 + 0.25 * @cos(ang * 5));
        if (r < bl[2] * 0.3) return tx(scale(centre, 1.05 - r * 2), 0);
        if (r < edge) {
            // Petals lighter at their tips, a line down each.
            const vein = smoothstep(0.25, 0, @abs(@mod(ang * 5 / (2 * std.math.pi), 1) - 0.5));
            return tx(scale(mix(petal, rgb(0xffffff), (r / edge) * 0.25), 0.82 + 0.2 * (r / edge) - vein * 0.08), 0);
        }
    }
    // Stalks up to them.
    for (blooms, 0..) |bl, i| {
        const sway = (hash(@intCast(i), 3, s) - 0.5) * 0.12;
        const cx = bl[0] + sway * (v - bl[1]);
        if (v > bl[1] and @abs(u - cx) < 0.018) return tx(scale(rgb(0x3f7a2a), 0.9 + v * 0.15), 0);
    }
    // Grass below, as tall grass is.
    return if (v > 0.3) blades(u, v, s) else nothing;
}

/// Blades of grass curving up from the bottom of the tile.
fn blades(u: f32, v: f32, s: u32) Texel {
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
    if (best == 0) return nothing;
    return tx(scale(mix(rgb(0x2f6a22), rgb(0x8fd05a), tone), 0.85 + best * 0.2), 0);
}

fn normals(t: Tile, out: *[tile_size * tile_size][3]f32, cols: *[tile_size * tile_size]Texel) void {
    for (0..tile_size) |y| for (0..tile_size) |x| {
        cols[y * tile_size + x] = texel(t, @intCast(x), @intCast(y));
    };
    const h = struct {
        fn at(c: *const [tile_size * tile_size]Texel, x: i32, y: i32) f32 {
            // The tile repeats both ways.
            return c[@intCast(@mod(y, tile_size) * tile_size + @mod(x, tile_size))].h;
        }
    }.at;
    for (0..tile_size) |yu| for (0..tile_size) |xu| {
        const x: i32 = @intCast(xu);
        const y: i32 = @intCast(yu);
        const dx = (h(cols, x + 1, y) - h(cols, x - 1, y)) / 2;
        const dy = (h(cols, x, y + 1) - h(cols, x, y - 1)) / 2;
        const l = @sqrt(dx * dx + dy * dy + 1);
        out[yu * tile_size + xu] = .{ -dx / l, -dy / l, 1 / l };
    };
}

/// Light from the top left and in front, baked into the tiles' colours: a
/// gentle shading from their normals, 1 where the surface is flat.
fn shaded(c: Rgb, nm: [3]f32) Rgb {
    const l = [3]f32{ -0.45, -0.45, 0.77 };
    const d = nm[0] * l[0] + nm[1] * l[1] + nm[2] * l[2];
    return scale(c, 1 + (d - 0.77) * 1.1);
}

/// Strip `strip`, `strip_width` by `strip_height`, row by row: its
/// colours, shaded (see `shaded`); tiles not used left clear.
pub fn strips(strip: u2, colours: *[strip_width * strip_height]Pixel) void {
    @memset(colours, 0);
    var ns: [tile_size * tile_size][3]f32 = undefined;
    var cols: [tile_size * tile_size]Texel = undefined;
    for (std.enums.values(Tile)) |t| {
        if (t.strip() != strip) continue;
        normals(t, &ns, &cols);
        const oy = @as(u32, t.slot()) * tile_size;
        for (0..tile_size * tile_size) |i| {
            const at = (oy + i / tile_size) * strip_width + i % tile_size;
            colours[at] = pack(shaded(cols[i].c, ns[i]), cols[i].a);
        }
    }
}

/// A tile as icons show it (shaded), row by row.
pub fn tilePixels(t: Tile, out: *[tile_size * tile_size]Pixel) void {
    var ns: [tile_size * tile_size][3]f32 = undefined;
    var cols: [tile_size * tile_size]Texel = undefined;
    normals(t, &ns, &cols);
    for (out, cols, ns) |*o, c, nm| o.* = pack(shaded(c.c, nm), c.a);
}

// --- Icons ------------------------------------------------------------------------------

pub const icon_size = 48;

/// A block's icon: a cube seen from above at an angle, lit from the left
/// (a plant as it is).
pub fn icon(b: Block, out: *[icon_size * icon_size]Pixel) void {
    @memset(out, 0);
    const n: f32 = icon_size;
    var px: [3][tile_size * tile_size]Pixel = undefined;
    switch (b) {
        .palm => {
            // A trunk, and fronds out from its top.
            tilePixels(.palm_bark, &px[0]);
            for (12..icon_size) |y| for (20..28) |x| {
                out[y * icon_size + x] = px[0][(y * tile_size / icon_size) * tile_size + (x - 20) * 8];
            };
            tilePixels(.frond, &px[1]);
            fan(out, &px[1], .{ 24, 12 }, &.{ 2.8, 3.6, -1.57, -0.45, 0.35 }, 22, 7);
            return;
        },
        .leafy_plant => {
            tilePixels(.leafy_plant, &px[0]);
            fan(out, &px[0], .{ 24, 46 }, &.{ -0.55, -1.2, -1.95, -2.6 }, 26, 10);
            return;
        },
        .table, .bed, .chest, .post, .lamp => {
            furnitureIcon(b, out);
            return;
        },
        else => {},
    }
    if (b.shape() == .plant) {
        tilePixels(b.tile(.north), &px[0]);
        for (0..icon_size) |y| for (0..icon_size) |x| {
            out[y * icon_size + x] = px[0][(y * tile_size / icon_size) * tile_size + x * tile_size / icon_size];
        };
        return;
    }
    // The faces' corners (top, left, right), and how bright each is.
    const Face = struct { o: [2]f32, e1: [2]f32, e2: [2]f32, light: f32 };
    const top_y = n * 0.04;
    const faces = [_]Face{
        .{ .o = .{ n / 2, top_y }, .e1 = .{ n / 2, n * 0.24 }, .e2 = .{ -n / 2, n * 0.24 }, .light = 1 },
        .{ .o = .{ 0, top_y + n * 0.24 }, .e1 = .{ n / 2, n * 0.24 }, .e2 = .{ 0, n * 0.48 }, .light = 0.78 },
        .{ .o = .{ n / 2, top_y + n * 0.48 }, .e1 = .{ n / 2, -n * 0.24 }, .e2 = .{ 0, n * 0.48 }, .light = 0.6 },
    };
    const face_tiles = [3]Tile{ b.tile(.up), b.tile(.north), b.tile(.east) };
    var face_px: [3]*const [tile_size * tile_size]Pixel = undefined;
    for (face_tiles, 0..) |ft, fi| {
        const prev = for (0..fi) |pi| {
            if (face_tiles[pi] == ft) break face_px[pi];
        } else null;
        if (prev) |existing| {
            face_px[fi] = existing;
        } else {
            tilePixels(ft, &px[fi]);
            face_px[fi] = &px[fi];
        }
    }
    for (0..icon_size) |y| for (0..icon_size) |x| {
        const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
        for (faces, 0..) |f, fi| {
            // p = o + a·e1 + b·e2.
            const det = f.e1[0] * f.e2[1] - f.e1[1] * f.e2[0];
            const dx = p[0] - f.o[0];
            const dy = p[1] - f.o[1];
            const a = (dx * f.e2[1] - dy * f.e2[0]) / det;
            const c = (f.e1[0] * dy - f.e1[1] * dx) / det;
            if (a < 0 or a >= 1 or c < 0 or c >= 1) continue;
            const t = face_px[fi][@as(usize, @intFromFloat(c * tile_size)) * tile_size + @as(usize, @intFromFloat(a * tile_size))];
            const alpha: f32 = @floatFromInt(t >> 24);
            if (alpha == 0) continue;
            const col = Rgb{ @floatFromInt(t >> 16 & 0xff), @floatFromInt(t >> 8 & 0xff), @floatFromInt(t & 0xff) };
            // Glass shows as its frame and a pale fill.
            out[y * icon_size + x] = pack(scale(col, f.light), @max(alpha / 255, 0.35));
            break;
        }
    };
}

/// A box in an icon: its corners (in the block, 0 to 1), and the tiles
/// on its top and sides, each stretched over the face.
const IconBox = struct { lo: [3]f32, hi: [3]f32, top: Tile, side: Tile };

/// Furniture's icon: its boxes, as an icon's cube is drawn (from above,
/// at an angle), the furthest first.
fn furnitureIcon(b: Block, out: *[icon_size * icon_size]Pixel) void {
    const leg = struct {
        fn at(x: f32, z: f32, w: f32, h: f32) IconBox {
            return .{ .lo = .{ x, 0, z }, .hi = .{ x + w, h, z + w }, .top = .sticks_top, .side = .sticks_side };
        }
    }.at;
    const boxes: []const IconBox = switch (b) {
        .table => &.{
            leg(0.04, 0.04, 0.1, 0.88), leg(0.86, 0.04, 0.1, 0.88), leg(0.04, 0.86, 0.1, 0.88), leg(0.86, 0.86, 0.1, 0.88),
            .{ .lo = .{ 0, 0.88, 0 }, .hi = .{ 1, 1, 1 }, .top = .sticks_side, .side = .sticks_side },
        },
        .bed => &.{
            leg(0.03, 0.03, 0.09, 0.14),                                                                  leg(0.88, 0.03, 0.09, 0.14),                                                                leg(0.03, 0.88, 0.09, 0.14), leg(0.88, 0.88, 0.09, 0.14),
            .{ .lo = .{ 0.03, 0.14, 0.03 }, .hi = .{ 0.97, 0.28, 0.97 }, .top = .sticks_top, .side = .sticks_side }, .{ .lo = .{ 0.05, 0.28, 0.05 }, .hi = .{ 0.95, 0.44, 0.95 }, .top = .bed_cover, .side = .bed_cover },
            .{ .lo = .{ 0.14, 0.44, 0.08 }, .hi = .{ 0.86, 0.54, 0.34 }, .top = .plaster, .side = .plaster },
        },
        .chest => &.{.{ .lo = .{ 0.08, 0, 0.14 }, .hi = .{ 0.92, 0.7, 0.86 }, .top = .chest_top, .side = .chest_side }},
        .post => &.{.{ .lo = .{ 0.42, 0, 0.42 }, .hi = .{ 0.58, 1, 0.58 }, .top = .bamboo, .side = .bamboo }},
        .lamp => &.{
            .{ .lo = .{ 0.43, 0, 0.43 }, .hi = .{ 0.57, 0.6, 0.57 }, .top = .bamboo, .side = .bamboo },
            .{ .lo = .{ 0.39, 0.6, 0.39 }, .hi = .{ 0.61, 0.76, 0.61 }, .top = .bamboo, .side = .bamboo },
        },
        else => &.{},
    };
    const n: f32 = icon_size;
    const top_y = n * 0.04;
    const ex = [2]f32{ n / 2, n * 0.24 };
    const ez = [2]f32{ -n / 2, n * 0.24 };
    const down = [2]f32{ 0, n * 0.48 };
    const proj = struct {
        fn at(p: [3]f32, o: [2]f32, X: [2]f32, Z: [2]f32, D: [2]f32) [2]f32 {
            return .{ o[0] + p[0] * X[0] + p[2] * Z[0] + (1 - p[1]) * D[0], o[1] + p[0] * X[1] + p[2] * Z[1] + (1 - p[1]) * D[1] };
        }
    }.at;
    const o = [2]f32{ n / 2, top_y };
    var top_px: [tile_size * tile_size]Pixel = undefined;
    var side_px: [tile_size * tile_size]Pixel = undefined;
    for (boxes) |bx| {
        tilePixels(bx.top, &top_px);
        tilePixels(bx.side, &side_px);
        const lo = bx.lo;
        const hi = bx.hi;
        const w = hi[0] - lo[0];
        const d = hi[2] - lo[2];
        const h = hi[1] - lo[1];
        // Top, left (facing +z), right (facing +x): origin, across, down.
        const Fc = struct { a: [2]f32, e1: [2]f32, e2: [2]f32, px: *const [tile_size * tile_size]Pixel, light: f32 };
        const faces = [3]Fc{
            .{ .a = proj(.{ lo[0], hi[1], lo[2] }, o, ex, ez, down), .e1 = .{ ex[0] * w, ex[1] * w }, .e2 = .{ ez[0] * d, ez[1] * d }, .px = &top_px, .light = 1 },
            .{ .a = proj(.{ lo[0], hi[1], hi[2] }, o, ex, ez, down), .e1 = .{ ex[0] * w, ex[1] * w }, .e2 = .{ down[0] * h, down[1] * h }, .px = &side_px, .light = 0.78 },
            .{ .a = proj(.{ hi[0], hi[1], hi[2] }, o, ex, ez, down), .e1 = .{ -ez[0] * d, -ez[1] * d }, .e2 = .{ down[0] * h, down[1] * h }, .px = &side_px, .light = 0.6 },
        };
        for (0..icon_size) |y| for (0..icon_size) |x| {
            const p = [2]f32{ @as(f32, @floatFromInt(x)) + 0.5, @as(f32, @floatFromInt(y)) + 0.5 };
            for (faces) |f| {
                const det = f.e1[0] * f.e2[1] - f.e1[1] * f.e2[0];
                if (@abs(det) < 1e-6) continue;
                const dx = p[0] - f.a[0];
                const dy = p[1] - f.a[1];
                const a = (dx * f.e2[1] - dy * f.e2[0]) / det;
                const c = (f.e1[0] * dy - f.e1[1] * dx) / det;
                if (a < 0 or a >= 1 or c < 0 or c >= 1) continue;
                const t = f.px[@as(usize, @intFromFloat(c * tile_size)) * tile_size + @as(usize, @intFromFloat(a * tile_size))];
                const col = Rgb{ @floatFromInt(t >> 16 & 0xff), @floatFromInt(t >> 8 & 0xff), @floatFromInt(t & 0xff) };
                out[y * icon_size + x] = pack(scale(col, f.light), 1);
                break;
            }
        };
    }
    // A torch's flame, over its top.
    if (b == .lamp) {
        tilePixels(.lamp, &top_px);
        for (0..18) |y| for (0..14) |x| {
            const t = top_px[(y * tile_size / 18) * tile_size + x * tile_size / 14];
            if (t >> 24 < 0x80) continue;
            out[(y + 2) * icon_size + x + 17] = t | 0xff000000;
        };
    }
}

/// Fronds drawn from `tile` (its base at its top) out from `from` at each
/// of `angles` (radians, y down), `len` pixels long and `half` each side.
fn fan(out: *[icon_size * icon_size]Pixel, tile: *const [tile_size * tile_size]Pixel, from: [2]f32, angles: []const f32, len: f32, half: f32) void {
    for (0..icon_size) |y| for (0..icon_size) |x| {
        const dx = @as(f32, @floatFromInt(x)) + 0.5 - from[0];
        const dy = @as(f32, @floatFromInt(y)) + 0.5 - from[1];
        for (angles) |a| {
            const along = dx * @cos(a) + dy * @sin(a);
            const across = -dx * @sin(a) + dy * @cos(a);
            if (along < 0 or along >= len or @abs(across) >= half) continue;
            const tu: usize = @intFromFloat((across / half * 0.5 + 0.5) * (tile_size - 1));
            const tv: usize = @intFromFloat(along / len * (tile_size - 1));
            const t = tile[tv * tile_size + tu];
            if (t >> 24 < 0x80) continue;
            out[y * icon_size + x] = t | 0xff000000;
            break;
        }
    };
}

test "every tile is in its strip, opaque except where things are see-through, and joins its own edges" {
    const px = try std.testing.allocator.create([strip_width * strip_height]Pixel);
    defer std.testing.allocator.destroy(px);
    for (0..Tile.strips) |strip| {
        strips(@intCast(strip), px);
        for (std.enums.values(Tile)) |t| {
            if (t.strip() != strip) continue;
            const oy = @as(u32, t.slot()) * tile_size;
            const see_through = switch (t) {
                .glass, .water, .tall_grass, .frond, .leafy_plant, .lamp, .red_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower, .orange_flower => true,
                else => false,
            };
            var clear: u32 = 0;
            for (0..tile_size) |y| for (0..tile_size) |x| {
                if (px[(oy + y) * strip_width + x] >> 24 != 0xff) clear += 1;
            };
            try std.testing.expect((clear > 0) == see_through);
        }
    }
    // Wrapping noise: the left and right edges of grass are close in
    // colour (they meet when the tile repeats).
    strips(0, px);
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
    icon(.volcanic_wall, &px);
    try std.testing.expect(px[10 * icon_size + 24] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 10] >> 24 == 0xff);
    try std.testing.expect(px[28 * icon_size + 38] >> 24 == 0xff);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
    icon(.pink_flower, &px);
    try std.testing.expectEqual(@as(Pixel, 0), px[0]);
}
