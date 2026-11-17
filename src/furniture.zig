//! Furniture, made of sticks, as the mesher makes it: boxes smaller than
//! the block, solid (put with the solid faces that look up, as palms'
//! trunks are), lit as the block they are in.
//!
//! - A table: a top on four legs. Tables side by side are one bigger
//!   table, with legs only at its corners; stacked, they are shelves.
//! - A bed: a low frame of sticks, a mattress of bark cloth and a
//!   pillow. Beds side by side or end to end are one bigger bed (the
//!   pillows at the end with no bed beyond, to the north).
//! - A treasure chest.
//! - A stick: one pole of bamboo, upright, the height of the block.
//! - A lamp: a bamboo torch, its flame burning at its top (on a stick,
//!   raised). The flame is see-through, and flickers as plants sway.
//! - Slabs: the lower half of a block.
//! - A fence: a post, with rails to fences (and walls) beside it.
//! - A ladder: two rails and rungs, against the wall beside it.
//! - A campfire: a ring of stones, logs crossed, a fire burning.
//! - Bamboo: canes, the same in each block up a stack, sprigs of leaves
//!   at the top.
//! - A lattice: a frame of sticks, crossed inside, across the way it joins
//!   (to walls or more lattice); a bead curtain the same way, its strings
//!   hanging from a rail.
//! - A mat: thin, woven, joined to the next.
//! - A hammock: cloth sagging between whatever holds its ends (a wall, a
//!   post, a fence, a palm, or a stake of its own), hammocks in a row one
//!   longer one.
//! - A canoe: a hull hollowed out, pointed at the ends of a row of them,
//!   an outrigger beside it on two booms.

const std = @import("std");
const blocks = @import("blocks.zig");
const mesher = @import("mesher.zig");
const plants = @import("plants.zig");
const world_mod = @import("world.zig");

const Block = blocks.Block;
const Face = blocks.Face;
const Tile = blocks.Tile;
const World = world_mod.World;
const Out = plants.Out;
const V = plants.V;

/// The tiles on a box's faces.
const Tiles = struct {
    top: Tile,
    side: Tile,
    bottom: Tile,
    /// Each face shows the whole tile (not the block's part of it).
    fit: bool = false,
};

/// Where a face's place is across and down it, as seen from outside (as
/// the mesher has it), in blocks.
fn uvOf(face: Face, p: V) [2]f32 {
    return switch (face) {
        .up, .down => .{ p[0], p[2] },
        .east => .{ -p[2], -p[1] },
        .west => .{ p[2], -p[1] },
        .south => .{ p[0], -p[1] },
        .north => .{ -p[0], -p[1] },
    };
}

/// A box from `lo` to `hi`, its faces in `skip` left out.
fn box(o: Out, lo: V, hi: V, tiles: Tiles, skip: std.EnumSet(Face)) !void {
    for (Face.all) |face| {
        if (skip.contains(face)) continue;
        const n = face.normal();
        const ax: usize = @intFromEnum(face) / 2;
        const b = (ax + 1) % 3;
        const c = (ax + 2) % 3;
        const d = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 1, 1 }, .{ 0, 1 } };
        var corners: [4]V = undefined;
        for (d, 0..) |q, k| {
            corners[k][ax] = if (n[ax] > 0) hi[ax] else lo[ax];
            corners[k][b] = if (q[0] > 0) hi[b] else lo[b];
            corners[k][c] = if (q[1] > 0) hi[c] else lo[c];
        }
        if (@intFromEnum(face) % 2 == 1) {
            const c0 = corners;
            corners = .{ c0[0], c0[3], c0[2], c0[1] };
        }
        const tile = switch (face) {
            .up => tiles.top,
            .down => tiles.bottom,
            else => tiles.side,
        };
        var uv: [4][2]f32 = undefined;
        var min = [2]f32{ std.math.inf(f32), std.math.inf(f32) };
        var max = [2]f32{ -std.math.inf(f32), -std.math.inf(f32) };
        for (corners, 0..) |p, k| {
            uv[k] = uvOf(face, p);
            for (0..2) |i| {
                min[i] = @min(min[i], uv[k][i]);
                max[i] = @max(max[i], uv[k][i]);
            }
        }
        for (&uv) |*t| {
            if (tiles.fit) {
                t.* = .{ 0.002 + (t[0] - min[0]) / (max[0] - min[0]) * 0.996, (t[1] - min[1]) / (max[1] - min[1]) };
            } else {
                // Down the tile, the block's own part of it.
                t[1] = std.math.clamp(t[1] - @floor(min[1] + 0.0001), 0, 1);
            }
        }
        try o.quad(tile, face, corners, uv, @splat(.none));
    }
}

const none: std.EnumSet(Face) = .{};

const sticks_tiles: Tiles = .{ .top = .sticks_top, .side = .sticks_side, .bottom = .sticks_top };

