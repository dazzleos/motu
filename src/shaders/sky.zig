//! The sky: a dome around the eye, always as far away, coloured from the
//! horizon up to the zenith, with the sun's disc and glow and, at night,
//! the moon. Drawn after the blocks (with early Z, only where they left
//! the sky showing), so its per-pixel work is only done where it shows.

const gpu = @import("gpu");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Uniforms = extern struct {
    /// Projection and the view's turn (not its move: the sky is always
    /// around the eye), column-major.
    turn: [4]Vec4,
    /// xyz: towards the sun; w: how much of it shows (0 below the horizon).
    sun: Vec4,
    sun_color: Vec4,
    /// xyz: towards the moon; w: how much of it shows.
    moon: Vec4,
    zenith: Vec4,
    horizon: Vec4,
};
const u = gpu.uniforms(Uniforms);

const in_dir = gpu.vertexInput(Vec3, 0);
const v_sun = gpu.vertexOutput(Vec3, 0);
const v_color = gpu.vertexOutput(Vec3, 1);

/// How far away the dome is (within the camera's far plane).
const radius = 150.0;

export fn vertex() callconv(.spirv_vertex) void {
    const d = in_dir.*;
    const m = u.turn;
    gpu.position.* = m[0] * gpu.splat4(d[0] * radius) + m[1] * gpu.splat4(d[1] * radius) + m[2] * gpu.splat4(d[2] * radius) + m[3];

    const sun = u.sun;
    const moon = u.moon;
    const body = if (sun[3] >= moon[3]) Vec3{ sun[0], sun[1], sun[2] } else Vec3{ moon[0], moon[1], moon[2] };
    v_sun.* = .{ d[0] - body[0], d[1] - body[1], d[2] - body[2] };

    const up = @sqrt(gpu.clamp(d[1], 0, 1));
    const z = u.zenith;
    const h = u.horizon;
    const cs = d[0] * sun[0] + d[1] * sun[1] + d[2] * sun[2];
    const glow = @exp2((cs - 1) * 12) * 0.45 * sun[3];
    const sc = u.sun_color;
    v_color.* = .{
        h[0] + (z[0] - h[0]) * up + sc[0] * glow,
        h[1] + (z[1] - h[1]) * up + sc[1] * glow,
        h[2] + (z[2] - h[2]) * up + sc[2] * glow,
    };
}

const f_sun = gpu.fragmentInput(Vec3, 0);
const f_color = gpu.fragmentInput(Vec3, 1);

export fn fragment() callconv(.spirv_fragment) void {
    const ds = f_sun.*;
    const d2 = ds[0] * ds[0] + ds[1] * ds[1] + ds[2] * ds[2];
    // Tight corona and the sun or moon's disc, from squared chord distance
    // (d2 = 2 * (1 - cos(angle))).
    const corona = gpu.clamp(1 - d2 * 33, 0, 1);
    const disc = gpu.clamp((0.0014 - d2) * 1500, 0, 1);
    const s = (disc * 3 + corona * corona * 0.5) * u.sun[3];
    const m = disc * u.moon[3] * 0.9;
    const base = f_color.*;
    const sc = u.sun_color;
    gpu.color.* = .{
        base[0] + sc[0] * s + m,
        base[1] + sc[1] * s + m,
        base[2] + sc[2] * s + m * 0.95,
        1,
    };
}
