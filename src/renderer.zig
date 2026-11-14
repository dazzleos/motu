//! Draws the world with the GPU, straight into the frame: the chunks'
//! meshes (each chunk's three in one buffer), the sea around the world,
//! the sky, the other players and the outline of the block picked.
//!
//! What is drawn, in order, and why:
//!
//! 1. Solid blocks, the nearest chunks first, with early Z: the GPU then
//!    skips shading what is behind what it has drawn, so the cost is about
//!    a pixel's shading once each. Then the other players (on the
//!    network), as block figures, one draw each.
//! 2. The sky, behind everything (only where nothing was drawn, again
//!    thanks to early Z): its gradient and sun are per pixel.
//! 3. Water and the sea, blended, the furthest first.
//! 4. Glass and plants, blended, the furthest first.
//! 5. The outline of the block picked.
//!
//! Chunks out of view, or past the fog, are not drawn at all. Every quad's
//! two triangles come from one shared index buffer (0 1 2, 0 2 3, then the
//! next four...), so a mesh is only its vertices; a chunk with more quads
//! than one index range holds is drawn in parts.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const mesher = @import("mesher.zig");
const math = @import("math.zig");
const textures = @import("textures.zig");
const player_mod = @import("player.zig");
const creatures = @import("creatures.zig");

const World = world_mod.World;
const Vertex = mesher.Vertex;
const V3 = math.V3;
const Mat4 = math.Mat4;

/// Quads one draw can have: their vertices are numbered within a 16-bit
/// index.
pub const max_quads = 16384;

/// Mipmap levels after the first: down to a pixel a tile (64 to 1).
const mip_levels = 6;

/// Chunks nearer than this (in blocks, along the ground) are drawn with
/// their bumps and detail (terrain_bump.zig, whose `bump_far` it is);
/// further off, the bumps are too small to see, and terrain.zig draws them
/// for less.
pub const near_distance = 32;

/// The detail texture: as the strips, but repeating both ways.
fn detailConfig() vc4.texture.Config {
    const layout = vc4.texture.mipmapLayout(textures.detail_size, textures.detail_size, detail_levels);
    return .{
        .offset = layout.base,
        .width = textures.detail_size,
        .height = textures.detail_size,
        .mag_filter = .linear,
        .min_filter = .nearest,
        .mip_levels = detail_levels,
        .mip_filter = .linear,
        .wrap_s = .repeat,
        .wrap_t = .repeat,
    };
}

const detail_levels = 6;

/// The ripple texture: as the detail texture.
fn rippleConfig() vc4.texture.Config {
    var c = detailConfig();
    c.offset = vc4.texture.mipmapLayout(textures.ripple_size, textures.ripple_size, detail_levels).base;
    c.width = textures.ripple_size;
    c.height = textures.ripple_size;
    return c;
}

/// How the strips are sampled: smoothly (bilinear) up close; further off,
/// from the mipmap levels, the nearest texel of the two nearest levels
/// mixed (so a texel of the next tile down never bleeds in); repeating
/// across the tile, and not down it.
fn stripConfig() vc4.texture.Config {
    const layout = vc4.texture.mipmapLayout(textures.strip_width, textures.strip_height, mip_levels);
    return .{
        .offset = layout.base,
        .width = textures.strip_width,
        .height = textures.strip_height,
        .mag_filter = .linear,
        .min_filter = .nearest,
        .mip_levels = mip_levels,
        .mip_filter = .linear,
        .wrap_s = .repeat,
        .wrap_t = .clamp,
    };
}

/// Where the fog starts, and how deep it is: past its far end nothing is
/// drawn, so this is how far one can see.
pub const fog_start: f32 = 55;
pub const fog_depth: f32 = 85;
pub const view_distance = fog_start + fog_depth;

/// The scene's uniforms (shaders/common.zig's `Scene`).
pub const Scene = extern struct {
    mvp: Mat4,
    camera: [4]f32,
    sun: [4]f32,
    sun_color: [4]f32,
    ambient: [4]f32,
    fog: [4]f32,
    misc: [4]f32,
    zenith: [4]f32,
};

const SkyUniforms = extern struct {
    turn: Mat4,
    sun: [4]f32,
    sun_color: [4]f32,
    moon: [4]f32,
    zenith: [4]f32,
    horizon: [4]f32,
    disc: [4]f32,
    corona: [4]f32,
};

/// How sharp the sun and moon discs' edges are; the sky shader scales the
/// vector to them by its square root (`body_scale`).
const sky_disc_sharpness = 1500.0;
/// The discs cover squared chord distances (2 * (1 - cos(angle))) below this.
const sky_disc_size = 0.0014;
/// The corona fades out at this squared chord distance.
const sky_corona_size = 1.0 / 33.0;

const LineUniforms = extern struct {
    mvp: Mat4,
    color: [4]f32,
};

// --- The time of day ------------------------------------------------------------------

/// The light and colours at a time of day.
pub const Environment = struct {
    /// Towards the sun.
    sun_dir: V3,
    /// How much daylight (0 at night, 1 by day).
    daylight: f32,
    /// How much of the sun's disc shows, and the moon's.
    sun_shows: f32,
    moon_shows: f32,
    sun_color: V3,
    ambient: V3,
    zenith: V3,
    horizon: V3,
    lamps: f32,

    fn mix3(a: V3, b: V3, t: f32) V3 {
        return a + (b - a) * math.splat(t);
    }

    fn smoothstep(lo: f32, hi: f32, x: f32) f32 {
        const t = std.math.clamp((x - lo) / (hi - lo), 0, 1);
        return t * t * (3 - 2 * t);
    }

    /// `t` from 0 to 1 through the day: 0.25 sunrise, 0.5 noon, 0.75
    /// sunset.
    pub fn at(t: f32) Environment {
        const angle = 2 * std.math.pi * (t - 0.25);
        const sun_dir = math.normalize(.{ @cos(angle), @sin(angle), 0.3 });
        const height = sun_dir[1];
        const daylight = smoothstep(-0.12, 0.22, height);
        // Reddest with the sun at the horizon.
        const low = @exp(-(height / 0.2) * (height / 0.2)) * smoothstep(-0.2, 0, height);
        const day_zenith = V3{ 0.3, 0.54, 0.92 };
        const day_horizon = V3{ 0.7, 0.83, 0.95 };
        const dusk_zenith = V3{ 0.27, 0.32, 0.6 };
        const dusk_horizon = V3{ 0.98, 0.56, 0.3 };
        const night_zenith = V3{ 0.008, 0.014, 0.045 };
        const night_horizon = V3{ 0.035, 0.05, 0.1 };
        const zenith = mix3(night_zenith, mix3(day_zenith, dusk_zenith, low * 0.7), daylight);
        const horizon = mix3(night_horizon, mix3(day_horizon, dusk_horizon, low), daylight);
        const sun_up = smoothstep(-0.04, 0.12, height);
        const sunlight = mix3(V3{ 0.64, 0.61, 0.54 }, V3{ 0.85, 0.48, 0.24 }, low) * math.splat(sun_up);
        const night = 1 - daylight;
        const moonlight = V3{ 0.15, 0.18, 0.3 } * math.splat(night);
        return .{
            .sun_dir = sun_dir,
            .daylight = daylight,
            .sun_shows = smoothstep(-0.1, 0.02, height),
            .moon_shows = smoothstep(-0.1, 0.02, -height),
            .sun_color = sunlight + moonlight,
            .ambient = mix3(V3{ 0.11, 0.13, 0.22 }, V3{ 0.4, 0.45, 0.55 }, daylight) + V3{ 0.05, 0.03, 0.0 } * math.splat(low),
            .zenith = zenith,
            .horizon = horizon,
            .lamps = 0.55 + 0.45 * night,
        };
    }

    /// Which way the light that shades faces comes from: the sun, or by
    /// night the moon.
    pub fn lightDir(e: Environment) V3 {
        return if (e.sun_dir[1] > -0.05) e.sun_dir else -e.sun_dir;
    }
};

