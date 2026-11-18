//! Makes Motu's tiles and icons at build time, so the game does not spend
//! its start drawing them (see src/textures.zig): each strip of tiles as
//! the GPU takes it, in 16 bits a texel, mipmaps and all
//! (vc4.texture.uploadMipmapsOf's layout), deflated (raw), as a quarter as much is quicker to read from
//! an SD card than to inflate; and the palette's icons, one after another
//! (0xAARRGGBB, little endian).
//!
//!     mktiles <strip-0.bin> <strip-1.bin> <strip-2.bin> <strip-3.bin> <icons.bin>

const std = @import("std");
const textures = @import("textures");
const texture = @import("texture");

pub fn main(init: std.process.Init) !void {
    const arena = init.arena.allocator();
    var args = try init.minimal.args.toSlice(arena);
    // For Vulkan (on Linux): each strip as plain RGBA.
    const linear = args.len > 1 and std.mem.eql(u8, args[1], "--linear");
    if (linear) args = args[1..];
    if (args.len != 2 + textures.strip_count) {
        std.debug.print("usage: mktiles [--linear] <strip-0.bin> .. <strip-3.bin> <icons.bin>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const px = try arena.alloc(u32, textures.strip_width * textures.strip_height);
    for (0..textures.strip_count) |i| {
        textures.strips(@intCast(i), px[0 .. textures.strip_width * textures.strip_height]);
        // In 16 bits a texel (see textures.stripSeeThrough).
        if (linear) {
            try write(init.io, cwd, args[1 + i], try deflate(arena, std.mem.sliceAsBytes(try linearMipmaps(arena, px))));
            continue;
        }
        const see_through = textures.stripSeeThrough(@intCast(i));
        const layout = if (see_through)
            texture.mipmapLayoutOf(.rgba4444, textures.strip_width, textures.strip_height, textures.mip_levels)
        else
            texture.mipmapLayoutOf(.rgb565, textures.strip_width, textures.strip_height, textures.mip_levels);
        const out = try arena.alloc(u8, layout.size);
        @memset(out, 0);
        if (see_through)
            try texture.uploadMipmapsOf(arena, .rgba4444, out, px, textures.strip_width, textures.strip_height, textures.mip_levels, .colour, textures.pack4444)
        else
            try texture.uploadMipmapsOf(arena, .rgb565, out, px, textures.strip_width, textures.strip_height, textures.mip_levels, .colour, textures.pack565);
        try write(init.io, cwd, args[1 + i], try deflate(arena, out));
    }
    const icons = try arena.alloc(u32, textures.palette.len * textures.icon_size * textures.icon_size);
    for (textures.palette, 0..) |b, i| textures.icon(b, icons[i * textures.icon_size * textures.icon_size ..][0 .. textures.icon_size * textures.icon_size]);
    try write(init.io, cwd, args[1 + textures.strip_count], std.mem.sliceAsBytes(icons));
}

/// A strip (0xAARRGGBB) and its mipmaps, as bytes R, G, B, A (Vulkan's
/// R8G8B8A8), each level after the one before: each pixel of a level the
/// average of four of the last, weighted by how opaque they are (as
/// Dazzle's `texture.uploadMipmaps` makes them).
fn linearMipmaps(arena: std.mem.Allocator, px: []const u32) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    var prev = px;
    var w: u32 = textures.strip_width;
    var h: u32 = textures.strip_height;
    var level: u32 = 0;
    while (true) : (level += 1) {
        for (prev) |c| try out.append(arena, c & 0xff00ff00 | (c >> 16 & 0xff) | (c & 0xff) << 16);
        if (level == textures.mip_levels) break;
        const nw = @max(1, w / 2);
        const nh = @max(1, h / 2);
        const next = try arena.alloc(u32, nw * nh);
        for (0..nh) |y| for (0..nw) |x| {
            var sum: [4]f32 = @splat(0);
            for ([2]u32{ 0, 1 }) |dy| for ([2]u32{ 0, 1 }) |dx| {
                const c = prev[@min(y * 2 + dy, h - 1) * w + @min(x * 2 + dx, w - 1)];
                const a: f32 = @floatFromInt(c >> 24);
                sum[0] += a;
                for (0..3) |k| sum[k + 1] += a * @as(f32, @floatFromInt(c >> @intCast(16 - k * 8) & 0xff));
            };
            var c: u32 = @as(u32, @intFromFloat(@round(sum[0] / 4))) << 24;
            if (sum[0] > 0) for (0..3) |k| {
                c |= @as(u32, @intFromFloat(@round(sum[k + 1] / sum[0]))) << @intCast(16 - k * 8);
            };
            next[y * nw + x] = c;
        };
        prev = next;
        w = nw;
        h = nh;
    }
    return out.items;
}

fn deflate(arena: std.mem.Allocator, bytes: []const u8) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(arena);
    const window = try arena.alloc(u8, std.compress.flate.max_window_len);
    var c: std.compress.flate.Compress = try .init(&out.writer, window, .raw, .best);
    try c.writer.writeAll(bytes);
    try c.finish();
    return out.written();
}

fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