pub fn build(gpa: std.mem.Allocator, w: *const World, p: [3]i32, blk: Block, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1], p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .solid = true };
    const x: f32 = @floatFromInt(p[0]);
    const y: f32 = @floatFromInt(p[1]);
    const z: f32 = @floatFromInt(p[2]);
    const sticks = sticks_tiles;
    const bamboo: Tiles = .{ .top = .sticks_top, .side = .bamboo, .bottom = .sticks_top, .fit = true };
    // Which sides have the same beside them (-x, +x, -z, +z).
    const same = [4]bool{
        w.get(p[0] - 1, p[1], p[2]) == blk,
        w.get(p[0] + 1, p[1], p[2]) == blk,
        w.get(p[0], p[1], p[2] - 1) == blk,
        w.get(p[0], p[1], p[2] + 1) == blk,
    };
    const side_faces = [4]Face{ .west, .east, .north, .south };
    var joined: std.EnumSet(Face) = .{};
    for (same, side_faces) |s, f| if (s) joined.insert(f);
    switch (blk) {
        .table => {
            // The top, a slab at the top of the block, joined to the next
            // table's; legs at the corners with no table beside them.
            const top = y + 0.88;
            var skip = joined;
            if (w.get(p[0], p[1] + 1, p[2]).isOpaque()) skip.insert(.up);
            try box(o, .{ x, top, z }, .{ x + 1, y + 1, z + 1 }, .{ .top = .sticks_side, .side = .sticks_side, .bottom = .sticks_side }, skip);
            try legs(o, x, y, z, same, top, 0.1, 0.04, sticks);
        },
        .bed => {
            const frame = y + 0.28;
            const mattress = y + 0.44;
            const in_x0: f32 = if (same[0]) 0 else 0.03;
            const in_x1: f32 = if (same[1]) 0 else 0.03;
            const in_z0: f32 = if (same[2]) 0 else 0.03;
            const in_z1: f32 = if (same[3]) 0 else 0.03;
            try box(o, .{ x + in_x0, y + 0.14, z + in_z0 }, .{ x + 1 - in_x1, frame, z + 1 - in_z1 }, sticks, joined);
            try box(o, .{ x + in_x0 + 0.02 * @as(f32, @intFromBool(!same[0])), frame, z + in_z0 + 0.02 * @as(f32, @intFromBool(!same[2])) }, .{ x + 1 - in_x1 - 0.02 * @as(f32, @intFromBool(!same[1])), mattress, z + 1 - in_z1 - 0.02 * @as(f32, @intFromBool(!same[3])) }, .{ .top = .bed_cover, .side = .bed_cover, .bottom = .bed_cover }, joined.unionWith(std.EnumSet(Face).initOne(.down)));
            try legs(o, x, y, z, same, y + 0.14, 0.09, 0.03, sticks);
            // The pillow, at the north end of the bed.
            if (!same[2]) try box(o, .{ x + 0.14, mattress, z + 0.08 }, .{ x + 0.86, mattress + 0.1, z + 0.34 }, .{ .top = .plaster, .side = .plaster, .bottom = .plaster }, std.EnumSet(Face).initOne(.down));
        },
        .chest => {
            try box(o, .{ x + 0.08, y, z + 0.14 }, .{ x + 0.92, y + 0.7, z + 0.86 }, .{ .top = .chest_top, .side = .chest_side, .bottom = .chest_top, .fit = true }, std.EnumSet(Face).initOne(.down));
        },
        .post => {
            var skip: std.EnumSet(Face) = .{};
            if (w.get(p[0], p[1] + 1, p[2]) == .post or w.get(p[0], p[1] + 1, p[2]) == .lamp) skip.insert(.up);
            if (w.get(p[0], p[1] - 1, p[2]) == .post or w.get(p[0], p[1] - 1, p[2]).isOpaque()) skip.insert(.down);
            try box(o, .{ x + 0.44, y, z + 0.44 }, .{ x + 0.56, y + 1, z + 0.56 }, bamboo, skip);
        },
        .lamp => {
            // The torch: its pole, a wider cup of bamboo at its top, and
            // the flame.
            var skip: std.EnumSet(Face) = .initOne(.up);
            if (w.get(p[0], p[1] - 1, p[2]) == .post or w.get(p[0], p[1] - 1, p[2]).isOpaque()) skip.insert(.down);
            try box(o, .{ x + 0.44, y, z + 0.44 }, .{ x + 0.56, y + 0.6, z + 0.56 }, bamboo, skip);
            try box(o, .{ x + 0.4, y + 0.6, z + 0.4 }, .{ x + 0.6, y + 0.76, z + 0.6 }, .{ .top = .sticks_top, .side = .bamboo, .bottom = .bamboo, .fit = true }, none);
            var f = o;
            f.solid = false;
            const fl = [2][2][2]f32{ .{ .{ -1, 0 }, .{ 1, 0 } }, .{ .{ 0, -1 }, .{ 0, 1 } } };
            for (fl) |d| {
                const r = 0.16;
                const c = [4]V{
                    .{ x + 0.5 + d[0][0] * r, y + 0.74, z + 0.5 + d[0][1] * r }, .{ x + 0.5 + d[1][0] * r, y + 0.74, z + 0.5 + d[1][1] * r },
                    .{ x + 0.5 + d[1][0] * r, y + 1.12, z + 0.5 + d[1][1] * r }, .{ x + 0.5 + d[0][0] * r, y + 1.12, z + 0.5 + d[0][1] * r },
                };
                try f.twoSided(.lamp, .up, .up, c, .{ .{ 0.002, 1 }, .{ 0.998, 1 }, .{ 0.998, 0 }, .{ 0.002, 0 } }, .{ .none, .none, .plant, .plant });
            }
        },
        .sandstone_slab, .rock_slab, .thatch_slab => {
            var skip: std.EnumSet(Face) = .{};
            if (w.get(p[0], p[1] - 1, p[2]).isOpaque()) skip.insert(.down);
            for (same, side_faces) |sm, f| if (sm) skip.insert(f);
            const t: Tiles = .{ .top = blk.tile(.up), .side = blk.tile(.north), .bottom = blk.tile(.down) };
            try box(o, .{ x, y, z }, .{ x + 1, y + 0.5, z + 1 }, t, skip);
        },
        .fence => {
            try box(o, .{ x + 0.38, y, z + 0.38 }, .{ x + 0.62, y + 1, z + 0.62 }, sticks, std.EnumSet(Face).initOne(.down));
            // Rails out to fences, and walls, beside it.
            const dirs = [4][2]i32{ .{ -1, 0 }, .{ 1, 0 }, .{ 0, -1 }, .{ 0, 1 } };
            for (dirs) |d| {
                const n = w.get(p[0] + d[0], p[1], p[2] + d[1]);
                if (n != .fence and !n.isOpaque()) continue;
                for ([2]f32{ 0.35, 0.72 }) |ry| {
                    const lo_x = if (d[0] < 0) x else if (d[0] > 0) x + 0.62 else x + 0.44;
                    const hi_x = if (d[0] < 0) x + 0.38 else if (d[0] > 0) x + 1 else x + 0.56;
                    const lo_z = if (d[1] < 0) z else if (d[1] > 0) z + 0.62 else z + 0.44;
                    const hi_z = if (d[1] < 0) z + 0.38 else if (d[1] > 0) z + 1 else z + 0.56;
                    try box(o, .{ lo_x, y + ry, lo_z }, .{ hi_x, y + ry + 0.12, hi_z }, sticks, .{});
                }
            }
        },
        .ladder => {
            // Against the first wall beside it (north, south, west, east);
            // with none, stood in the middle, across x.
            const walls = [4]struct { [2]i32, f32, f32 }{ .{ .{ 0, -1 }, 0, 1 }, .{ .{ 0, 1 }, 1, 1 }, .{ .{ -1, 0 }, 0, 0 }, .{ .{ 1, 0 }, 1, 0 } };
            var against: ?usize = null;
            for (walls, 0..) |wl, k| if (w.get(p[0] + wl[0][0], p[1], p[2] + wl[0][1]).isOpaque()) {
                against = k;
                break;
            };
            const along_x = if (against) |k| walls[k][2] == 1 else true;
            const out: f32 = if (against) |k| (if (walls[k][1] == 0) 0.06 else 0.82) else 0.44;
            const deep: f32 = 0.12;
            for ([2]f32{ 0.12, 0.8 }) |at| {
                const lo_v: V = if (along_x) .{ x + at, y, z + out } else .{ x + out, y, z + at };
                const hi_v: V = if (along_x) .{ x + at + 0.08, y + 1, z + out + deep } else .{ x + out + deep, y + 1, z + at + 0.08 };
                try box(o, lo_v, hi_v, sticks, .{});
            }
            for ([4]f32{ 0.1, 0.35, 0.6, 0.85 }) |ry| {
                const lo_v: V = if (along_x) .{ x + 0.2, y + ry, z + out + 0.03 } else .{ x + out + 0.03, y + ry, z + 0.2 };
                const hi_v: V = if (along_x) .{ x + 0.8, y + ry + 0.06, z + out + deep - 0.03 } else .{ x + out + deep - 0.03, y + ry + 0.06, z + 0.8 };
                try box(o, lo_v, hi_v, sticks, .{});
            }
        },
        .campfire => {
            // A ring of stones.
            for (0..7) |k| {
                const a = @as(f32, @floatFromInt(k)) * std.math.pi * 2 / 7;
                const cx = x + 0.5 + @cos(a) * 0.36;
                const cz = z + 0.5 + @sin(a) * 0.36;
                try box(o, .{ cx - 0.09, y, cz - 0.09 }, .{ cx + 0.09, y + 0.15, cz + 0.09 }, .{ .top = .volcanic_rock, .side = .volcanic_rock, .bottom = .volcanic_rock }, std.EnumSet(Face).initOne(.down));
            }
            // Logs crossed.
            try box(o, .{ x + 0.22, y, z + 0.44 }, .{ x + 0.78, y + 0.1, z + 0.56 }, sticks, std.EnumSet(Face).initOne(.down));
            try box(o, .{ x + 0.44, y + 0.1, z + 0.22 }, .{ x + 0.56, y + 0.2, z + 0.78 }, sticks, .{});
            // The fire, as a torch's but bigger.
            var f = o;
            f.solid = false;
            const fl = [2][2][2]f32{ .{ .{ -1, 0 }, .{ 1, 0 } }, .{ .{ 0, -1 }, .{ 0, 1 } } };
            for (fl) |d| {
                const r = 0.26;
                const c = [4]V{
                    .{ x + 0.5 + d[0][0] * r, y + 0.08, z + 0.5 + d[0][1] * r }, .{ x + 0.5 + d[1][0] * r, y + 0.08, z + 0.5 + d[1][1] * r },
                    .{ x + 0.5 + d[1][0] * r, y + 0.75, z + 0.5 + d[1][1] * r }, .{ x + 0.5 + d[0][0] * r, y + 0.75, z + 0.5 + d[0][1] * r },
                };
                try f.twoSided(.lamp, .up, .up, c, .{ .{ 0.002, 1 }, .{ 0.998, 1 }, .{ 0.998, 0 }, .{ 0.002, 0 } }, .{ .none, .none, .plant, .plant });
            }
        },
        .bamboo => {
            // Three canes, in the same places all the way up (from the
            // column), sprigs of leaves at the top.
            const top = w.get(p[0], p[1] + 1, p[2]) != .bamboo;
            const below_too = w.get(p[0], p[1] - 1, p[2]) == .bamboo;
            var f = o;
            f.solid = false;
            for (0..3) |k| {
                const ki: i32 = @intCast(k);
                const cx = x + 0.2 + world_mod.hash(61 +% @as(u32, @intCast(k)), p[0], p[2]) * 0.6;
                const cz = z + 0.2 + world_mod.hash(71 +% @as(u32, @intCast(k)), p[0], p[2]) * 0.6;
                const w2: f32 = 0.06;
                // The last cane is shorter at the top.
                const h: f32 = if (top and k == 2) 0.6 else 1;
                var skip: std.EnumSet(Face) = .{};
                if (below_too) skip.insert(.down);
                try box(o, .{ cx - w2, y, cz - w2 }, .{ cx + w2, y + h, cz + w2 }, bamboo, skip);
                if (top) {
                    for (0..3) |j| {
                        const a = world_mod.hash(81, p[0] * 3 + ki, p[2] * 5 + @as(i32, @intCast(j))) * std.math.pi * 2;
                        try plants.frond(f, .{ cx, y + h, cz }, a, 0.5, 0.55, 0.35, 0.1, 2);
                    }
                }
            }
        },
        .hibiscus => {
            // A rounded bush: a body, and lumps on it.
            const leaves: Tiles = .{ .top = .hibiscus, .side = .hibiscus, .bottom = .hibiscus };
            const down_skip = std.EnumSet(Face).initOne(.down);
            try box(o, .{ x + 0.08, y, z + 0.08 }, .{ x + 0.92, y + 0.72, z + 0.92 }, leaves, down_skip);
            const ox = (world_mod.hash(91, p[0], p[2]) - 0.5) * 0.3;
            const oz = (world_mod.hash(92, p[0], p[2]) - 0.5) * 0.3;
            try box(o, .{ x + 0.22 + ox, y + 0.72, z + 0.22 + oz }, .{ x + 0.78 + ox, y + 0.98, z + 0.78 + oz }, leaves, down_skip);
            try box(o, .{ x + 0.02, y + 0.15, z + 0.3 - oz }, .{ x + 0.2, y + 0.6, z + 0.7 - oz }, leaves, down_skip);
        },
        .lattice => {
            const ax = acrossX(w, p, blk);
            const skip_end = [2]bool{ sameAlong(w, p, blk, ax, -1), sameAlong(w, p, blk, ax, 1) };
            const a: Axis = .{ .o = o, .x = x, .y = y, .z = z, .along_x = ax };
            // Rails top and bottom, joined to the next lattice's.
            var ends: std.EnumSet(Face) = .{};
            if (skip_end[0]) ends.insert(a.endFace(-1));
            if (skip_end[1]) ends.insert(a.endFace(1));
            var bottom = ends;
            if (w.get(p[0], p[1] - 1, p[2]).isOpaque()) bottom.insert(.down);
            try a.part(0, 1, 0, 0.08, 0.44, 0.56, sticks, bottom);
            try a.part(0, 1, 0.92, 1, 0.44, 0.56, sticks, ends);
            // Posts at its ends, unless it goes on.
            if (!skip_end[0]) try a.part(0, 0.08, 0.08, 0.92, 0.44, 0.56, sticks, std.EnumSet(Face).initMany(&.{ .up, .down }));
            if (!skip_end[1]) try a.part(0.92, 1, 0.08, 0.92, 0.44, 0.56, sticks, std.EnumSet(Face).initMany(&.{ .up, .down }));
            // Slats crossing inside.
            for ([2]f32{ 0.3, 0.63 }) |at| {
                try a.part(at, at + 0.07, 0.08, 0.92, 0.46, 0.54, sticks, std.EnumSet(Face).initMany(&.{ .up, .down }));
                try a.part(if (skip_end[0]) 0 else 0.08, if (skip_end[1]) 1 else 0.92, at, at + 0.07, 0.465, 0.535, sticks, .{});
            }
        },
        .curtain => {
            const ax = acrossX(w, p, blk);
            const a: Axis = .{ .o = o, .x = x, .y = y, .z = z, .along_x = ax };
            var ends: std.EnumSet(Face) = .{};
            if (sameAlong(w, p, blk, ax, -1)) ends.insert(a.endFace(-1));
            if (sameAlong(w, p, blk, ax, 1)) ends.insert(a.endFace(1));
            if (w.get(p[0], p[1] + 1, p[2]).isOpaque()) ends.insert(.up);
            // Stacked, one long curtain: the rail only at the top, the
            // strings on down to the bottom.
            const above = w.get(p[0], p[1] + 1, p[2]) == .curtain;
            const below = w.get(p[0], p[1] - 1, p[2]) == .curtain;
            const top: f32 = if (above) 1 else 0.9;
            if (!above) try a.part(0, 1, 0.9, 0.98, 0.44, 0.56, bamboo, ends);
            const beads: Tiles = .{ .top = .beads, .side = .beads, .bottom = .beads, .fit = true };
            for (0..6) |k| {
                const at = (@as(f32, @floatFromInt(k)) + 0.5) / 6;
                const foot = if (below) 0 else 0.03 + world_mod.hash(101 +% @as(u32, @intCast(k)), p[0] + p[2], p[1]) * 0.08;
                var skip: std.EnumSet(Face) = .initOne(.up);
                if (below) skip.insert(.down);
                try a.part(at - 0.04, at + 0.04, foot, top, 0.46, 0.54, beads, skip);
            }
        },
        .mat => {
            var skip = joined;
            if (w.get(p[0], p[1] - 1, p[2]).isOpaque()) skip.insert(.down);
            try box(o, .{ x, y, z }, .{ x + 1, y + 0.05, z + 1 }, .{ .top = .mat, .side = .mat, .bottom = .mat }, skip);
        },
        .hammock => try hammock(o, w, p, x, y, z, bamboo, sticks),
        .canoe => try canoe(o, w, p, x, y, z),
        else => {},
    }
}

