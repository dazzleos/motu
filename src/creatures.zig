//! Birds in the air over the island, fish in the sea around it, and,
//! much rarer, turtles in the shallows and sharks in deeper water: how
//! they move (flocking, circling, turning from the shore and rising over
//! hills and trees) and how they are turned into quads of `mesher.Vertex`
//! drawn from the colour strip (strip 2).

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const mesher = @import("mesher.zig");
const math = @import("math.zig");

const Block = blocks.Block;
const Tile = blocks.Tile;
const Face = blocks.Face;
const World = world_mod.World;
const Vertex = mesher.Vertex;
const V3 = math.V3;

pub const bird_count = 24;
pub const fish_count = 40;
pub const turtle_count = 3;
pub const shark_count = 2;
/// Enough for every creature in view at once (each is under 40 quads),
/// and the seaplane.
pub const max_quads = (bird_count + fish_count + turtle_count + shark_count) * 40 + 120;

pub const BirdKind = enum(u2) {
    /// White with grey-shaded wings, black wingtips and an orange beak;
    /// wheels over the shore and sea.
    gull,
    /// Blue back and wings, warm orange breast.
    bluebird,
    /// Bright red with black wings and tail.
    cardinal,
    /// Golden yellow with black wings and tail.
    goldfinch,
};

pub const FishKind = enum(u2) {
    /// Orange with a white band across the middle.
    clownfish,
    /// Blue with a yellow tail and fins.
    tang,
    /// Golden yellow with orange-red fins.
    goldfish,
    /// Coral pink with cyan fins.
    reef,
};

pub const Bird = struct {
    pos: V3,
    yaw: f32,
    pitch: f32 = 0,
    roll: f32 = 0,
    speed: f32 = 5.5,
    /// Wingbeat phase, in radians.
    phase: f32 = 0,
    /// 0 while flapping hard, 1 while gliding with wings spread.
    glide: f32 = 0,
    /// The place it circles around, and how wide and high.
    home: [2]f32,
    orbit: f32,
    cruise_y: f32,
    /// +1 or -1: which way round its circle it goes.
    turn_dir: f32,
    flock: u8,
    kind: BirdKind,
};

pub const Fish = struct {
    pos: V3,
    yaw: f32,
    pitch: f32 = 0,
    speed: f32 = 2.0,
    /// Tail-beat phase, in radians.
    phase: f32 = 0,
    /// The water it stays near.
    home: [2]f32,
    school: u8,
    kind: FishKind,
};

/// A turtle or a shark: alone, wandering near its home, in the water it
/// keeps to.
pub const Swimmer = struct {
    pos: V3,
    yaw: f32,
    pitch: f32 = 0,
    speed: f32,
    /// Flipper or tail-beat phase, in radians.
    phase: f32 = 0,
    home: [2]f32,
    kind: Kind,

    pub const Kind = enum {
        /// Keeps to the shallows (three blocks deep at most), paddling
        /// slowly.
        turtle,
        /// Keeps to deeper water (five blocks or more).
        shark,
    };

    /// Whether the water at (x, z) is the kind it keeps to.
    fn keepsTo(s: *const Swimmer, w: *const World, x: f32, z: f32) bool {
        return waterFor(s.kind, w, x, z);
    }
};

