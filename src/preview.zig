//! The renderer's draws drawn on the CPU, for tests and for pictures made
//! without a Pi: the real compiled shaders run in the QPU simulator (the
//! vertex shaders for the varyings, the coordinate shaders for clip-space
//! positions, the fragment shaders for the colours), and triangles are
//! clipped, culled, rasterized and depth-tested here as the GPU would.
//! Lines are not drawn.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");
const renderer = @import("renderer.zig");

const sim = vc4.qpu_sim;
const lanes = sim.lanes;

/// A draw, as the renderer asked for it.
const Recorded = struct {
    pipeline: *shader.Pipeline,
    /// The pipeline's uniform words when it was drawn.
    values: []u32,
    draw: shader.Pipeline.Draw,
};

pub const Image = struct {
    width: u32,
    height: u32,
    /// 0xAARRGGBB.
    pixels: []u32,
    depth: []f32,
};

/// Collects the renderer's draws (as a sink: see renderer.FrameSink).
pub const Recorder = struct {
    gpa: std.mem.Allocator,
    draws: std.ArrayList(Recorded) = .empty,

    pub fn deinit(r: *Recorder) void {
        for (r.draws.items) |d| r.gpa.free(d.values);
        r.draws.deinit(r.gpa);
    }

    pub fn hasRoom(_: *Recorder, _: usize) bool {
        return true;
    }

    pub fn draw(r: *Recorder, p: *shader.Pipeline, d: shader.Pipeline.Draw) !void {
        const values = try r.gpa.dupe(u32, p.values);
        errdefer r.gpa.free(values);
        // The viewport's scale follows the uniforms (Pipeline.draw sets it).
        const scale = d.viewport.?.scaleBits();
        values[p.program.uniform_words] = scale[0];
        values[p.program.uniform_words + 1] = scale[1];
        try r.draws.append(r.gpa, .{ .pipeline = p, .values = values, .draw = d });
    }
};

/// A vertex after its shaders: where it is in clip space, and its
/// varyings.
const Shaded = struct {
    clip: [4]f32,
    vary: [shader.program.max_varyings]f32,
};

/// Texture slot i's P0 relocated to `sim.texture_base` * i (see
/// `sim.Env.textures`).
fn streamOf(c: *const vc4.compiler.Compiled, values: []const u32, tex: [3]?vc4.render.Texture, buf: []u32) []const u32 {
    const kinds = c.uniforms();
    for (kinds, buf[0..kinds.len]) |k, *o| o.* = switch (k) {
        .user => |i| values[i],
        .tex_p0 => |slot| vc4.texture.p0(tex[slot].?.config) + slot * sim.texture_base,
        .tex_p1 => |slot| vc4.texture.p1(tex[slot].?.config),
        .constant => |v| v,
    };
    return buf[0..kinds.len];
}

fn f32At(mem: []const u8, offset: usize) f32 {
    if (offset + 4 > mem.len) return 0;
    return @bitCast(std.mem.readInt(u32, mem[offset..][0..4], .little));
}

/// Draws everything recorded into `img`, in order.
pub fn render(gpa: std.mem.Allocator, rec: *const Recorder, dev: *const renderer.FakeDevice.State, img: Image) !void {
    for (rec.draws.items) |*d| {
        if (d.pipeline.options.primitive != .triangles) continue;
        try renderDraw(gpa, d, dev, img);
    }
}

