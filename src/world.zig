//! The world: 128 by 128 blocks across and 64 high, in a sea that goes on
//! past its edges (drawn, but not made of blocks). It starts as an island,
//! made from a seed: beaches, hills, a volcano, palms, grass
//! and flowers, and the sea bed around.
//!
//! Each block has light too, as Minecraft does it, from 0 to 15: sunlight
//! (full straight down from the open sky, then a step less for each block
//! it spreads sideways or under something) and lamps' light (a step less
//! for each block from the lamp). Both are kept, so the time of day only
//! changes how bright sunlight is (a uniform in the shader), not the
//! world. Changing a block lights the blocks around it again, within
//! light's reach.
//!
//! The world is in chunks, 16 by 16 blocks and the full height, which are
//! drawn as a mesh each: a change marks the chunks it changes the look of
//! (`dirty`) for the renderer to mesh again.

const std = @import("std");
const blocks = @import("blocks.zig");

const Block = blocks.Block;

pub const size_x = 128;
pub const size_y = 64;
pub const size_z = 128;
/// Water fills everything below this height that is not land.
pub const sea_level = 24;

pub const chunk_size = 16;
pub const chunks_x = size_x / chunk_size;
pub const chunks_z = size_z / chunk_size;
pub const chunk_count = chunks_x * chunks_z;

/// The island a new world starts as.
pub const default_seed = 2;

pub const volume = size_x * size_y * size_z;

/// How far light reaches: an edit can change the light this far away.
const light_reach = 15;

pub const Pos = [3]i32;

/// Light at a block: sunlight in the high four bits, lamps' in the low.
pub fn skyOf(l: u8) u4 {
    return @intCast(l >> 4);
}

pub fn lampOf(l: u8) u4 {
    return @intCast(l & 15);
}