pub const Creatures = struct {
    birds: [bird_count]Bird = undefined,
    fish: [fish_count]Fish = undefined,
    swimmers: [turtle_count + shark_count]Swimmer = undefined,
    spawned: bool = false,
    seed: u32 = 0,
    time: f32 = 0,

    /// Places birds over the island and coast, and schools of fish in the
    /// shallows and sea around it.
    pub fn spawn(c: *Creatures, w: *const World) void {
        c.seed = w.seed;
        c.time = 0;
        c.spawned = true;
        const seed = w.seed ^ 0x5f3759df;

        // Six small flocks of four birds each: two of gulls along the
        // coast (one near the spawn beach), four of songbirds over the
        // island's woods, meadows and hills.
        for (&c.birds, 0..) |*b, i| {
            const flock: u8 = @intCast(i / 4);
            const member: u32 = @intCast(i % 4);
            const s = seed +% @as(u32, @intCast(i)) *% 747796405;
            const kind: BirdKind = switch (flock) {
                0, 1 => .gull,
                2 => .bluebird,
                3 => .cardinal,
                4 => .goldfinch,
                else => @enumFromInt(@as(u2, @truncate(i))),
            };
            const home: [2]f32 = switch (flock) {
                // Near the player's beach, wheeling out over the bay.
                0 => .{
                    std.math.clamp(w.spawn[0] + @sin(w.spawn_yaw) * 18, 16, world_mod.size_x - 16),
                    std.math.clamp(w.spawn[2] - @cos(w.spawn_yaw) * 18, 16, world_mod.size_z - 16),
                },
                // Opposite coast.
                1 => .{ world_mod.size_x - w.spawn[0], world_mod.size_z - w.spawn[2] },
                // Songbirds over the atoll's islands.
                else => blk: {
                    const a = (@as(f32, @floatFromInt(flock - 2)) + 0.35) * (std.math.pi / 2.0);
                    const r: f32 = world_mod.atoll_radius - 6 + 12 * rand01(s +% 1);
                    break :blk .{
                        world_mod.size_x * 0.5 + @cos(a) * r,
                        world_mod.size_z * 0.5 + @sin(a) * r,
                    };
                },
            };
            const orbit: f32 = if (kind == .gull) 16 + 6 * rand01(s +% 2) else 11 + 5 * rand01(s +% 2);
            const angle = @as(f32, @floatFromInt(member)) * 0.55 + @as(f32, @floatFromInt(flock)) * 1.1;
            const bx = home[0] + @cos(angle) * orbit;
            const bz = home[1] + @sin(angle) * orbit;
            const ground = groundUnder(w, bx, bz);
            const cruise_y = std.math.clamp(ground + (if (kind == .gull) @as(f32, 11) else 8) + 4 * rand01(s +% 3), world_mod.sea_level + 7, world_mod.size_y - 7);
            const turn_dir: f32 = if (flock % 2 == 0) 1 else -1;
            // Tangent to its circle (yaw 0 faces -z, +pi/2 faces +x).
            const tangent_x = -@sin(angle) * turn_dir;
            const tangent_z = @cos(angle) * turn_dir;
            b.* = .{
                .pos = .{ bx, cruise_y + @as(f32, @floatFromInt(member)) * 0.6, bz },
                .yaw = std.math.atan2(tangent_x, -tangent_z),
                .speed = if (kind == .gull) 5.8 + 0.8 * rand01(s +% 4) else 5.0 + 0.9 * rand01(s +% 4),
                .phase = rand01(s +% 5) * std.math.pi * 2,
                .glide = if (kind == .gull) 0.6 else 0.2,
                .home = home,
                .orbit = orbit,
                .cruise_y = cruise_y,
                .turn_dir = turn_dir,
                .flock = flock,
                .kind = kind,
            };
        }

        // Eight schools of five fish in the water around the island; the
        // first two schools swim near the spawn beach where the player
        // starts.
        for (0..8) |school| {
            const school_u8: u8 = @intCast(school);
            const center = findSchoolWater(w, seed +% @as(u32, @intCast(school)) *% 2891336453, school);
            const base_yaw = rand01(seed +% @as(u32, @intCast(school)) *% 97) * std.math.pi * 2;
            const kind: FishKind = @enumFromInt(@as(u2, @truncate(school)));
            for (0..5) |m| {
                const idx = school * 5 + m;
                const s = seed +% @as(u32, @intCast(idx)) *% 1664525;
                const ox = (rand01(s +% 1) - 0.5) * 3.0;
                const oz = (rand01(s +% 2) - 0.5) * 3.0;
                var fx = center[0] + ox;
                var fz = center[1] + oz;
                if (!isSwimmableWater(w, fx, fz)) {
                    fx = center[0];
                    fz = center[1];
                }
                const floor = seaFloorAt(w, fx, fz);
                const min_y = floor + 1.35;
                const max_y = @max(min_y, @as(f32, world_mod.sea_level) - 0.75);
                const fy = std.math.clamp(min_y + (max_y - min_y) * (0.35 + 0.45 * rand01(s +% 3)), min_y, max_y);
                c.fish[idx] = .{
                    .pos = .{ fx, fy, fz },
                    .yaw = base_yaw + (rand01(s +% 4) - 0.5) * 0.35,
                    .speed = 1.7 + 0.6 * rand01(s +% 5),
                    .phase = rand01(s +% 6) * std.math.pi * 2,
                    .home = center,
                    .school = school_u8,
                    .kind = kind,
                };
            }
        }

        // A few turtles in the shallows and a couple of sharks further
        // out, each alone, round the island.
        for (&c.swimmers, 0..) |*sw, i| {
            const kind: Swimmer.Kind = if (i < turtle_count) .turtle else .shark;
            const s = seed +% @as(u32, @intCast(i)) *% 2246822519 +% 77;
            const home = findWaterFor(w, kind, s, i);
            const floor = seaFloorAt(w, home[0], home[1]);
            sw.* = .{
                .pos = .{ home[0], (swimBand(kind, floor)[0] + swimBand(kind, floor)[1]) * 0.5, home[1] },
                .yaw = rand01(s +% 1) * std.math.pi * 2,
                .speed = if (kind == .turtle) 0.7 + 0.2 * rand01(s +% 2) else 1.6 + 0.4 * rand01(s +% 2),
                .phase = rand01(s +% 3) * std.math.pi * 2,
                .home = home,
                .kind = kind,
            };
        }
    }

    /// Advances the simulation to `time` (spawning first if needed).
    pub fn sync(c: *Creatures, w: *const World, time: f32) void {
        if (!c.spawned or c.seed != w.seed or time < c.time - 1.0) {
            c.spawn(w);
            // Warm up a little so at t > 0 wings and tails are mid-beat.
            const warmup = @min(@max(time, 0), 2.0);
            var t: f32 = 0;
            while (t < warmup) : (t += 0.05) c.tick(w, 0.05);
            c.time = time;
            return;
        }
        var rem = std.math.clamp(time - c.time, 0, 0.5);
        c.time = time;
        while (rem > 1e-4) {
            const dt = @min(rem, 0.05);
            c.tick(w, dt);
            rem -= dt;
        }
    }

    /// Moves birds and fish on by `dt` seconds.
    pub fn tick(c: *Creatures, w: *const World, dt_in: f32) void {
        const dt = std.math.clamp(dt_in, 0, 0.1);
        if (dt == 0) return;
        c.tickBirds(w, dt);
        c.tickFish(w, dt);
        c.tickSwimmers(w, dt);
    }

    fn tickSwimmers(c: *Creatures, w: *const World, dt: f32) void {
        for (&c.swimmers, 0..) |*s, idx| {
            // Wander, drawn back home when far from it.
            var wish_x = @sin(s.yaw);
            var wish_z = -@cos(s.yaw);
            const hx = s.home[0] - s.pos[0];
            const hz = s.home[1] - s.pos[2];
            const hd = @sqrt(hx * hx + hz * hz);
            const leash: f32 = if (s.kind == .turtle) 10 else 22;
            if (hd > leash) {
                wish_x += (hx / hd) * 0.8;
                wish_z += (hz / hd) * 0.8;
            }
            const wander = @sin(s.phase * 0.05 + @as(f32, @floatFromInt(idx)) * 1.3) * 0.5;
            wish_x += @cos(s.yaw) * wander;
            wish_z += @sin(s.yaw) * wander;
            // Turn from water not its own (land, or too deep or shallow).
            const look: f32 = if (s.kind == .turtle) 1.5 else 3;
            if (!s.keepsTo(w, s.pos[0] + @sin(s.yaw) * look, s.pos[2] - @cos(s.yaw) * look)) {
                var best = s.yaw + std.math.pi;
                for (1..8) |step| {
                    const cand = s.yaw + @as(f32, @floatFromInt(step)) * (std.math.pi / 4.0);
                    if (s.keepsTo(w, s.pos[0] + @sin(cand) * look, s.pos[2] - @cos(cand) * look)) {
                        best = cand;
                        break;
                    }
                }
                wish_x = @sin(best) * 3;
                wish_z = -@cos(best) * 3;
            }
            const diff = angleDiff(std.math.atan2(wish_x, -wish_z), s.yaw);
            const max_turn: f32 = (if (s.kind == .turtle) @as(f32, 1.2) else 0.9) * dt;
            s.yaw = wrapAngle(s.yaw + std.math.clamp(diff, -max_turn, max_turn));
            const nx = s.pos[0] + @sin(s.yaw) * s.speed * dt;
            const nz = s.pos[2] - @cos(s.yaw) * s.speed * dt;
            if (s.keepsTo(w, nx, nz)) {
                s.pos[0] = nx;
                s.pos[2] = nz;
            } else s.yaw = wrapAngle(s.yaw + std.math.pi * 0.5);
            // Between the bed and the surface, as its kind swims.
            const band = swimBand(s.kind, seaFloorAt(w, s.pos[0], s.pos[2]));
            const target = band[0] + (band[1] - band[0]) * 0.5;
            const dy = target - s.pos[1];
            s.pitch = std.math.clamp(dy * 0.3, -0.2, 0.2);
            s.pos[1] = std.math.clamp(s.pos[1] + dy * @min(1, 1.5 * dt), band[0], band[1]);
            const rate: f32 = if (s.kind == .turtle) 2.2 else 3.5 + s.speed;
            s.phase = @mod(s.phase + rate * dt, std.math.pi * 200);
        }
    }

    fn tickBirds(c: *Creatures, w: *const World, dt: f32) void {
        for (&c.birds, 0..) |*b, idx| {
            // Circle around `home`, nudged by flockmates so they spread out
            // cleanly without overlapping.
            const dx = b.pos[0] - b.home[0];
            const dz = b.pos[2] - b.home[1];
            const r = @max(@sqrt(dx * dx + dz * dz), 0.001);
            const rx = dx / r;
            const rz = dz / r;
            const tx = -rz * b.turn_dir;
            const tz = rx * b.turn_dir;
            const radial = std.math.clamp((b.orbit - r) / b.orbit, -0.8, 0.8);
            var wish_x = tx + rx * radial * 0.65;
            var wish_z = tz + rz * radial * 0.65;

            // Gentle separation and alignment within the flock.
            for (c.birds, 0..) |other, j| {
                if (idx == j or other.flock != b.flock) continue;
                const ox = b.pos[0] - other.pos[0];
                const oz = b.pos[2] - other.pos[2];
                const d2 = ox * ox + oz * oz;
                if (d2 > 0.01 and d2 < 9.0) {
                    const inv = 1.0 / @sqrt(d2);
                    wish_x += ox * inv * 0.45;
                    wish_z += oz * inv * 0.45;
                }
            }

            const want_yaw = std.math.atan2(wish_x, -wish_z);
            const diff = angleDiff(want_yaw, b.yaw);
            const max_turn: f32 = 1.8 * dt;
            const turn = std.math.clamp(diff, -max_turn, max_turn);
            b.yaw = wrapAngle(b.yaw + turn);

            // Bank into the turn.
            const want_roll = std.math.clamp(-diff * 0.55, -0.55, 0.55);
            b.roll += (want_roll - b.roll) * @min(1, 5 * dt);

            // Stay well clear of hills, trees and anything built below or
            // ahead, looking far enough ahead to rise in time.
            var ground = groundUnder(w, b.pos[0], b.pos[2]);
            for ([_]f32{ 3, 6, 10 }) |ahead| {
                ground = @max(ground, groundUnder(w, b.pos[0] + @sin(b.yaw) * ahead, b.pos[2] - @cos(b.yaw) * ahead));
            }
            const safe_y = @min(ground + 5.0, world_mod.size_y - 4.0);
            const wave_y = @sin(b.phase * 0.18 + @as(f32, @floatFromInt(idx))) * 1.4;
            const target_y = std.math.clamp(@max(b.cruise_y + wave_y, safe_y), world_mod.sea_level + 5.0, world_mod.size_y - 4.0);
            const dy = target_y - b.pos[1];
            const want_pitch = std.math.clamp(dy * 0.18, -0.32, 0.38);
            b.pitch += (want_pitch - b.pitch) * @min(1, 4 * dt);

            // Gulls glide when descending or level; songbirds flap more
            // briskly.
            const climbing = b.pitch > 0.03;
            const cycle = @sin(b.phase * 0.15 + @as(f32, @floatFromInt(idx)) * 1.7);
            const want_glide: f32 = if (climbing) 0 else if (b.kind == .gull) (if (cycle > -0.2) 0.85 else 0.1) else (if (cycle > 0.45) 0.65 else 0.0);
            b.glide += (want_glide - b.glide) * @min(1, 3.5 * dt);
            const flap_rate: f32 = (if (b.kind == .gull) @as(f32, 7.5) else 11.5) * (1.0 - b.glide * 0.72);
            b.phase = @mod(b.phase + flap_rate * dt, std.math.pi * 200);

            const fwd = V3{ @sin(b.yaw) * @cos(b.pitch), @sin(b.pitch), -@cos(b.yaw) * @cos(b.pitch) };
            b.pos += fwd * math.splat(b.speed * dt);
            // Too low after all: rise, quickly but smoothly.
            if (b.pos[1] < safe_y - 0.5) b.pos[1] += (safe_y - 0.5 - b.pos[1]) * @min(1, 2.5 * dt);
        }
    }

    fn tickFish(c: *Creatures, w: *const World, dt: f32) void {
        for (&c.fish, 0..) |*f, idx| {
            // Schooling: steer gently around `home`, align with schoolmates
            // and keep a little room between fish.
            var wish_x = @sin(f.yaw);
            var wish_z = -@cos(f.yaw);

            const hx = f.home[0] - f.pos[0];
            const hz = f.home[1] - f.pos[2];
            const hd = @sqrt(hx * hx + hz * hz);
            if (hd > 8.0) {
                wish_x += (hx / hd) * 0.6;
                wish_z += (hz / hd) * 0.6;
            }
            // Gentle wander.
            const wander = @sin(f.phase * 0.17 + @as(f32, @floatFromInt(idx)) * 2.1) * 0.35;
            wish_x += @cos(f.yaw) * wander;
            wish_z += @sin(f.yaw) * wander;

            for (c.fish, 0..) |other, j| {
                if (idx == j or other.school != f.school) continue;
                const ox = f.pos[0] - other.pos[0];
                const oz = f.pos[2] - other.pos[2];
                const d2 = ox * ox + oz * oz;
                if (d2 > 0.001 and d2 < 1.2) {
                    const inv = 1.0 / @sqrt(d2);
                    wish_x += ox * inv * 0.9;
                    wish_z += oz * inv * 0.9;
                } else if (d2 < 12.0) {
                    wish_x += @sin(other.yaw) * 0.2;
                    wish_z += -@cos(other.yaw) * 0.2;
                }
            }

            // Look ahead: if the water ahead is too shallow or blocked by a
            // solid block, turn toward deeper water.
            const ahead_x = f.pos[0] + @sin(f.yaw) * 2.2;
            const ahead_z = f.pos[2] - @cos(f.yaw) * 2.2;
            if (!isSwimmableWater(w, ahead_x, ahead_z)) {
                var best_yaw = f.yaw + std.math.pi;
                var best_depth: f32 = -999;
                for (1..8) |step| {
                    const delta = @as(f32, @floatFromInt(step)) * (std.math.pi / 4.0);
                    const cand = f.yaw + delta;
                    const cx = f.pos[0] + @sin(cand) * 3.0;
                    const cz = f.pos[2] - @cos(cand) * 3.0;
                    const depth = @as(f32, world_mod.sea_level) - seaFloorAt(w, cx, cz);
                    if (isSwimmableWater(w, cx, cz) and depth > best_depth) {
                        best_depth = depth;
                        best_yaw = cand;
                    }
                }
                wish_x = @sin(best_yaw) * 3.0;
                wish_z = -@cos(best_yaw) * 3.0;
            }

            const want_yaw = std.math.atan2(wish_x, -wish_z);
            const diff = angleDiff(want_yaw, f.yaw);
            const max_turn: f32 = 3.2 * dt;
            f.yaw = wrapAngle(f.yaw + std.math.clamp(diff, -max_turn, max_turn));

            const next_x = f.pos[0] + @sin(f.yaw) * f.speed * dt;
            const next_z = f.pos[2] - @cos(f.yaw) * f.speed * dt;
            if (isSwimmableWater(w, next_x, next_z)) {
                f.pos[0] = next_x;
                f.pos[2] = next_z;
            } else {
                f.yaw = wrapAngle(f.yaw + std.math.pi * 0.5);
            }

            // Keep vertically between the sea bed (whose top face is at
            // `floor + 1`) and the water's surface.
            const floor = seaFloorAt(w, f.pos[0], f.pos[2]);
            const min_y = floor + 1.35;
            const max_y = @max(min_y, @as(f32, world_mod.sea_level) - 0.75);
            const band_y = min_y + (max_y - min_y) * (0.45 + 0.25 * @sin(f.phase * 0.12 + @as(f32, @floatFromInt(idx))));
            const target_y = std.math.clamp(band_y, min_y, max_y);
            const dy = target_y - f.pos[1];
            f.pitch = std.math.clamp(dy * 0.35, -0.25, 0.25);
            f.pos[1] = std.math.clamp(f.pos[1] + dy * @min(1, 4.0 * dt), min_y, max_y);

            // Tail wiggles with speed and turning.
            const wiggle_rate: f32 = 7.5 + f.speed * 2.2 + @abs(diff) * 2.0;
            f.phase = @mod(f.phase + wiggle_rate * dt, std.math.pi * 200);
        }
    }

    /// Writes the visible creatures (and the seaplane, if it is flying,
    /// on day `day`, `day_seconds` into it) into `out` (a slice of at
    /// least `max_quads * 4` vertices) and returns how many quads were
    /// written.
    pub fn buildMesh(c: *const Creatures, w: *const World, frustum: *const math.Frustum, eye: V3, max_dist: f32, day: u32, day_seconds: f32, out: []Vertex) u32 {
        if (!c.spawned) return 0;
        var builder: Builder = .{ .out = out };
        const max_d2 = max_dist * max_dist;

        if (planeAt(w.seed, day, day_seconds)) |plane| {
            const d = plane.pos - eye;
            if (math.dot(d, d) < max_d2 and frustum.sees(plane.pos - V3{ 8, 3, 8 }, plane.pos + V3{ 8, 3, 8 })) emitPlane(&builder, plane);
        }

        for (&c.birds) |*b| {
            const d = b.pos - eye;
            if (math.dot(d, d) > max_d2) continue;
            if (!frustum.sees(b.pos - V3{ 1.2, 1.0, 1.2 }, b.pos + V3{ 1.2, 1.0, 1.2 })) continue;
            const light = lightAtPos(w, b.pos);
            emitBird(&builder, b, light);
        }

        for (&c.fish) |*f| {
            const d = f.pos - eye;
            if (math.dot(d, d) > max_d2) continue;
            if (!frustum.sees(f.pos - V3{ 0.8, 0.6, 0.8 }, f.pos + V3{ 0.8, 0.6, 0.8 })) continue;
            const light = lightAtPos(w, f.pos);
            emitFish(&builder, f, light);
        }

        for (&c.swimmers) |*s| {
            const d = s.pos - eye;
            if (math.dot(d, d) > max_d2) continue;
            if (!frustum.sees(s.pos - V3{ 1.2, 0.6, 1.2 }, s.pos + V3{ 1.2, 0.6, 1.2 })) continue;
            const light = lightAtPos(w, s.pos);
            switch (s.kind) {
                .turtle => emitTurtle(&builder, s, light),
                .shark => emitShark(&builder, s, light),
            }
        }

        return @intCast(builder.at / 4);
    }
};

