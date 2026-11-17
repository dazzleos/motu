//! Makes Motu's tiles and icons at build time, so the game does not spend
//! its start drawing them (see src/apps/motu/textures.zig): each strip of
//! tiles as the GPU takes it, mipmaps and all (vc4.texture.uploadMipmaps's
//! layout), and the palette's icons, one after another (0xAARRGGBB, little
//! endian).
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
    const layout = texture.mipmapLayout(textures.strip_width, textures.strip_height, textures.mip_levels);
    const out = try arena.alloc(u8, layout.size);
    for (0..textures.strip_count) |i| {
        textures.strips(@intCast(i), px[0 .. textures.strip_width * textures.strip_height]);
        @memset(out, 0);
        try texture.uploadMipmaps(arena, out, px, textures.strip_width, textures.strip_height, textures.mip_levels, .colour);
        try write(init.io, cwd, args[1 + i], out);
    }
    const icons = try arena.alloc(u32, textures.palette.len * textures.icon_size * textures.icon_size);
    for (textures.palette, 0..) |b, i| textures.icon(b, icons[i * textures.icon_size * textures.icon_size ..][0 .. textures.icon_size * textures.icon_size]);
    try write(init.io, cwd, args[1 + textures.strip_count], std.mem.sliceAsBytes(icons));
}

fn write(io: std.Io, dir: std.Io.Dir, path: []const u8, bytes: []const u8) !void {
    const file = try dir.createFile(io, path, .{});
    defer file.close(io);
    try file.writeStreamingAll(io, bytes);
}
