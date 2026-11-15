//! The kinds of block: how each is drawn (a solid cube, a see-through
//! cube, water, a palm's trunk, a plant or furniture), which of the atlas's tiles
//! each face shows, the light it gives, and its name.
//!
//! Each kind's number is what worlds are saved with, so they are only
//! ever added to: the trunk and the plants took the numbers of the log,
//! tall grass and flowers they replaced.

const std = @import("std");

pub const Block = enum(u8) {
    air,
    grass,
    dirt,
    volcanic_rock,
    volcanic_wall,
    sand,
    sandstone,
    /// Removed: read as sand (see `current`).
    gravel,
    /// Removed: read as sand.
    clay,
    /// Removed: read as volcanic rock.
    snow,
    water,
    /// A palm's trunk: a round pole, with fronds and coconuts at its top.
    palm,
    /// Removed: read as stick wall.
    planks,
    /// Removed: read as green paint.
    leaves,
    /// Removed: read as stick wall.
    dark_planks,
    glass,
    /// Removed: read as sandstone.
    sandstone_bricks,
    /// Removed: read as volcanic wall.
    volcanic_bricks,
    thatch,
    /// Removed: read as sandstone.
    plaster,
    /// Removed: read as volcanic wall.
    iron,
    /// Removed: read as yellow paint.
    gold,
    /// A bamboo torch, its flame burning: on a stick, raised.
    lamp,
    /// Removed: read as a table (stacked, they make shelves).
    bookshelf,
    white,
    black,
    red,
    orange,
    yellow,
    green,
    blue,
    purple,
    pink,
    cyan,
    tall_grass,
    red_flower,
    yellow_flower,
    /// Big arrow-shaped leaves on tall stalks.
    leafy_plant,
    pink_flower,
    purple_flower,
    blue_flower,
    white_flower,
    orange_flower,
    /// Grass with flat round stones set in it, for paths: the stones join
    /// up with the next paving's.
    paving,
    /// Removed: read as sandstone.
    coral_stone,
    /// Straight poles side by side, lashed together, for walls.
    sticks,
    /// Living coral, for reefs.
    coral,
    /// A table top on four legs: tables side by side make one bigger
    /// table (legs only at its corners), and stacked they make shelves.
    table,
    /// A low frame of sticks with a mattress and a pillow: beds side by
    /// side or end to end make one bigger bed.
    bed,
    /// A treasure chest.
    chest,
    /// A single stick of bamboo, upright: a lamp on one is raised.
    post,
    /// Half a block, its lower half: sandstone, rock and thatch.
    sandstone_slab,
    rock_slab,
    thatch_slab,
    /// Rungs between two rails, against the wall beside it: climbed.
    ladder,
    /// A post, with rails to fences (and walls) beside it.
    fence,
    /// A fire in a ring of stones, giving light.
    campfire,
    /// Ribbons of grass under the water (the block is water too).
    seagrass,
    /// Canes of bamboo, leaves at their tops.
    bamboo,
    _,

    pub const Shape = enum {
        none,
        /// A cube that hides what is behind it and casts shadows.
        cube,
        /// A cube drawn see-through (glass).
        clear,
        water,
        /// A round pole up the middle of the block (a palm's trunk), with
        /// a crown of fronds on top: solid, but hiding nothing.
        pole,
        /// Fronds and blades from the ground, drawn see-through, not in
        /// the way.
        plant,
        /// Made of parts smaller than the block (see furniture.zig):
        /// solid, but hiding nothing.
        furniture,
    };

    pub fn shape(b: Block) Shape {
        return switch (b) {
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf => .none,
            .table, .bed, .chest, .post, .lamp, .sandstone_slab, .rock_slab, .thatch_slab, .ladder, .fence, .campfire, .bamboo => .furniture,
            .water => .water,
            .glass => .clear,
            .palm => .pole,
            .tall_grass, .seagrass, .leafy_plant, .red_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower, .orange_flower => .plant,
            _ => .none,
            else => .cube,
        };
    }

    /// Hides the faces next to it, shades corners (ambient occlusion) and
    /// stops light.
    pub fn isOpaque(b: Block) bool {
        return b.shape() == .cube;
    }

    /// The player cannot walk through it.
    pub fn isSolid(b: Block) bool {
        return b.solidHeight() > 0;
    }

    /// How high the part of it the player cannot walk through is, from
    /// its bottom (0: none of it; 1: all of it).
    pub fn solidHeight(b: Block) f32 {
        return switch (b) {
            .sandstone_slab, .rock_slab, .thatch_slab => 0.5,
            .ladder, .campfire => 0,
            else => switch (b.shape()) {
                .cube, .clear, .pole, .furniture => 1,
                else => 0,
            },
        };
    }

    /// Water, or what is in water (and holds it too).
    pub fn isWatery(b: Block) bool {
        return b == .water or b == .seagrass;
    }

    /// How much more than a step light loses going through it: sunlight
    /// dims under water.
    pub fn lightLoss(b: Block) u4 {
        return switch (b) {
            .water => 2,
            else => 0,
        };
    }

    /// Whether light passes through at all.
    pub fn passesLight(b: Block) bool {
        return !b.isOpaque();
    }

    /// The light it gives (0 to 15).
    pub fn emits(b: Block) u4 {
        return switch (b) {
            .lamp => 15,
            .campfire => 14,
            else => 0,
        };
    }

    /// The tile on its face `face` (see `Face`).
    pub fn tile(b: Block, face: Face) Tile {
        const top = face == .up;
        const bottom = face == .down;
        return switch (b) {
            .grass, .paving => if (top) .grass_top else if (bottom) .dirt else .grass_side,
            .dirt => .dirt,
            .volcanic_rock => .volcanic_rock,
            .volcanic_wall => .volcanic_wall,
            .sand => .sand,
            .sandstone => if (top or bottom) .sandstone_top else .sandstone_side,
            .palm => .palm_bark,
            .glass => .glass,
            .thatch => .thatch,
            .coral => .coral,
            .sticks => if (top or bottom) .sticks_top else .sticks_side,
            .lamp => .lamp,
            .table => if (top or bottom) .sticks_top else .sticks_side,
            .post, .bamboo => .bamboo,
            .sandstone_slab => if (top or bottom) .sandstone_top else .sandstone_side,
            .rock_slab => .volcanic_rock,
            .thatch_slab => .thatch,
            .ladder, .fence => if (top or bottom) .sticks_top else .sticks_side,
            .campfire => .lamp,
            .seagrass => .seagrass,
            .bed => .bed_cover,
            .chest => if (top or bottom) .chest_top else .chest_side,
            .white => .white,
            .black => .black,
            .red => .red,
            .orange => .orange,
            .yellow => .yellow,
            .green => .green,
            .blue => .blue,
            .purple => .purple,
            .pink => .pink,
            .cyan => .cyan,
            .tall_grass => .tall_grass,
            .leafy_plant => .leafy_plant,
            .red_flower => .red_flower,
            .yellow_flower => .yellow_flower,
            .pink_flower => .pink_flower,
            .purple_flower => .purple_flower,
            .blue_flower => .blue_flower,
            .white_flower => .white_flower,
            .orange_flower => .orange_flower,
            .water => .water,
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf, _ => .volcanic_rock,
        };
    }

    pub fn name(b: Block) []const u8 {
        return switch (b) {
            .air => "Air",
            .grass => "Grass",
            .dirt => "Dirt",
            .volcanic_rock => "Volcanic rock",
            .volcanic_wall => "Volcanic wall",
            .sand => "Sand",
            .sandstone => "Sandstone",
            .water => "Water",
            .palm => "Palm",
            .glass => "Glass",
            .thatch => "Thatch",
            .lamp => "Lamp",
            .table => "Table",
            .bed => "Bed",
            .chest => "Treasure chest",
            .post => "Stick",
            .sandstone_slab => "Sandstone slab",
            .rock_slab => "Rock slab",
            .thatch_slab => "Thatch slab",
            .ladder => "Ladder",
            .fence => "Fence",
            .campfire => "Campfire",
            .seagrass => "Seagrass",
            .bamboo => "Bamboo",
            .white => "White",
            .black => "Black",
            .red => "Red",
            .orange => "Orange",
            .yellow => "Yellow",
            .green => "Green",
            .blue => "Blue",
            .purple => "Purple",
            .pink => "Pink",
            .cyan => "Cyan",
            .tall_grass => "Tall grass",
            .leafy_plant => "Leafy plant",
            .red_flower => "Red flowers",
            .yellow_flower => "Yellow flowers",
            .pink_flower => "Pink flowers",
            .purple_flower => "Purple flowers",
            .blue_flower => "Blue flowers",
            .white_flower => "White flowers",
            .orange_flower => "Orange flowers",
            .paving => "Paving stones",
            .sticks => "Stick wall",
            .coral => "Coral",
            .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf, _ => "?",
        };
    }

    /// A block that exists (one of the named ones).
    pub fn isValid(b: Block) bool {
        return @intFromEnum(b) <= @intFromEnum(Block.bamboo) and b.current() == b;
    }

    /// What a block is now: a kind that was removed is read as the one
    /// most like it.
    pub fn current(b: Block) Block {
        return switch (b) {
            .iron, .volcanic_bricks => .volcanic_wall,
            .sandstone_bricks, .coral_stone => .sandstone,
            .planks, .dark_planks => .sticks,
            .gold => .yellow,
            .gravel, .clay => .sand,
            .snow => .volcanic_rock,
            .plaster => .sandstone,
            .leaves => .green,
            .bookshelf => .table,
            else => b,
        };
    }

    /// Flowers: grass with flowers among it.
    pub fn isFlower(b: Block) bool {
        return switch (b) {
            .red_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower, .orange_flower => true,
            else => false,
        };
    }

    pub const flowers = [_]Block{ .red_flower, .orange_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower };
};