// --- The seaplane --------------------------------------------------------------------------

/// The seaplane, where it is.
pub const Plane = struct {
    pos: V3,
    yaw: f32,
    roll: f32,
    /// The propeller's turn, in radians.
    prop: f32,
};

/// How fast the seaplane flies, blocks a second, and how high.
const plane_speed: f32 = 24;
const plane_y: f32 = world_mod.sea_level + 24;
/// How far it flies, from out at sea to out at sea.
const plane_path: f32 = 720;

/// Where the seaplane is on day `day`, `secs` seconds into it (it flies
/// past once a day, at a time between morning and afternoon, along one
/// side of the island, over the beaches and shallows), or null.
pub fn planeAt(seed: u32, day: u32, secs: f32) ?Plane {
    const s = seed ^ 0x5ea91a4e;
    const d: i32 = @intCast(day % 1000000);
    const length_secs = plane_path / plane_speed;
    // From 0.32 to 0.62 of a 600 second day.
    const start = 192 + world_mod.hash(s, d, 1) * 180;
    const along = (secs - start) * plane_speed - plane_path / 2;
    if (secs < start or secs > start + length_secs) return null;
    const heading = world_mod.hash(s, d, 2) * 2 * std.math.pi;
    const dir = V3{ @sin(heading), 0, -@cos(heading) };
    const side = V3{ @cos(heading), 0, @sin(heading) };
    // Past the atoll's middle, off to one side: over its ring.
    const offset = (world_mod.atoll_radius - 12 + world_mod.hash(s, d, 3) * 24) * (if (world_mod.hash(s, d, 4) < 0.5) @as(f32, -1) else 1);
    const centre = V3{ world_mod.size_x / 2, plane_y, world_mod.size_z / 2 } + side * math.splat(offset);
    return .{
        .pos = centre + dir * math.splat(along) + V3{ 0, @sin(secs * 0.3) * 0.8, 0 },
        .yaw = heading,
        .roll = @sin(secs * 0.25) * 0.08,
        .prop = @mod(secs * 40, 2 * std.math.pi),
    };
}