/// Parts laid along an axis (x, or z): places in the block given along
/// it, up, and across it.
const Axis = struct {
    o: Out,
    x: f32,
    y: f32,
    z: f32,
    along_x: bool,

    fn at(a: Axis, along: f32, up: f32, across: f32) V {
        return if (a.along_x) .{ a.x + along, a.y + up, a.z + across } else .{ a.x + across, a.y + up, a.z + along };
    }

    fn part(a: Axis, a0: f32, a1: f32, y0: f32, y1: f32, c0: f32, c1: f32, tiles: Tiles, skip: std.EnumSet(Face)) !void {
        try box(a.o, a.at(a0, y0, c0), a.at(a1, y1, c1), tiles, skip);
    }

    /// The face at the end of the axis, towards `dir` (-1 or 1).
    fn endFace(a: Axis, dir: i32) Face {
        return if (a.along_x) (if (dir < 0) .west else .east) else (if (dir < 0) .north else .south);
    }

    /// A quad facing up (or down), from `a0` to `a1` along and `c0` to
    /// `c1` across, at heights `y0` and `y1` at its ends.
    fn slope(a: Axis, tile: Tile, face: Face, a0: f32, a1: f32, y0: f32, y1: f32, c0: f32, c1: f32, v0: f32, v1: f32) !void {
        var c = [4]V{ a.at(a0, y0, c0), a.at(a0, y0, c1), a.at(a1, y1, c1), a.at(a1, y1, c0) };
        var uv = [4][2]f32{ .{ 0.002, v0 }, .{ 0.998, v0 }, .{ 0.998, v1 }, .{ 0.002, v1 } };
        // Swapping x and z turns it over: wind it back.
        if (a.along_x != (face == .up)) {
            const was = c;
            const uv0 = uv;
            c = .{ was[0], was[3], was[2], was[1] };
            uv = .{ uv0[0], uv0[3], uv0[2], uv0[1] };
        }
        try a.o.quad(tile, face, c, uv, @splat(.none));
    }
};

