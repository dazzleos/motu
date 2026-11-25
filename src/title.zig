//! The title scene: what is behind the menu before an island is joined
//! (and after one is left). A map, title.motu, as islands are kept (see
//! Game.encode), made into Motu.
//!
//! The camera stands on its cyan block (`camera_block`), always facing
//! the same way (north: towards -z, `yaw`), at the same time of day
//! (`time_of_day`); the weather is always fair (Game.weather). Its
//! creatures are the title scene's (creatures.zig: one pod of dolphins and
//! a turtle, ahead of the camera), as its world's seed is
//! `World.title_seed`.
//!
//! To change it: copy title.motu to the islands folder (on Linux,
//! ~/.local/share/motu, or ~/snap/motu/common in the snap) under another
//! name (Title.motu), join it from the menu, change it (keeping one cyan
//! block, where the camera stands), leave it (it is saved) and copy it
//! back here.

const std = @import("std");
const blocks = @import("blocks.zig");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const player_mod = @import("player.zig");
const seen_mod = @import("seen.zig");

const Block = blocks.Block;
const World = world_mod.World;
const Game = game_mod.Game;

pub const data = @embedFile("title.motu");

/// What the camera stands on.
pub const camera_block: Block = .cyan;
/// Which way it faces (yaw 0 faces -z), a little down.
pub const yaw: f32 = 0;
pub const pitch: f32 = -0.04;
/// The time of day (0.4: mid-morning).
pub const time_of_day: f32 = 0.4;

/// The title scene into `g`: its world, and the camera on its cyan block.
pub fn load(g: *Game) !void {
    try g.decode(data);
    const w = g.world;
    const at = find(w) orelse return error.NoCameraBlock;
    w.spawn = .{ @as(f32, @floatFromInt(at[0])) + 0.5, @floatFromInt(at[1] + 1), @as(f32, @floatFromInt(at[2])) + 0.5 };
    w.spawn_yaw = yaw;
    g.player = .{ .pos = w.spawn, .yaw = yaw, .pitch = pitch };
    g.time_of_day = time_of_day;
}

/// The one place the title scene is seen from (its camera never moves),
/// for the renderer to draw only what is seen from there (see seen.zig):
/// the camera on the cyan block (`w.spawn`, once loaded).
pub fn fixedView(w: *const World) seen_mod.View {
    const p: player_mod.Player = .{ .pos = w.spawn, .yaw = yaw, .pitch = pitch };
    return .{ .camera = p.camera() };
}

/// Where the cyan block is (the highest, if there are more).
fn find(w: *const World) ?world_mod.Pos {
    var y: i32 = world_mod.size_y - 1;
    while (y >= 0) : (y -= 1) {
        var z: i32 = 0;
        while (z < world_mod.size_z) : (z += 1) {
            var x: i32 = 0;
            while (x < world_mod.size_x) : (x += 1) {
                if (w.blocks[World.index(x, y, z)] == camera_block) return .{ x, y, z };
            }
        }
    }
    return null;
}

const testing = std.testing;

test "the title scene: the camera on its block, the seed the title's, and every kind of plant ahead of it" {
    const w = try World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    defer g.deinit();
    try load(&g);
    try testing.expectEqual(World.title_seed, w.seed);
    const c = find(w).?;
    try testing.expectEqual(camera_block, w.get(c[0], c[1], c[2]));
    try testing.expect(!w.get(c[0], c[1] + 1, c[2]).isSolid() and !w.get(c[0], c[1] + 2, c[2]).isSolid());
    try testing.expectEqual(w.spawn, g.player.pos);
    // Ahead (the way it looks), within sixty blocks: every plant.
    var seen: std.EnumSet(Block) = .empty;
    const fwd = [2]f32{ @sin(g.player.yaw), -@cos(g.player.yaw) };
    var z: i32 = 0;
    while (z < world_mod.size_z) : (z += 1) {
        var x: i32 = 0;
        while (x < world_mod.size_x) : (x += 1) {
            const dx = @as(f32, @floatFromInt(x - c[0]));
            const dz = @as(f32, @floatFromInt(z - c[2]));
            const ahead = dx * fwd[0] + dz * fwd[1];
            if (ahead < 0 or ahead > 60 or @abs(dx * fwd[1] - dz * fwd[0]) > 60) continue;
            var y: i32 = 0;
            while (y < world_mod.size_y) : (y += 1) seen.insert(w.get(x, y, z));
        }
    }
    for ([_]Block{ .palm, .bamboo, .banana, .mangrove, .hibiscus, .frangipani, .leafy_plant, .tall_grass, .seagrass, .coral } ++ Block.flowers) |b| {
        if (!seen.contains(b)) std.debug.print("missing {s}\n", .{@tagName(b)});
        try testing.expect(seen.contains(b));
    }
}