fn emitPlane(b: *Builder, p: Plane) void {
    const light: u8 = 0xf0;
    const f = Frame.fromAngles(p.yaw, 0, p.roll);
    const body = BoxLook.uniform(.white);
    const red = BoxLook.uniform(.red);
    // The fuselage, its cockpit's windows, and its tail, thinner.
    b.box(f, f.point(p.pos, .{ 0, 0, -0.4 }), .{ 0.55, 0.6, 2.2 }, .{ 0.75, 0.75 }, .{ 0.9, 0.9 }, body, light);
    b.box(f, f.point(p.pos, .{ 0, 0.32, -1.5 }), .{ 0.57, 0.2, 0.55 }, .{ 0.8, 1 }, .{ 1, 1 }, BoxLook.uniform(.black), light);
    b.box(f, f.point(p.pos, .{ 0, 0.15, 2.8 }), .{ 0.38, 0.38, 1.4 }, .{ 1, 1 }, .{ 0.35, 0.45 }, body, light);
    // The wings, high on it, and the tail's.
    b.box(f, f.point(p.pos, .{ 0, 0.68, -0.8 }), .{ 6.5, 0.08, 0.8 }, .{ 1, 1 }, .{ 1, 1 }, red, light);
    b.box(f, f.point(p.pos, .{ 0, 0.3, 4.0 }), .{ 2.0, 0.06, 0.45 }, .{ 1, 1 }, .{ 1, 1 }, red, light);
    b.box(f, f.point(p.pos, .{ 0, 1.05, 4.0 }), .{ 0.06, 0.75, 0.5 }, .{ 1, 0.6 }, .{ 1, 1 }, red, light);
    // Its floats, under it, and the struts to them.
    for ([2]f32{ -1, 1 }) |side| {
        b.box(f, f.point(p.pos, .{ side * 1.25, -1.45, -0.4 }), .{ 0.24, 0.22, 2.6 }, .{ 0.6, 0.6 }, .{ 0.8, 0.8 }, body, light);
        for ([2]f32{ -1.4, 0.6 }) |z| b.box(f, f.point(p.pos, .{ side * 0.9, -0.95, z }), .{ 0.05, 0.4, 0.05 }, .{ 1, 1 }, .{ 1, 1 }, BoxLook.uniform(.black), light);
    }
    // The propeller, turning, at its nose.
    const nose = f.point(p.pos, .{ 0, 0, -2.75 });
    b.box(f, nose, .{ 0.14, 0.14, 0.12 }, .{ 1, 1 }, .{ 1, 1 }, BoxLook.uniform(.black), light);
    b.box(f.rollBy(p.prop), f.point(p.pos, .{ 0, 0, -2.88 }), .{ 1.1, 0.07, 0.025 }, .{ 1, 1 }, .{ 1, 1 }, BoxLook.uniform(.black), light);
}

// --- Terrain and water queries -------------------------------------------------------------

fn rand01(seed: u32) f32 {
    var h = seed *% 0x9e3779b9;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777216.0;
}

fn wrapAngle(a: f32) f32 {
    return std.math.atan2(@sin(a), @cos(a));
}

fn angleDiff(target: f32, current: f32) f32 {
    return wrapAngle(target - current);
}