pub const World = struct {
    gpa: std.mem.Allocator,
    blocks: []Block,
    light: []u8,
    seed: u32 = 0,
    /// Chunks whose look changed since they were last meshed.
    dirty: std.StaticBitSet(chunk_count) = .full,
    /// Where players start: on a beach, looking inland.
    spawn: [3]f32 = .{ 64, 40, 64 },
    spawn_yaw: f32 = 0,
    /// For spreading light.
    queue: std.ArrayList(u32) = .empty,

    pub fn create(gpa: std.mem.Allocator) !*World {
        const w = try gpa.create(World);
        errdefer gpa.destroy(w);
        const b = try gpa.alloc(Block, volume);
        errdefer gpa.free(b);
        const l = try gpa.alloc(u8, volume);
        @memset(b, .air);
        @memset(l, 0xf0);
        w.* = .{ .gpa = gpa, .blocks = b, .light = l };
        return w;
    }

    pub fn destroy(w: *World) void {
        w.queue.deinit(w.gpa);
        w.gpa.free(w.blocks);
        w.gpa.free(w.light);
        w.gpa.destroy(w);
    }

    pub inline fn index(x: i32, y: i32, z: i32) u32 {
        return @intCast((y * size_z + z) * size_x + x);
    }

    pub inline fn inBounds(x: i32, y: i32, z: i32) bool {
        return x >= 0 and x < size_x and y >= 0 and y < size_y and z >= 0 and z < size_z;
    }

    /// The block at a place: below the world, rock; above, air; beside it,
    /// the sea.
    pub fn get(w: *const World, x: i32, y: i32, z: i32) Block {
        if (y < 0) return .volcanic_rock;
        if (y >= size_y) return .air;
        if (x < 0 or x >= size_x or z < 0 or z >= size_z) return if (y < sea_level) .water else .air;
        return w.blocks[index(x, y, z)];
    }

    /// The light at a place (outside the world, as the open sea would have).
    pub fn lightAt(w: *const World, x: i32, y: i32, z: i32) u8 {
        if (y < 0) return 0;
        if (y >= size_y) return 0xf0;
        if (x < 0 or x >= size_x or z < 0 or z >= size_z) {
            if (y >= sea_level) return 0xf0;
            const sky = @max(0, 15 - 2 * (sea_level - y));
            return @intCast(sky << 4);
        }
        return w.light[index(x, y, z)];
    }

    /// Changes a block, lighting around it again and marking the chunks
    /// that look different. Returns whether anything changed.
    pub fn set(w: *World, x: i32, y: i32, z: i32, b: Block) bool {
        if (!inBounds(x, y, z) or !b.isValid()) return false;
        const i = index(x, y, z);
        if (w.blocks[i] == b) return false;
        w.blocks[i] = b;
        w.markDirty(x - 1, x + 1, z - 1, z + 1);
        w.relight(x, z) catch {
            // Out of memory: light everything again, more slowly but
            // without the queue growing as much.
            w.computeLight() catch {};
            w.dirty = .full;
        };
        return true;
    }

    /// Marks the chunks holding columns x0..x1, z0..z1 as needing meshing.
    pub fn markDirty(w: *World, x0: i32, x1: i32, z0: i32, z1: i32) void {
        const cx0: usize = @intCast(std.math.clamp(@divFloor(x0, chunk_size), 0, chunks_x - 1));
        const cx1: usize = @intCast(std.math.clamp(@divFloor(x1, chunk_size), 0, chunks_x - 1));
        const cz0: usize = @intCast(std.math.clamp(@divFloor(z0, chunk_size), 0, chunks_z - 1));
        const cz1: usize = @intCast(std.math.clamp(@divFloor(z1, chunk_size), 0, chunks_z - 1));
        for (cz0..cz1 + 1) |cz| for (cx0..cx1 + 1) |cx| w.dirty.set(cz * chunks_x + cx);
    }

    /// The highest block that is not air in a column (-1 if none).
    pub fn top(w: *const World, x: i32, z: i32) i32 {
        var y: i32 = size_y - 1;
        while (y >= 0) : (y -= 1) if (w.get(x, y, z) != .air) return y;
        return -1;
    }

    // --- Light --------------------------------------------------------------------

    /// Sunlight straight down a column, and lamps' own light in it.
    fn lightColumn(w: *World, x: i32, z: i32) void {
        var sky: u8 = 15;
        var y: i32 = size_y - 1;
        while (y >= 0) : (y -= 1) {
            const i = index(x, y, z);
            const b = w.blocks[i];
            if (!b.passesLight()) sky = 0 else sky -|= b.lightLoss();
            w.light[i] = sky << 4 | b.emits();
        }
    }

    /// Spreads the light of the cells in the queue to their neighbours,
    /// within x0..x1 and z0..z1.
    fn spread(w: *World, x0: i32, x1: i32, z0: i32, z1: i32) !void {
        var head: usize = 0;
        while (head < w.queue.items.len) : (head += 1) {
            const i = w.queue.items[head];
            const l = w.light[i];
            if (l & 0xee == 0) continue; // nothing above 1 to spread
            const x: i32 = @intCast(i % size_x);
            const z: i32 = @intCast(i / size_x % size_z);
            const y: i32 = @intCast(i / (size_x * size_z));
            const sky = skyOf(l);
            const lamp = lampOf(l);
            const nbs = [6]Pos{ .{ x + 1, y, z }, .{ x - 1, y, z }, .{ x, y + 1, z }, .{ x, y - 1, z }, .{ x, y, z + 1 }, .{ x, y, z - 1 } };
            for (nbs) |n| {
                if (n[0] < x0 or n[0] > x1 or n[2] < z0 or n[2] > z1 or n[1] < 0 or n[1] >= size_y) continue;
                const j = index(n[0], n[1], n[2]);
                const b = w.blocks[j];
                if (!b.passesLight()) continue;
                const loss: u8 = 1 + @as(u8, b.lightLoss());
                const have = w.light[j];
                const ns = @max(skyOf(have), @as(u8, sky) -| loss);
                const nl = @max(lampOf(have), @as(u8, lamp) -| loss);
                const now = ns << 4 | nl;
                if (now != have) {
                    w.light[j] = now;
                    try w.queue.append(w.gpa, j);
                }
            }
        }
        w.queue.clearRetainingCapacity();
    }

    /// Lights the whole world.
    pub fn computeLight(w: *World) !void {
        var z: i32 = 0;
        while (z < size_z) : (z += 1) {
            var x: i32 = 0;
            while (x < size_x) : (x += 1) w.lightColumn(x, z);
        }
        // Spread from every cell lit more than a neighbour that light
        // passes into would be by it.
        for (w.light, 0..) |l, i| {
            if (l & 0xee == 0) continue;
            if (w.couldSpread(@intCast(i))) try w.queue.append(w.gpa, @intCast(i));
        }
        try w.spread(0, size_x - 1, 0, size_z - 1);
    }

    fn couldSpread(w: *const World, i: u32) bool {
        const l = w.light[i];
        const x: i32 = @intCast(i % size_x);
        const z: i32 = @intCast(i / size_x % size_z);
        const y: i32 = @intCast(i / (size_x * size_z));
        const nbs = [6]Pos{ .{ x + 1, y, z }, .{ x - 1, y, z }, .{ x, y + 1, z }, .{ x, y - 1, z }, .{ x, y, z + 1 }, .{ x, y, z - 1 } };
        for (nbs) |n| {
            if (!inBounds(n[0], n[1], n[2])) continue;
            const j = index(n[0], n[1], n[2]);
            if (!w.blocks[j].passesLight()) continue;
            const have = w.light[j];
            if (@as(u8, skyOf(have)) + 1 < skyOf(l) or @as(u8, lampOf(have)) + 1 < lampOf(l)) return true;
        }
        return false;
    }

    /// Lights again everything a change at column x, z can light
    /// differently, and marks the chunks whose light changed.
    fn relight(w: *World, x: i32, z: i32) !void {
        const x0: i32 = @max(x - light_reach, 0);
        const x1: i32 = @min(x + light_reach, size_x - 1);
        const z0: i32 = @max(z - light_reach, 0);
        const z1: i32 = @min(z + light_reach, size_z - 1);
        const nx: usize = @intCast(x1 - x0 + 1);
        const nz: usize = @intCast(z1 - z0 + 1);
        // What it was, to see what changed.
        const before = try w.gpa.alloc(u8, nx * nz * size_y);
        defer w.gpa.free(before);
        var k: usize = 0;
        var y: i32 = 0;
        while (y < size_y) : (y += 1) {
            var cz = z0;
            while (cz <= z1) : (cz += 1) {
                const row = index(x0, y, cz);
                @memcpy(before[k..][0..nx], w.light[row..][0..nx]);
                k += nx;
            }
        }
        var cz = z0;
        while (cz <= z1) : (cz += 1) {
            var cx = x0;
            while (cx <= x1) : (cx += 1) w.lightColumn(cx, cz);
        }
        // Light comes in from around the box, which stays as it was (light
        // from a change cannot reach it), and spreads from what is lit in it.
        y = 0;
        while (y < size_y) : (y += 1) {
            cz = z0 - 1;
            while (cz <= z1 + 1) : (cz += 1) {
                var cx = x0 - 1;
                while (cx <= x1 + 1) : (cx += 1) {
                    if (!inBounds(cx, y, cz)) continue;
                    const i = index(cx, y, cz);
                    if (w.light[i] & 0xee == 0) continue;
                    const border = cx < x0 or cx > x1 or cz < z0 or cz > z1;
                    if (border or w.couldSpread(i)) try w.queue.append(w.gpa, i);
                }
            }
        }
        try w.spread(x0, x1, z0, z1);
        // Where it changed.
        var lo: [2]i32 = .{ x1 + 1, z1 + 1 };
        var hi: [2]i32 = .{ x0 - 1, z0 - 1 };
        k = 0;
        y = 0;
        while (y < size_y) : (y += 1) {
            cz = z0;
            while (cz <= z1) : (cz += 1) {
                const row = index(x0, y, cz);
                if (!std.mem.eql(u8, before[k..][0..nx], w.light[row..][0..nx])) {
                    for (0..nx) |c| if (before[k + c] != w.light[row + c]) {
                        const cx = x0 + @as(i32, @intCast(c));
                        lo = .{ @min(lo[0], cx), @min(lo[1], cz) };
                        hi = .{ @max(hi[0], cx), @max(hi[1], cz) };
                    };
                }
                k += nx;
            }
        }
        // Corners' light mixes the blocks around them: a block further.
        if (lo[0] <= hi[0]) w.markDirty(lo[0] - 1, hi[0] + 1, lo[1] - 1, hi[1] + 1);
    }

    // --- Making the island -----------------------------------------------------------

    pub fn generate(w: *World, seed: u32) !void {
        w.seed = seed;
        const heights = try w.gpa.alloc(i32, size_x * size_z);
        defer w.gpa.free(heights);
        var rocks: std.StaticBitSet(size_x * size_z) = .empty;
        for (0..size_z) |z| for (0..size_x) |x| {
            const g = groundAt(seed, @floatFromInt(x), @floatFromInt(z));
            heights[z * size_x + x] = @intFromFloat(@floor(g.h));
            rocks.setValue(z * size_x + x, g.rock);
        };
        const hAt = struct {
            fn f(hs: []const i32, x: i32, z: i32) i32 {
                const cx = std.math.clamp(x, 0, size_x - 1);
                const cz = std.math.clamp(z, 0, size_z - 1);
                return hs[@intCast(cz * size_x + cx)];
            }
        }.f;
        @memset(w.blocks, .air);
        var z: i32 = 0;
        while (z < size_z) : (z += 1) {
            var x: i32 = 0;
            while (x < size_x) : (x += 1) {
                const h = hAt(heights, x, z);
                var slope: i32 = 0;
                for ([_][2]i32{ .{ 1, 0 }, .{ -1, 0 }, .{ 0, 1 }, .{ 0, -1 } }) |d| slope = @max(slope, @as(i32, @intCast(@abs(hAt(heights, x + d[0], z + d[1]) - h))));
                const fx: f32 = @floatFromInt(x);
                const fz: f32 = @floatFromInt(z);
                const bare_line: i32 = 47 + @as(i32, @intFromFloat(fbm(seed +% 11, fx / 7, fz / 7, 2) * 4));
                // The top few blocks, and what is under them.
                const surface: [2]Block, const depth: i32 = if (rocks.isSet(@intCast(z * size_x + x)))
                    .{ .{ .volcanic_rock, .volcanic_rock }, 1 }
                else if (h < sea_level - 1)
                    .{ .{ .sand, .sand }, 2 }
                else if (h <= sea_level + 1)
                    .{ .{ .sand, .sand }, 3 }
                else if (h >= bare_line)
                    .{ .{ .volcanic_rock, .volcanic_rock }, 1 }
                else if (slope >= 3 and h > sea_level + 4)
                    .{ .{ .volcanic_rock, .volcanic_rock }, 1 }
                else
                    .{ .{ .grass, .dirt }, 4 };
                var y: i32 = 0;
                while (y <= h) : (y += 1) {
                    const b: Block = if (y == h) surface[0] else if (y > h - depth) surface[1] else if (y > h - depth - 5 and surface[0] == .sand and h >= sea_level - 1) .sandstone else .volcanic_rock;
                    w.blocks[index(x, y, z)] = b;
                }
                while (y < sea_level) : (y += 1) w.blocks[index(x, y, z)] = .water;
            }
        }
        w.growTrees(heights);
        w.growPlants();
        w.findSpawn(heights);
        try w.computeLight();
        w.dirty = .full;
    }

    fn growTrees(w: *World, heights: []const i32) void {
        const seed = w.seed;
        const grid = 7;
        var gz: i32 = 0;
        while (gz < size_z / grid) : (gz += 1) {
            var gx: i32 = 0;
            while (gx < size_x / grid) : (gx += 1) {
                // One place in each cell of the grid may have a palm, so
                // palms are never too close.
                const x = gx * grid + @as(i32, @intFromFloat(hash(seed +% 21, gx, gz) * (grid - 2))) + 1;
                const z = gz * grid + @as(i32, @intFromFloat(hash(seed +% 22, gx, gz) * (grid - 2))) + 1;
                const h = heights[@intCast(z * size_x + x)];
                const ground = w.get(x, h, z);
                // On grass, in groves; on the beaches, here and there.
                const chance: f32 = if (ground == .grass) blk: {
                    const grove = fbm(seed +% 23, @as(f32, @floatFromInt(x)) / 20, @as(f32, @floatFromInt(z)) / 20, 3);
                    break :blk if (grove > 0.55) 0.7 else if (grove > 0.42) 0.3 else 0.06;
                } else if (ground == .sand and h >= sea_level) 0.4 else 0;
                if (hash(seed +% 24, gx, gz) >= chance) continue;
                const trunk: i32 = 4 + @as(i32, @intFromFloat(hash(seed +% 25, gx, gz) * 4));
                w.tree(x, h + 1, z, trunk, seed +% @as(u32, @bitCast(gx * 977 + gz)));
            }
        }
    }

    /// A palm: a trunk `trunk` blocks high from (x, y, z) (the fronds
    /// and coconuts at its top are drawn, not blocks).
    pub fn tree(w: *World, x: i32, y: i32, z: i32, trunk: i32, seed: u32) void {
        _ = seed;
        if (y + trunk + 1 >= size_y) return;
        var i: i32 = 0;
        while (i < trunk) : (i += 1) w.blocks[index(x, y + i, z)] = .palm;
    }

    /// Grass and ferns about the island, and meadows: grass with patches
    /// of flowers, each patch its own colour.
    fn growPlants(w: *World) void {
        const seed = w.seed;
        var z: i32 = 0;
        while (z < size_z) : (z += 1) {
            var x: i32 = 0;
            while (x < size_x) : (x += 1) {
                const h = w.top(x, z);
                if (h < 0 or h + 1 >= size_y or w.blocks[index(x, h, z)] != .grass) continue;
                const fx: f32 = @floatFromInt(x);
                const fz: f32 = @floatFromInt(z);
                const meadow = fbm(seed +% 31, fx / 12, fz / 12, 2);
                const r = hash(seed +% 32, x, z);
                const b: Block = if (meadow > 0.56) blk: {
                    // Patches a few blocks across, each of one colour.
                    const patch = fbm(seed +% 33, fx / 4, fz / 4, 1);
                    const colour: usize = @intFromFloat(@floor(hash(seed +% 34, @intFromFloat(@floor(fx / 5 + patch * 3)), @intFromFloat(@floor(fz / 5 + patch * 2))) * Block.flowers.len));
                    if (r < 0.45) break :blk Block.flowers[colour];
                    if (r < 0.8) break :blk .tall_grass;
                    continue;
                } else if (r < 0.012)
                    .fern
                else if (r < meadow * 0.35)
                    .tall_grass
                else
                    continue;
                w.blocks[index(x, h + 1, z)] = b;
            }
        }
    }

    /// On the widest beach, at the water's edge, looking inland at the
    /// mountain.
    fn findSpawn(w: *World, heights: []const i32) void {
        const centre = [2]f32{ size_x / 2, size_z / 2 };
        var best: [2]i32 = .{ size_x / 2, size_z / 2 };
        var best_width: i32 = -1;
        // Out from the middle in each of 32 directions: the sand before
        // the sea.
        for (0..32) |i| {
            const a = @as(f32, @floatFromInt(i)) * std.math.pi / 16;
            var sand: i32 = 0;
            var edge: ?[2]i32 = null;
            var r: f32 = 4;
            while (r < size_x / 2) : (r += 1) {
                const x: i32 = @intFromFloat(centre[0] + @cos(a) * r);
                const z: i32 = @intFromFloat(centre[1] + @sin(a) * r);
                const h = heights[@intCast(z * size_x + x)];
                if (h < sea_level) break;
                if (w.get(x, h, z) == .sand and w.get(x, h + 1, z) == .air) {
                    sand += 1;
                    edge = .{ x, z };
                } else sand = 0;
            }
            if (edge) |e| if (sand > best_width) {
                best_width = sand;
                best = e;
            };
        }
        const x = best[0];
        const z = best[1];
        var y = w.top(x, z) + 1;
        while (y < size_y - 2 and (w.get(x, y, z).isSolid() or w.get(x, y + 1, z).isSolid())) : (y += 1) {}
        w.spawn = .{ @as(f32, @floatFromInt(x)) + 0.5, @floatFromInt(y), @as(f32, @floatFromInt(z)) + 0.5 };
        // Facing the mountain (yaw 0 faces -z; positive turns to +x).
        const dx = size_x * 0.58 - w.spawn[0];
        const dz = size_z * 0.42 - w.spawn[2];
        w.spawn_yaw = std.math.atan2(dx, -dz);
    }

    // --- Saving ------------------------------------------------------------------------

    pub const magic = "DZBW";
    /// 2: palms. Worlds from before (1) are read too: their trees' logs
    /// are palms' trunks now (the same number), and the leaves round
    /// their tops are taken away (see `fromTrees`).
    pub const version = 2;

    /// The world's blocks, run-length encoded (light is worked out again
    /// on loading).
    pub fn encode(w: *const World, out: *std.ArrayList(u8), gpa: std.mem.Allocator) !void {
        try out.appendSlice(gpa, magic);
        try out.append(gpa, version);
        var hdr: [10]u8 = undefined;
        std.mem.writeInt(u16, hdr[0..2], size_x, .little);
        std.mem.writeInt(u16, hdr[2..4], size_y, .little);
        std.mem.writeInt(u16, hdr[4..6], size_z, .little);
        std.mem.writeInt(u32, hdr[6..10], w.seed, .little);
        try out.appendSlice(gpa, &hdr);
        var i: usize = 0;
        while (i < w.blocks.len) {
            const b = w.blocks[i];
            var n: usize = 1;
            while (n < 256 and i + n < w.blocks.len and w.blocks[i + n] == b) n += 1;
            try out.appendSlice(gpa, &.{ @intCast(n - 1), @intFromEnum(b) });
            i += n;
        }
    }

    /// For a world from before palms: its trees' trunks are palms now,
    /// and the leaves that were their tops are taken away, as palms' own
    /// fronds are drawn. The leaves taken are those around the top of a
    /// trunk with leaves on it, as far out as a tree's reached: leaves
    /// built elsewhere stay.
    fn fromTrees(w: *World) void {
        var y: i32 = 0;
        while (y < size_y - 1) : (y += 1) {
            var z: i32 = 0;
            while (z < size_z) : (z += 1) {
                var x: i32 = 0;
                while (x < size_x) : (x += 1) {
                    if (w.blocks[index(x, y, z)] != .palm or w.blocks[index(x, y + 1, z)] != .leaves) continue;
                    var dy: i32 = -2;
                    while (dy <= 2) : (dy += 1) {
                        var dz: i32 = -2;
                        while (dz <= 2) : (dz += 1) {
                            var dx: i32 = -2;
                            while (dx <= 2) : (dx += 1) {
                                const lx = x + dx;
                                const ly = y + dy;
                                const lz = z + dz;
                                if (inBounds(lx, ly, lz) and w.blocks[index(lx, ly, lz)] == .leaves) w.blocks[index(lx, ly, lz)] = .air;
                            }
                        }
                    }
                }
            }
        }
    }

    /// Reads what `encode` wrote; returns how many bytes it took.
    pub fn decode(w: *World, data: []const u8) !usize {
        if (data.len < 15 or !std.mem.eql(u8, data[0..4], magic) or data[4] < 1 or data[4] > version) return error.NotAWorld;
        const from = data[4];
        if (std.mem.readInt(u16, data[5..7], .little) != size_x or std.mem.readInt(u16, data[7..9], .little) != size_y or std.mem.readInt(u16, data[9..11], .little) != size_z) return error.WrongSize;
        w.seed = std.mem.readInt(u32, data[11..15], .little);
        var at: usize = 15;
        var i: usize = 0;
        while (i < w.blocks.len) {
            if (at + 2 > data.len) return error.Truncated;
            const n = @as(usize, data[at]) + 1;
            // As saved: removed kinds are read as others after (an old
            // world's trees need its leaves).
            const b: Block = @enumFromInt(data[at + 1]);
            if (!b.current().isValid() or i + n > w.blocks.len) return error.Corrupt;
            @memset(w.blocks[i..][0..n], b);
            i += n;
            at += 2;
        }
        if (from < 2) w.fromTrees();
        for (w.blocks) |*b| b.* = b.current();
        try w.computeLight();
        w.dirty = .full;
        return at;
    }
};

