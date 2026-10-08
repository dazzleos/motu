//! Solid blocks, bump mapped: as terrain.zig, but the sun lights each
//! pixel by the tile's normal map (texture unit 1), so the grain of wood,
//! the mortar between bricks and the cracks in stone catch the light, and
//! turn with it through the day.
//!
//! The normal map is in each face's own frame (x across the tile, y down
//! it, z out of the face), so the vertex shader turns the sun into that
//! frame instead of the fragment shader turning every normal into the
//! world. What does not depend on the normal (the sky's light, lamps,
//! ambient occlusion and fog) is summed per vertex as before, leaving the
//! fragment shader three texture reads, a dot product and a few
//! multiply-adds.
//!
//! Up close, a third texture adds fine detail (textures.detail): grains
//! of sand finer than the tile's texels, wood's fibres, the grit of stone.
//! It leans the normal a little, and lightens or darkens, more or less and
//! stretched one way or not by the tile's kind of detail. It fades out a
//! few blocks away, and the bumps themselves further off, by `bump_far`,
//! where the renderer draws chunks with terrain.zig instead (with the
//! tiles' plain colours, so they look the same there).

const gpu = @import("gpu");
const common = @import("common.zig");
const Vec2 = gpu.Vec2;
const Vec3 = gpu.Vec3;

const u = gpu.uniforms(common.Scene);

const in_pos = gpu.vertexInput(Vec3, 0);
const in_uv = gpu.vertexInput(Vec2, 1);
const in_info = gpu.vertexInput(f32, 2);

const v_uv = gpu.vertexOutput(Vec2, 0);
const v_light = gpu.vertexOutput(Vec3, 1);
const v_sun = gpu.vertexOutput(Vec3, 2);
const v_fog = gpu.vertexOutput(f32, 3);
/// Where on the detail texture (x, y), and how strong it is (z).
const v_detail = gpu.vertexOutput(Vec3, 4);

/// Fine detail is drawn fully up to `detail_near` blocks away, and not at
/// all from `detail_far`; the bumps alike, to `bump_far` (renderer.zig's
/// `near_distance`).
const detail_near: f32 = 5;
const detail_far: f32 = 12;
const bump_near: f32 = 24;
const bump_far: f32 = 32;

/// Which way across a face (s) and down it (t) run, as mesher.zig's uvOf
/// lays tiles out.
fn across(face: f32) Vec3 {
    if (face < 0.5) return .{ 0, 0, -1 }; // east
    if (face < 1.5) return .{ 0, 0, 1 }; // west
    if (face < 3.5) return .{ 1, 0, 0 }; // up, down
    if (face < 4.5) return .{ 1, 0, 0 }; // south
    return .{ -1, 0, 0 }; // north
}

fn down(face: f32) Vec3 {
    if (face > 1.5 and face < 3.5) return .{ 0, 0, 1 }; // up, down
    return .{ 0, -1, 0 };
}

fn dot(a: Vec3, b: Vec3) f32 {
    return a[0] * b[0] + a[1] * b[1] + a[2] * b[2];
}

export fn vertex() callconv(.spirv_vertex) void {
    const info = common.unpack(in_info.*);
    var p = in_pos.*;
    const sway = 0.035 * info.anim * info.anim * u.misc[1];
    const t = u.camera[3];
    const phase = t * 0.9 + p[0] * 0.31 + p[2] * 0.23;
    p[0] += common.wave(phase) * sway;
    p[2] += common.wave(phase * 0.8 + 0.35) * sway * 0.7;
    gpu.position.* = common.project(u, p);

    const n = common.faceNormal(info.face);
    const ao = 1 - info.ao * 0.19;
    const cam = u.camera;
    const d = Vec3{ p[0] - cam[0], p[1] - cam[1], p[2] - cam[2] };
    const dist = gpu.length(d);
    const fog = common.fogAmount(u, dist);
    const keep = ao * (1 - fog);

    // Everything but the sun, as terrain.zig.
    const facing = 0.8 + 0.2 * n[1] - 0.08 * @abs(n[2]);
    const s = common.level(info.sky);
    const l = @max(common.level(info.lamp) - 0.03, 0) * u.ambient[3];
    const amb = u.ambient;
    const lc = common.lamp_color;
    v_light.* = .{
        (amb[0] * facing * s + lc[0] * l) * keep,
        (amb[1] * facing * s + lc[1] * l) * keep,
        (amb[2] * facing * s + lc[2] * l) * keep,
    };
    // The sun in the face's frame, scaled by how much of it reaches here
    // (the sun's colour is applied per pixel, from the uniforms).
    const sun = Vec3{ u.sun[0], u.sun[1], u.sun[2] };
    const k = s * keep;
    const bumps = gpu.clamp((bump_far - dist) * (1.0 / (bump_far - bump_near)), 0, 1) * k;
    const ac = across(info.face);
    const dn = down(info.face);
    v_sun.* = .{ dot(sun, ac) * bumps, dot(sun, dn) * bumps, dot(sun, n) * k };

    // Detail: grain four times a block, streaks drawn out across, rough
    // grit twice a block and stronger.
    const kind = info.detail;
    const su: f32 = if (kind < 1.5) 4 else if (kind < 2.5) 0.75 else 2.5;
    const sv: f32 = if (kind < 1.5) 4 else if (kind < 2.5) 9 else 2.5;
    const amp: f32 = if (kind < 0.5) 0 else if (kind < 1.5) 0.6 else if (kind < 2.5) 0.35 else 0.9;
    const near = gpu.clamp((detail_far - dist) * (1.0 / (detail_far - detail_near)), 0, 1);
    v_detail.* = .{ dot(p, ac) * su, dot(p, dn) * sv, amp * near };
    v_fog.* = fog;
    v_uv.* = in_uv.*;
}

const f_uv = gpu.fragmentInput(Vec2, 0);
const f_light = gpu.fragmentInput(Vec3, 1);
const f_sun = gpu.fragmentInput(Vec3, 2);
const f_fog = gpu.fragmentInput(f32, 3);
const f_detail = gpu.fragmentInput(Vec3, 4);

export fn fragment() callconv(.spirv_fragment) void {
    const t = gpu.texture(f_uv.*);
    const nm = gpu.texture1(f_uv.*);
    const dt = f_detail.*;
    const fine = gpu.texture2(.{ dt[0], dt[1] });
    const a = dt[2];
    const ls = f_sun.*;
    const nx = nm[0] * 2 - 1 + (fine[0] * 2 - 1) * a;
    const ny = nm[1] * 2 - 1 + (fine[1] * 2 - 1) * a;
    const nz = nm[2] * 2 - 1;
    const lit = @max(nx * ls[0] + ny * ls[1] + nz * ls[2], 0);
    const shade = 1 + (fine[2] - 0.5) * a;
    // What tilts away from the face sees less of the sky, so the shape
    // shows in the shade too.
    const l = f_light.*;
    const sc = u.sun_color;
    const fog = f_fog.*;
    const fc = u.fog;
    gpu.color.* = .{
        t[0] * shade * (l[0] * nz + sc[0] * lit) + fc[0] * fog,
        t[1] * shade * (l[1] * nz + sc[1] * lit) + fc[1] * fog,
        t[2] * shade * (l[2] * nz + sc[2] * lit) + fc[2] * fog,
        t[3],
    };
}
