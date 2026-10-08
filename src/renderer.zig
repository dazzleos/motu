//! Draws the world with the GPU, straight into the frame: the chunks'
//! meshes (each chunk's three in one buffer), the sea around the world,
//! the sky and the outline of the block picked.
//!
//! What is drawn, in order, and why:
//!
//! 1. Solid blocks, the nearest chunks first, with early Z: the GPU then
//!    skips shading what is behind what it has drawn, so the cost is about
//!    a pixel's shading once each.
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

const World = world_mod.World;
const Vertex = mesher.Vertex;
const V3 = math.V3;
const Mat4 = math.Mat4;

/// Quads one draw can have: their vertices are numbered within a 16-bit
/// index.
pub const max_quads = 16384;

/// Mipmap levels after the first: down to a pixel a tile (64 to 1).
const mip_levels = 6;

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
};

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

const ChunkGpu = struct {
    bo: ?vc4.Bo = null,
    /// Quads in each of its meshes (one after another in `bo`, in the
    /// order of mesher.Section).
    quads: [mesher.Section.count]u32 = @splat(0),
    /// How high its faces go, for culling.
    min_y: f32 = 0,
    max_y: f32 = 0,

    /// Where a mesh starts in its buffer.
    fn offset(c: ChunkGpu, s: mesher.Section) u32 {
        var n: u32 = 0;
        for (c.quads[0..@intFromEnum(s)]) |q| n += q;
        return n * 4 * @sizeOf(Vertex);
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
    /// The block to outline.
    outline: ?world_mod.Pos = null,
};

/// What the last frame drew.
pub const Stats = struct {
    chunks: u32 = 0,
    draws: u32 = 0,
    triangles: u32 = 0,
};

pub fn Renderer(comptime Device: type) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        dev: Device,
        terrain: shader.Pipeline,
        terrain_blend: shader.Pipeline,
        water: shader.Pipeline,
        sky: shader.Pipeline,
        line: shader.Pipeline,
        /// The tiles, a strip each (see textures.zig), with mipmaps.
        strips: [blocks.Tile.strips]vc4.Bo,
        indices: vc4.Bo,
        sea: vc4.Bo,
        sea_quads: u32,
        dome: vc4.Bo,
        dome_quads: u32,
        cube_lines: vc4.Bo,
        chunks: [world_mod.chunk_count]ChunkGpu = @splat(.{}),
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
            var terrain_blend = try shader.Pipeline.init(gpa, dev, prog(@embedFile("terrain_blend.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .back, .early_z = true });
            errdefer terrain_blend.deinit(dev);
            var water = try shader.Pipeline.init(gpa, dev, prog(@embedFile("water.shader")) catch unreachable, .{ .vertex_stride = @sizeOf(Vertex), .attributes = world_layout, .cull = .none, .early_z = true });
            errdefer water.deinit(dev);
            var sky = try shader.Pipeline.init(gpa, dev, prog(@embedFile("sky.shader")) catch unreachable, .{ .vertex_stride = 12, .attributes = pos_layout, .cull = .none, .early_z = true });
            errdefer sky.deinit(dev);
            var line = try shader.Pipeline.init(gpa, dev, prog(@embedFile("line.shader")) catch unreachable, .{ .vertex_stride = 12, .attributes = pos_layout, .primitive = .lines, .early_z = true });
            errdefer line.deinit(dev);

            // The tiles.
            const px = try gpa.create([textures.strip_width * textures.strip_height]u32);
            defer gpa.destroy(px);
            var strips: [blocks.Tile.strips]vc4.Bo = undefined;
            var made: usize = 0;
            errdefer for (strips[0..made]) |bo| dev.destroyBo(bo);
            const layout = vc4.texture.mipmapLayout(textures.strip_width, textures.strip_height, mip_levels);
            for (&strips, 0..) |*bo, i| {
                textures.stripPixels(@intCast(i), px);
                bo.* = try dev.createBo(layout.size);
                made += 1;
                try vc4.texture.uploadMipmaps(gpa, bo.map, px, textures.strip_width, textures.strip_height, mip_levels);
            }

            // Every quad's triangles.
            const indices = try dev.createBo(max_quads * 6 * 2);
            errdefer dev.destroyBo(indices);
            const idx = std.mem.bytesAsSlice(u16, indices.map[0 .. max_quads * 12]);
            for (0..max_quads) |q| {
                const v: u16 = @intCast(q * 4);
                idx[q * 6 ..][0..6].* = .{ v, v + 1, v + 2, v, v + 2, v + 3 };
            }

            const sea_verts = try seaRing(gpa);
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
            @memcpy(cube_lines.map[0 .. edges.len * 12], std.mem.sliceAsBytes(&edges));

            r.* = .{
                .gpa = gpa,
                .dev = dev,
                .terrain = terrain,
                .terrain_blend = terrain_blend,
                .water = water,
                .sky = sky,
                .line = line,
                .strips = strips,
                .indices = indices,
                .sea = sea,
                .sea_quads = @intCast(sea_verts.len / 4),
                .dome = dome,
                .dome_quads = @intCast(dome_verts.len / 4),
                .cube_lines = cube_lines,
            };
            return r;
        }

        pub fn deinit(r: *Self) void {
            for (&r.chunks) |*c| if (c.bo) |bo| r.dev.destroyBo(bo);
            for (r.strips) |bo| r.dev.destroyBo(bo);
            for ([_]vc4.Bo{ r.indices, r.sea, r.dome, r.cube_lines }) |bo| r.dev.destroyBo(bo);
            r.terrain.deinit(r.dev);
            r.terrain_blend.deinit(r.dev);
            r.water.deinit(r.dev);
            r.sky.deinit(r.dev);
            r.line.deinit(r.dev);
            r.mesh.deinit(r.gpa);
            r.gpa.destroy(r);
        }

        /// Meshes chunks the world marked as changed: at most `limit`, the
        /// nearest to `near` first (so what is close catches up first).
        /// Returns how many are left.
        pub fn update(r: *Self, w: *World, near: V3, limit: usize) !usize {
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
                try r.meshChunk(w, i);
            }
            return w.dirty.count();
        }

        fn meshChunk(r: *Self, w: *const World, i: usize) !void {
            const cx = i % world_mod.chunks_x;
            const cz = i / world_mod.chunks_x;
            try mesher.build(r.gpa, w, cx, cz, &r.mesh);
            const c = &r.chunks[i];
            const m = &r.mesh;
            const total = m.quads() * 4;
            // A new buffer: the old one may still be in a frame the GPU is
            // drawing (it keeps it until then).
            if (c.bo) |bo| r.dev.destroyBo(bo);
            c.* = .{};
            if (total == 0) return;
            const bo = try r.dev.createBo(@intCast(total * @sizeOf(Vertex)));
            var at: usize = 0;
            var min_y: f32 = std.math.inf(f32);
            var max_y: f32 = -std.math.inf(f32);
            var quads: [mesher.Section.count]u32 = undefined;
            for (m.lists, &quads) |l, *q| {
                const list = l.items;
                q.* = @intCast(list.len / 4);
                @memcpy(bo.map[at..][0 .. list.len * @sizeOf(Vertex)], std.mem.sliceAsBytes(list));
                at += list.len * @sizeOf(Vertex);
                for (list) |v| {
                    min_y = @min(min_y, v.pos[1]);
                    max_y = @max(max_y, v.pos[1]);
                }
            }
            c.* = .{
                .bo = bo,
                .quads = quads,
                // Room for swaying and waves.
                .min_y = min_y - 0.5,
                .max_y = max_y + 0.5,
            };
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
            const start: f32 = if (v.underwater) 0 else fog_start;
            const depth: f32 = if (v.underwater) 26 else fog_depth;
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
            r.terrain_blend.setUniforms(bytes);
            r.water.setUniforms(bytes);

            // The chunks in view, nearest first.
            const frustum = math.Frustum.of(vp);
            var order: [world_mod.chunk_count]struct { i: u8, d: f32 } = undefined;
            var n: usize = 0;
            for (r.chunks, 0..) |c, i| {
                if (c.bo == null) continue;
                const cx: f32 = @floatFromInt(i % world_mod.chunks_x * world_mod.chunk_size);
                const cz: f32 = @floatFromInt(i / world_mod.chunks_x * world_mod.chunk_size);
                const d = chunkDistance(i, cam.eye);
                if (d > depth + start + 12) continue;
                if (!frustum.sees(.{ cx, c.min_y, cz }, .{ cx + world_mod.chunk_size, c.max_y, cz + world_mod.chunk_size })) continue;
                order[n] = .{ .i = @intCast(i), .d = d };
                n += 1;
            }
            const visible = order[0..n];
            std.mem.sort(@TypeOf(order[0]), visible, {}, struct {
                fn less(_: void, a: @TypeOf(order[0]), b: @TypeOf(order[0])) bool {
                    return a.d < b.d;
                }
            }.less);
            r.stats.chunks = @intCast(n);
            var tex: [blocks.Tile.strips]vc4.render.Texture = undefined;
            for (&tex, r.strips) |*t, bo| t.* = .{ .handle = bo.handle, .config = stripConfig() };
            const target: Target(@TypeOf(sink)) = .{ .sink = sink, .viewport = viewport, .scissor = scissor, .indices = r.indices.handle, .stats = &r.stats };

            // 1. Solid blocks, near to far.
            for (visible) |o| {
                const c = r.chunks[o.i];
                for (0..blocks.Tile.strips) |k| {
                    const sec = mesher.Section.solid(@intCast(k));
                    try target.quads(&r.terrain, c.bo.?.handle, c.offset(sec), c.quads[@intFromEnum(sec)], tex[k]);
                }
            }
            // 2. The sky.
            const env_sun = env.sun_dir;
            const sky: SkyUniforms = .{
                .turn = math.mul(proj, cam.rotation()),
                .sun = .{ env_sun[0], env_sun[1], env_sun[2], env.sun_shows },
                .sun_color = .{ env.sun_color[0] + 0.3 * env.sun_shows, env.sun_color[1] + 0.25 * env.sun_shows, env.sun_color[2] + 0.15 * env.sun_shows, 0 },
                .moon = .{ -env_sun[0], -env_sun[1], -env_sun[2], env.moon_shows },
                .zenith = .{ env.zenith[0], env.zenith[1], env.zenith[2], 0 },
                .horizon = .{ fog[0], fog[1], fog[2], 0 },
            };
            r.sky.setUniforms(std.mem.asBytes(&sky));
            try target.quads(&r.sky, r.dome.handle, 0, r.dome_quads, null);
            // 3. Water, far to near; the sea around the world first (it is
            // furthest).
            try target.quads(&r.water, r.sea.handle, 0, r.sea_quads, null);
            var k = visible.len;
            while (k > 0) {
                k -= 1;
                const c = r.chunks[visible[k].i];
                try target.quads(&r.water, c.bo.?.handle, c.offset(.water), c.quads[@intFromEnum(mesher.Section.water)], null);
            }
            // 4. Glass and plants, far to near.
            k = visible.len;
            while (k > 0) {
                k -= 1;
                const c = r.chunks[visible[k].i];
                for (0..blocks.Tile.strips) |sk| {
                    const sec = mesher.Section.clear(@intCast(sk));
                    try target.quads(&r.terrain_blend, c.bo.?.handle, c.offset(sec), c.quads[@intFromEnum(sec)], tex[sk]);
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
        fn quads(t: @This(), p: *shader.Pipeline, handle: u32, offset: u32, count: u32, tex: ?vc4.render.Texture) !void {
            var done: u32 = 0;
            while (done < count) {
                const n: u32 = @min(count - done, max_quads);
                if (!t.sink.hasRoom(256)) return;
                try t.sink.draw(p, .{
                    .vertices = handle,
                    .vertex_offset = offset + done * 4 * @sizeOf(Vertex),
                    .count = n * 6,
                    .indices = .{ .handle = t.indices, .offset = 0, .max_index = n * 4 - 1 },
                    .texture = tex,
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

fn chunkDistance(i: usize, p: V3) f32 {
    const cx: f32 = @floatFromInt(i % world_mod.chunks_x * world_mod.chunk_size + world_mod.chunk_size / 2);
    const cz: f32 = @floatFromInt(i / world_mod.chunks_x * world_mod.chunk_size + world_mod.chunk_size / 2);
    const dx = @max(@abs(p[0] - cx) - world_mod.chunk_size / 2, 0);
    const dz = @max(@abs(p[2] - cz) - world_mod.chunk_size / 2, 0);
    return @sqrt(dx * dx + dz * dz);
}

// --- Fixed geometry ----------------------------------------------------------------------

/// The sea around the world: quads a block across for 16 blocks out (where
/// the waves die down), then 16 across, far enough to reach the fog from
/// anywhere in the world.
fn seaRing(gpa: std.mem.Allocator) ![]Vertex {
    var out: std.ArrayList(Vertex) = .empty;
    errdefer out.deinit(gpa);
    const y = world_mod.sea_level - 1 + mesher.water_top;
    const s = world_mod.size_x;
    const info = (mesher.Info{ .tile = 63, .face = .up, .sky = 15, .lamp = 0, .anim = .wave }).pack();
    const flat = (mesher.Info{ .tile = 63, .face = .up, .sky = 15, .lamp = 0 }).pack();
    const add = struct {
        fn quad(list: *std.ArrayList(Vertex), g: std.mem.Allocator, x0: f32, z0: f32, size: f32, yy: f32, inf: f32) !void {
            for ([4][2]f32{ .{ x0, z0 + size }, .{ x0 + size, z0 + size }, .{ x0 + size, z0 }, .{ x0, z0 } }) |c|
                try list.append(g, .{ .pos = .{ c[0], yy, c[1] }, .uv = .{ 0, 0 }, .info = inf });
        }
    }.quad;
    const band = 16;
    var z: i32 = -band;
    while (z < s + band) : (z += 1) {
        var x: i32 = -band;
        while (x < s + band) : (x += 1) {
            if (x >= 0 and x < s and z >= 0 and z < s) continue;
            try add(&out, gpa, @floatFromInt(x), @floatFromInt(z), 1, y, info);
        }
    }
    const far = 160;
    const step = 16;
    z = -far;
    while (z < s + far) : (z += step) {
        var x: i32 = -far;
        while (x < s + far) : (x += step) {
            if (x >= -band and x < s + band and z >= -band and z < s + band) continue;
            try add(&out, gpa, @floatFromInt(x), @floatFromInt(z), step, y, flat);
        }
    }
    return out.toOwnedSlice(gpa);
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

        pub fn deinit(s: *State) void {
            s.bos.deinit(s.gpa);
        }

        pub fn memory(s: *const State, handle: u32) []const u8 {
            return s.bos.get(handle) orelse &.{};
        }
    };

    pub fn createBo(d: FakeDevice, size: u32) !vc4.Bo {
        const s = d.state;
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
    std.debug.print("{d} chunks, {d} draws, {d} triangles; {d} bytes of control list, {d} uniform words, {d} buffers\n", .{ r.stats.chunks, r.stats.draws, r.stats.triangles, frame.bin.w.len, frame.uniforms_len, frame.bo_count });
    try testing.expect(r.stats.chunks > 30);
    // Everything drawn: room to spare for the UI over it.
    try testing.expect(frame.hasRoom(4096));
    try testing.expect(r.stats.triangles > 40000);
    // Meshing a changed chunk again replaces its buffer.
    const before = state.bos.count();
    _ = w.set(64, 50, 64, .gold);
    _ = try r.update(w, w.spawn, 1000);
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