// --- Noise ------------------------------------------------------------------------------

pub fn hash(seed: u32, x: i32, z: i32) f32 {
    var h: u32 = seed *% 0x9e3779b9 ^ @as(u32, @bitCast(x)) *% 0x85ebca6b ^ @as(u32, @bitCast(z)) *% 0xc2b2ae35;
    h ^= h >> 16;
    h *%= 0x7feb352d;
    h ^= h >> 15;
    h *%= 0x846ca68b;
    h ^= h >> 16;
    return @as(f32, @floatFromInt(h & 0xffffff)) / 16777216.0;
}

/// Smooth noise from 0 to 1.
fn noise(seed: u32, x: f32, z: f32) f32 {
    const ix: i32 = @intFromFloat(@floor(x));
    const iz: i32 = @intFromFloat(@floor(z));
    const fx = x - @floor(x);
    const fz = z - @floor(z);
    const sx = fx * fx * (3 - 2 * fx);
    const sz = fz * fz * (3 - 2 * fz);
    const a = hash(seed, ix, iz);
    const b = hash(seed, ix + 1, iz);
    const c = hash(seed, ix, iz + 1);
    const d = hash(seed, ix + 1, iz + 1);
    return (a + (b - a) * sx) * (1 - sz) + (c + (d - c) * sx) * sz;
}

