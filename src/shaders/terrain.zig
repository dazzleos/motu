//! Blocks: their faces textured from the atlas, lit per vertex (sun and
//! sky, lamps, ambient occlusion) and fogged with distance; leaves and
//! plants sway in the wind. Built twice: opaque, and blended (flames and
//! plants, whose tiles have see-through pixels).
//!
//! The fragment shader is kept to a texture read and a multiply-add: it
//! runs for every pixel, where the vertex shader runs four times a quad.
//! The texture unit does the rest: the tiles are 64 pixels, in strips one
//! tile wide that it repeats across a face, filtered smoothly up close and
//! from mipmaps further off (see textures.zig and mesher.zig).

const gpu = @import("gpu");
const common = @import("common.zig");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;

const u = gpu.uniforms(common.Scene);

/// mesher.zig's `nudge`.
const mesher_nudge: f32 = 1.0 / 4096.0;

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_info = gpu.vertexInput(f32, 2);

const v_uv = gpu.vertexOutput(Vec2, 0);
const v_light = gpu.vertexOutput(Vec3, 1);
const v_fog = gpu.vertexOutput(f32, 2);

export fn vertex() callconv(.spirv_vertex) void {
    const info = common.unpack(in_info.*);
    var p = in_pos.*;
    // Leaves (1) sway a little, plants' tops (2) more; the same at the
    // same place, so neighbours stay joined.
    const sway = 0.035 * info.anim * info.anim * u.misc[1];
    const t = u.camera[3];
    // Slowly, as a breeze moves them.
    const phase = t * 0.4 + p[0] * 0.31 + p[2] * 0.23;
    p[0] += common.wave(phase) * sway;
    p[2] += common.wave(phase * 0.8 + 0.35) * sway * 0.7;
    // A solid face's corner, nudged out across it from whole blocks (see
    // mesher.zig's `nudged`), moved on that way by an eighth of a pixel
    // however far away (the further, the more), so faces overlap and leave
    // no cracks. Kept cheap, as the GPU runs it for every corner twice:
    // the way from the distance to the nearest whole block (positions are
    // never below zero, so that is a truncation); how far away, roughly
    // (along the axes, added up). Anything else (a plant's leaf, say) is
    // moved no more than that eighth of a pixel.
    const whole = Vec3{ @trunc(p[0] + 0.5), @trunc(p[1] + 0.5), @trunc(p[2] + 0.5) };
    const scale: f32 = 1.0 / mesher_nudge;
    const way = Vec3{
        gpu.clamp((p[0] - whole[0]) * scale, -1, 1),
        gpu.clamp((p[1] - whole[1]) * scale, -1, 1),
        gpu.clamp((p[2] - whole[2]) * scale, -1, 1),
    };
    const cam0 = u.camera;
    const away = @abs(p[0] - cam0[0]) + @abs(p[1] - cam0[1]) + @abs(p[2] - cam0[2]);
    const grow = away * u.zenith[3];
    p = Vec3{ p[0] + way[0] * grow, p[1] + way[1] * grow, p[2] + way[2] * grow };
    gpu.position.* = common.project(u, p);

    const n = common.faceNormal(info.face);
    const ao = 1 - info.ao * 0.19;
    const lit = common.light(u, n, info.sky, info.lamp);
    const cam = u.camera;
    const d = Vec3{ p[0] - cam[0], p[1] - cam[1], p[2] - cam[2] };
    const fog = common.fogAmount(u, gpu.length(d));
    const keep = ao * (1 - fog);
    v_light.* = .{ lit[0] * keep, lit[1] * keep, lit[2] * keep };
    v_fog.* = fog;
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_light = gpu.fragmentInput(Vec3, 1);
const f_fog = gpu.fragmentInput(f32, 2);

export fn fragment() callconv(.{ .spirv_fragment = .{} }) void {
    const t = gpu.texture(f_uv.*);
    const l = f_light.*;
    const fog = f_fog.*;
    const fc = u.fog;
    gpu.color.* = .{ t[0] * l[0] + fc[0] * fog, t[1] * l[1] + fc[1] * fog, t[2] * l[2] + fc[2] * fog, t[3] };
}
