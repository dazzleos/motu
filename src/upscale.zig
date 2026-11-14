//! The world drawn smaller than the view, when the GPU cannot draw it
//! whole at the display's rate: into an image of its own (a separate GPU
//! job, run before the window's frame: the GPU runs them in turn), which
//! the window's frame stretches over the view. What is over the world
//! (the menu, the hints, the blocks to build with) is drawn at the
//! window's own size, so it stays sharp.
//!
//! How much smaller (`Scale`) follows how the frames go: while the GPU
//! holds them up (they are waited for, and come slower than the display
//! shows them), smaller; while it is idle when they are asked for, bigger
//! again, up to the view's own size.

const std = @import("std");
const vc4 = @import("vc4");
const shader = @import("shader");

const render = vc4.render;
const texture = vc4.texture;

/// The image is drawn into here (a frame is large: one, reused at once,
/// as the kernel copies what it is given).
var image_frame: render.Frame = undefined;

pub const Upscaler = struct {
    dev: vc4.Device,
    pipeline: shader.Pipeline,
    /// Two triangles over the view, with texture coordinates over the
    /// image.
    quad: vc4.Bo,
    /// The image: as big as the view (its smaller sizes fit in it).
    image: ?vc4.Bo = null,
    image_size: [2]u32 = .{ 0, 0 },

    pub fn init(gpa: std.mem.Allocator, dev: vc4.Device) !Upscaler {
        var pipeline = try shader.Pipeline.init(gpa, dev, shader.Program.decode(@embedFile("upscale.shader")) catch unreachable, .{
            .vertex_stride = 16,
            .attributes = &.{ .{ .location = 0, .offset = 0 }, .{ .location = 1, .offset = 8 } },
        });
        errdefer pipeline.deinit(dev);
        const quad = try dev.createBo(6 * 16);
        // Clip space over the view; the image's top at the view's top.
        const verts = [6][4]f32{
            .{ -1, 1, 0, 0 }, .{ -1, -1, 0, 1 }, .{ 1, 1, 1, 0 },
            .{ 1, 1, 1, 0 },  .{ -1, -1, 0, 1 }, .{ 1, -1, 1, 1 },
        };
        @memcpy(quad.map[0..@sizeOf(@TypeOf(verts))], std.mem.asBytes(&verts));
        return .{ .dev = dev, .pipeline = pipeline, .quad = quad };
    }

    pub fn deinit(u: *Upscaler) void {
        if (u.image) |bo| u.dev.destroyBo(bo);
        u.dev.destroyBo(u.quad);
        u.pipeline.deinit(u.dev);
    }

    /// A frame to draw the world into, `size` big (with room for it, for
    /// a view `view` big), begun; null if there is no memory for it.
    pub fn begin(u: *Upscaler, view: [2]u32, size: [2]u32, multisampled: bool) ?*render.Frame {
        if (u.image == null or u.image_size[0] < view[0] or u.image_size[1] < view[1]) {
            if (u.image) |bo| u.dev.destroyBo(bo);
            u.image = null;
            u.image = u.dev.createBo(texture.imageSizeOf(.xrgb8888, view[0], view[1])) catch return null;
            u.image_size = view;
        }
        const target = targetOf(u.image.?, size);
        if (multisampled) image_frame.beginMultisampled(target, 0xff000000) else image_frame.begin(target, .{ .clear = 0xff000000 });
        return &image_frame;
    }

    /// Sends the image's frame to the GPU, and draws the image over
    /// `viewport` of `frame` (the window's), clipped to `scissor`.
    /// Returns the image's job (to wait for, to time it).
    pub fn finish(u: *Upscaler, frame: *render.Frame, size: [2]u32, viewport: render.Viewport, scissor: ?render.Viewport) !u64 {
        const seqno = try u.dev.submit(image_frame.finish());
        const target = targetOf(u.image.?, size);
        try u.pipeline.draw(frame, .{
            .vertices = u.quad.handle,
            .count = 6,
            .viewport = viewport,
            .scissor = scissor,
            .texture = .{ .handle = target.handle, .config = .{
                .type = vc4.Format.xrgb8888.textureType(),
                .width = size[0],
                .height = size[1],
                .mag_filter = .linear,
                .min_filter = .linear,
                .wrap_s = .clamp,
                .wrap_t = .clamp,
            } },
        });
        return seqno;
    }

    fn targetOf(bo: vc4.Bo, size: [2]u32) render.Target {
        return .{
            .handle = bo.handle,
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
            .tiling = render.Target.textureTiling(.xrgb8888, size[0], size[1]),
        };
    }
};