/// Whether a lattice (or curtain) goes across x: with the same, or walls,
/// beside it that way (or none either way).
fn acrossX(w: *const World, p: [3]i32, blk: Block) bool {
    const joins = struct {
        fn f(b: Block, me: Block) bool {
            return b == me or b.isOpaque();
        }
    }.f;
    const on_x = joins(w.get(p[0] - 1, p[1], p[2]), blk) or joins(w.get(p[0] + 1, p[1], p[2]), blk);
    const on_z = joins(w.get(p[0], p[1], p[2] - 1), blk) or joins(w.get(p[0], p[1], p[2] + 1), blk);
    return on_x or !on_z;
}

/// The same beside it along the axis, towards `dir` (and laid the same way).
fn sameAlong(w: *const World, p: [3]i32, blk: Block, along_x: bool, dir: i32) bool {
    const q: [3]i32 = if (along_x) .{ p[0] + dir, p[1], p[2] } else .{ p[0], p[1], p[2] + dir };
    return w.get(q[0], q[1], q[2]) == blk and acrossX(w, q, blk) == along_x;
}

/// How many of the same are in a row with it along the axis, before it
/// and after it (up to `most` each way).
fn run(w: *const World, p: [3]i32, blk: Block, along_x: bool, most: i32) [2]i32 {
    var out: [2]i32 = .{ 0, 0 };
    for ([2]i32{ -1, 1 }, 0..) |dir, k| {
        var n: i32 = 1;
        while (n <= most) : (n += 1) {
            const q: [3]i32 = if (along_x) .{ p[0] + dir * n, p[1], p[2] } else .{ p[0], p[1], p[2] + dir * n };
            if (w.get(q[0], q[1], q[2]) != blk) break;
        }
        out[k] = n - 1;
    }
    return out;
}

