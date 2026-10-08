//! Water as water.zig, with ripples per pixel: a normal map of small
//! waves (textures.ripples), read twice at different sizes and drifting
//! different ways, so the pattern never repeats as it moves. The ripples
//! lean the surface's normal, so the sun glints off each one, and the
//! surface shimmers lighter and darker. They fade out further off, where
//! they would only shimmer.
//!
//! The glint is worked out against the half-way vector between the eye
//! and the sun (Blinn's), which the vertex shader works out with the
//! waves' normal, so the fragment shader needs only a dot product and a
//! few squarings: the ripples lean the normal across the surface (x and
//! z), which is only added to the dot product.

const gpu = @import("gpu");
const common = @import("common.zig");
const water = @import("water_common.zig");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const u = gpu.uniforms(common.Scene);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_info = gpu.vertexInput(f32, 2);

const v_color = gpu.vertexOutput(Vec4, 0);
/// Where on the ripple texture, twice.
const v_ripples = gpu.vertexOutput(Vec4, 1);
/// The half-way vector, its x and z scaled by how strong the ripples are
/// here; w: how strongly the sun glints.
const v_half = gpu.vertexOutput(Vec4, 2);
/// How much the ripples lighten and darken.
const v_shimmer = gpu.vertexOutput(f32, 3);

/// Ripples are drawn fully up to `ripple_near` blocks away, and not at all
/// from `ripple_far`.
const ripple_near: f32 = 24;
const ripple_far: f32 = 56;

export fn vertex() callconv(.spirv_vertex) void {
    const s = water.surface(u, in_pos.*, common.unpack(in_info.*));
    const p = s.pos;
    gpu.position.* = common.project(u, p);
    v_color.* = s.color;

    const t = u.camera[3];
    v_ripples.* = .{
        p[0] * 0.23 + t * 0.031,
        p[2] * 0.23 + t * 0.019,
        p[0] * 0.41 + 0.37 - t * 0.024,
        p[2] * 0.41 + t * 0.036,
    };
    const sun = u.sun;
    const e = s.to_eye;
    const h = gpu.normalize(Vec3{ e[0] + sun[0], e[1] + sun[1], e[2] + sun[2] });
    const n = s.normal;
    const amp = gpu.clamp((ripple_far - s.dist) * (1.0 / (ripple_far - ripple_near)), 0, 1);
    v_half.* = .{ h[0] * amp, n[0] * h[0] + n[1] * h[1] + n[2] * h[2], h[2] * amp, water.glintStrength(u, s) * 0.7 };
    v_shimmer.* = amp * 0.22 * (1 - s.fog);
}

const f_color = gpu.fragmentInput(Vec4, 0);
const f_ripples = gpu.fragmentInput(Vec4, 1);
const f_half = gpu.fragmentInput(Vec4, 2);
const f_shimmer = gpu.fragmentInput(f32, 3);

export fn fragment() callconv(.spirv_fragment) void {
    const rc = f_ripples.*;
    const a = gpu.texture(.{ rc[0], rc[1] });
    const b = gpu.texture(.{ rc[2], rc[3] });
    // The two normals' lean, averaged ((a * 2 - 1 + b * 2 - 1) / 2), and
    // gentled.
    const rx = (a[0] + b[0] - 1) * 0.6;
    const rz = (a[1] + b[1] - 1) * 0.6;
    const h = f_half.*;
    var g = @max(h[1] + rx * h[0] + rz * h[2], 0);
    // To the 128th power: a small, sharp glint on each ripple.
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g;
    g = g * g * h[3];
    const lift = 1 + (rx - rz) * f_shimmer.*;
    const c = f_color.*;
    const sc = u.sun_color;
    gpu.color.* = .{
        c[0] * lift + sc[0] * g,
        c[1] * lift + sc[1] * g,
        c[2] * lift + sc[2] * g,
        @min(c[3] + g, 1),
    };
}