fn renderDraw(gpa: std.mem.Allocator, d: *const Recorded, dev: *const renderer.FakeDevice.State, img: Image) !void {
    const p = d.pipeline;
    const prog = p.program;
    const draw = d.draw;
    const mem = dev.memory(draw.vertices);
    // Which vertices: by index, or in order.
    const count = draw.count;
    const indices = try gpa.alloc(u32, count);
    defer gpa.free(indices);
    if (draw.indices) |ib| {
        const idx_mem = dev.memory(ib.handle);
        for (indices, 0..) |*o, i| o.* = std.mem.readInt(u16, idx_mem[ib.offset + i * 2 ..][0..2], .little);
    } else for (indices, 0..) |*o, i| {
        o.* = @intCast(draw.first + i);
    }
    var most: u32 = 0;
    for (indices) |i| most = @max(most, i);
    const shaded = try gpa.alloc(Shaded, most + 1);
    defer gpa.free(shaded);
    const used = try gpa.alloc(bool, most + 1);
    defer gpa.free(used);
    @memset(used, false);
    for (indices) |i| used[i] = true;

    // The vertex and coordinate shaders, sixteen vertices at a time.
    var vs_buf: [256]u32 = undefined;
    var cs_buf: [256]u32 = undefined;
    const vs_uniforms = streamOf(&prog.vs, d.values, .{ draw.texture, draw.texture1, draw.texture2 }, &vs_buf);
    const cs_uniforms = streamOf(&prog.cs, d.values, .{ draw.texture, draw.texture1, draw.texture2 }, &cs_buf);
    var vs_decoded_buf: [vc4.compiler.max_code]sim.DecodedInst = undefined;
    var cs_decoded_buf: [vc4.compiler.max_code]sim.DecodedInst = undefined;
    const vs_decoded = sim.decodeProgram(prog.vs.code(), &vs_decoded_buf);
    const cs_decoded = sim.decodeProgram(prog.cs.code(), &cs_decoded_buf);
    var batch: [lanes]u32 = undefined;
    var n: usize = 0;
    var v: u32 = 0;
    while (v <= most) : (v += 1) {
        if (!used[v]) continue;
        batch[n] = v;
        n += 1;
        if (n == lanes or v == most) {
            try shadeVertices(prog, p, draw, mem, batch[0..n], vs_decoded, cs_decoded, vs_uniforms, cs_uniforms, shaded);
            n = 0;
        }
    }
    if (n > 0) try shadeVertices(prog, p, draw, mem, batch[0..n], vs_decoded, cs_decoded, vs_uniforms, cs_uniforms, shaded);

    var fs_buf: [256]u32 = undefined;
    const fs_uniforms = streamOf(&prog.fs, d.values, .{ draw.texture, draw.texture1, draw.texture2 }, &fs_buf);
    var fs_decoded_buf: [vc4.compiler.max_code]sim.DecodedInst = undefined;
    const fs_decoded = sim.decodeProgram(prog.fs.code(), &fs_decoded_buf);
    var frags: Fragments = .{ .prog = prog, .fs_decoded = fs_decoded, .uniforms = fs_uniforms, .img = img, .depth_write = p.options.depth_write };
    for (&frags.textures, [_]?vc4.render.Texture{ draw.texture, draw.texture1, draw.texture2 }) |*m, t| {
        m.* = if (t) |tex| dev.memory(tex.handle) else &.{};
    }
    const vp = draw.viewport.?;
    var t: usize = 0;
    while (t + 3 <= count) : (t += 3) {
        const tri = [3]*const Shaded{ &shaded[indices[t]], &shaded[indices[t + 1]], &shaded[indices[t + 2]] };
        try triangle(tri, prog, p.options.cull, vp, draw.scissor, &frags);
    }
    try frags.flush();
}

fn shadeVertices(prog: *const shader.Program, p: *const shader.Pipeline, draw: shader.Pipeline.Draw, mem: []const u8, batch: []const u32, vs_decoded: []const sim.DecodedInst, cs_decoded: []const sim.DecodedInst, vs_u: []const u32, cs_u: []const u32, out: []Shaded) !void {
    var vs_in: [32]sim.Vec = undefined;
    var cs_in: [32]sim.Vec = undefined;
    var nv: usize = 0;
    var nc: usize = 0;
    for (prog.attributeList(), 0..) |a, ai| {
        for (0..a.components) |comp| {
            var vec: sim.Vec = undefined;
            for (0..lanes) |lane| {
                const vi = batch[@min(lane, batch.len - 1)];
                const off = draw.vertex_offset + vi * p.options.vertex_stride + p.offsets[ai] + comp * 4;
                vec[lane] = @bitCast(f32At(mem, off));
            }
            vs_in[nv] = vec;
            nv += 1;
            if (a.in_coordinate_shader) {
                cs_in[nc] = vec;
                nc += 1;
            }
        }
    }
    const vs = try sim.runDecoded(vs_decoded, .{ .uniforms = vs_u, .vpm_in = vs_in[0..nv] });
    const cs = try sim.runDecoded(cs_decoded, .{ .uniforms = cs_u, .vpm_in = cs_in[0..nc] });
    const vo = vs.vpmOut();
    const co = cs.vpmOut();
    for (batch, 0..) |vi, lane| {
        var s: Shaded = undefined;
        for (0..4) |k| s.clip[k] = @bitCast(co[k][lane]);
        // After the screen-space header (x|y, z, 1/w).
        for (0..prog.varying_components) |k| s.vary[k] = @bitCast(vo[3 + k][lane]);
        out[vi] = s;
    }
}

