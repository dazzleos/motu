//! Turns a chunk of the world into triangles for the GPU: the faces of
//! blocks that can be seen (those next to something that does not hide
//! them), as quads of four vertices (the renderer's index buffer makes the
//! two triangles of each).
//!
//! Meshes for each chunk, drawn in turn: solid blocks; water (its
//! surface, a quad a block so it can wave); and see-through things (glass
//! and plants), drawn last, blended. Solid and see-through ones are split
//! by the texture strip their tiles are in (see blocks.Tile), as a draw
//! has one texture.
//!
//! Each corner has its ambient occlusion (how many of the three blocks
//! around the corner, in front of the face, are solid: corners in nooks
//! are darker) and its light, the average of the blocks around it in
//! front of the face, so light and shade are smooth across faces. Solid
//! faces side by side that look the same all over (tile, shade and light)
//! are merged into one longer quad, which cuts the vertices to draw by
//! more than half. They are merged only across the tile (along its s
//! coordinate), where the texture unit repeats it: a tile is one strip
//! wide, so s runs on in blocks and wraps by itself. Down the tile (t) a
//! quad is one block, so t stays within the tile's place in its strip.
//! Nothing is wrapped in the shader, so the texture unit's choice of
//! mipmap level (from how fast s and t change between pixels) is right
//! everywhere, merged or not.
//!
//! A vertex is six floats: its place, its texture coordinates and the
//! rest packed into one (see `Info`): the GPU reads vertex attributes only
//! as floats, and fewer bytes a vertex are less to fetch.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const plants = @import("plants.zig");

const Block = blocks.Block;
const Face = blocks.Face;
const World = world_mod.World;

pub const Vertex = extern struct {
    pos: [3]f32,
    uv: [2]f32,
    info: f32,
};

/// How a vertex moves (in the vertex shader).
pub const Anim = enum(u2) {
    none,
    /// Leaves: sways a little, as all leaves around do.
    sway,
    /// A plant's top: sways more.
    plant,
    /// Water's surface: waves.
    wave,
};

/// What a vertex packs into its last float: an integer under 2^23, exact
/// in a float, which the shader takes apart with floor and powers of two.
pub const Info = struct {
    /// The atlas tile (water: how deep it is, in blocks, up to 63).
    tile: u6,
    /// Ambient occlusion, 0 (open) to 3 (in a corner).
    ao: u2 = 0,
    face: Face,
    sky: u4,
    lamp: u4,
    anim: Anim = .none,

    pub fn pack(i: Info) f32 {
        const v: u32 = @as(u32, i.tile) | @as(u32, i.ao) << 6 | @as(u32, @intFromEnum(i.face)) << 8 |
            @as(u32, i.sky) << 11 | @as(u32, i.lamp) << 15 | @as(u32, @intFromEnum(i.anim)) << 19;
        return @floatFromInt(v);
    }

    pub fn unpack(f: f32) Info {
        const v: u32 = @intFromFloat(f);
        return .{
            .tile = @truncate(v),
            .ao = @truncate(v >> 6),
            .face = @enumFromInt(@as(u3, @truncate(v >> 8))),
            .sky = @truncate(v >> 11),
            .lamp = @truncate(v >> 15),
            .anim = @enumFromInt(@as(u2, @truncate(v >> 19))),
        };
    }
};

/// How high water's surface is in its block.
pub const water_top: f32 = 0.875;

/// A chunk's meshes, in the order they are drawn (and kept in its buffer).
pub const Section = enum(u3) {
    solid0,
    solid1,
    solid2,
    water,
    clear0,
    clear1,
    clear2,

    pub fn solid(strip: u2) Section {
        return @enumFromInt(@as(u3, strip));
    }

    pub fn clear(strip: u2) Section {
        return @enumFromInt(@as(u3, 4) + strip);
    }

    pub const count = 7;
};

/// The order a strip's solid faces are kept in, a face's after another's.
/// From most places only one of each pair of opposite faces can be seen
/// (and usually the tops), and whichever they are, this order puts most
/// of them next to each other, to be drawn together.
pub const face_order = [6]Face{ .north, .west, .up, .east, .south, .down };