/// The palette's sections (its tabs), and their blocks in the order it
/// shows them.
pub const Section = struct {
    name: []const u8,
    blocks: []const Block,
};

pub const sections = [_]Section{
    .{ .name = "Nature", .blocks = &.{ .grass, .dirt, .volcanic_rock, .sand, .sandstone, .water, .coral } },
    .{ .name = "Building", .blocks = &.{ .volcanic_wall, .paving, .sticks, .thatch, .glass, .sandstone_slab, .rock_slab, .thatch_slab, .fence, .ladder } },
    // Made of sticks.
    .{ .name = "Furniture", .blocks = &.{ .table, .bed, .chest, .post, .lamp, .campfire } },
    .{ .name = "Plants", .blocks = &.{ .palm, .bamboo, .leafy_plant, .tall_grass, .seagrass, .red_flower, .orange_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower } },
    // Colours to build with, not any material's.
    .{ .name = "Paint", .blocks = &.{ .white, .black, .red, .orange, .yellow, .green, .cyan, .blue, .purple, .pink } },
};

/// The section a block is in (the first, if none).
pub fn sectionOf(b: Block) usize {
    for (sections, 0..) |sec, i| for (sec.blocks) |o| if (o == b) return i;
    return 0;
}

/// The blocks that can be placed: every section's, in turn.
pub const palette = blk: {
    var n = 0;
    for (sections) |sec| n += sec.blocks.len;
    var out: [n]Block = undefined;
    var i = 0;
    for (sections) |sec| for (sec.blocks) |b| {
        out[i] = b;
        i += 1;
    };
    break :blk out;
};

