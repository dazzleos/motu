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
    const args = try init.minimal.args.toSlice(arena);
    if (args.len != 2 + textures.strip_count) {
        std.debug.print("usage: mktiles <strip-0.bin> .. <strip-3.bin> <icons.bin>\n", .{});
        std.process.exit(2);
    }
    const cwd = std.Io.Dir.cwd();
    const px = try arena.alloc(u32, textures.strip_width * textures.strip_height);
    for (0..textures.strip_count) |i| {
        textures.strips(@intCast(i), px[0 .. textures.strip_width * textures.strip_height]);
        // In 16 bits a texel (see textures.stripSeeThrough).
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