pub const Mesh = struct {
    lists: [Section.count]std.ArrayList(Vertex) = @splat(.empty),
    /// Quads of each solid strip facing each way (in `face_order`).
    face_quads: [blocks.Tile.strips][6]u32 = @splat(@splat(0)),

    pub fn deinit(m: *Mesh, gpa: std.mem.Allocator) void {
        for (&m.lists) |*l| l.deinit(gpa);
    }

    pub fn clearRetainingCapacity(m: *Mesh) void {
        for (&m.lists) |*l| l.clearRetainingCapacity();
        m.face_quads = @splat(@splat(0));
    }

    pub fn list(m: *Mesh, s: Section) *std.ArrayList(Vertex) {
        return &m.lists[@intFromEnum(s)];
    }

    pub fn items(m: *const Mesh, s: Section) []const Vertex {
        return m.lists[@intFromEnum(s)].items;
    }

    /// All the solid (or see-through) vertices, whatever their strip.
    pub fn solidCount(m: *const Mesh) usize {
        return m.items(.solid0).len + m.items(.solid1).len + m.items(.solid2).len;
    }

    pub fn clearCount(m: *const Mesh) usize {
        return m.items(.clear0).len + m.items(.clear1).len + m.items(.clear2).len;
    }

    pub fn quads(m: *const Mesh) usize {
        var n: usize = 0;
        for (m.lists) |l| n += l.items.len;
        return n / 4;
    }
};

/// A face of a block as it will look: its tile and each corner's shade and
/// light (corners 00, 10, 11, 01 across the face).
const FaceLook = struct {
    tile: u6,
    ao: [4]u2,
    sky: [4]u4,
    lamp: [4]u4,
    sway: bool,

    fn uniform(f: FaceLook) bool {
        return f.ao[0] == f.ao[1] and f.ao[0] == f.ao[2] and f.ao[0] == f.ao[3] and
            f.sky[0] == f.sky[1] and f.sky[0] == f.sky[2] and f.sky[0] == f.sky[3] and
            f.lamp[0] == f.lamp[1] and f.lamp[0] == f.lamp[2] and f.lamp[0] == f.lamp[3];
    }

    fn eql(a: FaceLook, b: FaceLook) bool {
        return a.tile == b.tile and a.sway == b.sway and std.meta.eql(a.ao, b.ao) and std.meta.eql(a.sky, b.sky) and std.meta.eql(a.lamp, b.lamp);
    }
};

const P = [3]i32;

fn add(a: P, b: P) P {
    return .{ a[0] + b[0], a[1] + b[1], a[2] + b[2] };
}

fn unit(axis: usize, sign: i32) P {
    var p: P = .{ 0, 0, 0 };
    p[axis] = sign;
    return p;
}

/// The look of the face of the block at `p` facing `face`: the corners'
/// occlusion and light come from the blocks in front of it.
fn faceLook(w: *const World, p: P, face: Face, tile: blocks.Tile, sway: bool) FaceLook {
    const a: usize = @intFromEnum(face) / 2;
    const b = (a + 1) % 3;
    const c = (a + 2) % 3;
    const n = face.normal();
    const l = add(p, n);
    const centre = w.lightAt(l[0], l[1], l[2]);
    var out: FaceLook = .{ .tile = @intFromEnum(tile), .ao = undefined, .sky = undefined, .lamp = undefined, .sway = sway };
    const corners = [4][2]i32{ .{ -1, -1 }, .{ 1, -1 }, .{ 1, 1 }, .{ -1, 1 } };
    for (corners, 0..) |d, k| {
        const sb = add(l, unit(b, d[0]));
        const sc = add(l, unit(c, d[1]));
        const cr = add(sb, unit(c, d[1]));
        const s1 = w.get(sb[0], sb[1], sb[2]).isOpaque();
        const s2 = w.get(sc[0], sc[1], sc[2]).isOpaque();
        const cc = w.get(cr[0], cr[1], cr[2]).isOpaque();
        out.ao[k] = if (s1 and s2) 3 else @as(u2, @intFromBool(s1)) + @intFromBool(s2) + @intFromBool(cc);
        var sky: u32 = world_mod.skyOf(centre);
        var lamp: u32 = world_mod.lampOf(centre);
        var count: u32 = 1;
        const around = [3]struct { P, bool }{ .{ sb, !s1 }, .{ sc, !s2 }, .{ cr, !cc and !(s1 and s2) } };
        for (around) |q| if (q[1]) {
            const ql = w.lightAt(q[0][0], q[0][1], q[0][2]);
            sky += world_mod.skyOf(ql);
            lamp += world_mod.lampOf(ql);
            count += 1;
        };
        out.sky[k] = @intCast((sky + count / 2) / count);
        out.lamp[k] = @intCast((lamp + count / 2) / count);
    }
    return out;
}