/// Noise at several scales, from 0 to 1.
fn fbm(seed: u32, x: f32, z: f32, octaves: u32) f32 {
    var sum: f32 = 0;
    var amp: f32 = 1;
    var total: f32 = 0;
    var f: f32 = 1;
    for (0..octaves) |o| {
        sum += noise(seed +% @as(u32, @intCast(o)) *% 101, x * f, z * f) * amp;
        total += amp;
        amp *= 0.5;
        f *= 2;
    }
    return sum / total;
}

/// The ground at a place: how high it is, and whether it is bare rock.
pub const Ground = struct { h: f32, rock: bool = false };

/// The ground at a place: an island in the middle, its coast made uneven
/// by noise; a beach all at one height (a block above the sea) and wide;
/// shallow sea around it, then the sea bed falling away. In places rocky
/// headlands take the beach's place and run out into the sea, and rocks
/// stand on the beaches. Inland, rolling hills, and a mountain
/// off-centre.
pub fn groundAt(seed: u32, x: f32, z: f32) Ground {
    const sea: f32 = sea_level;
    // The beach's top is at the water's surface.
    const beach: f32 = sea - 1;
    const dx = (x - size_x / 2) / 58;
    const dz = (z - size_z / 2) / 58;
    const warp = (fbm(seed +% 1, x / 26, z / 26, 4) - 0.5) * 0.7;
    const r = @sqrt(dx * dx + dz * dz) + warp;
    const land = 1 - r;
    // Where the coast is, and how far the beach reaches inland.
    const coast = 0.36;
    const beach_end = 0.52;
    // Headlands: rock in stretches of the coast, out into the sea.
    const headland = std.math.clamp((fbm(seed +% 5, x / 22, z / 22, 3) - 0.56) * 7, 0, 1);
    const rough = fbm(seed +% 6, x / 4, z / 4, 2);
    if (land < beach_end and headland > 0) {
        const out = @max(0, coast - land);
        const rock_h = beach + 1 + headland * 3 + rough * 2.5 - out * 40 - @max(0, land - coast) * 4;
        if (rock_h >= beach and (land < coast or headland > 0.25)) return .{ .h = @max(rock_h, beach), .rock = true };
    }
    if (land < coast) {
        // Shallow sea, a block or two deep; further out, the sea bed falls
        // away.
        const bed = fbm(seed +% 2, x / 10, z / 10, 2);
        if (land > coast - 0.22) return .{ .h = beach - 1 - bed * 1.6 };
        return .{ .h = @max(beach - 2.6 - (coast - 0.22 - land) * 40, sea - 11) + bed * 2 };
    }
    if (land < beach_end) {
        // Rocks here and there on the sand.
        if (fbm(seed +% 7, x / 3.5, z / 3.5, 2) > 0.74) return .{ .h = beach + 1 + rough, .rock = true };
        return .{ .h = beach };
    }
    const inland = std.math.clamp((land - beach_end) / 0.4, 0, 1);
    const hills = (fbm(seed +% 3, x / 22, z / 22, 4) - 0.3) * 14 * inland;
    // The mountain.
    const mx = x - size_x * 0.58;
    const mz = z - size_z * 0.42;
    const md = @max(0, 1 - @sqrt(mx * mx + mz * mz) / 34);
    const ridge = 1 - @abs(fbm(seed +% 4, x / 12, z / 12, 3) * 2 - 1);
    const mountain = md * md * (22 + ridge * 12);
    return .{ .h = std.math.clamp(beach + inland * 7 + @max(hills, 0) + mountain, 3, size_y - 6) };
}

