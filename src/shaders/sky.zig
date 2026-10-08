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
const v_dir = gpu.vertexOutput(Vec3, 0);

/// How far away the dome is (within the camera's far plane).
const radius = 150.0;

export fn vertex() callconv(.spirv_vertex) void {
    const d = in_dir.*;
    const m = u.turn;
    gpu.position.* = m[0] * gpu.splat4(d[0] * radius) + m[1] * gpu.splat4(d[1] * radius) + m[2] * gpu.splat4(d[2] * radius) + m[3];
    v_dir.* = d;
}

/// Stars: a few of the sky's tiny cells (by direction), lit at random.
fn stars(d: Vec3) f32 {
    const k = 260.0;
    const c = Vec3{ @floor(d[0] * k), @floor(d[1] * k), @floor(d[2] * k) };
    // A hash of the cell (fractions of products: cheap, and random enough
    // to look it).
    var p = Vec3{ c[0] * 0.1031, c[1] * 0.1030, c[2] * 0.0973 };
    p = p - Vec3{ @floor(p[0]), @floor(p[1]), @floor(p[2]) };
    const q = p[0] * (p[1] + 33.33) + p[1] * (p[2] + 33.33) + p[2] * (p[0] + 33.33);
    const h0 = (p[0] + q) * (p[2] + q);
    const h = h0 - @floor(h0);
    // One cell in a hundred or so, brighter or dimmer, above the horizon.
    return gpu.clamp((h - 0.988) * 70, 0, 0.9) * gpu.clamp(d[1] * 4, 0, 1);
}

const f_dir = gpu.fragmentInput(Vec3, 0);

export fn fragment() callconv(.spirv_fragment) void {
    const d = gpu.normalize(f_dir.*);
    const up = @sqrt(gpu.clamp(d[1], 0, 1));
    const z = u.zenith;
    const h = u.horizon;
    const sun = u.sun;
    const cs = d[0] * sun[0] + d[1] * sun[1] + d[2] * sun[2];
    // A wide glow, and the disc itself.
    const glow = @exp2((cs - 1) * 12) * 0.45 + @exp2((cs - 1) * 300) * 0.5;
    const disc = gpu.clamp((cs - 0.9993) * 3000, 0, 1) * 3;
    const s = (glow + disc) * sun[3];
    const moon = u.moon;
    const cm = d[0] * moon[0] + d[1] * moon[1] + d[2] * moon[2];
    const m = gpu.clamp((cm - 0.9995) * 4000, 0, 1) * moon[3] * 0.9 + stars(d) * moon[3];
    const sc = u.sun_color;
    gpu.color.* = .{
        h[0] + (z[0] - h[0]) * up + sc[0] * s + m,
        h[1] + (z[1] - h[1]) * up + sc[1] * s + m,
        h[2] + (z[2] - h[2]) * up + sc[2] * s + m * 0.95,
        1,
    };
}