/// Fragments waiting to be shaded, sixteen at a time.
const Fragments = struct {
    prog: *const shader.Program,
    fs_decoded: []const sim.DecodedInst,
    uniforms: []const u32,
    textures: [3][]const u8 = @splat(&.{}),
    img: Image,
    /// Whether depth-tested fragments are kept in the depth buffer.
    depth_write: bool = true,
    index: [lanes]usize = undefined,
    vary: [shader.program.max_varyings]sim.Vec = undefined,
    n: usize = 0,

    fn add(f: *Fragments, pixel: usize, vary: []const f32) !void {
        // A pixel twice in a batch would blend with the colour before the
        // first: shade what is waiting first.
        for (f.index[0..f.n]) |i| if (i == pixel) {
            try f.flush();
            break;
        };
        for (vary, 0..) |x, k| f.vary[k][f.n] = @bitCast(x);
        f.index[f.n] = pixel;
        f.n += 1;
        if (f.n == lanes) try f.flush();
    }

    fn flush(f: *Fragments) !void {
        if (f.n == 0) return;
        const nv = f.prog.varying_components;
        for (f.n..lanes) |lane| {
            f.index[lane] = f.index[f.n - 1];
            for (0..nv) |k| f.vary[k][lane] = f.vary[k][f.n - 1];
        }
        var tile: sim.Vec = undefined;
        for (&tile, f.index) |*c, i| c.* = f.img.pixels[i];
        const r = try sim.runFragmentDecoded(f.fs_decoded, .{ .uniforms = f.uniforms, .varyings = f.vary[0..nv], .tlb_color_in = tile, .textures = &f.textures });
        for (f.index[0..f.n], 0..) |i, lane| f.img.pixels[i] = r.tlb_color.?[lane];
        f.n = 0;
    }
};

/// Clips to the near plane (z > -w), then rasterizes what is left.
fn triangle(tri: [3]*const Shaded, prog: *const shader.Program, cull: shader.pipeline.Cull, vp: vc4.render.Viewport, scissor: ?vc4.render.Viewport, frags: *Fragments) !void {
    var poly: [8]Shaded = undefined;
    var np: usize = 0;
    const nv = prog.varying_components;
    for (0..3) |i| {
        const a = tri[i];
        const b = tri[(i + 1) % 3];
        const da = a.clip[2] + a.clip[3];
        const db = b.clip[2] + b.clip[3];
        if (da >= 0) {
            poly[np] = a.*;
            np += 1;
        }
        if ((da >= 0) != (db >= 0)) {
            const t = da / (da - db);
            var c: Shaded = undefined;
            for (0..4) |k| c.clip[k] = a.clip[k] + (b.clip[k] - a.clip[k]) * t;
            for (0..nv) |k| c.vary[k] = a.vary[k] + (b.vary[k] - a.vary[k]) * t;
            poly[np] = c;
            np += 1;
        }
    }
    if (np < 3) return;
    for (1..np - 1) |i| try raster(.{ &poly[0], &poly[i], &poly[i + 1] }, prog, cull, vp, scissor, frags);
}