const testing = std.testing;

test "the island: land in the middle, sea at the edges, a beach, trees and plants" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(1234);
    // The edges are under the sea.
    for ([_][2]i32{ .{ 0, 0 }, .{ 127, 0 }, .{ 0, 127 }, .{ 127, 127 }, .{ 64, 0 }, .{ 0, 64 } }) |c| {
        try testing.expect(w.top(c[0], c[1]) == sea_level - 1);
        try testing.expectEqual(Block.water, w.get(c[0], sea_level - 1, c[1]));
    }
    // Land above the sea in the middle, high in places.
    var land: u32 = 0;
    var highest: i32 = 0;
    var counts = std.EnumArray(Block, u32).initFill(0);
    for (0..size_z) |z| for (0..size_x) |x| {
        const t = w.top(@intCast(x), @intCast(z));
        if (t >= sea_level) land += 1;
        highest = @max(highest, t);
    };
    for (w.blocks) |b| counts.getPtr(b).* += 1;
    try testing.expect(land > 3000 and land < 12000);
    try testing.expect(highest > sea_level + 16);
    for ([_]Block{ .grass, .sand, .palm, .tall_grass, .fern, .volcanic_rock }) |b| try testing.expect(counts.get(b) > 0);
    var flowers: usize = 0;
    for (Block.flowers) |b| flowers += counts.get(b);
    try testing.expect(flowers > 0);
    // The spawn point is free, on land.
    const s = w.spawn;
    const sx: i32 = @intFromFloat(s[0]);
    const sy: i32 = @intFromFloat(s[1]);
    const sz: i32 = @intFromFloat(s[2]);
    try testing.expect(!w.get(sx, sy, sz).isSolid() and !w.get(sx, sy + 1, sz).isSolid());
    try testing.expect(sy >= sea_level);
    // The same seed, the same island.
    const w2 = try World.create(testing.allocator);
    defer w2.destroy();
    try w2.generate(1234);
    try testing.expect(std.mem.eql(Block, w.blocks, w2.blocks));
}