/// How far into a tile's texels its first and last rows are sampled: half
/// a texel, so a row of the next tile in the strip is never mixed in.
const inset: f32 = 0.5 / 64.0;

/// t for a place `down` (0 to 1) down the tile `tile`, in its strip.
pub fn stripT(tile: blocks.Tile, down: f32) f32 {
    return (@as(f32, @floatFromInt(tile.slot())) + inset + down * (1 - 2 * inset)) / blocks.Tile.per_strip;
}

/// Where across and down a face a place is, as seen from outside (so the
/// tiles are the right way round), in blocks.
fn uvOf(face: Face, x: f32, y: f32, z: f32) [2]f32 {
    return switch (face) {
        .up, .down => .{ x, z },
        .east => .{ -z, -y },
        .west => .{ z, -y },
        .south => .{ x, -y },
        .north => .{ -x, -y },
    };
}

fn emitQuad(list: *std.ArrayList(Vertex), gpa: std.mem.Allocator, face: Face, corners: [4][3]f32, look: FaceLook, anims: [4]Anim) !void {
    // Split along the diagonal that shades evenly: the one between the
    // two corners whose occlusion together is more.
    const flip = @as(u32, look.ao[0]) + look.ao[2] < @as(u32, look.ao[1]) + look.ao[3];
    var order = [4]usize{ 0, 1, 2, 3 };
    if (flip) order = .{ 1, 2, 3, 0 };
    // s runs on in blocks; down the quad (one block), t from the tile's
    // top to its bottom.
    var top: f32 = std.math.inf(f32);
    for (corners) |c| top = @min(top, uvOf(face, c[0], c[1], c[2])[1]);
    const tile: blocks.Tile = @enumFromInt(look.tile);
    for (order) |k| {
        const c = corners[k];
        const uv = uvOf(face, c[0], c[1], c[2]);
        try list.append(gpa, .{
            .pos = c,
            .uv = .{ uv[0], stripT(tile, uv[1] - top) },
            .info = (Info{ .tile = look.tile, .ao = look.ao[k], .face = face, .sky = look.sky[k], .lamp = look.lamp[k], .anim = anims[k] }).pack(),
        });
    }
}

/// The corners of a rectangle of faces on the plane `plane` across axis
/// `a`, from (b0, c0), `wb` by `wc` blocks: wound counter-clockwise seen
/// from in front.
fn rectCorners(face: Face, plane: f32, b0: f32, c0: f32, wb: f32, wc: f32) [4][3]f32 {
    const a: usize = @intFromEnum(face) / 2;
    const b = (a + 1) % 3;
    const c = (a + 2) % 3;
    const uv = [4][2]f32{ .{ b0, c0 }, .{ b0 + wb, c0 }, .{ b0 + wb, c0 + wc }, .{ b0, c0 + wc } };
    var out: [4][3]f32 = undefined;
    for (uv, 0..) |q, k| {
        out[k][a] = plane;
        out[k][b] = q[0];
        out[k][c] = q[1];
    }
    // e_b × e_c is +e_a: the order 00, 10, 11, 01 faces +a. For a face
    // looking the other way, go round the other way (keeping corner 0).
    if (@intFromEnum(face) % 2 == 1) return .{ out[0], out[3], out[2], out[1] };
    return out;
}

/// The same corners' looks, for a face looking the other way (see
/// `rectCorners`).
fn cornerLooks(face: Face, look: FaceLook) FaceLook {
    if (@intFromEnum(face) % 2 == 0) return look;
    var out = look;
    for ([4]usize{ 0, 3, 2, 1 }, 0..) |from, k| {
        out.ao[k] = look.ao[from];
        out.sky[k] = look.sky[from];
        out.lamp[k] = look.lamp[from];
    }
    return out;
}

