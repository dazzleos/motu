//! What the water shader works out per vertex (water.zig): waves moving across
//! the surface (the vertices rise and fall: a little chop everywhere, and
//! outside the atoll's reef a long swell a block from trough to crest; the
//! sea's beyond the world's edge fade to flat further out, where its quads
//! are big), shallows clear
//! and turquoise and the deep dark blue, the sky reflected more at a
//! glancing angle (Fresnel), and fog.

const gpu = @import("gpu");
const common = @import("common.zig");
const Vec3 = gpu.Vec3;
const Vec4 = gpu.Vec4;

const Scene = *addrspace(.uniform) const common.Scene;

/// The world's size across (world.zig's size_x and size_z), and the
/// atoll's reef's radius round its middle (world.zig's atoll_radius).
const world_size = 256.0;
const atoll_radius = 86.0;

const shallow = Vec3{ 0.12, 0.62, 0.62 };
const deep = Vec3{ 0.02, 0.16, 0.34 };

/// The waves' height at a place, and its slope (x and z).
fn waves(x: f32, z: f32, t: f32) Vec3 {
    const a = x * 0.17 + t * 0.32 + z * 0.06;
    const b = z * 0.21 - t * 0.27 + x * 0.05;
    const h = 0.65 * common.wave(a) + 0.45 * common.wave(b);
    const sa = common.waveSlope(a);
    const sb = common.waveSlope(b);
    const dx = 0.65 * sa * 0.17 + 0.45 * sb * 0.05;
    const dz = 0.65 * sa * 0.06 + 0.45 * sb * 0.21;
    return .{ h, dx, dz };
}

/// The ocean's swell at a place: long waves rolling in from one way; its
/// height (from -1 to 1) and slope.
fn swell(x: f32, z: f32, t: f32) Vec3 {
    const a = x * 0.055 + z * 0.032 - t * 0.19;
    const slope = common.waveSlope(a);
    return .{ common.wave(a), slope * 0.055, slope * 0.032 };
}

pub const Surface = struct {
    /// Where it is, after the waves.
    pos: Vec3,
    /// Its normal, tilted by the waves.
    normal: Vec3,
    /// Towards the eye, and how far.
    to_eye: Vec3,
    dist: f32,
    /// The normal against `to_eye`: below 0 seen from under the water.
    facing: f32,
    /// Its colour, the sky's reflection in it, fogged; and how opaque
    /// (without the sun's glint).
    color: Vec4,
    fog: f32,
};

/// A vertex of water, `info` its packed information (see mesher.Info).
pub fn surface(u: Scene, in_pos: Vec3, info: common.Info) Surface {
    var p = in_pos;
    const t = u.camera[3];
    // Waves only on the surface (3), fading out past the world's edge;
    // the swell only outside the reef, coming in over a dozen blocks.
    const out = @max(@max(-p[0], p[0] - world_size), @max(-p[2], p[2] - world_size));
    const on = (if (info.anim > 2.5) @as(f32, 1) else 0) * gpu.clamp(1 - out * (1.0 / 16.0), 0, 1);
    const cx = p[0] - world_size * 0.5;
    const cz = p[2] - world_size * 0.5;
    // (By the distance squared: from 90 blocks out to 102.)
    const ocean = gpu.clamp((cx * cx + cz * cz - (atoll_radius + 4) * (atoll_radius + 4)) * (1.0 / (102.0 * 102.0 - 90.0 * 90.0)), 0, 1);
    const amp = u.misc[2] * on;
    const swell_amp = u.misc[3] * on * ocean;
    const chop = waves(p[0], p[2], t);
    const sw = swell(p[0], p[2], t);
    p[1] += chop[0] * amp + sw[0] * swell_amp;
    const w = Vec3{ 0, chop[1] * amp + sw[1] * swell_amp, chop[2] * amp + sw[2] * swell_amp };

    const flat = common.faceNormal(info.face);
    const n = gpu.normalize(Vec3{ flat[0] - w[1] * flat[1], flat[1], flat[2] - w[2] * flat[1] });
    const cam = u.camera;
    const to_eye = Vec3{ cam[0] - p[0], cam[1] - p[1], cam[2] - p[2] };
    const dist = gpu.length(to_eye);
    const v = to_eye / gpu.splat3(dist);
    // From below (underwater, looking up), the other side faces us.
    const nv = n[0] * v[0] + n[1] * v[1] + n[2] * v[2];
    const k = 1 - @abs(nv);
    const fresnel = k * k * k;
    const depth = gpu.clamp(info.tile * (1.0 / 7.0), 0, 1);
    const base = Vec3{
        shallow[0] + (deep[0] - shallow[0]) * depth,
        shallow[1] + (deep[1] - shallow[1]) * depth,
        shallow[2] + (deep[2] - shallow[2]) * depth,
    };
    const lit = common.light(u, Vec3{ 0, 1, 0 }, info.sky, info.lamp);
    const z = u.zenith;
    const reflect = 0.25 + 0.65 * fresnel;
    var col = Vec3{
        base[0] * lit[0] * (1 - reflect) + z[0] * reflect,
        base[1] * lit[1] * (1 - reflect) + z[1] * reflect,
        base[2] * lit[2] * (1 - reflect) + z[2] * reflect,
    };
    var alpha = gpu.clamp(0.42 + depth * 0.45 + fresnel * 0.4, 0, 0.96);
    // Far off, it fades into the fog, solid (hiding where the sea bed
    // stops).
    const fog = common.fogAmount(u, dist);
    const fc = u.fog;
    col = .{ col[0] + (fc[0] - col[0]) * fog, col[1] + (fc[1] - col[1]) * fog, col[2] + (fc[2] - col[2]) * fog };
    alpha = alpha + (1 - alpha) * fog;
    return .{
        .pos = p,
        .normal = n,
        .to_eye = v,
        .dist = dist,
        .facing = nv,
        .color = .{ col[0], col[1], col[2], alpha },
        .fog = fog,
    };
}

/// How strongly the sun glints, before its colour: 1.6 at its brightest,
/// none seen from below, and fogged.
pub fn glintStrength(u: Scene, s: Surface) f32 {
    return if (s.facing > 0) 1.6 * u.sun[3] * (1 - s.fog) else 0;
}
