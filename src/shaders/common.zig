//! What the world's shaders share: taking a vertex's packed information
//! apart (see mesher.zig's `Info`), a cheap wave for things that move, and
//! how light and fog are worked out from the scene's uniforms.

const gpu = @import("gpu");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

/// The world's shaders' uniforms (the sky's are its own).
pub const Scene = extern struct {
    /// Model, view and projection, column-major.
    mvp: [4]Vec4,
    /// xyz: the eye; w: the time, in seconds (wrapping every so often).
    camera: Vec4,
    /// xyz: towards the sun (or the moon, at night); w: how much daylight
    /// there is, 0 to 1.
    sun: Vec4,
    /// Light from the sun (or moon) on a face turned to it.
    sun_color: Vec4,
    /// rgb: light from the sky, on every face open to it; w: how bright
    /// lamps are.
    ambient: Vec4,
    /// rgb: the fog's colour (the horizon's); w: 1 / its depth.
    fog: Vec4,
    /// x: where the fog starts; y: the wind's strength; z: how high
    /// waves are; w: unused.
    misc: Vec4,
    /// The sky's colour overhead, which water reflects.
    zenith: Vec4,
};

pub const Info = struct {
    tile: f32,
    ao: f32,
    face: f32,
    sky: f32,
    lamp: f32,
    anim: f32,
};

/// The packed float, taken apart (each field is a power of two wide, so
/// this is exact).
pub fn unpack(info: f32) Info {
    const a = @floor(info * (1.0 / 64.0));
    const b = @floor(a * 0.25);
    const c = @floor(b * 0.125);
    const d = @floor(c * 0.0625);
    const e = @floor(d * 0.0625);
    const f = @floor(e * 0.25);
    return .{
        .tile = info - a * 64,
        .ao = a - b * 4,
        .face = b - c * 8,
        .sky = c - d * 16,
        .lamp = d - e * 16,
        .anim = e - f * 4,
    };
}

/// A smooth wave from -1 to 1 with a period of 1 (a parabola each half:
/// close to a sine, and much cheaper).
pub fn wave(x: f32) f32 {
    const p = (x - @floor(x)) * 2 - 1;
    return 4 * p * (1 - @abs(p));
}

/// Its slope: d/dp of 4p(1 - |p|) is 4 - 8|p|, and dp/dx is 2.
pub fn waveSlope(x: f32) f32 {
    const p = (x - @floor(x)) * 2 - 1;
    return 8 - 16 * @abs(p);
}

/// The normal of a cube's face (see blocks.Face: east, west, up, down,
/// south, north).
pub fn faceNormal(face: f32) Vec3 {
    const nx: f32 = if (face < 0.5) 1 else if (face < 1.5) -1 else 0;
    const ny: f32 = if (face < 1.5) 0 else if (face < 2.5) 1 else if (face < 3.5) -1 else 0;
    const nz: f32 = if (face < 3.5) 0 else if (face < 4.5) 1 else -1;
    return .{ nx, ny, nz };
}

/// How bright a light level (0 to 15) is: each step down is a fifth less.
pub fn level(l: f32) f32 {
    return @exp2((l - 15) * 0.32);
}

/// Lamps' warm light.
pub const lamp_color = Vec3{ 1.0, 0.78, 0.5 };

/// The light on a vertex of a face turned to `n`, with the sky's and
/// lamps' light levels there, as an RGB multiplier.
pub fn light(u: *addrspace(.uniform) const Scene, n: Vec3, sky: f32, lamp: f32) Vec3 {
    const sun = u.sun;
    const diffuse = @max(n[0] * sun[0] + n[1] * sun[1] + n[2] * sun[2], 0);
    // Faces are shaded a little by which way they face, whatever the
    // sun does, so the shape of things shows in the shade too.
    const facing = 0.8 + 0.2 * n[1] - 0.08 * @abs(n[2]);
    const s = level(sky);
    const l = @max(level(lamp) - 0.03, 0) * u.ambient[3];
    const amb = u.ambient;
    const sc = u.sun_color;
    return .{
        (amb[0] * facing + sc[0] * diffuse) * s + lamp_color[0] * l,
        (amb[1] * facing + sc[1] * diffuse) * s + lamp_color[1] * l,
        (amb[2] * facing + sc[2] * diffuse) * s + lamp_color[2] * l,
    };
}

/// How much fog there is at a distance: none up close, all of it at the
/// far end.
pub fn fogAmount(u: *addrspace(.uniform) const Scene, dist: f32) f32 {
    const f = gpu.clamp((dist - u.misc[0]) * u.fog[3], 0, 1);
    return f * (2 - f);
}

pub fn project(u: *addrspace(.uniform) const Scene, p: Vec3) Vec4 {
    const m = u.mvp;
    return m[0] * gpu.splat4(p[0]) + m[1] * gpu.splat4(p[1]) + m[2] * gpu.splat4(p[2]) + m[3];
}