/// What a hammock's end is tied to.
fn holds(b: Block) bool {
    return b.isOpaque() or b == .post or b == .fence or b == .palm or b == .lamp or b == .lattice;
}

fn hammock(o: Out, w: *const World, p: [3]i32, x: f32, y: f32, z: f32, bamboo: Tiles, sticks: Tiles) !void {
    // Along whichever way it is held at both ends (or goes on).
    const ends = struct {
        fn f(wd: *const World, q: [3]i32, ax: bool) bool {
            const r = run(wd, q, .hammock, ax, 8);
            const lo: [3]i32 = if (ax) .{ q[0] - r[0] - 1, q[1], q[2] } else .{ q[0], q[1], q[2] - r[0] - 1 };
            const hi: [3]i32 = if (ax) .{ q[0] + r[1] + 1, q[1], q[2] } else .{ q[0], q[1], q[2] + r[1] + 1 };
            return holds(wd.get(lo[0], lo[1], lo[2])) and holds(wd.get(hi[0], hi[1], hi[2]));
        }
    }.f;
    const in_x = w.get(p[0] - 1, p[1], p[2]) == .hammock or w.get(p[0] + 1, p[1], p[2]) == .hammock;
    const in_z = w.get(p[0], p[1], p[2] - 1) == .hammock or w.get(p[0], p[1], p[2] + 1) == .hammock;
    const ax = if (ends(w, p, true)) true else if (ends(w, p, false)) false else !(in_z and !in_x);
    const r = run(w, p, .hammock, ax, 8);
    const len: f32 = @floatFromInt(r[0] + r[1] + 1);
    const before: f32 = @floatFromInt(r[0]);
    const a: Axis = .{ .o = o, .x = x, .y = y, .z = z, .along_x = ax };
    const first = r[0] == 0;
    const last = r[1] == 0;
    // The cloth: from a spreader bar at each end, sagging in the middle.
    const top: f32 = 0.8;
    const sag: f32 = @min(0.5, 0.25 + 0.1 * len);
    const from: f32 = if (first) 0.15 else 0;
    const to: f32 = if (last) 0.85 else 1;
    const span = len - 0.3;
    const steps = 6;
    for (0..steps) |k| {
        const a0 = from + (to - from) * @as(f32, @floatFromInt(k)) / steps;
        const a1 = from + (to - from) * @as(f32, @floatFromInt(k + 1)) / steps;
        const h = struct {
            fn f(t: f32, tp: f32, sg: f32) f32 {
                return tp - sg * @sin(std.math.pi * std.math.clamp(t, 0, 1));
            }
        }.f;
        const y0 = h((before + a0 - 0.15) / span, top, sag);
        const y1 = h((before + a1 - 0.15) / span, top, sag);
        try a.slope(.hammock, .up, a0, a1, y0, y1, 0.15, 0.85, a0, a1);
        try a.slope(.hammock, .down, a0, a1, y0 - 0.02, y1 - 0.02, 0.15, 0.85, a0, a1);
    }
    for ([2]bool{ first, last }, [2]i32{ -1, 1 }) |is_end, dir| {
        if (!is_end) continue;
        const bar0: f32 = if (dir < 0) 0.12 else 0.85;
        try a.part(bar0, bar0 + 0.03, top - 0.03, top + 0.02, 0.1, 0.9, sticks, .{});
        // A rope to what holds it, or to a stake of its own.
        const r0: f32 = if (dir < 0) 0 else 0.88;
        try a.part(r0, r0 + 0.12, top - 0.01, top + 0.02, 0.48, 0.52, sticks, .{});
        const q: [3]i32 = if (ax) .{ p[0] + dir, p[1], p[2] } else .{ p[0], p[1], p[2] + dir };
        if (!holds(w.get(q[0], q[1], q[2]))) {
            const s0: f32 = if (dir < 0) 0 else 0.9;
            var skip: std.EnumSet(Face) = .{};
            if (w.get(p[0], p[1] - 1, p[2]).isOpaque()) skip.insert(.down);
            try a.part(s0, s0 + 0.1, 0, 1, 0.45, 0.55, bamboo, skip);
        }
    }
}

