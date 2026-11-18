//! Motu, a game of building islands out of blocks, for Dazzle: built with
//! Dazzle's modules and tools (see Dazzle's build.zig, `addApp`).
//!
//!     zig build                 the program, and its archive and catalogue (zig-out/apps)
//!     zig build test            its tests, on this computer
//!     zig build -Dplatform=linux  for Linux (Wayland and Vulkan): see src/linux.zig
//!
//! With a Dazzle (or kete) checkout of your own beside it:
//! `zig build --fork=../dazzle`.

const std = @import("std");
const dazzle = @import("dazzle");

pub fn build(b: *std.Build) void {
    const app = dazzle.addApp(b, .{
        .name = "motu",
        .icon = .landscape,
        .title = "Motu",
        .description = "Build islands out of blocks",
        .about = "Build on a tropical atoll of blocks: shape the islands, build huts, paddle a canoe across the lagoon, and look out to sea with a telescope. Islands are kept between games, and friends on the same network can play on yours.",
        // Blocks (solid, then glass and plants blended), water, the sky,
        // the outline of the block picked, and the world drawn smaller
        // stretched over the view.
        .shaders = &.{
            .{ .source = "src/shaders/terrain.zig", .args = &.{"--depth-test"} },
            .{ .source = "src/shaders/terrain.zig", .name = "terrain_blend", .args = &.{ "--depth-test", "--blend=source-over" } },
            .{ .source = "src/shaders/water.zig", .args = &.{ "--depth-test", "--blend=source-over" } },
            .{ .source = "src/shaders/sky.zig", .args = &.{"--depth-test"} },
            .{ .source = "src/shaders/upscale.zig" },
            .{ .source = "src/shaders/line.zig", .args = &.{"--depth-test"} },
        },
    });

    // The tiles (each strip as the GPU takes it, with its mipmaps,
    // deflated) and the palette's icons, drawn at build time (see
    // tools/mktiles.zig): `@embedFile("tiles-<n>.bin")` and
    // `@embedFile("icons.bin")`.
    const mktiles = b.addExecutable(.{
        .name = "mktiles",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mktiles.zig"),
            .target = b.graph.host,
            // Hundreds of thousands of noisy pixels: seconds unoptimized.
            .optimize = .ReleaseFast,
            .imports = &.{
                .{ .name = "textures", .module = b.createModule(.{ .root_source_file = b.path("src/textures.zig") }) },
                .{ .name = "texture", .module = b.createModule(.{ .root_source_file = app.dazzle.path("src/vc4/texture.zig") }) },
            },
        }),
    });
    const run = b.addRunArtifact(mktiles);
    // For Vulkan: plain RGBA, each level after the one before.
    if (app.platform == .linux) run.addArg("--linear");
    var files: [5]std.Build.LazyPath = undefined;
    for (0..4) |i| files[i] = run.addOutputFileArg(b.fmt("tiles-{d}.bin", .{i}));
    files[4] = run.addOutputFileArg("icons.bin");
    for ([_]*std.Build.Module{ app.module, app.host_module }) |m| {
        for (0..4) |i| m.addAnonymousImport(b.fmt("tiles-{d}.bin", .{i}), .{ .root_source_file = files[i] });
        m.addAnonymousImport("icons.bin", .{ .root_source_file = files[4] });
    }

    // Each shader's render state, for the Vulkan backend (on Dazzle, the
    // shader compiler builds it into the program):
    // `@import("shader_state").<name>`.
    var state: std.Io.Writer.Allocating = .init(b.allocator);
    for (app.shaders) |sh| {
        var depth_test = false;
        var blend = false;
        for (sh.args) |a| {
            if (std.mem.eql(u8, a, "--depth-test")) depth_test = true;
            if (std.mem.eql(u8, a, "--blend=source-over")) blend = true;
        }
        state.writer.print("pub const {s} = .{{ .depth_test = {}, .blend = {} }};\n", .{ sh.name, depth_test, blend }) catch @panic("OOM");
    }
    const state_file = b.addWriteFiles().add("shader_state.zig", state.written());
    app.module.addAnonymousImport("shader_state", .{ .root_source_file = state_file });
}