test "light: full in the open, none under rock, spreading from lamps" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    // A flat floor of stone at y = 10.
    for (0..size_z) |z| for (0..size_x) |x| {
        w.blocks[World.index(@intCast(x), 10, @intCast(z))] = .volcanic_rock;
    };
    try w.computeLight();
    try testing.expectEqual(@as(u4, 15), skyOf(w.lightAt(5, 11, 5)));
    try testing.expectEqual(@as(u4, 0), skyOf(w.lightAt(5, 9, 5)));
    // A roof over a corner of open air: light spreads in under it.
    _ = w.set(50, 12, 50, .volcanic_rock);
    try testing.expectEqual(@as(u4, 14), skyOf(w.lightAt(50, 11, 50)));
    // A lamp in the dark under the floor.
    _ = w.set(30, 5, 30, .lamp);
    try testing.expectEqual(@as(u4, 14), lampOf(w.lightAt(31, 5, 30)));
    try testing.expectEqual(@as(u4, 12), lampOf(w.lightAt(33, 5, 30)));
    try testing.expectEqual(@as(u4, 0), skyOf(w.lightAt(31, 5, 30)));
    // Taken away: dark again.
    _ = w.set(30, 5, 30, .air);
    try testing.expectEqual(@as(u4, 0), lampOf(w.lightAt(31, 5, 30)));
    // A hole in the floor lets sunlight down.
    _ = w.set(70, 10, 70, .air);
    try testing.expectEqual(@as(u4, 15), skyOf(w.lightAt(70, 5, 70)));
    try testing.expectEqual(@as(u4, 14), skyOf(w.lightAt(71, 5, 70)));
    // Relit locally, the light is what lighting everything gives.
    const local = try testing.allocator.dupe(u8, w.light);
    defer testing.allocator.free(local);
    try w.computeLight();
    try testing.expect(std.mem.eql(u8, local, w.light));
}