/// The highest block (land, tree or water surface) under `(x, z)`.
fn groundUnder(w: *const World, x: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    if (!World.inBounds(ix, 0, iz)) return world_mod.sea_level;
    return @floatFromInt(@max(w.top(ix, iz), world_mod.sea_level));
}

/// The y index of the highest non-water block in column `(x, z)` (so its top
/// surface is at `seaFloorAt + 1`).
fn seaFloorAt(w: *const World, x: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    if (ix < 0 or ix >= world_mod.size_x or iz < 0 or iz >= world_mod.size_z) return world_mod.sea_level - 9;
    var y: i32 = world_mod.size_y - 1;
    while (y >= 0) : (y -= 1) {
        const b = w.get(ix, y, iz);
        if (b != .air and b != .water) return @floatFromInt(y);
    }
    return 0;
}

/// Whether column `(x, z)` is in the coastal ring around the island with at
/// least two full blocks of water (`sea_level - 2` and `sea_level - 1`)
/// above the sea bed.
fn isSwimmableWater(w: *const World, x: f32, z: f32) bool {
    if (x < -18 or x >= world_mod.size_x + 18 or z < -18 or z >= world_mod.size_z + 18) return false;
    const floor = seaFloorAt(w, x, z);
    if (floor > world_mod.sea_level - 3) return false;
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    return w.get(ix, world_mod.sea_level - 2, iz) == .water and w.get(ix, world_mod.sea_level - 1, iz) == .water;
}

/// How deep the water is at (x, z), in blocks (deep, past the world's
/// edge).
fn waterDepth(w: *const World, x: f32, z: f32) i32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    if (!World.inBounds(ix, 0, iz)) return 9;
    var d: i32 = 0;
    while (d < 12 and w.get(ix, world_mod.sea_level - 1 - d, iz) == .water) d += 1;
    return d;
}

/// Whether a turtle (the shallows) or a shark (deeper water) keeps to
/// the water at (x, z).
fn waterFor(kind: Swimmer.Kind, w: *const World, x: f32, z: f32) bool {
    if (x < -18 or x >= world_mod.size_x + 18 or z < -18 or z >= world_mod.size_z + 18) return false;
    const d = waterDepth(w, x, z);
    return switch (kind) {
        .turtle => d >= 1 and d <= 3,
        .shark => d >= 5,
    };
}

/// The heights a turtle or shark keeps between over a sea bed at `floor`
/// (its top at `floor + 1`): a turtle just under the surface, a shark in
/// the middle of the water.
fn swimBand(kind: Swimmer.Kind, floor: f32) [2]f32 {
    const surface: f32 = world_mod.sea_level - 1 + mesher.water_top;
    return switch (kind) {
        .turtle => .{ @min(floor + 1.15, surface - 0.4), surface - 0.4 },
        .shark => .{ floor + 1.6, @max(floor + 1.6, surface - 1.8) },
    };
}

/// Water a turtle or shark keeps to, round the island (the `i`th of
/// them, spread round it).
fn findWaterFor(w: *const World, kind: Swimmer.Kind, seed: u32, i: usize) [2]f32 {
    const base_a = @as(f32, @floatFromInt(i)) * 2.4 + rand01(seed) * 0.5;
    for (0..48) |attempt| {
        const a = base_a + @as(f32, @floatFromInt(attempt)) * 0.37;
        // Turtles in the lagoon; sharks outside the reef.
        var r: f32 = if (kind == .turtle) 30 else world_mod.atoll_radius + 24;
        while (r <= (if (kind == .turtle) world_mod.atoll_radius else world_mod.atoll_radius + 60)) : (r += 2) {
            const x = world_mod.size_x * 0.5 + @cos(a) * r;
            const z = world_mod.size_z * 0.5 + @sin(a) * r;
            if (waterFor(kind, w, x, z)) return .{ x, z };
        }
    }
    return .{ -10, -10 };
}

/// Finds a coastal water spot with good depth for school `school`.
fn findSchoolWater(w: *const World, seed: u32, school: usize) [2]f32 {
    // First two schools: right off the player's starting beach so fish are
    // easy to spot from the shore.
    if (school < 2) {
        const side: f32 = if (school == 0) -1 else 1;
        // `spawn_yaw` looks inland; `-spawn_yaw` looks out to sea.
        const sea_yaw = w.spawn_yaw + std.math.pi + side * 0.35;
        var dist: f32 = 8;
        while (dist <= 32) : (dist += 2) {
            const x = w.spawn[0] + @sin(sea_yaw) * dist;
            const z = w.spawn[2] - @cos(sea_yaw) * dist;
            if (isSwimmableWater(w, x, z)) return .{ x, z };
        }
    }
    const base_a = @as(f32, @floatFromInt(school)) * (std.math.pi * 2.0 / 8.0) + 0.25;
    for (0..24) |attempt| {
        const a = base_a + @as(f32, @floatFromInt(attempt)) * 0.26;
        var r: f32 = 36 + 28 * rand01(seed +% @as(u32, @intCast(attempt)));
        while (r <= 68) : (r += 4) {
            const x = world_mod.size_x * 0.5 + @cos(a) * r;
            const z = world_mod.size_z * 0.5 + @sin(a) * r;
            if (isSwimmableWater(w, x, z)) return .{ x, z };
        }
    }
    return .{ 2, 2 };
}

fn lightAtPos(w: *const World, p: V3) u8 {
    return w.lightAt(@intFromFloat(@floor(p[0])), @intFromFloat(@floor(p[1])), @intFromFloat(@floor(p[2])));
}

// --- Building creature meshes --------------------------------------------------------------

/// A right-handed local frame (`right × up = back`, where `back = -forward`).
const Frame = struct {
    right: V3,
    up: V3,
    back: V3,

    fn fromAngles(yaw: f32, pitch: f32, roll: f32) Frame {
        const cy = @cos(yaw);
        const sy = @sin(yaw);
        const cp = @cos(pitch);
        const sp = @sin(pitch);
        const cr = @cos(roll);
        const sr = @sin(roll);

        const fwd = V3{ sy * cp, sp, -cy * cp };
        const level_right = V3{ cy, 0, sy };
        const level_up = math.cross(level_right, fwd);
        const right = level_right * math.splat(cr) + level_up * math.splat(sr);
        const up = level_up * math.splat(cr) - level_right * math.splat(sr);
        return .{ .right = right, .up = up, .back = -fwd };
    }

    /// Rotates around `back` (rolling the wings up or down).
    fn rollBy(f: Frame, angle: f32) Frame {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            .right = f.right * math.splat(c) + f.up * math.splat(s),
            .up = f.up * math.splat(c) - f.right * math.splat(s),
            .back = f.back,
        };
    }

    /// Rotates around `up` (wagging the body or tail sideways).
    fn yawBy(f: Frame, angle: f32) Frame {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            .right = f.right * math.splat(c) - f.back * math.splat(s),
            .up = f.up,
            .back = f.back * math.splat(c) + f.right * math.splat(s),
        };
    }

    /// Rotates around `right` (pitching a fin or tail).
    fn pitchBy(f: Frame, angle: f32) Frame {
        const c = @cos(angle);
        const s = @sin(angle);
        return .{
            .right = f.right,
            .up = f.up * math.splat(c) + f.back * math.splat(s),
            .back = f.back * math.splat(c) - f.up * math.splat(s),
        };
    }

    fn point(f: Frame, origin: V3, local: [3]f32) V3 {
        return origin + f.right * math.splat(local[0]) + f.up * math.splat(local[1]) + f.back * math.splat(local[2]);
    }
};

