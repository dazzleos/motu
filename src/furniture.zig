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

pub fn build(gpa: std.mem.Allocator, w: *const World, p: [3]i32, blk: Block, mesh: *mesher.Mesh) !void {
    const l = w.lightAt(p[0], p[1], p[2]);
    const o: Out = .{ .gpa = gpa, .mesh = mesh, .sky = world_mod.skyOf(l), .lamp = world_mod.lampOf(l), .solid = true };
    const x: f32 = @floatFromInt(p[0]);
    const y: f32 = @floatFromInt(p[1]);
    const z: f32 = @floatFromInt(p[2]);
    const sticks: Tiles = .{ .top = .sticks_top, .side = .sticks_side, .bottom = .sticks_top };
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
        else => {},
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
