//! The world, drawn smaller (see upscale.zig), stretched over the view.

const gpu = @import("gpu");

const in_pos = gpu.vertexInput(gpu.Vec2, 0);
const in_uv = gpu.vertexInput(gpu.Vec2, 1);
const v_uv = gpu.vertexOutput(gpu.Vec2, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    gpu.position.* = .{ p[0], p[1], 0, 1 };
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(gpu.Vec2, 0);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    gpu.color.* = gpu.texture(f_uv.*);
}
