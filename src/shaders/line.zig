//! Lines in one colour: the outline of the block picked.

const gpu = @import("gpu");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    mvp: [4]Vec4,
    color: Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_pos = gpu.vertexInput(Vec3, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const p = in_pos.*;
    const m = u.mvp;
    gpu.position.* = m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
}

export fn fragment() callconv(.spirv_fragment) void {
    gpu.color.* = u.color;
}