/// How many layers from the bottom of the chunk have anything in them (0
/// if the chunk is all air).
fn chunkTopY(w: *const World, origin: P) i32 {
    var y: i32 = world_mod.size_y;
    while (y > 0) {
        y -= 1;
        var lz: i32 = 0;
        while (lz < world_mod.chunk_size) : (lz += 1) {
            const row = w.blocks[World.index(origin[0], y, origin[2] + lz)..][0..world_mod.chunk_size];
            if (std.mem.indexOfNone(Block, row, &.{.air}) != null) return y + 1;
        }
    }
    return 0;
}

/// Meshes chunk (cx, cz) into `mesh` (cleared first).
pub fn build(gpa: std.mem.Allocator, w: *const World, cx: usize, cz: usize, mesh: *Mesh) !void {
    mesh.clearRetainingCapacity();
    const origin = P{ @intCast(cx * world_mod.chunk_size), 0, @intCast(cz * world_mod.chunk_size) };
    const top_y = chunkTopY(w, origin);
    if (top_y == 0) return;
    try solidFaces(gpa, w, origin, top_y, mesh);
    try otherFaces(gpa, w, origin, top_y, mesh);
}

fn solidFaces(gpa: std.mem.Allocator, w: *const World, origin: P, top_y: i32, mesh: *Mesh) !void {
    const local_dims = [3]i32{ world_mod.chunk_size, top_y, world_mod.chunk_size };
    // The faces in one slice, waiting to be merged: the biggest slice is
    // 16 by 64.
    var mask: [world_mod.chunk_size * world_mod.size_y]?FaceLook = undefined;
    for (face_order, 0..) |face, k| {
        var before: [blocks.Tile.strips]usize = undefined;
        for (&before, 0..) |*b, st| b.* = mesh.items(.solid(@intCast(st))).len;
        defer for (before, 0..) |b, st| {
            mesh.face_quads[st][k] = @intCast((mesh.items(.solid(@intCast(st))).len - b) / 4);
        };
        const a: usize = @intFromEnum(face) / 2;
        const b = (a + 1) % 3;
        const c = (a + 2) % 3;
        const n = face.normal();
        const nb: usize = @intCast(local_dims[b]);
        const nc: usize = @intCast(local_dims[c]);
        var s: i32 = 0;
        while (s < local_dims[a]) : (s += 1) {
            var any = false;
            for (0..nc) |j| for (0..nb) |i| {
                var p = origin;
                p[a] += s;
                p[b] += @intCast(i);
                p[c] += @intCast(j);
                const blk = w.blocks[World.index(p[0], p[1], p[2])];
                mask[j * nb + i] = null;
                if (!blk.isOpaque()) continue;
                const q = add(p, n);
                if (w.get(q[0], q[1], q[2]).isOpaque()) continue;
                mask[j * nb + i] = faceLook(w, p, face, blk.tile(face), blk.sways());
                any = true;
            };
            if (!any) continue;
            // Merge: from each face not yet used, as wide as faces that
            // look the same, then as many rows as are all the same too.
            const plane: f32 = @floatFromInt(origin[a] + s + @as(i32, if (n[a] > 0) 1 else 0));
            for (0..nc) |j| {
                var i: usize = 0;
                while (i < nb) {
                    const look = mask[j * nb + i] orelse {
                        i += 1;
                        continue;
                    };
                    var wb: usize = 1;
                    var hc: usize = 1;
                    if (look.uniform()) {
                        // Across the tile only (see the top of the file):
                        // along b for the faces of z, along c for the rest.
                        if (a == 2) {
                            while (i + wb < nb) : (wb += 1) {
                                const o = mask[j * nb + i + wb] orelse break;
                                if (!o.eql(look)) break;
                            }
                        } else {
                            while (j + hc < nc) : (hc += 1) {
                                const o = mask[(j + hc) * nb + i] orelse break;
                                if (!o.eql(look)) break;
                            }
                        }
                    }
                    for (0..hc) |dj| @memset(mask[(j + dj) * nb + i ..][0..wb], null);
                    const corners = rectCorners(face, plane, @floatFromInt(origin[b] + @as(i32, @intCast(i))), @floatFromInt(origin[c] + @as(i32, @intCast(j))), @floatFromInt(wb), @floatFromInt(hc));
                    const anim: Anim = if (look.sway) .sway else .none;
                    const strip = (@as(blocks.Tile, @enumFromInt(look.tile))).strip();
                    try emitQuad(mesh.list(.solid(strip)), gpa, face, corners, cornerLooks(face, look), @splat(anim));
                    i += wb;
                }
            }
        }
        // Palms' trunks look every way, and paving's stones sit on the
        // grass: with the faces looking up, which are drawn from nearly
        // anywhere.
        if (face == .up) try shapedSolids(gpa, w, origin, top_y, mesh);
    }
}