test "an edit marks the chunks it changes the look of" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(7);
    w.dirty = .empty;
    // High in the open air: only the light right around it changes.
    try testing.expect(w.set(40, 60, 40, .volcanic_rock));
    try testing.expect(w.dirty.isSet(2 * chunks_x + 2));
    try testing.expect(!w.dirty.isSet(7 * chunks_x + 7));
    try testing.expect(!w.set(40, 60, 40, .volcanic_rock));
    try testing.expect(!w.set(-1, 60, 40, .volcanic_rock));
}

test "saving and loading give back the same world" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    try w.generate(99);
    _ = w.set(10, 40, 10, .lamp);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try w.encode(&out, testing.allocator);
    // Much smaller than a byte a block.
    try testing.expect(out.items.len < volume / 8);
    const back = try World.create(testing.allocator);
    defer back.destroy();
    try testing.expectEqual(out.items.len, try back.decode(out.items));
    try testing.expect(std.mem.eql(Block, w.blocks, back.blocks));
    try testing.expect(std.mem.eql(u8, w.light, back.light));
    try testing.expectEqual(@as(u32, 99), back.seed);
    try testing.expectError(error.NotAWorld, back.decode("nope"));
    try testing.expectError(error.Truncated, back.decode(out.items[0..100]));
}