/// How big the world is drawn, of the view's size (across and down).
pub const Scale = struct {
    k: f32 = 1,
    /// The frames since it last changed, and how they went: how long
    /// apart they came, and how long each waited for the GPU.
    frames: u32 = 0,
    interval_ns: u64 = 0,
    waited_ns: u64 = 0,
    last_ns: ?u64 = null,

    /// The smallest it is drawn: half across and down (a quarter of the
    /// pixels).
    pub const min: f32 = 0.5;
    /// The frames it waits for before changing.
    const window = 12;
    /// The display's rate: 60 frames a second, and a little slack.
    const frame_ns = std.time.ns_per_s / 60;

    /// A frame is being drawn, at `now`, `waited_ns` having been spent
    /// waiting for the GPU since the last. Returns whether `k` changed.
    pub fn frame(s: *Scale, now: u64, waited_ns: u64) bool {
        const last = s.last_ns orelse {
            s.last_ns = now;
            return false;
        };
        s.last_ns = now;
        // A gap (the window was covered, or the game paused): not counted.
        if (now -| last > 200 * std.time.ns_per_ms) return false;
        s.frames += 1;
        s.interval_ns += now -| last;
        s.waited_ns += waited_ns;
        if (s.frames < window) return false;
        const interval = s.interval_ns / s.frames;
        const waited = s.waited_ns / s.frames;
        s.frames = 0;
        s.interval_ns = 0;
        s.waited_ns = 0;
        const was = s.k;
        // Slower than the display, and the GPU holding them up: smaller.
        if (interval > frame_ns + frame_ns / 10 and waited > 2 * std.time.ns_per_ms) {
            // As much smaller as there are too many pixels (at most a
            // fifth across at once).
            const over = @as(f32, @floatFromInt(frame_ns)) / @as(f32, @floatFromInt(interval));
            s.k = @max(min, s.k * @max(0.8, @sqrt(over)));
        } else if (waited < std.time.ns_per_ms / 2) {
            // The GPU idle when asked: a little bigger.
            s.k = @min(1, s.k * 1.05);
        }
        // Not drawn smaller for a few pixels' sake.
        if (s.k > 0.97) s.k = 1;
        return s.k != was;
    }

    /// The size to draw the world at, for a view `view` big.
    pub fn of(s: Scale, view: [2]u32) [2]u32 {
        return .{
            @max(16, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(view[0])) * s.k)))),
            @max(16, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(view[1])) * s.k)))),
        };
    }
};

const testing = std.testing;

test "the world is drawn smaller while the GPU holds the frames up, and bigger again when it does not" {
    var s: Scale = .{};
    const ms = std.time.ns_per_ms;
    // At 30 frames a second, waiting for the GPU: smaller.
    var t: u64 = 0;
    var changed = false;
    for (0..13) |_| {
        t += 33 * ms;
        if (s.frame(t, 20 * ms)) changed = true;
    }
    try testing.expect(changed);
    try testing.expect(s.k < 1 and s.k >= 0.8);
    // Never smaller than half.
    for (0..200) |_| {
        t += 50 * ms;
        _ = s.frame(t, 30 * ms);
    }
    try testing.expectEqual(Scale.min, s.k);
    try testing.expectEqual([2]u32{ 960, 492 }, s.of(.{ 1920, 984 }));
    // At the display's rate, the GPU idle: bigger, back to the whole view.
    for (0..2000) |_| {
        t += 16 * ms;
        _ = s.frame(t, 0);
    }
    try testing.expectEqual(@as(f32, 1), s.k);
    // A pause is not counted as a slow frame.
    const k = s.k;
    t += 5 * std.time.ns_per_s;
    try testing.expect(!s.frame(t, 0));
    try testing.expectEqual(k, s.k);
}