// --- What is on the GPU -----------------------------------------------------------------

/// The chunks are drawn together, a square of `region_chunks` of them
/// across at a time (`regions`): fewer draws, each of more triangles,
/// which the Pi Zero to Pi 3's GPU draws faster (it goes over each draw
/// again in each 64 by 64 tile of the screen it covers).
pub const region_chunks = 1;
pub const region_size = world_mod.chunk_size * region_chunks;
pub const regions_x = world_mod.chunks_x / region_chunks;
pub const regions_z = world_mod.chunks_z / region_chunks;
pub const region_count = regions_x * regions_z;

/// The region chunk `i` is in.
pub fn regionOf(i: usize) usize {
    return (i / world_mod.chunks_x / region_chunks) * regions_x + (i % world_mod.chunks_x) / region_chunks;
}

/// A chunk's mesh, kept to make its region's buffer of: its sections one
/// after another (as a region's), its solid strips' faces by the way they
/// face.
const ChunkMesh = struct {
    verts: []Vertex = &.{},
    quads: [mesher.Section.count]u32 = @splat(0),
    face_quads: [blocks.Tile.strips][6]u32 = @splat(@splat(0)),
    min_y: f32 = std.math.inf(f32),
    max_y: f32 = -std.math.inf(f32),

    /// Where a section starts, in quads.
    fn start(c: ChunkMesh, s: mesher.Section) u32 {
        var n: u32 = 0;
        for (c.quads[0..@intFromEnum(s)]) |q| n += q;
        return n;
    }
};

/// What is drawn: a region's chunks' meshes in one buffer, each section's
/// together, and of each solid strip, the faces facing each way together.
const ChunkGpu = struct {
    bo: ?vc4.Bo = null,
    /// Quads in each of its meshes (one after another in `bo`, in the
    /// order of mesher.Section).
    quads: [mesher.Section.count]u32 = @splat(0),
    /// Of the solid quads, how many face each way (see mesher.face_order).
    face_quads: [blocks.Tile.strips][6]u32 = @splat(@splat(0)),
    /// How high its faces go, for culling.
    min_y: f32 = 0,
    max_y: f32 = 0,
    /// One of its chunks has changed since it was made.
    dirty: bool = false,

    /// Where a mesh starts in its buffer.
    fn offset(c: ChunkGpu, s: mesher.Section) u32 {
        var n: u32 = 0;
        for (c.quads[0..@intFromEnum(s)]) |q| n += q;
        return n * 4 * @sizeOf(Vertex);
    }

    /// The parts of a solid strip that can face the eye, as runs of quads
    /// (first, count) from the strip's start: a face is seen only from in
    /// front of it, so of the faces of a chunk the eye is east of, none
    /// facing west are.
    fn facing(c: ChunkGpu, strip: usize, corner: V3, eye: V3, runs: *[3][2]u32) []const [2]u32 {
        const size: f32 = region_size;
        // A little room for leaves swaying.
        const m = 0.25;
        var n: usize = 0;
        var at: u32 = 0;
        for (mesher.face_order, c.face_quads[strip]) |face, q| {
            const seen = switch (face) {
                .east => eye[0] > corner[0] - m,
                .west => eye[0] < corner[0] + size + m,
                .up => eye[1] > c.min_y,
                .down => eye[1] < c.max_y,
                .south => eye[2] > corner[2] - m,
                .north => eye[2] < corner[2] + size + m,
            };
            if (seen and q > 0) {
                if (n > 0 and runs[n - 1][0] + runs[n - 1][1] == at) {
                    runs[n - 1][1] += q;
                } else {
                    runs[n] = .{ at, q };
                    n += 1;
                }
            }
            at += q;
        }
        return runs[0..n];
    }
};

/// What `draw` needs to know of the moment.
pub const View = struct {
    camera: math.Camera,
    /// The viewport's width over its height.
    aspect: f32,
    /// Seconds, for things that move.
    time: f32,
    env: Environment,
    underwater: bool = false,
    /// Solid blocks lit per pixel from their normal maps, and water
    /// rippled.
    bump: bool = true,
    /// The block to outline.
    outline: ?world_mod.Pos = null,
    /// The other players.
    avatars: []const player_mod.Other = &.{},
    /// How far one sees, of `view_distance` (the fog nearer to match):
    /// less to draw.
    reach: f32 = 1,
};

/// What the last frame drew.
pub const Stats = struct {
    chunks: u32 = 0,
    draws: u32 = 0,
    triangles: u32 = 0,
    /// Of the draws, those with bumps and detail (the near chunks').
    detailed: u32 = 0,
};