/// Solid things that are not cubes: palms' trunks, paving's stones.
fn shapedSolids(gpa: std.mem.Allocator, w: *const World, origin: P, top_y: i32, mesh: *Mesh) !void {
    var y: i32 = 0;
    while (y < top_y) : (y += 1) {
        var lz: i32 = 0;
        while (lz < world_mod.chunk_size) : (lz += 1) {
            const row = w.blocks[World.index(origin[0], y, origin[2] + lz)..][0..world_mod.chunk_size];
            for (row, 0..) |blk, lx| {
                const p = P{ origin[0] + @as(i32, @intCast(lx)), y, origin[2] + lz };
                switch (blk) {
                    .palm => try plants.trunk(gpa, w, p, mesh),
                    .paving => if (!w.get(p[0], p[1] + 1, p[2]).isOpaque()) try plants.paving(gpa, w, p, mesh),
                    else => {},
                }
            }
        }
    }
}

/// Water, glass, palms and plants.
fn otherFaces(gpa: std.mem.Allocator, w: *const World, origin: P, top_y: i32, mesh: *Mesh) !void {
    var y: i32 = 0;
    while (y < top_y) : (y += 1) {
        var lz: i32 = 0;
        while (lz < world_mod.chunk_size) : (lz += 1) {
            const row = w.blocks[World.index(origin[0], y, origin[2] + lz)..][0..world_mod.chunk_size];
            for (row, 0..) |blk, lx| {
                if (blk == .air) continue;
                const p = P{ origin[0] + @as(i32, @intCast(lx)), y, origin[2] + lz };
                switch (blk.shape()) {
                    .water => try waterFaces(gpa, w, p, mesh),
                    .clear => for (Face.all) |face| {
                        const q = add(p, face.normal());
                        const other = w.get(q[0], q[1], q[2]);
                        if (other.isOpaque() or other == blk) continue;
                        const look = faceLook(w, p, face, blk.tile(face), false);
                        const corners = rectCorners(face, @floatFromInt(p[@intFromEnum(face) / 2] + @as(i32, if (@intFromEnum(face) % 2 == 0) 1 else 0)), @floatFromInt(p[(@intFromEnum(face) / 2 + 1) % 3]), @floatFromInt(p[(@intFromEnum(face) / 2 + 2) % 3]), 1, 1);
                        try emitQuad(mesh.list(.clear(blk.tile(face).strip())), gpa, face, corners, cornerLooks(face, look), @splat(.none));
                    },
                    .plant => try plants.plant(gpa, w, p, blk, mesh),
                    .pole => try plants.crown(gpa, w, p, mesh),
                    else => {},
                }
            }
        }
    }
}