/// The hotbar's blocks to start with.
pub const starting_hotbar = [9]Block{ .grass, .volcanic_rock, .sticks, .palm, .glass, .volcanic_wall, .thatch, .lamp, .pink_flower };

/// A cube's faces, by the direction they face: +x, -x, +y (up), -y, +z, -z.
pub const Face = enum(u3) {
    east,
    west,
    up,
    down,
    south,
    north,

    pub fn normal(f: Face) [3]i32 {
        return switch (f) {
            .east => .{ 1, 0, 0 },
            .west => .{ -1, 0, 0 },
            .up => .{ 0, 1, 0 },
            .down => .{ 0, -1, 0 },
            .south => .{ 0, 0, 1 },
            .north => .{ 0, 0, -1 },
        };
    }

    pub const all = std.enums.values(Face);
};

/// The tiles (see textures.zig): 64 pixels square, in strips of 16, one
/// tile across (so a tile repeats across a face by the texture unit's
/// own wrapping). A tile's number is its strip times 16 plus its place.
/// The first strip has everything the island is made of, so a chunk not
/// built on is drawn with one texture.
pub const Tile = enum(u6) {
    // The island.
    grass_top = 0,
    grass_side,
    dirt,
    volcanic_rock,
    sand,
    sandstone_top,
    sandstone_side,
    /// Under the lagoon, with the island's.
    seagrass,
    coral,
    palm_bark,
    frond,
    coconut,
    tall_grass,
    red_flower,
    yellow_flower,
    leafy_plant,
    // Building.
    volcanic_wall = 16,
    glass,
    thatch,
    /// A bed's pillow.
    plaster,
    /// A torch's flame.
    lamp,
    /// For water's icon (the water itself is drawn by its own shader).
    water,
    sticks_side,
    bed_cover,
    chest_side,
    chest_top,
    bamboo,
    sticks_top,
    // Colours.
    white = 32,
    black,
    red,
    orange,
    yellow,
    green,
    blue,
    purple,
    pink,
    cyan,
    // More flowers.
    pink_flower,
    purple_flower,
    blue_flower,
    white_flower,
    orange_flower,
    /// For sharks.
    grey,

    pub const per_strip = 16;
    pub const strips = 3;

    pub fn strip(t: Tile) u2 {
        return @intCast(@intFromEnum(t) / per_strip);
    }

    /// Its place in its strip.
    pub fn slot(t: Tile) u4 {
        return @intCast(@intFromEnum(t) % per_strip);
    }
};

