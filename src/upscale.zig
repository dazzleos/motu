//! The world drawn smaller than the view, with the widgets over it at the
//! window's own size (sharp): when the window's buffer cannot be drawn
//! smaller and stretched by the shell, as it is playing on the whole
//! screen, because the menu or a window's title bar is drawn in it too.
//! The world goes into an image of its own (a separate GPU job, handed
//! over before the window's frame: the GPU runs them in turn), which the
//! window's frame stretches over the view.

const std = @import("std");
const gpu = @import("gpu.zig");
const app = @import("app");

const render = gpu;
const texture = gpu.texture;

/// The image is drawn into here (a frame is large: one, reused at once,
/// as the kernel copies what it is given).
var image_frame: render.Frame = undefined;

pub const Upscaler = struct {
    dev: gpu.Device,
    pipeline: gpu.Pipeline,
    /// Two triangles over the view, with texture coordinates over the
    /// image.
    quad: gpu.Buffer,
    /// The image: as big as the view (its smaller sizes fit in it).
    image: ?gpu.Buffer = null,
    image_size: [2]u32 = .{ 0, 0 },

    pub fn init(gpa: std.mem.Allocator, dev: gpu.Device) !Upscaler {
        var pipeline = try gpu.Pipeline.init(gpa, dev, gpu.Program.decode(@embedFile("upscale.shader")) catch unreachable, .{
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
        u.release();
        u.dev.destroyBo(u.quad);
        u.pipeline.deinit(u.dev);
    }

    /// Frees the image (while the world is drawn straight into the
    /// window's buffer, the memory is better used for other things). The
    /// GPU may still be reading it: the kernel keeps it until it is done.
    pub fn release(u: *Upscaler) void {
        if (u.image) |bo| u.dev.destroyBo(bo);
        u.image = null;
        u.image_size = .{ 0, 0 };
    }

    /// A frame to draw the world into, `size` big (with room for it, for
    /// a view `view` big), begun; null if there is no memory for it.
    pub fn begin(u: *Upscaler, view: [2]u32, size: [2]u32) ?*render.Frame {
        if (u.image == null or u.image_size[0] < view[0] or u.image_size[1] < view[1]) {
            u.release();
            u.image = u.dev.createBo(texture.imageSizeOf(.xrgb8888, view[0], view[1])) catch return null;
            u.image_size = view;
        }
        image_frame.begin(targetOf(u.image.?, size), .{ .clear = 0xff000000 });
        return &image_frame;
    }

    /// Hands the image's frame to the GPU, and draws the image over
    /// `viewport` of `frame` (the window's), clipped to `scissor`.
    pub fn finish(u: *Upscaler, frame: *render.Frame, size: [2]u32, viewport: render.Viewport, scissor: ?render.Viewport) !void {
        const job = image_frame.finish();
        // Counted with the window's frames, while they are.
        job.perfmonid = app.window.perfmon_id;
        _ = try u.dev.submit(job);
        try u.pipeline.draw(frame, .{
            .vertices = u.quad.handle,
            .count = 6,
            .viewport = viewport,
            .scissor = scissor,
            .texture = .{ .handle = u.image.?.handle, .config = .{
                .type = gpu.Format.xrgb8888.textureType(),
                .width = size[0],
                .height = size[1],
                .mag_filter = .linear,
                .min_filter = .linear,
                .wrap_s = .clamp,
                .wrap_t = .clamp,
            } },
        });
    }

    fn targetOf(bo: gpu.Buffer, size: [2]u32) render.Target {
        return .{
            .handle = bo.handle,
            .width = @intCast(size[0]),
            .height = @intCast(size[1]),
            .tiling = render.Target.textureTiling(.xrgb8888, size[0], size[1]),
        };
    }
};

/// The size to draw the world at, `quality` of a view `view` big across
/// and down.
pub fn sizeOf(view: [2]u32, quality: f32) [2]u32 {
    return .{
        @max(16, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(view[0])) * quality)))),
        @max(16, @as(u32, @intFromFloat(@round(@as(f32, @floatFromInt(view[1])) * quality)))),
    };
}

test "the world is drawn as much smaller as the quality says, and never tiny" {
    try std.testing.expectEqual([2]u32{ 1152, 648 }, sizeOf(.{ 1920, 1080 }, 0.6));
    try std.testing.expectEqual([2]u32{ 960, 492 }, sizeOf(.{ 1920, 984 }, 0.5));
    try std.testing.expectEqual([2]u32{ 16, 16 }, sizeOf(.{ 10, 10 }, 0.5));
}