const BoxLook = struct {
    top: Tile,
    bottom: Tile,
    sides: Tile,
    front: Tile,
    back: Tile,
    top_ao: u2 = 0,
    bottom_ao: u2 = 1,
    side_ao: u2 = 0,

    fn uniform(t: Tile) BoxLook {
        return .{ .top = t, .bottom = t, .sides = t, .front = t, .back = t };
    }

    fn shaded(t: Tile, ao: u2) BoxLook {
        return .{ .top = t, .bottom = t, .sides = t, .front = t, .back = t, .top_ao = ao, .bottom_ao = @min(3, ao + 1), .side_ao = ao };
    }

    fn twoTone(top: Tile, belly: Tile) BoxLook {
        return .{ .top = top, .bottom = belly, .sides = top, .front = top, .back = top };
    }
};

const Builder = struct {
    out: []Vertex,
    at: usize = 0,

    fn quad(b: *Builder, corners: [4]V3, normal: V3, tile: Tile, ao: u2, light: u8) void {
        if (b.at + 4 > b.out.len) return;
        const face = closestFace(normal);
        const t0 = mesher.stripT(tile, 0.15);
        const t1 = mesher.stripT(tile, 0.85);
        const uvs = [4][2]f32{ .{ 0.15, t0 }, .{ 0.85, t0 }, .{ 0.85, t1 }, .{ 0.15, t1 } };
        const info = (mesher.Info{
            .tile = @intFromEnum(tile),
            .ao = ao,
            .face = face,
            .sky = world_mod.skyOf(light),
            .lamp = world_mod.lampOf(light),
        }).pack();
        for (corners, uvs, 0..) |c, uv, k| {
            b.out[b.at + k] = .{
                .pos = .{ c[0], c[1], c[2] },
                .uv = uv,
                .info = info,
            };
        }
        b.at += 4;
    }

    /// Emits a 6-sided oriented box centered at `center` with half-extents
    /// `half` (`x` right, `y` up, `z` back), optionally tapered at the
    /// front (`z = -half[2]`) or back (`z = +half[2]`).
    fn box(b: *Builder, frame: Frame, center: V3, half: [3]f32, front_taper: [2]f32, back_taper: [2]f32, look: BoxLook, light: u8) void {
        var p: [2][2][2]V3 = undefined;
        for (0..2) |ix| for (0..2) |iy| for (0..2) |iz| {
            const sx: f32 = if (ix == 0) -1 else 1;
            const sy: f32 = if (iy == 0) -1 else 1;
            const sz: f32 = if (iz == 0) -1 else 1;
            const taper = if (iz == 0) front_taper else back_taper;
            p[ix][iy][iz] = frame.point(center, .{
                sx * half[0] * taper[0],
                sy * half[1] * taper[1],
                sz * half[2],
            });
        };
        // Top (+up), bottom (-up), right (+right), left (-right), back (+back), front (-back).
        b.quad(.{ p[0][1][0], p[0][1][1], p[1][1][1], p[1][1][0] }, frame.up, look.top, look.top_ao, light);
        b.quad(.{ p[0][0][1], p[0][0][0], p[1][0][0], p[1][0][1] }, -frame.up, look.bottom, look.bottom_ao, light);
        b.quad(.{ p[1][1][0], p[1][1][1], p[1][0][1], p[1][0][0] }, frame.right, look.sides, look.side_ao, light);
        b.quad(.{ p[0][1][1], p[0][1][0], p[0][0][0], p[0][0][1] }, -frame.right, look.sides, look.side_ao, light);
        b.quad(.{ p[1][1][1], p[0][1][1], p[0][0][1], p[1][0][1] }, frame.back, look.back, look.side_ao, light);
        b.quad(.{ p[0][1][0], p[1][1][0], p[1][0][0], p[0][0][0] }, -frame.back, look.front, look.top_ao, light);
    }
};

fn closestFace(n: V3) Face {
    const ax = @abs(n[0]);
    const ay = @abs(n[1]);
    const az = @abs(n[2]);
    if (ay >= ax and ay >= az) return if (n[1] >= 0) .up else .down;
    if (ax >= az) return if (n[0] >= 0) .east else .west;
    return if (n[2] >= 0) .south else .north;
}

fn emitBird(b: *Builder, bird: *const Bird, light: u8) void {
    const scale: f32 = if (bird.kind == .gull) 1.0 else 0.78;
    const body_look: BoxLook, const head_tile: Tile, const wing_look: BoxLook, const tip_tile: Tile, const tail_tile: Tile, const beak_tile: Tile = switch (bird.kind) {
        .gull => .{
            BoxLook.uniform(.white),
            .white,
            BoxLook.shaded(.white, 1),
            .black,
            .white,
            .orange,
        },
        .bluebird => .{
            BoxLook.twoTone(.blue, .orange),
            .blue,
            BoxLook.twoTone(.blue, .cyan),
            .blue,
            .blue,
            .black,
        },
        .cardinal => .{
            BoxLook.uniform(.red),
            .red,
            BoxLook.uniform(.black),
            .black,
            .black,
            .orange,
        },
        .goldfinch => .{
            BoxLook.uniform(.yellow),
            .yellow,
            BoxLook.uniform(.black),
            .black,
            .black,
            .orange,
        },
    };

    const flap = @sin(bird.phase) * (1.0 - bird.glide * 0.78);
    // Body bobs slightly opposite the wing stroke.
    const f = Frame.fromAngles(bird.yaw, bird.pitch, bird.roll);
    const center = bird.pos + f.up * math.splat(-flap * 0.03 * scale);

    // Streamlined body.
    b.box(f, center, .{ 0.11 * scale, 0.09 * scale, 0.22 * scale }, .{ 0.85, 0.85 }, .{ 0.75, 0.75 }, body_look, light);

    // Head and pointed beak at the front (-back).
    const head_pos = f.point(center, .{ 0, 0.06 * scale, -0.25 * scale });
    b.box(f, head_pos, .{ 0.085 * scale, 0.08 * scale, 0.09 * scale }, .{ 0.85, 0.85 }, .{ 1, 1 }, BoxLook.uniform(head_tile), light);
    const beak_pos = f.point(head_pos, .{ 0, -0.01 * scale, -0.14 * scale });
    b.box(f, beak_pos, .{ 0.038 * scale, 0.032 * scale, 0.07 * scale }, .{ 0.35, 0.35 }, .{ 1, 1 }, BoxLook.uniform(beak_tile), light);

    // Flared tail feathers at the back (+back), pitched slightly up.
    const tail_frame = f.pitchBy(0.18 - flap * 0.06);
    const tail_pos = f.point(center, .{ 0, 0.02 * scale, 0.29 * scale });
    b.box(tail_frame, tail_pos, .{ 0.12 * scale, 0.022 * scale, 0.12 * scale }, .{ 0.65, 1 }, .{ 1.25, 1 }, BoxLook.uniform(tail_tile), light);

    // Articulated left and right wings: inner wing + outer wingtip.
    const inner_span = 0.26 * scale;
    const outer_span = 0.24 * scale;
    const inner_angle = flap * 0.68 + bird.glide * 0.12;
    const outer_angle = flap * 0.95 - 0.12;
    for ([2]f32{ -1, 1 }) |side| {
        const shoulder = f.point(center, .{ side * 0.09 * scale, 0.04 * scale, -0.02 * scale });
        const wf1 = f.rollBy(side * inner_angle);
        const inner_center = wf1.point(shoulder, .{ side * inner_span * 0.5, 0, 0 });
        b.box(wf1, inner_center, .{ inner_span * 0.5, 0.024 * scale, 0.12 * scale }, .{ 1, 1 }, .{ 0.85, 1 }, wing_look, light);

        const elbow = wf1.point(shoulder, .{ side * inner_span, 0, 0.01 * scale });
        const wf2 = f.rollBy(side * outer_angle);
        const outer_center = wf2.point(elbow, .{ side * outer_span * 0.5, 0, 0.02 * scale });
        b.box(wf2, outer_center, .{ outer_span * 0.5, 0.018 * scale, 0.09 * scale }, .{ 0.75, 1 }, .{ 0.55, 1 }, BoxLook.uniform(tip_tile), light);
    }
}