/// How far a canoe on water sits down in it.
pub const float_depth: f32 = 0.2;

/// The longest canoe.
pub const most_canoe = 16;

/// Where across its block a canoe's hull is.
pub const canoe_centre: f32 = 0.38;

/// A row of canoes, end to end: one canoe.
pub const Row = struct {
    /// Its first block (the least x, or z).
    start: [3]i32,
    along_x: bool,
    len: i32,

    pub fn cell(r: Row, k: i32) [3]i32 {
        return if (r.along_x) .{ r.start[0] + k, r.start[1], r.start[2] } else .{ r.start[0], r.start[1], r.start[2] + k };
    }
};

fn canoeAxis(w: *const World, p: [3]i32) bool {
    const in_x = w.get(p[0] - 1, p[1], p[2]) == .canoe or w.get(p[0] + 1, p[1], p[2]) == .canoe;
    const in_z = w.get(p[0], p[1], p[2] - 1) == .canoe or w.get(p[0], p[1], p[2] + 1) == .canoe;
    return !(in_z and !in_x);
}

/// The canoe a canoe block is part of.
pub fn canoeRow(w: *const World, p: [3]i32) Row {
    const ax = canoeAxis(w, p);
    const r = run(w, p, .canoe, ax, most_canoe - 1);
    const start: [3]i32 = if (ax) .{ p[0] - r[0], p[1], p[2] } else .{ p[0], p[1], p[2] - r[0] };
    return .{ .start = start, .along_x = ax, .len = @min(most_canoe, r[0] + r[1] + 1) };
}

fn canoe(o: Out, w: *const World, p: [3]i32, x: f32, y: f32, z: f32) !void {
    const ax = canoeAxis(w, p);
    const r = run(w, p, .canoe, ax, most_canoe);
    // On water it floats, down in it.
    const sink: f32 = if (w.wateryAt(p[0], p[1] - 1, p[2])) float_depth else 0;
    try canoePart(o, .{ x, y - sink, z }, ax, r[0], r[0] + r[1] + 1);
}

/// A canoe, `len` blocks long, its hull's middle at x 0 and its bottom at
/// y 0, its bow to -z (as a figure faces): drawn as it moves (see
/// boat.zig), lit as under the open sky.
pub fn canoeMesh(gpa: std.mem.Allocator, len: i32, mesh: *mesher.Mesh) !void {
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = 15, .lamp = 0, .solid = true };
    const half = @as(f32, @floatFromInt(len)) / 2;
    var k: i32 = 0;
    while (k < len) : (k += 1) try canoePart(o, .{ -canoe_centre, 0, @as(f32, @floatFromInt(k)) - half }, false, k, len);
}