pub fn Renderer(comptime Device: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        dev: Device,
        terrain: shader.Pipeline,
        terrain_bump: shader.Pipeline,
        terrain_blend: shader.Pipeline,
        water: shader.Pipeline,
        water_ripples: shader.Pipeline,
        sky: shader.Pipeline,
        line: shader.Pipeline,
        /// The tiles, a strip each (see textures.zig), with mipmaps: shaded
        /// for drawing without normal maps, their plain colours for
        /// drawing with them, and the normal maps.
        strips: [blocks.Tile.strips]vc4.Bo,
        albedo: [blocks.Tile.strips]vc4.Bo,
        normals: [blocks.Tile.strips]vc4.Bo,
        /// Fine detail drawn over near faces.
        detail: vc4.Bo,
        /// Ripples on water.
        ripples: vc4.Bo,
        indices: vc4.Bo,
        sea: vc4.Bo,
        sea_quads: u32,
        sea_patches: [sea_patch_count]SeaPatch,
        dome: vc4.Bo,
        dome_quads: u32,
        cube_lines: vc4.Bo,
        /// The other players' figures, one for each colour.
        avatars: vc4.Bo,
        /// Double-buffered vertices for birds and fish (so a pipelined
        /// frame in flight on the GPU is not overwritten).
        creatures_bo: [2]vc4.Bo,
        creatures_frame: u1 = 0,
        creatures: creatures.Creatures = .{},
        world: ?*const World = null,
        chunks: [world_mod.chunk_count]ChunkMesh = @splat(.{}),
        regions: [region_count]ChunkGpu = @splat(.{}),
        mesh: mesher.Mesh = .{},
        stats: Stats = .{},

        const world_layout: []const shader.pipeline.VertexField = &.{
            .{ .location = 0, .offset = @offsetOf(Vertex, "pos") },
            .{ .location = 1, .offset = @offsetOf(Vertex, "uv") },
            .{ .location = 2, .offset = @offsetOf(Vertex, "info") },
        };
        const pos_layout: []const shader.pipeline.VertexField = &.{.{ .location = 0, .offset = 0 }};

        pub fn init(gpa: std.mem.Allocator, dev: Device) !*Self {
            const r = try gpa.create(Self);
            errdefer gpa.destroy(r);
            const prog = shader.Program.decode;
            var terrain = try shader.Pipeline.init(gpa, dev, prog(@embedFile("terrain.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .back, .early_z = true });
            errdefer terrain.deinit(dev);
            var terrain_bump = try shader.Pipeline.init(gpa, dev, prog(@embedFile("terrain_bump.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .back, .early_z = true });
            errdefer terrain_bump.deinit(dev);
            var terrain_blend = try shader.Pipeline.init(gpa, dev, prog(@embedFile("terrain_blend.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .back, .early_z = true });
            errdefer terrain_blend.deinit(dev);
            var water = try shader.Pipeline.init(gpa, dev, prog(@embedFile("water.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .none, .early_z = true });
            errdefer water.deinit(dev);
            var water_ripples = try shader.Pipeline.init(gpa, dev, prog(@embedFile("water_ripples.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .none, .early_z = true });
            errdefer water_ripples.deinit(dev);
            var sky = try shader.Pipeline.init(gpa, dev, prog(@embedFile("sky.shader")) catch unreachable, .{ .vertex_stride = 12, .attributes = pos_layout, .cull = .none, .early_z = true });
            errdefer sky.deinit(dev);
            var line = try shader.Pipeline.init(gpa, dev, prog(@embedFile("line.shader")) catch unreachable, .{ .vertex_stride = 12, .attributes = pos_layout, .primitive = .lines, .early_z = true });
            errdefer line.deinit(dev);

            // The tiles: shaded, plain and normal maps (see `strips`).
            const layout = vc4.texture.mipmapLayout(textures.strip_width, textures.strip_height, mip_levels);
            var bos: [3 * blocks.Tile.strips]vc4.Bo = undefined;
            var made: usize = 0;
            errdefer for (bos[0..made]) |bo| dev.destroyBo(bo);
            for (&bos) |*bo| {
                bo.* = try dev.createBo(layout.size);
                made += 1;
            }
            const detail_layout = vc4.texture.mipmapLayout(textures.detail_size, textures.detail_size, detail_levels);
            const detail = try dev.createBo(detail_layout.size);
            errdefer dev.destroyBo(detail);
            {
                var fine: [textures.detail_size * textures.detail_size]u32 = undefined;
                textures.detail(&fine);
                try vc4.texture.uploadMipmaps(gpa, detail.map, &fine, textures.detail_size, textures.detail_size, detail_levels, .colour);
            }
            const ripples = try dev.createBo(vc4.texture.mipmapLayout(textures.ripple_size, textures.ripple_size, detail_levels).size);
            errdefer dev.destroyBo(ripples);
            {
                var px: [textures.ripple_size * textures.ripple_size]u32 = undefined;
                textures.ripples(&px);
                try vc4.texture.uploadMipmaps(gpa, ripples.map, &px, textures.ripple_size, textures.ripple_size, detail_levels, .normal);
            }
            const px = try gpa.create([3][textures.strip_width * textures.strip_height]u32);
            defer gpa.destroy(px);
            for (0..blocks.Tile.strips) |i| {
                textures.allStrips(@intCast(i), &px[0], &px[1], &px[2]);
                for (0..3) |set| {
                    const bo = bos[set * blocks.Tile.strips + i];
                    try vc4.texture.uploadMipmaps(gpa, bo.map, &px[set], textures.strip_width, textures.strip_height, mip_levels, if (set == 2) .normal else .colour);
                }
            }

            // Every quad's triangles.
            const indices = try dev.createBo(max_quads * 6 * 2);
            errdefer dev.destroyBo(indices);
            const idx = std.mem.bytesAsSlice(u16, indices.map[0 .. max_quads * 12]);
            for (0..max_quads) |q| {
                const v: u16 = @intCast(q * 4);
                idx[q * 6 ..][0..6].* = .{ v, v + 1, v + 2, v, v + 2, v + 3 };
            }

            var sea_patches: [sea_patch_count]SeaPatch = undefined;
            const sea_verts = try seaRingPatches(gpa, &sea_patches);
            defer gpa.free(sea_verts);
            const sea = try dev.createBo(@intCast(sea_verts.len * @sizeOf(Vertex)));
            errdefer dev.destroyBo(sea);
            @memcpy(sea.map[0 .. sea_verts.len * @sizeOf(Vertex)], std.mem.sliceAsBytes(sea_verts));

            var dome_buf: [dome_rings * dome_segments * 4][3]f32 = undefined;
            const dome_verts = skyDome(&dome_buf);
            const dome = try dev.createBo(@intCast(dome_verts.len * 12));
            errdefer dev.destroyBo(dome);
            @memcpy(dome.map[0 .. dome_verts.len * 12], std.mem.sliceAsBytes(dome_verts));

            const edges = cubeEdges();
            const cube_lines = try dev.createBo(edges.len * 12);
            errdefer dev.destroyBo(cube_lines);
            @memcpy(cube_lines.map[0 .. edges.len * 12], std.mem.sliceAsBytes(&edges));

            const figures = avatarMeshes();
            const avatars = try dev.createBo(@sizeOf(@TypeOf(figures)));
            @memcpy(avatars.map[0..@sizeOf(@TypeOf(figures))], std.mem.asBytes(&figures));
            const creatures_bytes: u32 = creatures.max_quads * 4 * @sizeOf(Vertex);
            const creatures_bo0 = try dev.createBo(creatures_bytes);
            errdefer dev.destroyBo(creatures_bo0);
            const creatures_bo1 = try dev.createBo(creatures_bytes);
            errdefer dev.destroyBo(creatures_bo1);

            r.* = .{
                .gpa = gpa,
                .dev = dev,
                .terrain = terrain,
                .terrain_bump = terrain_bump,
                .terrain_blend = terrain_blend,
                .water = water,
                .water_ripples = water_ripples,
                .sky = sky,
                .line = line,
                .strips = bos[0..blocks.Tile.strips].*,
                .albedo = bos[blocks.Tile.strips..][0..blocks.Tile.strips].*,
                .normals = bos[2 * blocks.Tile.strips ..][0..blocks.Tile.strips].*,
                .detail = detail,
                .ripples = ripples,
                .indices = indices,
                .sea = sea,
                .sea_quads = @intCast(sea_verts.len / 4),
                .sea_patches = sea_patches,
                .dome = dome,
                .dome_quads = @intCast(dome_verts.len / 4),
                .cube_lines = cube_lines,
                .avatars = avatars,
                .creatures_bo = .{ creatures_bo0, creatures_bo1 },
            };
            return r;
        }

        pub fn deinit(r: *Self) void {
            for (&r.chunks) |*c| r.gpa.free(c.verts);
            for (&r.regions) |*g| if (g.bo) |bo| r.dev.destroyBo(bo);
            for ([_][blocks.Tile.strips]vc4.Bo{ r.strips, r.albedo, r.normals }) |set| for (set) |bo| r.dev.destroyBo(bo);
            for ([_]vc4.Bo{ r.indices, r.sea, r.dome, r.cube_lines, r.avatars, r.detail, r.ripples, r.creatures_bo[0], r.creatures_bo[1] }) |bo| r.dev.destroyBo(bo);
            r.terrain.deinit(r.dev);
            r.terrain_bump.deinit(r.dev);
            r.terrain_blend.deinit(r.dev);
            r.water.deinit(r.dev);
            r.water_ripples.deinit(r.dev);
            r.sky.deinit(r.dev);
            r.line.deinit(r.dev);
            r.mesh.deinit(r.gpa);
            r.gpa.destroy(r);
        }

        /// Meshes chunks the world marked as changed: at most `limit`, the
        /// nearest to `near` first (so what is close catches up first).
        /// Returns how many are left.
        pub fn update(r: *Self, w: *World, near: V3, limit: usize) !usize {
            r.world = w;
            var done: usize = 0;
            while (done < limit) : (done += 1) {
                var best: ?usize = null;
                var best_d: f32 = std.math.inf(f32);
                var it = w.dirty.iterator(.{});
                while (it.next()) |i| {
                    const d = chunkDistance(i, near);
                    if (d < best_d) {
                        best_d = d;
                        best = i;
                    }
                }
                const i = best orelse break;
                w.dirty.unset(i);
                // Not meshed (no memory for it): shown as it was, and
                // meshed again later.
                r.meshChunk(w, i) catch |err| {
                    w.dirty.set(i);
                    return err;
                };
            }
            // The regions of those meshed, made again (one without memory
            // for it is shown as it was, and made again later).
            for (&r.regions, 0..) |*g, ri| if (g.dirty) try r.makeRegion(ri);
            return w.dirty.count();
        }

        fn meshChunk(r: *Self, w: *const World, i: usize) !void {
            const cx = i % world_mod.chunks_x;
            const cz = i / world_mod.chunks_x;
            try mesher.build(r.gpa, w, cx, cz, &r.mesh);
            const m = &r.mesh;
            const verts = try r.gpa.alloc(Vertex, m.quads() * 4);
            var c: ChunkMesh = .{ .verts = verts, .face_quads = m.face_quads };
            var at: usize = 0;
            for (m.lists, &c.quads) |l, *q| {
                const list = l.items;
                q.* = @intCast(list.len / 4);
                @memcpy(verts[at..][0..list.len], list);
                at += list.len;
                for (list) |v| {
                    c.min_y = @min(c.min_y, v.pos[1]);
                    c.max_y = @max(c.max_y, v.pos[1]);
                }
            }
            r.gpa.free(r.chunks[i].verts);
            r.chunks[i] = c;
            r.regions[regionOf(i)].dirty = true;
        }

        /// Makes region `ri`'s buffer from its chunks' meshes: a new one
        /// (the old one may still be in a frame the GPU is drawing: it keeps
        /// it until then), made before the old one goes, which stays if
        /// there is no memory for it.
        fn makeRegion(r: *Self, ri: usize) !void {
            const rx = ri % regions_x;
            const rz = ri / regions_x;
            var members: [region_chunks * region_chunks]*const ChunkMesh = undefined;
            for (0..region_chunks) |dz| for (0..region_chunks) |dx| {
                members[dz * region_chunks + dx] = &r.chunks[(rz * region_chunks + dz) * world_mod.chunks_x + rx * region_chunks + dx];
            };
            var g: ChunkGpu = .{ .min_y = std.math.inf(f32), .max_y = -std.math.inf(f32) };
            for (members) |c| {
                for (&g.quads, c.quads) |*q, n| q.* += n;
                for (&g.face_quads, c.face_quads) |*gs, cs| for (gs, cs) |*q, n| {
                    q.* += n;
                };
                g.min_y = @min(g.min_y, c.min_y);
                g.max_y = @max(g.max_y, c.max_y);
            }
            var total: u32 = 0;
            for (g.quads) |q| total += q;
            const bo = if (total == 0) null else try r.dev.createBo(total * 4 * @sizeOf(Vertex));
            if (r.regions[ri].bo) |old| r.dev.destroyBo(old);
            r.regions[ri] = .{};
            const new = bo orelse return;
            const out = std.mem.bytesAsSlice(Vertex, new.map[0 .. total * 4 * @sizeOf(Vertex)]);
            var at: usize = 0;
            for (0..mesher.Section.count) |si| {
                const sec: mesher.Section = @enumFromInt(si);
                if (si < blocks.Tile.strips) {
                    // A solid strip: by the way its faces face, each across
                    // the chunks.
                    for (0..6) |face| for (members) |c| {
                        var first = c.start(sec);
                        for (c.face_quads[si][0..face]) |q| first += q;
                        const n = c.face_quads[si][face] * 4;
                        @memcpy(out[at..][0..n], c.verts[first * 4 ..][0..n]);
                        at += n;
                    };
                } else for (members) |c| {
                    const n = c.quads[si] * 4;
                    @memcpy(out[at..][0..n], c.verts[c.start(sec) * 4 ..][0..n]);
                    at += n;
                }
            }
            g.bo = new;
            // Room for swaying and waves.
            g.min_y -= 0.5;
            g.max_y += 0.5;
            r.regions[ri] = g;
        }

        /// Records the scene into `sink` (a `FrameSink`, or the preview's),
        /// filling `viewport`.
        pub fn draw(r: *Self, sink: anytype, viewport: vc4.render.Viewport, scissor: ?vc4.render.Viewport, v: View) !void {
            r.stats = .{};
            const cam = v.camera;
            const proj = cam.projection(v.aspect);
            const vp = math.mul(proj, cam.view());
            const env = v.env;
            const light = env.lightDir();
            const fog: V3 = if (v.underwater) V3{ 0.07, 0.34, 0.44 } * math.splat(0.25 + 0.75 * env.daylight) else env.horizon;
            const start: f32 = if (v.underwater) 0 else fog_start * v.reach;
            const depth: f32 = if (v.underwater) 26 else fog_depth * v.reach;
            const scene: Scene = .{
                .mvp = vp,
                .camera = .{ cam.eye[0], cam.eye[1], cam.eye[2], @mod(v.time, 1000) },
                .sun = .{ light[0], light[1], light[2], env.daylight },
                .sun_color = .{ env.sun_color[0], env.sun_color[1], env.sun_color[2], 0 },
                .ambient = .{ env.ambient[0], env.ambient[1], env.ambient[2], env.lamps },
                .fog = .{ fog[0], fog[1], fog[2], 1 / depth },
                .misc = .{ start, 1, 0.09, 0 },
                .zenith = .{ env.zenith[0], env.zenith[1], env.zenith[2], 0 },
            };
            const bytes = std.mem.asBytes(&scene);
            r.terrain.setUniforms(bytes);
            r.terrain_bump.setUniforms(bytes);
            r.terrain_blend.setUniforms(bytes);
            r.water.setUniforms(bytes);
            r.water_ripples.setUniforms(bytes);

            // The regions in view, nearest first.
            const frustum = math.Frustum.of(vp);
            var order: [region_count]struct { i: u8, d: f32 } = undefined;
            var n: usize = 0;
            for (r.regions, 0..) |c, i| {
                if (c.bo == null) continue;
                const corner = regionCorner(i);
                const d = regionDistance(i, cam.eye);
                if (d > depth + start + 12) continue;
                if (!frustum.sees(.{ corner[0], c.min_y, corner[2] }, .{ corner[0] + region_size, c.max_y, corner[2] + region_size })) continue;
                order[n] = .{ .i = @intCast(i), .d = d };
                n += 1;
            }
            const visible = order[0..n];
            std.mem.sort(@TypeOf(order[0]), visible, {}, struct {
                fn less(_: void, a: @TypeOf(order[0]), b: @TypeOf(order[0])) bool {
                    return a.d < b.d;
                }
            }.less);
            // The chunks in them.
            r.stats.chunks = @intCast(n * region_chunks * region_chunks);
            var tex: [blocks.Tile.strips]vc4.render.Texture = undefined;
            for (&tex, r.strips) |*t, bo| t.* = .{ .handle = bo.handle, .config = stripConfig() };
            var plain: [blocks.Tile.strips]vc4.render.Texture = undefined;
            for (&plain, r.albedo) |*t, bo| t.* = .{ .handle = bo.handle, .config = stripConfig() };
            var normal: [blocks.Tile.strips]vc4.render.Texture = undefined;
            for (&normal, r.normals) |*t, bo| t.* = .{ .handle = bo.handle, .config = stripConfig() };
            const fine: vc4.render.Texture = .{ .handle = r.detail.handle, .config = detailConfig() };
            const target: Target(@TypeOf(sink)) = .{ .sink = sink, .viewport = viewport, .scissor = scissor, .indices = r.indices.handle, .stats = &r.stats };

            // 1. Solid blocks, near to far.
            for (visible) |o| {
                const c = r.regions[o.i];
                const corner = regionCorner(o.i);
                const near = o.d < near_distance;
                for (0..blocks.Tile.strips) |k| {
                    const sec = mesher.Section.solid(@intCast(k));
                    var runs: [3][2]u32 = undefined;
                    for (c.facing(k, corner, cam.eye, &runs)) |run| {
                        const offset = c.offset(sec) + run[0] * 4 * @sizeOf(Vertex);
                        if (!v.bump) {
                            try target.quads(&r.terrain, c.bo.?.handle, offset, run[1], .{ tex[k], null, null });
                        } else if (near) {
                            try target.quads(&r.terrain_bump, c.bo.?.handle, offset, run[1], .{ plain[k], normal[k], fine });
                            r.stats.detailed += 1;
                        } else {
                            try target.quads(&r.terrain, c.bo.?.handle, offset, run[1], .{ plain[k], null, null });
                        }
                    }
                }
            }
            // The other players: each its figure, turned and moved to them
            // (with the eye and the sun turned into its frame, for the fog
            // and the light).
            const figure_strip = blocks.Tile.red.strip();
            for (v.avatars) |o| {
                if (math.length(o.pos - cam.eye) > depth + start) continue;
                if (!frustum.sees(o.pos - V3{ 1, 0, 1 }, o.pos + V3{ 1, 2, 1 })) continue;
                const turn = math.rotationY(o.yaw);
                var at = scene;
                at.mvp = math.mul(vp, math.mul(math.translation(o.pos), math.rotationY(-o.yaw)));
                const eye = math.transform(turn, cam.eye - o.pos);
                at.camera = .{ eye[0], eye[1], eye[2], scene.camera[3] };
                const sun = math.transform(turn, light);
                at.sun = .{ sun[0], sun[1], sun[2], scene.sun[3] };
                r.terrain.setUniforms(std.mem.asBytes(&at));
                const offset = @as(u32, o.colour) * avatar_quads * 4 * @sizeOf(Vertex);
                try target.quads(&r.terrain, r.avatars.handle, offset, avatar_quads, .{ if (v.bump) plain[figure_strip] else tex[figure_strip], null, null });
            }
            if (v.avatars.len > 0) r.terrain.setUniforms(bytes);
            if (r.world) |w| {
                r.creatures.sync(w, v.time);
                const cbo = r.creatures_bo[r.creatures_frame];
                r.creatures_frame ^= 1;
                const cverts = std.mem.bytesAsSlice(Vertex, cbo.map[0 .. creatures.max_quads * 4 * @sizeOf(Vertex)]);
                const cquads = r.creatures.buildMesh(w, &frustum, cam.eye, depth + start + 12, cverts);
                if (cquads > 0) {
                    try target.quads(&r.terrain, cbo.handle, 0, cquads, .{ if (v.bump) plain[2] else tex[2], null, null });
                }
            }
            // 2. The sky.
            const env_sun = env.sun_dir;
            var sky: SkyUniforms = .{
                .turn = math.mul(proj, cam.rotation()),
                .sun = .{ env_sun[0], env_sun[1], env_sun[2], env.sun_shows },
                .sun_color = .{ env.sun_color[0] + 0.3 * env.sun_shows, env.sun_color[1] + 0.25 * env.sun_shows, env.sun_color[2] + 0.15 * env.sun_shows, 0 },
                .moon = .{ -env_sun[0], -env_sun[1], -env_sun[2], env.moon_shows },
                .zenith = .{ env.zenith[0], env.zenith[1], env.zenith[2], 0 },
                .horizon = .{ fog[0], fog[1], fog[2], 0 },
                .disc = .{ 0, 0, 0, sky_disc_size * sky_disc_sharpness },
                .corona = .{ 0, 0, 0, 1.0 / (sky_corona_size * sky_disc_sharpness) },
            };
            // The disc is the sun's light, three times over, or the moon's
            // pale grey; the corona is half the sun's light. Premultiplied
            // here by how much of each shows, so the shader adds them as is.
            for (0..3) |k| {
                const moon_grey: f32 = if (k == 2) 0.855 else 0.9;
                sky.disc[k] = sky.sun_color[k] * 3 * env.sun_shows + moon_grey * env.moon_shows;
                sky.corona[k] = sky.sun_color[k] * 0.5 * env.sun_shows;
            }
            r.sky.setUniforms(std.mem.asBytes(&sky));
            try target.quads(&r.sky, r.dome.handle, 0, r.dome_quads, .{ null, null, null });
            // 3. Water, far to near; the sea around the world first (it is
            // furthest), culled in 64x64 patches.
            const water = if (v.bump) &r.water_ripples else &r.water;
            const ripple_one: ?vc4.render.Texture = if (v.bump) .{ .handle = r.ripples.handle, .config = rippleConfig() } else null;
            const ripple_tex: [3]?vc4.render.Texture = .{ ripple_one, ripple_one, null };
            const sea_y: f32 = world_mod.sea_level - 1 + mesher.water_top;
            const max_sea_d = depth + start + 16;
            var sea_run_first: u32 = 0;
            var sea_run_count: u32 = 0;
            for (r.sea_patches) |sp| {
                const dx = @max(@max(sp.x0 - cam.eye[0], cam.eye[0] - (sp.x0 + sea_patch_size)), 0);
                const dz = @max(@max(sp.z0 - cam.eye[2], cam.eye[2] - (sp.z0 + sea_patch_size)), 0);
                const in_view = dx * dx + dz * dz <= max_sea_d * max_sea_d and
                    frustum.sees(.{ sp.x0, sea_y - 0.5, sp.z0 }, .{ sp.x0 + sea_patch_size, sea_y + 0.5, sp.z0 + sea_patch_size });
                if (in_view) {
                    if (sea_run_count > 0 and sea_run_first + sea_run_count == sp.first_quad) {
                        sea_run_count += sp.quad_count;
                    } else {
                        if (sea_run_count > 0) {
                            try target.quads(water, r.sea.handle, sea_run_first * 4 * @sizeOf(Vertex), sea_run_count, ripple_tex);
                        }
                        sea_run_first = sp.first_quad;
                        sea_run_count = sp.quad_count;
                    }
                }
            }
            if (sea_run_count > 0) {
                try target.quads(water, r.sea.handle, sea_run_first * 4 * @sizeOf(Vertex), sea_run_count, ripple_tex);
            }
            var k = visible.len;
            while (k > 0) {
                k -= 1;
                const c = r.regions[visible[k].i];
                try target.quads(water, c.bo.?.handle, c.offset(.water), c.quads[@intFromEnum(mesher.Section.water)], ripple_tex);
            }
            // 4. Glass and plants, far to near.
            k = visible.len;
            while (k > 0) {
                k -= 1;
                const c = r.regions[visible[k].i];
                for (0..blocks.Tile.strips) |sk| {
                    const sec = mesher.Section.clear(@intCast(sk));
                    try target.quads(&r.terrain_blend, c.bo.?.handle, c.offset(sec), c.quads[@intFromEnum(sec)], .{ tex[sk], null, null });
                }
            }
            // 5. The outline.
            if (v.outline) |cell| {
                const at = V3{ @floatFromInt(cell[0]), @floatFromInt(cell[1]), @floatFromInt(cell[2]) };
                const lu: LineUniforms = .{ .mvp = math.mul(vp, math.translation(at)), .color = .{ 0.05, 0.05, 0.05, 1 } };
                r.line.setUniforms(std.mem.asBytes(&lu));
                if (sink.hasRoom(64)) {
                    try sink.draw(&r.line, .{ .vertices = r.cube_lines.handle, .count = 24, .viewport = viewport, .scissor = scissor });
                    r.stats.draws += 1;
                }
            }
        }
    };
}

/// Where the GPU's draws go: into a frame.
pub const FrameSink = struct {
    frame: *vc4.render.Frame,

    pub fn hasRoom(s: FrameSink, uniform_words: usize) bool {
        return s.frame.hasRoom(uniform_words);
    }

    pub fn draw(s: FrameSink, p: *shader.Pipeline, d: shader.Pipeline.Draw) !void {
        try p.draw(s.frame, d);
    }
};

/// Where draws go, and counting them.
fn Target(comptime Sink: type) type {
    return struct {
        sink: Sink,
        viewport: vc4.render.Viewport,
        scissor: ?vc4.render.Viewport,
        indices: u32,
        stats: *Stats,

        /// Draws `count` quads from `offset` in a buffer, in parts of up to
        /// `max_quads`. A frame that is full gets no more (it cannot be
        /// rendered and started again without losing its depth).
        fn quads(t: @This(), p: *shader.Pipeline, handle: u32, offset: u32, count: u32, tex: [3]?vc4.render.Texture) !void {
            var done: u32 = 0;
            while (done < count) {
                const n: u32 = @min(count - done, max_quads);
                if (!t.sink.hasRoom(256)) return;
                try t.sink.draw(p, .{
                    .vertices = handle,
                    .vertex_offset = offset + done * 4 * @sizeOf(Vertex),
                    .count = n * 6,
                    .indices = .{ .handle = t.indices, .offset = 0, .max_index = n * 4 - 1 },
                    .texture = tex[0],
                    .texture1 = tex[1],
                    .texture2 = tex[2],
                    .viewport = t.viewport,
                    .scissor = t.scissor,
                });
                t.stats.draws += 1;
                t.stats.triangles += n * 2;
                done += n;
            }
        }
    };
}

// --- The other players ----------------------------------------------------------------

/// The colours players are told apart by (their bodies'), by id.
const avatar_colours = [player_mod.colours]blocks.Tile{ .red, .green, .yellow, .purple, .orange, .cyan, .pink, .black };
/// Quads in a figure: legs, body and head, six faces each.
const avatar_quads = 18;

const AvatarMeshes = [player_mod.colours][avatar_quads * 4]Vertex;

/// The figures, one for each colour: standing on the origin, facing north
/// (-z) as a player with no yaw does; legs, the body in the colour, and a
/// head with a face on its front. Their tiles are all in one strip, so each
/// is one draw; lit as in the open.
fn avatarMeshes() AvatarMeshes {
    var out: AvatarMeshes = undefined;
    for (&out, avatar_colours) |*mesh, colour| {
        var n: usize = 0;
        const boxes = [_]struct { min: V3, max: V3, tile: blocks.Tile, front: blocks.Tile }{
            .{ .min = .{ -0.2, 0, -0.12 }, .max = .{ 0.2, 0.75, 0.12 }, .tile = .blue, .front = .blue },
            .{ .min = .{ -0.26, 0.75, -0.15 }, .max = .{ 0.26, 1.4, 0.15 }, .tile = colour, .front = colour },
            .{ .min = .{ -0.22, 1.4, -0.22 }, .max = .{ 0.22, 1.84, 0.22 }, .tile = .white, .front = .black },
        };
        for (boxes) |b| for (blocks.Face.all) |face| {
            const tile = if (face == .north) b.front else b.tile;
            for (boxFace(face, b.min, b.max)) |c| {
                mesh[n] = .{
                    .pos = c,
                    .uv = boxUv(face, b.min, b.max, c, tile),
                    .info = (mesher.Info{ .tile = @intFromEnum(tile), .face = face, .sky = 15, .lamp = 0 }).pack(),
                };
                n += 1;
            }
        };
    }
    return out;
}

/// A box's face `face`: its corners, wound counter-clockwise seen from
/// outside (as mesher.zig's faces).
fn boxFace(face: blocks.Face, min_v: V3, max_v: V3) [4][3]f32 {
    const min: [3]f32 = min_v;
    const max: [3]f32 = max_v;
    const a: usize = @intFromEnum(face) / 2;
    const b = (a + 1) % 3;
    const c = (a + 2) % 3;
    const plane = if (@intFromEnum(face) % 2 == 0) max[a] else min[a];
    const bc = [4][2]f32{ .{ min[b], min[c] }, .{ max[b], min[c] }, .{ max[b], max[c] }, .{ min[b], max[c] } };
    var out: [4][3]f32 = undefined;
    for (bc, 0..) |q, k| {
        out[k][a] = plane;
        out[k][b] = q[0];
        out[k][c] = q[1];
    }
    // e_b × e_c is +e_a: a face looking the other way goes round the other
    // way.
    if (@intFromEnum(face) % 2 == 1) return .{ out[0], out[3], out[2], out[1] };
    return out;
}

/// Where corner `c` of a box's face is on its tile: across in blocks, and
/// down the tile from the face's top (or, on top and below, its north edge)
/// to its bottom.
fn boxUv(face: blocks.Face, min: V3, max: V3, c: [3]f32, tile: blocks.Tile) [2]f32 {
    return switch (face) {
        .up, .down => .{ c[0] - min[0], mesher.stripT(tile, (c[2] - min[2]) / (max[2] - min[2])) },
        .east, .west => .{ c[2] - min[2], mesher.stripT(tile, (max[1] - c[1]) / (max[1] - min[1])) },
        .south, .north => .{ c[0] - min[0], mesher.stripT(tile, (max[1] - c[1]) / (max[1] - min[1])) },
    };
}

/// A chunk's corner nearest the origin (at y = 0).
fn chunkCorner(i: usize) V3 {
    return .{
        @floatFromInt(i % world_mod.chunks_x * world_mod.chunk_size),
        0,
        @floatFromInt(i / world_mod.chunks_x * world_mod.chunk_size),
    };
}

/// A region's corner nearest the origin (at y = 0).
fn regionCorner(ri: usize) V3 {
    return .{
        @floatFromInt(ri % regions_x * region_size),
        0,
        @floatFromInt(ri / regions_x * region_size),
    };
}

/// How far `p` is from a region, across.
fn regionDistance(ri: usize, p: V3) f32 {
    const corner = regionCorner(ri);
    const half: f32 = region_size / 2;
    const dx = @max(@abs(p[0] - (corner[0] + half)) - half, 0);
    const dz = @max(@abs(p[2] - (corner[2] + half)) - half, 0);
    return @sqrt(dx * dx + dz * dz);
}

fn chunkDistance(i: usize, p: V3) f32 {
    const cx: f32 = @floatFromInt(i % world_mod.chunks_x * world_mod.chunk_size + world_mod.chunk_size / 2);
    const cz: f32 = @floatFromInt(i / world_mod.chunks_x * world_mod.chunk_size + world_mod.chunk_size / 2);
    const dx = @max(@abs(p[0] - cx) - world_mod.chunk_size / 2, 0);
    const dz = @max(@abs(p[2] - cz) - world_mod.chunk_size / 2, 0);
    return @sqrt(dx * dx + dz * dz);
}

// --- Fixed geometry ----------------------------------------------------------------------

const sea_patch_size = 64;
const sea_grid = 7;
/// Of the 7x7 grid of 64x64 patches across -160..288, the middle one
/// (32..96) is wholly inside the island.
const sea_patch_count = sea_grid * sea_grid - 1;

const SeaPatch = struct {
    x0: f32,
    z0: f32,
    first_quad: u32,
    quad_count: u32,
};

/// The sea around the world, grouped into 64x64 patches for culling: quads
/// a block across for 4 blocks out (matching the island's edge), 2 across to
/// 16 out (where the waves die down), then 4 across to 48 out, then 16
/// across, far enough to reach the fog from anywhere in the world.
fn seaRingPatches(gpa: std.mem.Allocator, patches: *[sea_patch_count]SeaPatch) ![]Vertex {
    var out: std.ArrayList(Vertex) = .empty;
    errdefer out.deinit(gpa);
    const y = world_mod.sea_level - 1 + mesher.water_top;
    const s = world_mod.size_x;
    const wave = (mesher.Info{ .tile = 63, .face = .up, .sky = 15, .lamp = 0, .anim = .wave }).pack();
    const flat = (mesher.Info{ .tile = 63, .face = .up, .sky = 15, .lamp = 0 }).pack();
    const add = struct {
        fn quad(list: *std.ArrayList(Vertex), g: std.mem.Allocator, x0: f32, z0: f32, size: f32, yy: f32, inf: f32) !void {
            for ([4][2]f32{ .{ x0, z0 + size }, .{ x0 + size, z0 + size }, .{ x0 + size, z0 }, .{ x0, z0 } }) |c|
                try list.append(g, .{ .pos = .{ c[0], yy, c[1] }, .uv = .{ 0, 0 }, .info = inf });
        }
    }.quad;
    const Ring = struct { inner: i32, far: i32, step: i32, info: f32 };
    const rings = [_]Ring{
        .{ .inner = 0, .far = 4, .step = 1, .info = wave },
        .{ .inner = 4, .far = 16, .step = 2, .info = wave },
        .{ .inner = 16, .far = 48, .step = 4, .info = flat },
        .{ .inner = 48, .far = 160, .step = 16, .info = flat },
    };
    var pi: usize = 0;
    for (0..sea_grid) |gz| for (0..sea_grid) |gx| {
        const px0: i32 = -160 + @as(i32, @intCast(gx)) * sea_patch_size;
        const pz0: i32 = -160 + @as(i32, @intCast(gz)) * sea_patch_size;
        const first: u32 = @intCast(out.items.len / 4);
        for (rings) |ring| {
            var z: i32 = @max(pz0, -ring.far);
            const z_end: i32 = @min(pz0 + sea_patch_size, s + ring.far);
            while (z < z_end) : (z += ring.step) {
                var x: i32 = @max(px0, -ring.far);
                const x_end: i32 = @min(px0 + sea_patch_size, s + ring.far);
                while (x < x_end) : (x += ring.step) {
                    if (x >= -ring.inner and x < s + ring.inner and z >= -ring.inner and z < s + ring.inner) continue;
                    try add(&out, gpa, @floatFromInt(x), @floatFromInt(z), @floatFromInt(ring.step), y, ring.info);
                }
            }
        }
        const count: u32 = @as(u32, @intCast(out.items.len / 4)) - first;
        if (count > 0) {
            patches[pi] = .{
                .x0 = @floatFromInt(px0),
                .z0 = @floatFromInt(pz0),
                .first_quad = first,
                .quad_count = count,
            };
            pi += 1;
        }
    };
    std.debug.assert(pi == sea_patch_count);
    return out.toOwnedSlice(gpa);
}

fn seaRing(gpa: std.mem.Allocator) ![]Vertex {
    var patches: [sea_patch_count]SeaPatch = undefined;
    return seaRingPatches(gpa, &patches);
}

const dome_rings = 8;
const dome_segments = 24;

/// A dome of quads around the eye, from a little below the horizon to
/// overhead: their corners are directions.
fn skyDome(buf: *[dome_rings * dome_segments * 4][3]f32) [][3]f32 {
    var n: usize = 0;
    const dir = struct {
        fn f(ring: usize, seg: usize) [3]f32 {
            // From 12 degrees below the horizon up to the zenith.
            const el = -0.21 + (std.math.pi / 2.0 + 0.21) * @as(f32, @floatFromInt(ring)) / dome_rings;
            const az = 2 * std.math.pi * @as(f32, @floatFromInt(seg)) / dome_segments;
            return .{ @cos(el) * @cos(az), @sin(el), @cos(el) * @sin(az) };
        }
    }.f;
    for (0..dome_rings) |ring| for (0..dome_segments) |seg| {
        for ([4][2]usize{ .{ ring, seg }, .{ ring, seg + 1 }, .{ ring + 1, seg + 1 }, .{ ring + 1, seg } }) |c| {
            buf[n] = dir(c[0], c[1]);
            n += 1;
        }
    };
    return buf[0..n];
}

/// The twelve edges of a block, a little bigger than it (so they show
/// over its faces), as pairs of points.
fn cubeEdges() [24][3]f32 {
    const lo = -0.003;
    const hi = 1.003;
    var out: [24][3]f32 = undefined;
    var n: usize = 0;
    for (0..3) |axis| for ([2]f32{ lo, hi }) |a| for ([2]f32{ lo, hi }) |b| {
        var p: [3]f32 = undefined;
        var q: [3]f32 = undefined;
        p[axis] = lo;
        q[axis] = hi;
        p[(axis + 1) % 3] = a;
        q[(axis + 1) % 3] = a;
        p[(axis + 2) % 3] = b;
        q[(axis + 2) % 3] = b;
        out[n] = p;
        out[n + 1] = q;
        n += 2;
    };
    return out;
}

// --- Tests ------------------------------------------------------------------------------

const testing = std.testing;

/// A device with buffers in memory (for tests and the preview), which
/// draws nothing.
pub const FakeDevice = struct {
    fd: i32 = -1,
    state: *State,

    pub const State = struct {
        gpa: std.mem.Allocator,
        next: u32 = 1,
        bos: std.AutoHashMapUnmanaged(u32, []u8) = .empty,
        /// Making buffers fails (as when the GPU's memory is used up).
        full: bool = false,

        pub fn deinit(s: *State) void {
            s.bos.deinit(s.gpa);
        }

        pub fn memory(s: *const State, handle: u32) []const u8 {
            return s.bos.get(handle) orelse &.{};
        }
    };

    pub fn createBo(d: FakeDevice, size: u32) !vc4.Bo {
        const s = d.state;
        if (s.full) return error.OutOfMemory;
        const map = try s.gpa.alignedAlloc(u8, .fromByteUnits(std.heap.page_size_min), std.mem.alignForward(u32, size, 4096));
        errdefer s.gpa.free(map);
        s.next += 1;
        try s.bos.put(s.gpa, s.next, map);
        return .{ .handle = s.next, .map = map };
    }

    pub fn destroyBo(d: FakeDevice, bo: vc4.Bo) void {
        _ = d.state.bos.remove(bo.handle);
        d.state.gpa.free(bo.map);
    }

    pub fn createShaderBo(_: FakeDevice, _: []const vc4.qpu.Inst) !u32 {
        return 7;
    }
};

test "the other players' figures face outwards, each in one strip, standing on the origin" {
    const figures = avatarMeshes();
    for (figures, avatar_colours) |mesh, colour| {
        var lowest: f32 = std.math.inf(f32);
        for (0..avatar_quads) |q| {
            const v = mesh[q * 4 ..][0..4];
            const info = mesher.Info.unpack(v[0].info);
            const tile: blocks.Tile = @enumFromInt(info.tile);
            try std.testing.expectEqual(colour.strip(), tile.strip());
            // Counter-clockwise from outside: the winding's normal is the face's.
            const p0: V3 = v[0].pos;
            const n = math.cross(@as(V3, v[1].pos) - p0, @as(V3, v[2].pos) - p0);
            const want = info.face.normal();
            try std.testing.expect(math.dot(n, .{ @floatFromInt(want[0]), @floatFromInt(want[1]), @floatFromInt(want[2]) }) > 0);
            for (v) |c| lowest = @min(lowest, c.pos[1]);
        }
        try std.testing.expectEqual(@as(f32, 0), lowest);
    }
}

test "the whole island in view fits one frame, the near chunks first" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);
    var state: FakeDevice.State = .{ .gpa = testing.allocator };
    defer state.deinit();
    const r = try Renderer(FakeDevice).init(testing.allocator, .{ .state = &state });
    defer r.deinit();
    try testing.expectEqual(@as(usize, 0), try r.update(w, w.spawn, 1000));
    // High over the island, looking down at all of it.
    const cam: math.Camera = .{ .eye = .{ 64, 100, 150 }, .yaw = 0, .pitch = -0.6 };
    const frame = try testing.allocator.create(vc4.render.Frame);
    defer testing.allocator.destroy(frame);
    frame.begin(.{ .handle = 1, .width = 1920, .height = 1080 }, .{ .clear = 0 });
    try r.draw(FrameSink{ .frame = frame }, .{ .x = 0, .y = 0, .width = 1920, .height = 1080 }, null, .{
        .camera = cam,
        .aspect = 1920.0 / 1080.0,
        .time = 12.5,
        .env = Environment.at(0.4),
        .outline = .{ 10, 30, 10 },
    });
    std.log.info("{d} chunks, {d} draws, {d} triangles; {d} bytes of control list, {d} uniform words, {d} buffers", .{ r.stats.chunks, r.stats.draws, r.stats.triangles, frame.bin.w.len, frame.uniforms_len, frame.bo_count });
    try testing.expect(r.stats.chunks > 30);
    // Everything drawn: room to spare for the UI over it.
    try testing.expect(frame.hasRoom(4096));
    try testing.expect(r.stats.triangles > 40000);
    // Drawn a region at a time: at most a draw for each strip's faces
    // facing the eye (in up to three runs), and its water and glass.
    try testing.expect(r.stats.draws < 100);
    // Meshing a changed chunk again replaces its buffer.
    const before = state.bos.count();
    _ = w.set(64, 50, 64, .gold);
    _ = try r.update(w, w.spawn, 1000);
    try testing.expectEqual(before, state.bos.count());

    // No memory for its region's new buffer: it is shown as it was, and
    // made again when there is.
    _ = w.set(64, 50, 64, .stone);
    const i = for (0..world_mod.chunk_count) |c| {
        if (w.dirty.isSet(c)) break c;
    } else unreachable;
    const ri = regionOf(i);
    const old = r.regions[ri].bo.?.handle;
    state.full = true;
    try testing.expectError(error.OutOfMemory, r.update(w, w.spawn, 1000));
    try testing.expectEqual(old, r.regions[ri].bo.?.handle);
    try testing.expect(state.bos.contains(old));
    try testing.expect(r.regions[ri].dirty);
    state.full = false;
    try testing.expectEqual(@as(usize, 0), try r.update(w, w.spawn, 1000));
    try testing.expect(r.regions[ri].bo.?.handle != old);
    try testing.expect(!r.regions[ri].dirty);
    try testing.expectEqual(before, state.bos.count());
}

test "the day: bright at noon, dark at midnight, red at sunset, lamps brighter at night" {
    const noon = Environment.at(0.5);
    const night = Environment.at(0.0);
    const dusk = Environment.at(0.75);
    try testing.expect(noon.daylight > 0.99 and night.daylight < 0.01);
    try testing.expect(noon.sun_dir[1] > 0.9 and night.sun_dir[1] < -0.9);
    try testing.expect(dusk.horizon[0] > dusk.horizon[2]);
    try testing.expect(noon.horizon[2] > noon.horizon[0]);
    try testing.expect(night.lamps > noon.lamps);
    try testing.expect(night.lightDir()[1] > 0.9);
    try testing.expect(noon.sun_shows > 0.99 and night.moon_shows > 0.99);
}

test "fixed geometry: the sea ring leaves the world's middle to its own water; the outline's edges" {
    const sea = try seaRing(testing.allocator);
    defer testing.allocator.free(sea);
    for (sea) |v| {
        const inside = v.pos[0] > 0 and v.pos[0] < world_mod.size_x and v.pos[2] > 0 and v.pos[2] < world_mod.size_z;
        try testing.expect(!inside);
    }
    try testing.expect(sea.len / 4 < max_quads);
    const e = cubeEdges();
    for (0..12) |i| {
        // Each edge runs along one axis, the length of the cube.
        const p = e[i * 2];
        const q = e[i * 2 + 1];
        var along: u32 = 0;
        for (0..3) |k| if (p[k] != q[k]) {
            along += 1;
        };
        try testing.expectEqual(@as(u32, 1), along);
    }
}

test "faces turned away are not drawn, and none that can be seen are left out" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);
    var m: mesher.Mesh = .{};
    defer m.deinit(testing.allocator);
    const eyes = [_]V3{ w.spawn + V3{ 0, 1.6, 0 }, .{ 64, 100, 150 }, .{ 20, 30, 20 }, .{ 100, 5, 70 } };
    var all: usize = 0;
    var drawn: usize = 0;
    for (0..world_mod.chunk_count) |i| {
        try mesher.build(testing.allocator, w, i % world_mod.chunks_x, i / world_mod.chunks_x, &m);
        for (0..blocks.Tile.strips) |k| {
            const list = m.items(.solid(@intCast(k)));
            var min_y: f32 = std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            for (list) |v| {
                min_y = @min(min_y, v.pos[1]);
                max_y = @max(max_y, v.pos[1]);
            }
            const c: ChunkGpu = .{ .face_quads = m.face_quads, .min_y = min_y - 0.5, .max_y = max_y + 0.5 };
            for (eyes) |eye| {
                var runs: [3][2]u32 = undefined;
                const got = c.facing(k, chunkCorner(i), eye, &runs);
                for (got) |run| drawn += run[1];
                all += list.len / 4;
                for (0..list.len / 4) |q| {
                    const v = list[q * 4];
                    const n = mesher.Info.unpack(v.info).face.normal();
                    const to = eye - v.pos;
                    const front = @as(f32, @floatFromInt(n[0])) * to[0] + @as(f32, @floatFromInt(n[1])) * to[1] + @as(f32, @floatFromInt(n[2])) * to[2] > 0;
                    if (!front) continue;
                    var in = false;
                    for (got) |run| in = in or (q >= run[0] and q < run[0] + run[1]);
                    try testing.expect(in);
                }
            }
        }
    }
    // About half are turned away from any one place.
    try testing.expect(drawn * 10 < all * 7);
    std.log.info("faces turned to the eye: {d} of {d} quads drawn", .{ drawn, all });
}