fn emitFish(b: *Builder, fish: *const Fish, light: u8) void {
    const body_tile: Tile, const band_tile: Tile, const fin_tile: Tile = switch (fish.kind) {
        .clownfish => .{ .orange, .white, .orange },
        .tang => .{ .blue, .cyan, .yellow },
        .goldfish => .{ .yellow, .orange, .red },
        .reef => .{ .pink, .pink, .cyan },
    };

    // Travelling wave from head to tail.
    const s0 = @sin(fish.phase);
    const s1 = @sin(fish.phase - 1.1);
    const s2 = @sin(fish.phase - 2.2);
    const base = Frame.fromAngles(fish.yaw, fish.pitch, s0 * 0.06);

    // Front body and head (with dark eyes on the sides).
    const f_head = base.yawBy(-s0 * 0.09);
    const head_pos = base.point(fish.pos, .{ 0, 0, -0.12 });
    b.box(f_head, head_pos, .{ 0.065, 0.095, 0.10 }, .{ 0.55, 0.65 }, .{ 1, 1 }, BoxLook.uniform(body_tile), light);

    // Small dark eye quads just outside the left and right of the head.
    for ([2]f32{ -1, 1 }) |side| {
        const ex = side * 0.062;
        const ey0: f32 = 0.01;
        const ey1: f32 = 0.045;
        const ez0: f32 = -0.055;
        const ez1: f32 = -0.02;
        const corners: [4]V3 = if (side > 0) .{
            f_head.point(head_pos, .{ ex, ey1, ez0 }),
            f_head.point(head_pos, .{ ex, ey1, ez1 }),
            f_head.point(head_pos, .{ ex, ey0, ez1 }),
            f_head.point(head_pos, .{ ex, ey0, ez0 }),
        } else .{
            f_head.point(head_pos, .{ ex, ey1, ez1 }),
            f_head.point(head_pos, .{ ex, ey1, ez0 }),
            f_head.point(head_pos, .{ ex, ey0, ez0 }),
            f_head.point(head_pos, .{ ex, ey0, ez1 }),
        };
        b.quad(corners, f_head.right * math.splat(side), .black, 0, light);
    }

    // Middle body (shows the white stripe on clownfish) and dorsal fin.
    const f_mid = base.yawBy(s0 * 0.11);
    const mid_pos = f_head.point(head_pos, .{ 0, 0, 0.16 });
    b.box(f_mid, mid_pos, .{ 0.062, 0.10, 0.075 }, .{ 1, 1 }, .{ 0.85, 0.9 }, BoxLook.uniform(band_tile), light);

    const dorsal_pos = f_mid.point(mid_pos, .{ 0, 0.125, 0.01 });
    b.box(f_mid.pitchBy(-0.2), dorsal_pos, .{ 0.014, 0.045, 0.075 }, .{ 1, 0.5 }, .{ 1, 1 }, BoxLook.uniform(fin_tile), light);

    // Pectoral fins on each side.
    for ([2]f32{ -1, 1 }) |side| {
        const pec_frame = f_mid.yawBy(side * (0.45 + s0 * 0.18)).rollBy(-side * 0.25);
        const pec_pos = f_mid.point(mid_pos, .{ side * 0.075, -0.025, -0.02 });
        b.box(pec_frame, pec_pos, .{ 0.045, 0.012, 0.04 }, .{ 1, 1 }, .{ 0.7, 1 }, BoxLook.uniform(fin_tile), light);
    }

    // Rear body (peduncle) and swishing tail fin.
    const f_rear = f_mid.yawBy(s1 * 0.24);
    const rear_pos = f_mid.point(mid_pos, .{ 0, 0, 0.14 });
    b.box(f_rear, rear_pos, .{ 0.045, 0.072, 0.075 }, .{ 1, 1 }, .{ 0.55, 0.65 }, BoxLook.uniform(body_tile), light);

    const f_tail = f_rear.yawBy(s2 * 0.38);
    const tail_pos = f_rear.point(rear_pos, .{ 0, 0, 0.14 });
    b.box(f_tail, tail_pos, .{ 0.014, 0.105, 0.08 }, .{ 1, 0.45 }, .{ 1, 1.25 }, BoxLook.uniform(fin_tile), light);
}

fn emitTurtle(b: *Builder, t: *const Swimmer, light: u8) void {
    const f = Frame.fromAngles(t.yaw, t.pitch, @sin(t.phase) * 0.04);
    // The shell: a low dome, a smaller one on top, darker.
    b.box(f, t.pos, .{ 0.2, 0.05, 0.26 }, .{ 0.7, 0.8 }, .{ 0.7, 0.8 }, BoxLook.shaded(.green, 1), light);
    b.box(f, f.point(t.pos, .{ 0, 0.07, 0 }), .{ 0.15, 0.03, 0.19 }, .{ 0.7, 1 }, .{ 0.7, 1 }, BoxLook.shaded(.green, 2), light);
    // The head, out in front, nodding a little.
    const head = f.pitchBy(@sin(t.phase * 0.5) * 0.1);
    b.box(head, f.point(t.pos, .{ 0, 0.01, -0.33 }), .{ 0.065, 0.05, 0.08 }, .{ 0.75, 0.8 }, .{ 1, 1 }, BoxLook.uniform(.green), light);
    // Front flippers, long, sweeping like wings; back ones small.
    const stroke = @sin(t.phase);
    for ([2]f32{ -1, 1 }) |side| {
        const ff = f.yawBy(side * (0.5 + stroke * 0.35)).rollBy(side * stroke * 0.3);
        b.box(ff, f.point(t.pos, .{ side * 0.27, -0.01, -0.12 }), .{ 0.13, 0.015, 0.05 }, .{ 1, 1 }, .{ 0.8, 1 }, BoxLook.shaded(.green, 1), light);
        const bf = f.yawBy(-side * (0.6 - stroke * 0.2));
        b.box(bf, f.point(t.pos, .{ side * 0.17, -0.02, 0.25 }), .{ 0.06, 0.012, 0.05 }, .{ 1, 1 }, .{ 0.7, 1 }, BoxLook.shaded(.green, 1), light);
    }
}

