//! Water, and the sea around the world, all per vertex (see
//! water_common.zig), with the sun glinting on the waves: the fragment
//! shader only passes the colour on, so water costs little more to fill
//! than to blend. Drawn so with bump mapping off; water_ripples.zig adds
//! ripples per pixel.

const gpu = @import("gpu");
const common = @import("common.zig");
const water = @import("water_common.zig");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const u = gpu.uniforms(common.Scene);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_info = gpu.vertexInput(f32, 2);

const v_color = gpu.vertexOutput(Vec4, 0);

export fn vertex() callconv(.spirv_vertex) void {
    const s = water.surface(u, in_pos.*, common.unpack(in_info.*));
    gpu.position.* = common.project(u, s.pos);
    // The sun's reflection: the eye's direction mirrored in the surface,
    // against the sun's (sharpened by squaring).
    const sun = u.sun;
    const n = s.normal;
    const r = n * gpu.splat3(2 * s.facing) - s.to_eye;
    var g = @max(r[0] * sun[0] + r[1] * sun[1] + r[2] * sun[2], 0);
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g * water.glintStrength(u, s);
    const sc = u.sun_color;
    const c = s.color;
    v_color.* = .{ c[0] + sc[0] * g, c[1] + sc[1] * g, c[2] + sc[2] * g, @min(c[3] + g, 1) };
}

const f_color = gpu.fragmentInput(Vec4, 0);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    gpu.color.* = f_color.*;
}