test "a world from before palms: trees' trunks are palms, without their leaves; leaves built stay" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    // An old tree, as trees were made: a trunk of logs (the number palms
    // have now) with leaves round its top.
    const top: i32 = 30;
    var y: i32 = 25;
    while (y < top) : (y += 1) w.blocks[World.index(20, y, 20)] = .palm;
    var dy: i32 = -3;
    while (dy <= 1) : (dy += 1) {
        var dz: i32 = -2;
        while (dz <= 2) : (dz += 1) {
            var dx: i32 = -2;
            while (dx <= 2) : (dx += 1) {
                const i = World.index(20 + dx, top + dy, 20 + dz);
                if (w.blocks[i] == .air) w.blocks[i] = .leaves;
            }
        }
    }
    // A hedge.
    for (0..5) |x| w.blocks[World.index(@intCast(60 + x), 25, 60)] = .leaves;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try w.encode(&out, testing.allocator);
    out.items[4] = 1;
    const back = try World.create(testing.allocator);
    defer back.destroy();
    _ = try back.decode(out.items);
    var hedge: usize = 0;
    var palms: usize = 0;
    for (back.blocks) |b| {
        if (b == .green) hedge += 1;
        if (b == .palm) palms += 1;
    }
    // Leaves are gone since: the hedge is green paint.
    try testing.expectEqual(@as(usize, 5), hedge);
    try testing.expectEqual(@as(usize, 5), palms);
    // Read as it is now, no leaves are taken (all are paint).
    out.items[4] = World.version;
    _ = try back.decode(out.items);
    var green: usize = 0;
    for (back.blocks) |b| {
        if (b == .green) green += 1;
    }
    try testing.expect(green > 5);
}

test "removed kinds of block are read as the ones most like them" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    w.blocks[World.index(5, 30, 5)] = .iron;
    w.blocks[World.index(6, 30, 5)] = .gold;
    w.blocks[World.index(7, 30, 5)] = .snow;
    w.blocks[World.index(8, 30, 5)] = .clay;
    w.blocks[World.index(9, 30, 5)] = .gravel;
    w.blocks[World.index(10, 30, 5)] = .planks;
    w.blocks[World.index(11, 30, 5)] = .volcanic_bricks;
    w.blocks[World.index(12, 30, 5)] = .coral_stone;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(testing.allocator);
    try w.encode(&out, testing.allocator);
    _ = try w.decode(out.items);
    try testing.expectEqual(Block.volcanic_wall, w.get(5, 30, 5));
    try testing.expectEqual(Block.yellow, w.get(6, 30, 5));
    try testing.expectEqual(Block.volcanic_rock, w.get(7, 30, 5));
    try testing.expectEqual(Block.sand, w.get(8, 30, 5));
    try testing.expectEqual(Block.sand, w.get(9, 30, 5));
    try testing.expectEqual(Block.sticks, w.get(10, 30, 5));
    try testing.expectEqual(Block.volcanic_wall, w.get(11, 30, 5));
    try testing.expectEqual(Block.sandstone, w.get(12, 30, 5));
}