fn emitShark(b: *Builder, s: *const Swimmer, light: u8) void {
    const look = BoxLook.twoTone(.grey, .white);
    const s0 = @sin(s.phase);
    const s1 = @sin(s.phase - 1.0);
    const s2 = @sin(s.phase - 2.0);
    const base = Frame.fromAngles(s.yaw, s.pitch, 0);
    // Snout and head, the body, then the tail end, each swinging a
    // little more than the last.
    const f_head = base.yawBy(-s0 * 0.05);
    const head = base.point(s.pos, .{ 0, 0, -0.5 });
    b.box(f_head, head, .{ 0.13, 0.12, 0.26 }, .{ 0.45, 0.5 }, .{ 1, 1 }, look, light);
    const f_mid = base.yawBy(s0 * 0.06);
    const mid = f_head.point(head, .{ 0, 0, 0.5 });
    b.box(f_mid, mid, .{ 0.16, 0.15, 0.26 }, .{ 1, 1 }, .{ 0.75, 0.8 }, look, light);
    // Dorsal fin, tall and swept back; pectoral fins out to the sides.
    b.box(f_mid.pitchBy(-0.35), f_mid.point(mid, .{ 0, 0.25, 0.03 }), .{ 0.018, 0.13, 0.12 }, .{ 1, 0.3 }, .{ 1, 1 }, BoxLook.uniform(.grey), light);
    for ([2]f32{ -1, 1 }) |side| {
        const pf = f_mid.yawBy(side * 0.35).rollBy(-side * 0.35);
        b.box(pf, f_mid.point(mid, .{ side * 0.26, -0.08, -0.12 }), .{ 0.14, 0.015, 0.08 }, .{ 1, 1 }, .{ 0.5, 1 }, BoxLook.uniform(.grey), light);
    }
    const f_rear = f_mid.yawBy(s1 * 0.18);
    const rear = f_mid.point(mid, .{ 0, 0.01, 0.45 });
    b.box(f_rear, rear, .{ 0.1, 0.1, 0.22 }, .{ 1, 1 }, .{ 0.45, 0.5 }, look, light);
    // The tail fin: its upper lobe longer.
    const f_tail = f_rear.yawBy(s2 * 0.35);
    const tail = f_rear.point(rear, .{ 0, 0.06, 0.28 });
    b.box(f_tail.pitchBy(-0.5), tail, .{ 0.015, 0.2, 0.08 }, .{ 1, 1 }, .{ 1, 0.4 }, BoxLook.uniform(.grey), light);
    b.box(f_tail.pitchBy(0.6), f_rear.point(rear, .{ 0, -0.06, 0.26 }), .{ 0.015, 0.11, 0.06 }, .{ 1, 1 }, .{ 1, 0.4 }, BoxLook.uniform(.grey), light);
}

// --- Tests ---------------------------------------------------------------------------------

const testing = std.testing;

test "birds fly in the air above the island and fish swim in the sea around it" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);

    var c: Creatures = .{};
    c.sync(w, 0);
    try testing.expect(c.spawned);

    // Step forward several seconds of flight and swimming.
    for (0..120) |_| c.tick(w, 1.0 / 20.0);

    for (c.birds) |b| {
        try testing.expect(b.pos[1] > world_mod.sea_level + 3);
        try testing.expect(b.pos[1] < world_mod.size_y - 2);
        const ix: i32 = @intFromFloat(@floor(b.pos[0]));
        const iy: i32 = @intFromFloat(@floor(b.pos[1]));
        const iz: i32 = @intFromFloat(@floor(b.pos[2]));
        try testing.expectEqual(Block.air, w.get(ix, iy, iz));
    }

    // Turtles in the shallows, sharks in deeper water, all in water.
    for (c.swimmers) |s| {
        try testing.expect(waterFor(s.kind, w, s.pos[0], s.pos[2]));
        const ix: i32 = @intFromFloat(@floor(s.pos[0]));
        const iy: i32 = @intFromFloat(@floor(s.pos[1]));
        const iz: i32 = @intFromFloat(@floor(s.pos[2]));
        try testing.expectEqual(Block.water, w.get(ix, iy, iz));
    }
    try testing.expect(c.swimmers.len < c.fish.len / 4);

    for (c.fish) |f| {
        try testing.expect(f.pos[1] < world_mod.sea_level - 0.5);
        try testing.expect(f.pos[1] > 1);
        const ix: i32 = @intFromFloat(@floor(f.pos[0]));
        const iy: i32 = @intFromFloat(@floor(f.pos[1]));
        const iz: i32 = @intFromFloat(@floor(f.pos[2]));
        try testing.expectEqual(Block.water, w.get(ix, iy, iz));
    }
}

test "creature meshes: every quad uses strip 2 and is wound counter-clockwise facing out" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(world_mod.default_seed);

    var c: Creatures = .{};
    c.sync(w, 2.5);

    const cam: math.Camera = .{ .eye = .{ world_mod.size_x / 2, 90, world_mod.size_z / 2 + 86 }, .yaw = 0, .pitch = -0.6 };
    const frustum = math.Frustum.of(math.mul(cam.projection(1.5), cam.view()));
    const verts = try testing.allocator.alloc(Vertex, max_quads * 4);
    defer testing.allocator.free(verts);

    const quads = c.buildMesh(w, &frustum, cam.eye, 250, 0, 0, verts);
    try testing.expect(quads > 400);
    try testing.expect(quads <= max_quads);

    var q: usize = 0;
    while (q < quads) : (q += 1) {
        const v = verts[q * 4 ..][0..4];
        const info = mesher.Info.unpack(v[0].info);
        const tile: Tile = @enumFromInt(info.tile);
        try testing.expectEqual(@as(u2, 2), tile.strip());
        // Both triangles (0 1 2, 0 2 3) have non-zero area and agree on
        // their outward normal.
        const e1 = V3{ v[1].pos[0] - v[0].pos[0], v[1].pos[1] - v[0].pos[1], v[1].pos[2] - v[0].pos[2] };
        const e2 = V3{ v[2].pos[0] - v[0].pos[0], v[2].pos[1] - v[0].pos[1], v[2].pos[2] - v[0].pos[2] };
        const e3 = V3{ v[3].pos[0] - v[0].pos[0], v[3].pos[1] - v[0].pos[1], v[3].pos[2] - v[0].pos[2] };
        const n1 = math.cross(e1, e2);
        const n2 = math.cross(e2, e3);
        try testing.expect(math.dot(n1, n2) > 0);
        const face_n = info.face.normal();
        const fn_v = V3{ @floatFromInt(face_n[0]), @floatFromInt(face_n[1]), @floatFromInt(face_n[2]) };
        try testing.expect(math.dot(n1, fn_v) > 0);
    }
}

test "the seaplane flies past once a day, for a while, high over the sea by the island" {
    for (0..20) |day| {
        var seen: u32 = 0;
        var secs: f32 = 0;
        while (secs < 600) : (secs += 0.5) {
            const p = planeAt(7, @intCast(day), secs) orelse continue;
            seen += 1;
            try testing.expect(p.pos[1] > world_mod.sea_level + 20 and p.pos[1] < world_mod.size_y);
        }
        // Half a minute or so, once.
        try testing.expect(seen > 40 and seen < 80);
        // Near the island at the middle of its flight.
        var nearest: f32 = 999;
        secs = 0;
        while (secs < 600) : (secs += 0.5) if (planeAt(7, @intCast(day), secs)) |p| {
            const d = p.pos - V3{ world_mod.size_x / 2, p.pos[1], world_mod.size_z / 2 };
            nearest = @min(nearest, @sqrt(math.dot(d, d)));
        };
        try testing.expect(nearest > world_mod.atoll_radius - 15 and nearest < world_mod.atoll_radius + 15);
    }
}