/// A canoe's hull, across at a place along it (`t` blocks from its
/// start, of `len`): how far out its sides are from its middle, how high
/// its rim and its bottom are, and how far in and down it is hollowed.
/// It narrows to a point at each end, its bottom and rim rising there,
/// and is not hollowed near the points.
const Station = struct {
    w: f32,
    rim: f32,
    bottom: f32,
    wi: f32,
    di: f32,

    fn at(t: f32, len: f32) Station {
        const d = @min(t, len - t);
        const s = @sin(std.math.pi / 2.0 * std.math.clamp(d / @min(1.1, len / 2), 0, 1));
        const lift = (1 - s) * (1 - s);
        const w = 0.025 + 0.22 * s;
        const rim = 0.42 + 0.1 * lift;
        const bottom = 0.05 + 0.25 * lift;
        const open = std.math.clamp((s - 0.45) / 0.35, 0, 1);
        return .{ .w = w, .rim = rim, .bottom = bottom, .wi = (w - 0.04) * open, .di = (rim - bottom - 0.07) * open };
    }

    /// A point round its outside, from the left rim (k 0) under it to
    /// the right rim (k `round`): across and up.
    fn outside(st: Station, k: usize) [2]f32 {
        const th = std.math.pi * (1 + @as(f32, @floatFromInt(k)) / round);
        return .{ st.w * @cos(th), st.rim + (st.rim - st.bottom) * @sin(th) };
    }

    fn hollow(st: Station) bool {
        return st.wi > 0.005 and st.di > 0.005;
    }

    const round = 5;
};

/// The block of a canoe `len_n` long, `before_n` from its start, at
/// `origin`: one smooth hull, hollowed, and its outrigger.
fn canoePart(o: Out, origin: V, ax: bool, before_n: i32, len_n: i32) !void {
    const len: f32 = @floatFromInt(len_n);
    const before: f32 = @floatFromInt(before_n);
    const centre = canoe_centre;
    const a: Axis = .{ .o = o, .x = origin[0], .y = origin[1], .z = origin[2], .along_x = ax };
    const H = struct {
        a: Axis,
        fn pt(h: @This(), along: f32, ac: [2]f32) V {
            return h.a.at(along, ac[1], centre + ac[0]);
        }
        fn dir(h: @This(), along: f32, up_: f32, across: f32) V {
            return if (h.a.along_x) .{ along, up_, across } else .{ across, up_, along };
        }
        fn quad(h: @This(), c: [4]V, uv: [4][2]f32, out: V) !void {
            try plants.facing(h.a.o, .canoe, c, uv, out, @splat(.none));
        }
    };
    const h: H = .{ .a = a };
    const steps = 4;
    for (0..steps) |k| {
        const a0 = @as(f32, @floatFromInt(k)) / steps;
        const a1 = @as(f32, @floatFromInt(k + 1)) / steps;
        const s0 = Station.at(before + a0, len);
        const s1 = Station.at(before + a1, len);
        // Round the outside.
        for (0..Station.round) |j| {
            const p00 = s0.outside(j);
            const p01 = s0.outside(j + 1);
            const p10 = s1.outside(j);
            const p11 = s1.outside(j + 1);
            const th = std.math.pi * (1 + (@as(f32, @floatFromInt(j)) + 0.5) / Station.round);
            const v = struct {
                fn f(st: Station, p: [2]f32) f32 {
                    return std.math.clamp((st.rim - p[1]) / @max(st.rim - st.bottom, 0.01), 0, 1);
                }
            }.f;
            try h.quad(.{ h.pt(a0, p00), h.pt(a0, p01), h.pt(a1, p11), h.pt(a1, p10) }, .{ .{ a0, v(s0, p00) }, .{ a0, v(s0, p01) }, .{ a1, v(s1, p11) }, .{ a1, v(s1, p10) } }, h.dir(0, @sin(th), @cos(th)));
        }
        const up_dir = h.dir(0, 1, 0);
        // Across the tile as far as across the canoe (a tile a block), so
        // the wood is as fine as anywhere: the floor from the tile's
        // middle, the rims and deck from above it.
        const floor_v: [4][2]f32 = .{ .{ a0, 0.6 - s0.wi }, .{ a0, 0.6 + s0.wi }, .{ a1, 0.6 + s1.wi }, .{ a1, 0.6 - s1.wi } };
        const deck_v: [4][2]f32 = .{ .{ a0, 0.45 - s0.w }, .{ a0, 0.45 + s0.w }, .{ a1, 0.45 + s1.w }, .{ a1, 0.45 - s1.w } };
        if (s0.hollow() and s1.hollow()) {
            // The rims, the sides inside, the floor.
            for ([2]f32{ -1, 1 }) |side| {
                const rim_v: [4][2]f32 = .{ .{ a0, 0.45 + side * s0.w }, .{ a0, 0.45 + side * s0.wi }, .{ a1, 0.45 + side * s1.wi }, .{ a1, 0.45 + side * s1.w } };
                try h.quad(.{ h.pt(a0, .{ side * s0.w, s0.rim }), h.pt(a0, .{ side * s0.wi, s0.rim }), h.pt(a1, .{ side * s1.wi, s1.rim }), h.pt(a1, .{ side * s1.w, s1.rim }) }, rim_v, up_dir);
                try h.quad(.{ h.pt(a0, .{ side * s0.wi, s0.rim }), h.pt(a0, .{ side * s0.wi, s0.rim - s0.di }), h.pt(a1, .{ side * s1.wi, s1.rim - s1.di }), h.pt(a1, .{ side * s1.wi, s1.rim }) }, .{ .{ a0, 0.25 }, .{ a0, 0.25 + s0.di }, .{ a1, 0.25 + s1.di }, .{ a1, 0.25 } }, h.dir(0, 0, -side));
            }
            try h.quad(.{ h.pt(a0, .{ -s0.wi, s0.rim - s0.di }), h.pt(a0, .{ s0.wi, s0.rim - s0.di }), h.pt(a1, .{ s1.wi, s1.rim - s1.di }), h.pt(a1, .{ -s1.wi, s1.rim - s1.di }) }, floor_v, up_dir);
        } else {
            // Decked over, near the points; where the hollow starts, its
            // end.
            try h.quad(.{ h.pt(a0, .{ -s0.w, s0.rim }), h.pt(a0, .{ s0.w, s0.rim }), h.pt(a1, .{ s1.w, s1.rim }), h.pt(a1, .{ -s1.w, s1.rim }) }, deck_v, up_dir);
            // (Facing into the hollow, beyond it.)
            for ([2]Station{ s0, s1 }, [2]f32{ a0, a1 }, [2]f32{ -1, 1 }) |st, at, toward| {
                if (!st.hollow()) continue;
                try h.quad(.{ h.pt(at, .{ -st.wi, st.rim }), h.pt(at, .{ st.wi, st.rim }), h.pt(at, .{ st.wi, st.rim - st.di }), h.pt(at, .{ -st.wi, st.rim - st.di }) }, .{ .{ 0.1, 0.25 }, .{ 0.9, 0.25 }, .{ 0.9, 0.6 }, .{ 0.1, 0.6 } }, h.dir(toward, 0, 0));
            }
        }
        // Its points, closed.
        for ([2]bool{ before + a0 == 0, before + a1 == len }, [2]Station{ s0, s1 }, [2]f32{ a0, a1 }, [2]f32{ -1, 1 }) |is_end, st, at, toward| {
            if (!is_end) continue;
            const p = [6][2]f32{ st.outside(0), st.outside(1), st.outside(2), st.outside(3), st.outside(4), st.outside(5) };
            const uv: [4][2]f32 = .{ .{ 0.1, 0.1 }, .{ 0.3, 0.5 }, .{ 0.6, 0.5 }, .{ 0.9, 0.1 } };
            try h.quad(.{ h.pt(at, p[0]), h.pt(at, p[1]), h.pt(at, p[2]), h.pt(at, p[3]) }, uv, h.dir(toward, 0, 0));
            try h.quad(.{ h.pt(at, p[0]), h.pt(at, p[3]), h.pt(at, p[4]), h.pt(at, p[5]) }, uv, h.dir(toward, 0, 0));
        }
    }
    // The outrigger: a float beside it, on two booms resting across the
    // hull, at the canoe's ends (or the middle of one alone), each held
    // on the float by a peg.
    const float_lo: f32 = 0.08;
    const float_hi: f32 = 0.2;
    const float_c: f32 = 0.5;
    const wood: Tiles = .{ .top = .canoe, .side = .canoe, .bottom = .canoe, .fit = true };
    const f0 = @max(0, 0.3 - before);
    const f1 = @min(1, len - 0.3 - before);
    if (f1 > f0) try a.part(f0, f1, float_lo, float_hi, centre + float_c - 0.06, centre + float_c + 0.06, wood, .{});
    const booms: []const f32 = if (len_n == 1) &.{0.5} else if (before_n == 0) &.{0.6} else if (before_n == len_n - 1) &.{0.4} else &.{};
    for (booms) |at| {
        const st = Station.at(before + at, len);
        try a.part(at - 0.03, at + 0.03, st.rim, st.rim + 0.05, centre - st.w - 0.02, centre + float_c + 0.04, sticks_tiles, .{});
        try a.part(at - 0.02, at + 0.02, float_hi, st.rim, centre + float_c - 0.02, centre + float_c + 0.02, sticks_tiles, std.EnumSet(Face).initMany(&.{ .up, .down }));
    }
}

