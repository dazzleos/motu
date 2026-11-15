//! The kinds of block: how each is drawn (a solid cube, a see-through
//! cube, water, a palm's trunk, or a plant), which of the atlas's tiles
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
    leaves,
    /// Removed: read as stick wall.
    dark_planks,
    glass,
    /// Removed: read as sandstone.
    sandstone_bricks,
    /// Removed: read as volcanic wall.
    volcanic_bricks,
    thatch,
    plaster,
    /// Removed: read as volcanic wall.
    iron,
    /// Removed: read as yellow paint.
    gold,
    lamp,
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
    fern,
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
    };

    pub fn shape(b: Block) Shape {
        return switch (b) {
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone => .none,
            .water => .water,
            .glass => .clear,
            .palm => .pole,
            .tall_grass, .fern, .red_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower, .orange_flower => .plant,
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
        return switch (b.shape()) {
            .cube, .clear, .pole => true,
            else => false,
        };
    }

    /// How much more than a step light loses going through it: sunlight
    /// dims under leaves and water.
    pub fn lightLoss(b: Block) u4 {
        return switch (b) {
            .leaves => 1,
            .water => 2,
            else => 0,
        };
    }

    /// Whether light passes through at all.
    pub fn passesLight(b: Block) bool {
        return !b.isOpaque() or b == .leaves;
    }

    /// The light it gives (0 to 15).
    pub fn emits(b: Block) u4 {
        return switch (b) {
            .lamp => 15,
            else => 0,
        };
    }

    /// Its leaves sway in the wind.
    pub fn sways(b: Block) bool {
        return b == .leaves;
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
            .leaves => .leaves,
            .glass => .glass,
            .thatch => .thatch,
            .coral => .coral,
            .sticks => if (top or bottom) .sticks_top else .sticks_side,
            .plaster => .plaster,
            .lamp => .lamp,
            .bookshelf => if (top or bottom) .planks else .bookshelf,
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
            .fern => .frond,
            .red_flower => .red_flower,
            .yellow_flower => .yellow_flower,
            .pink_flower => .pink_flower,
            .purple_flower => .purple_flower,
            .blue_flower => .blue_flower,
            .white_flower => .white_flower,
            .orange_flower => .orange_flower,
            .water => .water,
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, _ => .volcanic_rock,
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
            .leaves => "Leaves",
            .glass => "Glass",
            .thatch => "Thatch",
            .plaster => "Plaster",
            .lamp => "Lamp",
            .bookshelf => "Bookshelf",
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
            .fern => "Fern",
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
            .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, _ => "?",
        };
    }

    /// A block that exists (one of the named ones).
    pub fn isValid(b: Block) bool {
        return @intFromEnum(b) <= @intFromEnum(Block.coral) and b.current() == b;
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
    .{ .name = "Building", .blocks = &.{ .volcanic_wall, .paving, .sticks, .plaster, .thatch, .glass, .lamp, .bookshelf } },
    .{ .name = "Plants", .blocks = &.{ .palm, .leaves, .fern, .tall_grass, .red_flower, .orange_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower } },
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
    sticks_top,
    coral,
    palm_bark,
    frond,
    coconut,
    tall_grass,
    red_flower,
    yellow_flower,
    // Building.
    volcanic_wall = 16,
    planks,
    glass,
    thatch,
    plaster,
    lamp,
    bookshelf,
    /// For water's icon (the water itself is drawn by its own shader).
    water,
    leaves,
    sticks_side,
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
    try std.testing.expectEqual(@as(usize, 2), sectionOf(.palm));
    for (palette) |b| {
        try std.testing.expect(b.isValid() and b != .air);
        try std.testing.expect(!std.mem.eql(u8, b.name(), "?"));
        try std.testing.expect(b.shape() != .none);
    }
    for (std.enums.values(Tile)) |t| try std.testing.expect(t.strip() < Tile.strips);
    // What the island is made of is all in the first strip.
    for ([_]Block{ .grass, .dirt, .volcanic_rock, .sand, .sandstone, .palm, .tall_grass, .fern }) |b|
        for (Face.all) |f| try std.testing.expectEqual(@as(u2, 0), b.tile(f).strip());
    try std.testing.expectEqual(Tile.grass_top, Block.grass.tile(.up));
    try std.testing.expectEqual(Tile.grass_side, Block.grass.tile(.north));
    try std.testing.expect(Block.leaves.isOpaque() and Block.leaves.passesLight());
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
