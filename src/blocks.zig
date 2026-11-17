//! The kinds of block: how each is drawn (a solid cube, water, a palm's
//! trunk, a plant or furniture), which of the atlas's tiles each face
//! shows, the light it gives, and its name.
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
    /// Retired: no longer made, its number kept for those after it.
    gravel,
    /// Retired: no longer made, its number kept for those after it.
    clay,
    /// Retired: no longer made, its number kept for those after it.
    snow,
    water,
    /// A palm's trunk: a round pole, with fronds and coconuts at its top.
    palm,
    /// Retired: no longer made, its number kept for those after it.
    planks,
    /// Retired: no longer made, its number kept for those after it.
    leaves,
    /// Retired: no longer made, its number kept for those after it.
    dark_planks,
    /// Retired: no longer made, its number kept for those after it.
    glass,
    /// Retired: no longer made, its number kept for those after it.
    sandstone_bricks,
    /// Retired: no longer made, its number kept for those after it.
    volcanic_bricks,
    /// Retired: no longer made, its number kept for those after it.
    thatch,
    /// Retired: no longer made, its number kept for those after it.
    plaster,
    /// Retired: no longer made, its number kept for those after it.
    iron,
    /// Retired: no longer made, its number kept for those after it.
    gold,
    /// A bamboo torch, its flame burning: on a stick, raised.
    lamp,
    /// Retired: no longer made, its number kept for those after it.
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
    /// Retired: no longer made, its number kept for those after it.
    paving,
    /// Retired: no longer made, its number kept for those after it.
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
    /// Half a block, its lower half: sandstone, rock and thatch (the only
    /// thatch: a roof's).
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
    /// A banana plant: a stem, big paddle leaves, a bunch of bananas.
    banana,
    /// A hibiscus bush: glossy leaves, big red flowers.
    hibiscus,
    /// A mangrove: arching roots, a short trunk, leaves over them; below
    /// the sea's level, in the water (see World.wateryAt).
    mangrove,
    /// Sand from volcanic rock, near black.
    black_sand,
    /// Sand with shells and starfish washed up on it.
    shells,
    /// Molten rock, glowing.
    lava,
    /// A see-through panel of crossed sticks, for windows and screens:
    /// across the way it joins to walls or more of it.
    lattice,
    /// A woven mat, thin, on the floor.
    mat,
    /// Strings of shells and seeds hanging from a rail, for doorways:
    /// walked through.
    curtain,
    /// A cloth slung between posts (or walls, or palms), sagging: hammocks
    /// in a row are one longer one.
    hammock,
    /// Retired: no longer made, its number kept for those after it.
    pot,
    /// A dugout canoe with an outrigger: canoes end to end are one longer
    /// one, pointed at its ends.
    canoe,
    /// Retired: no longer made, its number kept for those after it.
    statue,
    /// Flat round stones on the ground (put on grass, as flowers are), for
    /// paths: they join up with the stones beside them.
    stones,
    _,

    pub const Shape = enum {
        none,
        /// A cube that hides what is behind it and casts shadows.
        cube,
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
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf, .glass, .pot, .statue, .thatch, .paving => .none,
            .table, .bed, .chest, .post, .lamp, .sandstone_slab, .rock_slab, .thatch_slab, .ladder, .fence, .campfire, .bamboo, .hibiscus, .lattice, .mat, .curtain, .hammock, .canoe, .stones => .furniture,
            .water => .water,
            .palm => .pole,
            .tall_grass, .seagrass, .leafy_plant, .banana, .mangrove, .red_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower, .orange_flower => .plant,
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
            .sandstone_slab, .rock_slab, .thatch_slab, .hammock, .canoe => 0.5,
            .mat => 0.0625,
            .ladder, .campfire, .curtain, .stones => 0,
            else => switch (b.shape()) {
                .cube, .pole, .furniture => 1,
                else => 0,
            },
        };
    }

    /// Water, or what is always in water (and holds it too); see also
    /// World.wateryAt (mangroves, below the sea's level).
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
            .lamp, .lava => 15,
            .campfire => 14,
            else => 0,
        };
    }

    /// The tile on its face `face` (see `Face`).
    pub fn tile(b: Block, face: Face) Tile {
        const top = face == .up;
        const bottom = face == .down;
        return switch (b) {
            .grass => if (top) .grass_top else if (bottom) .dirt else .grass_side,
            .dirt => .dirt,
            .volcanic_rock => .volcanic_rock,
            .volcanic_wall => .volcanic_wall,
            .sand => .sand,
            .sandstone => if (top or bottom) .sandstone_top else .sandstone_side,
            .palm => .palm_bark,
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
            .banana => .leafy_plant,
            .hibiscus => .hibiscus,
            .mangrove => .mangrove_leaf,
            .bed => .bed_cover,
            .black_sand => .black_sand,
            .stones => .sandstone_top,
            .shells => if (top) .shells else .sand,
            .lava => .lava,
            .lattice, .canoe => if (top or bottom) .sticks_top else .sticks_side,
            .mat => .mat,
            .curtain => .beads,
            .hammock => .hammock,
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
            .air, .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf, .glass, .pot, .statue, .thatch, .paving, _ => .volcanic_rock,
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
            .lamp => "Lamp",
            .table => "Table",
            .bed => "Bed",
            .chest => "Treasure chest",
            .post => "Stick",
            .sandstone_slab => "Sandstone slab",
            .rock_slab => "Rock slab",
            .thatch_slab => "Thatch",
            .ladder => "Ladder",
            .fence => "Fence",
            .campfire => "Campfire",
            .seagrass => "Seagrass",
            .bamboo => "Bamboo",
            .banana => "Banana",
            .hibiscus => "Hibiscus",
            .mangrove => "Mangrove",
            .black_sand => "Black sand",
            .shells => "Shells",
            .lava => "Lava",
            .lattice => "Lattice",
            .mat => "Mat",
            .curtain => "Bead curtain",
            .hammock => "Hammock",
            .canoe => "Canoe",
            .stones => "Paving stones",
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
            .sticks => "Stick wall",
            .coral => "Coral",
            .iron, .gold, .gravel, .clay, .snow, .planks, .dark_planks, .sandstone_bricks, .volcanic_bricks, .coral_stone, .leaves, .plaster, .bookshelf, .glass, .pot, .statue, .thatch, .paving, _ => "?",
        };
    }

    /// A block that exists (one of the named ones).
    pub fn isValid(b: Block) bool {
        return @intFromEnum(b) <= @intFromEnum(Block.stones) and !b.retired();
    }

    /// A kind no longer made (its number kept, for those after it).
    pub fn retired(b: Block) bool {
        return switch (b) {
            .iron, .volcanic_bricks, .sandstone_bricks, .coral_stone, .planks, .dark_planks, .gold, .gravel, .clay, .snow, .plaster, .leaves, .bookshelf, .glass, .thatch, .paving, .pot, .statue => true,
            else => false,
        };
    }

    /// Put on the ground (and gone with it): plants, and paving stones.
    pub fn onGround(b: Block) bool {
        return b.shape() == .plant or b == .stones;
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
    .{ .name = "Nature", .blocks = &.{ .grass, .dirt, .volcanic_rock, .sand, .black_sand, .shells, .sandstone, .water, .coral, .lava } },
    .{ .name = "Building", .blocks = &.{ .volcanic_wall, .stones, .sticks, .sandstone_slab, .rock_slab, .thatch_slab, .fence, .ladder, .lattice, .mat, .curtain } },
    // Made of sticks.
    .{ .name = "Furniture", .blocks = &.{ .table, .bed, .chest, .post, .lamp, .campfire, .hammock, .canoe } },
    .{ .name = "Plants", .blocks = &.{ .palm, .bamboo, .banana, .mangrove, .hibiscus, .leafy_plant, .tall_grass, .seagrass, .red_flower, .orange_flower, .yellow_flower, .pink_flower, .purple_flower, .blue_flower, .white_flower } },
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
pub const starting_hotbar = [9]Block{ .grass, .volcanic_rock, .sticks, .palm, .lattice, .volcanic_wall, .thatch_slab, .lamp, .pink_flower };

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
    hibiscus,
    mangrove_leaf,
    black_sand,
    /// Sand, shells on it.
    shells,
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
    // More building and furniture.
    lava = 48,
    mat,
    hammock,
    /// A string of beads.
    beads,
    /// A canoe's hull, carved.
    canoe,
    // Players' skin (see avatar.zig).
    skin_pale,
    skin_light,
    skin_tan,
    skin_brown,
    skin_dark,

    pub const per_strip = 16;
    pub const strips = 4;

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
    try std.testing.expect(!Block.water.isSolid());
    const unknown: Block = @enumFromInt(200);
    try std.testing.expect(!unknown.isValid() and unknown.shape() == .none);
    // Retired kinds are not.
    try std.testing.expect(!Block.iron.isValid() and !Block.gold.isValid() and Block.iron.retired());
    // Lava glows; a curtain is walked through; a mat is stepped onto.
    try std.testing.expect(Block.lava.emits() > 0 and Block.lava.isOpaque());
    try std.testing.expect(!Block.curtain.isSolid() and Block.mat.solidHeight() < 0.1);
}