/// Where on the screen corners are, as the GPU has them: in sixteenths of
/// a pixel.
const subpixels = 16;

fn raster(tri: [3]*const Shaded, prog: *const shader.Program, cull: shader.pipeline.Cull, vp: vc4.render.Viewport, scissor: ?vc4.render.Viewport, frags: *Fragments) !void {
    const img = frags.img;
    var sx: [3]f32 = undefined;
    var sy: [3]f32 = undefined;
    var sz: [3]f32 = undefined;
    var rw: [3]f32 = undefined;
    // The corners in sixteenths of a pixel (as the GPU snaps them).
    var fx: [3]i64 = undefined;
    var fy: [3]i64 = undefined;
    for (tri, 0..) |v, i| {
        const w = v.clip[3];
        if (w <= 1e-6) return;
        rw[i] = 1 / w;
        const x = @as(f32, @floatFromInt(vp.x)) + (v.clip[0] * rw[i] * 0.5 + 0.5) * @as(f32, @floatFromInt(vp.width));
        const y = @as(f32, @floatFromInt(vp.y)) + (0.5 - v.clip[1] * rw[i] * 0.5) * @as(f32, @floatFromInt(vp.height));
        if (@abs(x) > 1 << 20 or @abs(y) > 1 << 20) return;
        fx[i] = @intFromFloat(@round(x * subpixels));
        fy[i] = @intFromFloat(@round(y * subpixels));
        sx[i] = @as(f32, @floatFromInt(fx[i])) / subpixels;
        sy[i] = @as(f32, @floatFromInt(fy[i])) / subpixels;
        sz[i] = v.clip[2] * rw[i] * 0.5 + 0.5;
    }
    const twice = (fx[1] - fx[0]) * (fy[2] - fy[0]) - (fy[1] - fy[0]) * (fx[2] - fx[0]);
    if (twice == 0) return;
    // Facing: counter-clockwise in clip space (y up) is the front; on the
    // screen (y down) that is a negative area.
    const area = (sx[1] - sx[0]) * (sy[2] - sy[0]) - (sy[1] - sy[0]) * (sx[2] - sx[0]);
    if (area == 0) return;
    const front = area < 0;
    if (cull == .back and !front) return;
    if (cull == .front and front) return;
    var x0: i32 = @intFromFloat(@floor(@min(sx[0], @min(sx[1], sx[2]))));
    var y0: i32 = @intFromFloat(@floor(@min(sy[0], @min(sy[1], sy[2]))));
    var x1: i32 = @intFromFloat(@ceil(@max(sx[0], @max(sx[1], sx[2]))));
    var y1: i32 = @intFromFloat(@ceil(@max(sy[0], @max(sy[1], sy[2]))));
    var clip = vp;
    if (scissor) |s| clip = s;
    x0 = @max(x0, @max(clip.x, 0));
    y0 = @max(y0, @max(clip.y, 0));
    x1 = @min(x1, @min(clip.x + @as(i32, @intCast(clip.width)), @as(i32, @intCast(img.width))));
    y1 = @min(y1, @min(clip.y + @as(i32, @intCast(clip.height)), @as(i32, @intCast(img.height))));
    const nv = prog.varying_components;
    var vary: [shader.program.max_varyings]f32 = undefined;
    var y = y0;
    while (y < y1) : (y += 1) {
        var x = x0;
        while (x < x1) : (x += 1) {
            const px = @as(f32, @floatFromInt(x)) + 0.5;
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            var b: [3]f32 = undefined;
            var inside = true;
            // Inside each edge, exactly (in sixteenths); a pixel on an edge
            // is drawn by one of the two triangles sharing it (the one it
            // is a top or left edge of), as on the GPU.
            const qx: i64 = @as(i64, x) * subpixels + subpixels / 2;
            const qy: i64 = @as(i64, y) * subpixels + subpixels / 2;
            for (0..3) |k| {
                const i = (k + 1) % 3;
                const j = (k + 2) % 3;
                var dx = fx[j] - fx[i];
                var dy = fy[j] - fy[i];
                var e = dx * (qy - fy[i]) - dy * (qx - fx[i]);
                if (twice < 0) {
                    e = -e;
                    dx = -dx;
                    dy = -dy;
                }
                const top_left = dy < 0 or (dy == 0 and dx > 0);
                if (e < 0 or (e == 0 and !top_left)) inside = false;
                b[k] = ((sx[j] - sx[i]) * (py - sy[i]) - (sy[j] - sy[i]) * (px - sx[i])) / area;
            }
            if (!inside) continue;
            const z = b[0] * sz[0] + b[1] * sz[1] + b[2] * sz[2];
            const pixel: usize = @as(usize, @intCast(y)) * img.width + @as(usize, @intCast(x));
            if (prog.options.depth_test) {
                if (!(z < img.depth[pixel])) continue;
                if (frags.depth_write) img.depth[pixel] = z;
            }
            // Perspective-correct: weighted by 1/w.
            const pw = [3]f32{ b[0] * rw[0], b[1] * rw[1], b[2] * rw[2] };
            const sum = pw[0] + pw[1] + pw[2];
            for (0..nv) |k| vary[k] = (pw[0] * tri[0].vary[k] + pw[1] * tri[1].vary[k] + pw[2] * tri[2].vary[k]) / sum;
            try frags.add(pixel, vary[0..nv]);
        }
    }
}