fn waterFaces(gpa: std.mem.Allocator, w: *const World, p: P, mesh: *Mesh) !void {
    const above = w.get(p[0], p[1] + 1, p[2]);
    const surface = above != .water;
    const top: f32 = @as(f32, @floatFromInt(p[1])) + (if (surface) water_top else 1);
    // How deep: water down to the bottom (at most 7 blocks, where the
    // shader reaches its deepest blue). Worked out only if a face shows.
    var depth: u6 = 0;
    const getDepth = struct {
        fn f(world: *const World, pos: P, d: *u6) u6 {
            if (d.* == 0) {
                var n: u6 = 1;
                while (n < 7 and world.get(pos[0], pos[1] - @as(i32, n), pos[2]) == .water) n += 1;
                d.* = n;
            }
            return d.*;
        }
    }.f;
    const x: f32 = @floatFromInt(p[0]);
    const y: f32 = @floatFromInt(p[1]);
    const z: f32 = @floatFromInt(p[2]);
    if (surface and !above.isOpaque()) {
        const l = w.lightAt(p[0], p[1] + 1, p[2]);
        try waterQuad(gpa, mesh, .up, .{ .{ x, top, z + 1 }, .{ x + 1, top, z + 1 }, .{ x + 1, top, z }, .{ x, top, z } }, getDepth(w, p, &depth), l, @splat(.wave));
    }
    // Sides against air (not into the sea beyond the world), and the
    // bottom if it is over air.
    const top_anim: Anim = if (surface) .wave else .none;
    for ([_]Face{ .east, .west, .south, .north, .down }) |face| {
        const q = add(p, face.normal());
        if (!World.inBounds(q[0], @max(q[1], 0), q[2])) continue;
        const other = w.get(q[0], q[1], q[2]);
        if (other == .water or other.isOpaque()) continue;
        const l = w.lightAt(q[0], q[1], q[2]);
        const corners: [4][3]f32 = switch (face) {
            .east => .{ .{ x + 1, y, z + 1 }, .{ x + 1, y, z }, .{ x + 1, top, z }, .{ x + 1, top, z + 1 } },
            .west => .{ .{ x, y, z }, .{ x, y, z + 1 }, .{ x, top, z + 1 }, .{ x, top, z } },
            .south => .{ .{ x, y, z + 1 }, .{ x + 1, y, z + 1 }, .{ x + 1, top, z + 1 }, .{ x, top, z + 1 } },
            .north => .{ .{ x + 1, y, z }, .{ x, y, z }, .{ x, top, z }, .{ x + 1, top, z } },
            else => .{ .{ x, y, z }, .{ x + 1, y, z }, .{ x + 1, y, z + 1 }, .{ x, y, z + 1 } },
        };
        const anims: [4]Anim = if (face == .down) @splat(.none) else .{ .none, .none, top_anim, top_anim };
        try waterQuad(gpa, mesh, face, corners, getDepth(w, p, &depth), l, anims);
    }
}

fn waterQuad(gpa: std.mem.Allocator, mesh: *Mesh, face: Face, corners: [4][3]f32, depth: u6, light: u8, anims: [4]Anim) !void {
    for (corners, anims) |c, anim| try mesh.list(.water).append(gpa, .{
        .pos = c,
        .uv = .{ 0, 0 },
        .info = (Info{ .tile = depth, .face = face, .sky = world_mod.skyOf(light), .lamp = world_mod.lampOf(light), .anim = anim }).pack(),
    });
}

// --- Tests ------------------------------------------------------------------------------

const testing = std.testing;

fn emptyWorld() !*World {
    const w = try World.create(testing.allocator);
    try w.computeLight();
    return w;
}

fn normalOf(v: []const Vertex) [3]f32 {
    const a = v[0].pos;
    const b = v[1].pos;
    const c = v[2].pos;
    const e1 = [3]f32{ b[0] - a[0], b[1] - a[1], b[2] - a[2] };
    const e2 = [3]f32{ c[0] - a[0], c[1] - a[1], c[2] - a[2] };
    return .{ e1[1] * e2[2] - e1[2] * e2[1], e1[2] * e2[0] - e1[0] * e2[2], e1[0] * e2[1] - e1[1] * e2[0] };
}