/// Legs at the corners with nothing the same beside them either way, `w`
/// thick, `inset` in from the edges, up to `top`.
fn legs(o: Out, x: f32, y: f32, z: f32, same: [4]bool, top: f32, w: f32, inset: f32, tiles: Tiles) !void {
    for ([2]usize{ 0, 1 }) |i| for ([2]usize{ 0, 1 }) |j| {
        if (same[i] or same[2 + j]) continue;
        const lx = if (i == 0) x + inset else x + 1 - inset - w;
        const lz = if (j == 0) z + inset else z + 1 - inset - w;
        try box(o, .{ lx, y, lz }, .{ lx + w, top, lz + w }, tiles, std.EnumSet(Face).initMany(&.{ .up, .down }));
    };
}

test "tables side by side are one, with legs only at its corners" {
    const testing = std.testing;
    const w = try World.create(testing.allocator);
    defer w.destroy();
    var m: mesher.Mesh = .{};
    defer m.deinit(testing.allocator);
    // Alone: a top (five faces: none below) and four legs (four faces).
    _ = w.set(4, 20, 4, .table);
    try build(testing.allocator, w, .{ 4, 20, 4 }, .table, &m);
    try testing.expectEqual(@as(usize, (6 + 4 * 4) * 4), m.items(.solid1).len + m.items(.solid0).len);
    // Two side by side: each has two legs, and no top's side between.
    _ = w.set(5, 20, 4, .table);
    m.clearRetainingCapacity();
    try build(testing.allocator, w, .{ 4, 20, 4 }, .table, &m);
    try testing.expectEqual(@as(usize, (5 + 2 * 4) * 4), m.items(.solid1).len + m.items(.solid0).len);
    // Everything is within the block.
    for (m.items(.solid1)) |v| try testing.expect(v.pos[0] >= 4 and v.pos[0] <= 5 and v.pos[1] >= 20 and v.pos[1] <= 21);
}