// --- Pictures -------------------------------------------------------------------------------

const world_mod = @import("world.zig");
const math = @import("math.zig");
const testing = std.testing;

/// Renders the island as the game would, with the real shaders.
pub fn picture(gpa: std.mem.Allocator, w: *world_mod.World, view: renderer.View, width: u32, height: u32) !Image {
    var state: renderer.FakeDevice.State = .{ .gpa = gpa };
    defer state.deinit();
    const r = try renderer.Renderer(renderer.FakeDevice).init(gpa, .{ .state = &state });
    defer r.deinit();
    _ = try r.update(w, view.camera.eye, 1000);
    var rec: Recorder = .{ .gpa = gpa };
    defer rec.deinit();
    try r.draw(&rec, .{ .x = 0, .y = 0, .width = width, .height = height }, null, view);
    const pixels = try gpa.alloc(u32, width * height);
    errdefer gpa.free(pixels);
    const depth = try gpa.alloc(f32, width * height);
    defer gpa.free(depth);
    const img: Image = .{ .width = width, .height = height, .pixels = pixels, .depth = depth };
    @memset(img.pixels, 0xff000000);
    @memset(img.depth, 1);
    try render(gpa, &rec, &state, img);
    return img;
}

fn channel(c: u32, shift: u5) i32 {
    return @intCast(c >> shift & 0xff);
}

test "the island from its beach, drawn with the real shaders: sky above, land and sea below" {
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);
    const width = 96;
    const height = 54;
    const eye = w.spawn + math.V3{ 0, 1.62, 0 };
    const img = try picture(testing.allocator, w, .{
        .camera = .{ .eye = eye, .yaw = w.spawn_yaw, .pitch = -0.1 },
        .aspect = @as(f32, width) / height,
        .time = 3,
        .env = renderer.Environment.at(0.38),
    }, width, height);
    defer testing.allocator.free(img.pixels);
    // The top row is mostly sky (palms' fronds may be against it): blue,
    // bright.
    var sky: u32 = 0;
    for (0..width) |x| {
        const c = img.pixels[x];
        if (channel(c, 0) > channel(c, 16) and channel(c, 0) > 150) sky += 1;
    }
    try testing.expect(sky > width / 2);
    // Something was drawn over every pixel (none left black).
    for (img.pixels) |c| try testing.expect(c & 0xffffff != 0);
    // The bottom row (the beach and the lagoon at the player's feet) is
    // not the sky: darker, or not blue.
    var ground: u32 = 0;
    for (0..width) |x| {
        const c = img.pixels[(height - 1) * width + x];
        if (channel(c, 0) < channel(c, 16) + 20 or channel(c, 0) < 150) ground += 1;
    }
    try testing.expect(ground > width / 2);
}