/// Every quad's two triangles (0 1 2, 0 2 3) face the way its face does.
fn expectWound(list: []const Vertex) !void {
    var q: usize = 0;
    while (q + 4 <= list.len) : (q += 4) {
        const face = Info.unpack(list[q].info).face;
        const n = face.normal();
        for ([2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |t| {
            const tri = [3]Vertex{ list[q + t[0]], list[q + t[1]], list[q + t[2]] };
            const got = normalOf(&tri);
            const d = got[0] * @as(f32, @floatFromInt(n[0])) + got[1] * @as(f32, @floatFromInt(n[1])) + got[2] * @as(f32, @floatFromInt(n[2]));
            try testing.expect(d > 0);
        }
    }
}

test "a lone block: six faces, wound to face out, lit and unshaded" {
    const w = try emptyWorld();
    defer w.destroy();
    _ = w.set(5, 30, 5, .sandstone_bricks);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    // Bricks are in the second strip.
    const bricks = m.items(.solid1);
    try testing.expectEqual(@as(usize, 24), bricks.len);
    try testing.expectEqual(@as(usize, 24), m.solidCount());
    try expectWound(bricks);
    var faces: u8 = 0;
    var q: usize = 0;
    while (q < 24) : (q += 4) {
        const i = Info.unpack(bricks[q].info);
        faces |= @as(u8, 1) << @intFromEnum(i.face);
        try testing.expectEqual(@as(u2, 0), i.ao);
        try testing.expectEqual(@intFromEnum(Block.sandstone_bricks.tile(i.face)), i.tile);
    }
    try testing.expectEqual(@as(u8, 63), faces);
    // Lit by the sky all round (under it, by what spreads in from the
    // sides, smoothed with the open air around).
    for (bricks) |v| try testing.expect(Info.unpack(v.info).sky >= 14);
    try testing.expectEqual(@as(u4, 14), world_mod.skyOf(w.lightAt(5, 29, 5)));
}

test "faces between blocks are hidden, and level faces alike are merged" {
    const w = try emptyWorld();
    defer w.destroy();
    // A row of four blocks in the air.
    for (0..4) |x| _ = w.set(@intCast(4 + x), 30, 4, .volcanic_rock);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    // Top, bottom, both long sides: one quad each; the two ends.
    const stone = m.items(.solid0);
    try testing.expectEqual(@as(usize, 6 * 4), stone.len);
    try expectWound(stone);
    // The long faces' s runs the 4 blocks (the texture unit repeats the
    // tile); t stays within stone's place in the strip, top to bottom.
    const lo = stripT(.volcanic_rock, 0);
    const hi = stripT(.volcanic_rock, 1);
    for (stone) |v| {
        const i = Info.unpack(v.info);
        if (i.face == .up) {
            try testing.expect(v.pos[0] == 4 or v.pos[0] == 8);
            try testing.expectEqual(v.pos[0], v.uv[0]);
        }
        try testing.expect(v.uv[1] == lo or v.uv[1] == hi);
        if (i.face == .south) try testing.expectEqual(if (v.pos[1] == 31) lo else hi, v.uv[1]);
    }
    try testing.expect(lo > @as(f32, @floatFromInt(@intFromEnum(blocks.Tile.volcanic_rock))) / 16 and hi < @as(f32, @floatFromInt(@intFromEnum(blocks.Tile.volcanic_rock) + 1)) / 16);
}

test "corners in nooks are shaded" {
    const w = try emptyWorld();
    defer w.destroy();
    // A floor (above the sea, which is darker), with a block standing on
    // it.
    for (0..16) |z| for (0..16) |x| {
        _ = w.set(@intCast(x), 30, @intCast(z), .volcanic_rock);
    };
    _ = w.set(8, 31, 8, .volcanic_rock);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    const solid = m.items(.solid0);
    try expectWound(solid);
    // The floor's top next to the block: the corners against it shaded.
    var shaded: u32 = 0;
    for (solid) |v| {
        const i = Info.unpack(v.info);
        // The floor's corners at the block's foot.
        if (i.face == .up and v.pos[1] == 31 and v.pos[0] == 8 and v.pos[2] == 8 and i.ao > 0) shaded += 1;
    }
    try testing.expect(shaded > 0);
    // The floor's top is still merged where it is open: far fewer quads
    // than faces.
    var tops: usize = 0;
    var q: usize = 0;
    while (q < solid.len) : (q += 4) {
        if (Info.unpack(solid[q].info).face == .up and solid[q].pos[1] == 31) tops += 1;
    }
    // Rows across the open floor merge: about a quad a row.
    try testing.expect(tops < 40);
}

test "water: a surface quad a block, lower than the block's top, with its depth" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    // Sand under two blocks of water, everywhere.
    for (0..world_mod.size_z) |z| for (0..world_mod.size_x) |x| {
        w.blocks[World.index(@intCast(x), 0, @intCast(z))] = .sand;
        w.blocks[World.index(@intCast(x), 1, @intCast(z))] = .water;
        w.blocks[World.index(@intCast(x), 2, @intCast(z))] = .water;
    };
    try w.computeLight();
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    // Only the surface: the chunk's edges are against water (or, at the
    // world's edge, the sea).
    try testing.expectEqual(@as(usize, 256 * 4), m.items(.water).len);
    try expectWound(m.items(.water));
    for (m.items(.water)) |v| {
        try testing.expectEqual(@as(f32, 2 + water_top), v.pos[1]);
        const i = Info.unpack(v.info);
        try testing.expectEqual(@as(u6, 2), i.tile);
        try testing.expectEqual(Anim.wave, i.anim);
    }
}

test "plants: fans of fronds, both ways round; glass: faces against air" {
    const w = try emptyWorld();
    defer w.destroy();
    _ = w.set(3, 20, 3, .red_flower);
    _ = w.set(6, 20, 6, .glass);
    _ = w.set(7, 20, 6, .glass);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    try testing.expectEqual(@as(usize, 0), m.solidCount());
    // Seven fronds, both ways round (the island's strip); 10 glass faces
    // (the building strip; none between the two panes).
    try testing.expectEqual(@as(usize, 14 * 4), m.items(.clear0).len);
    try testing.expectEqual(@as(usize, 10 * 4), m.items(.clear1).len);
    // Their tips sway; their feet are on the ground, in the block.
    var tips: u32 = 0;
    for (m.items(.clear0)) |v| {
        if (Info.unpack(v.info).anim == .plant) {
            try testing.expect(v.pos[1] > 20.4 and v.pos[1] < 21.1);
            tips += 1;
        } else try testing.expectEqual(@as(f32, 20), v.pos[1]);
        try testing.expect(v.pos[0] > 2.4 and v.pos[0] < 4.6 and v.pos[2] > 2.4 and v.pos[2] < 4.6);
    }
    try testing.expectEqual(@as(u32, 28), tips);
}

test "palms: a solid trunk facing out, and a crown of fronds reaching past its block" {
    const w = try emptyWorld();
    defer w.destroy();
    for (0..5) |y| _ = w.set(8, @intCast(20 + y), 8, .palm);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    try build(testing.allocator, w, 0, 0, &m);
    // Eight sides a block, the ends, and coconuts: solid, with the faces
    // looking up (drawn from anywhere above the chunk's bottom).
    const solid = m.items(.solid0);
    try testing.expect(solid.len >= (5 * 8 + 6 + 3 * 6) * 4);
    try expectWound(solid);
    const up = for (face_order, 0..) |f, k| {
        if (f == .up) break k;
    } else unreachable;
    try testing.expectEqual(@as(u32, @intCast(solid.len / 4)), m.face_quads[0][up]);
    // The trunk stays within its column.
    for (solid) |v| try testing.expect(v.pos[0] > 7.5 and v.pos[0] < 9.5 and v.pos[2] > 7.5 and v.pos[2] < 9.5);
    // The crown: see-through, round the top, reaching out past the block.
    var far: f32 = 0;
    for (m.items(.clear0)) |v| {
        try testing.expect(v.pos[1] > 22 and v.pos[1] < 27);
        far = @max(far, @abs(v.pos[0] - 8.5), @abs(v.pos[2] - 8.5));
    }
    try testing.expect(far > 2 and far < 3.5);
}

test "packing a vertex's information round trips, exactly as a float" {
    const i: Info = .{ .tile = 63, .ao = 3, .face = .north, .sky = 15, .lamp = 15, .anim = .wave };
    const f = i.pack();
    try testing.expect(f < 1 << 21);
    try testing.expectEqual(i, Info.unpack(f));
    try testing.expectEqual(Info{ .tile = 0, .face = .east, .sky = 0, .lamp = 0 }, Info.unpack(0));
}

test "the island's chunks: how many quads (to keep drawing it within budget)" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);
    var m: Mesh = .{};
    defer m.deinit(testing.allocator);
    var solid: usize = 0;
    var water: usize = 0;
    var clear: usize = 0;
    var most: usize = 0;
    for (0..world_mod.chunks_z) |cz| for (0..world_mod.chunks_x) |cx| {
        try build(testing.allocator, w, cx, cz, &m);
        solid += m.solidCount() / 4;
        water += m.items(.water).len / 4;
        clear += m.clearCount() / 4;
        most = @max(most, m.quads());
        try expectWound(m.items(.solid0));
        // Nothing built: the island's strip only.
        try testing.expectEqual(m.items(.solid0).len, m.solidCount());
    };
    std.log.info("island: {d} solid, {d} water, {d} see-through quads; at most {d} in a chunk", .{ solid, water, clear, most });
    // A chunk's meshes fit one index range (16384 quads).
    try testing.expect(most < 16384);
    try testing.expect(solid < 80000);
}