test "every block that can be placed has a name and its own look" {
    // Every block is in one section.
    for (std.enums.values(Block)) |b| {
        if (b == .air or !b.isValid()) continue;
        var n: usize = 0;
        for (palette) |p| {
            if (p == b) n += 1;
        }
        try std.testing.expectEqual(@as(usize, 1), n);
    }
    try std.testing.expectEqual(@as(usize, 3), sectionOf(.palm));
    for (palette) |b| {
        try std.testing.expect(b.isValid() and b != .air);
        try std.testing.expect(!std.mem.eql(u8, b.name(), "?"));
        try std.testing.expect(b.shape() != .none);
    }
    for (std.enums.values(Tile)) |t| try std.testing.expect(t.strip() < Tile.strips);
    // What the island is made of is all in the first strip.
    for ([_]Block{ .grass, .dirt, .volcanic_rock, .sand, .sandstone, .palm, .tall_grass, .leafy_plant }) |b|
        for (Face.all) |f| try std.testing.expectEqual(@as(u2, 0), b.tile(f).strip());
    try std.testing.expectEqual(Tile.grass_top, Block.grass.tile(.up));
    try std.testing.expectEqual(Tile.grass_side, Block.grass.tile(.north));
    try std.testing.expect(Block.table.isSolid() and !Block.table.isOpaque() and Block.lamp.emits() > 0);
    try std.testing.expect(Block.palm.isSolid() and !Block.palm.isOpaque());
    for (Block.flowers) |b| try std.testing.expect(b.isFlower() and b.shape() == .plant);
    try std.testing.expect(!Block.glass.isOpaque() and Block.glass.isSolid());
    try std.testing.expect(!Block.water.isSolid());
    const unknown: Block = @enumFromInt(200);
    try std.testing.expect(!unknown.isValid() and unknown.shape() == .none);
    // Removed kinds are not placed, and are read as others.
    try std.testing.expect(!Block.iron.isValid() and !Block.gold.isValid());
    try std.testing.expect(Block.iron.current().isValid() and Block.gold.current().isValid());
}
