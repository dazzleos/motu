//! The kinds of block: how each is drawn (a solid cube, a see-through
//! cube, water, or a plant: two crossed planes), which of the atlas's
//! tiles each face shows, the light it gives, and its name.

const std = @import("std");

pub const Block = enum(u8) {
    air,
    grass,
    dirt,
    stone,
    cobblestone,
    sand,
    sandstone,
    gravel,
    clay,
    snow,
    water,
    log,
    planks,
    leaves,
    dark_planks,
    glass,
    bricks,
    stone_bricks,
    roof,
    plaster,
    iron,
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
    _,

    pub const Shape = enum {
        none,
        /// A cube that hides what is behind it and casts shadows.
        cube,
        /// A cube drawn see-through (glass).
        clear,
        water,
        /// Two crossed planes (drawn see-through).
        plant,
    };

    pub fn shape(b: Block) Shape {
        return switch (b) {
            .air => .none,
            .water => .water,
            .glass => .clear,
            .tall_grass, .red_flower, .yellow_flower => .plant,
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
            .cube, .clear => true,
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
            .grass => if (top) .grass_top else if (bottom) .dirt else .grass_side,
            .dirt => .dirt,
            .stone => .stone,
            .cobblestone => .cobblestone,
            .sand => .sand,
            .sandstone => if (top or bottom) .sandstone_top else .sandstone_side,
            .gravel => .gravel,
            .clay => .clay,
            .snow => .snow,
            .log => if (top or bottom) .log_top else .log_side,
            .planks => .planks,
            .leaves => .leaves,
            .dark_planks => .dark_planks,
            .glass => .glass,
            .bricks => .bricks,
            .stone_bricks => .stone_bricks,
            .roof => .roof,
            .plaster => .plaster,
            .iron => .iron,
            .gold => .gold,
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
            .red_flower => .red_flower,
            .yellow_flower => .yellow_flower,
            .water => .water,
            .air, _ => .stone,
        };
    }

    pub fn name(b: Block) []const u8 {
        return switch (b) {
            .air => "Air",
            .grass => "Grass",
            .dirt => "Dirt",
            .stone => "Stone",
            .cobblestone => "Cobblestone",
            .sand => "Sand",
            .sandstone => "Sandstone",
            .gravel => "Gravel",
            .clay => "Clay",
            .snow => "Snow",
            .water => "Water",
            .log => "Log",
            .planks => "Planks",
            .leaves => "Leaves",
            .dark_planks => "Dark planks",
            .glass => "Glass",
            .bricks => "Bricks",
            .stone_bricks => "Stone bricks",
            .roof => "Roof tiles",
            .plaster => "Plaster",
            .iron => "Iron",
            .gold => "Gold",
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
            .red_flower => "Poppy",
            .yellow_flower => "Dandelion",
            _ => "?",
        };
    }

    /// A block that exists (one of the named ones).
    pub fn isValid(b: Block) bool {
        return @intFromEnum(b) <= @intFromEnum(Block.yellow_flower);
    }
};

/// The blocks that can be placed, in the order the palette shows them.
pub const palette = [_]Block{
    .grass,        .dirt,       .stone,      .cobblestone,   .sand,        .sandstone, .gravel,    .clay,
    .snow,         .water,      .log,        .planks,        .dark_planks, .leaves,    .glass,     .bricks,
    .stone_bricks, .roof,       .plaster,    .iron,          .gold,        .lamp,      .bookshelf, .white,
    .black,        .red,        .orange,     .yellow,        .green,       .blue,      .purple,    .pink,
    .cyan,         .tall_grass, .red_flower, .yellow_flower,
};

/// The hotbar's blocks to start with.
pub const starting_hotbar = [9]Block{ .grass, .stone, .planks, .log, .glass, .bricks, .roof, .lamp, .red_flower };

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
    stone,
    sand,
    sandstone_top,
    sandstone_side,
    gravel,
    clay,
    snow,
    log_side,
    log_top,
    leaves,
    tall_grass,
    red_flower,
    yellow_flower,
    // Building.
    cobblestone = 16,
    planks,
    dark_planks,
    glass,
    bricks,
    stone_bricks,
    roof,
    plaster,
    iron,
    gold,
    lamp,
    bookshelf,
    /// For water's icon (the water itself is drawn by its own shader).
    water,
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
    for (palette) |b| {
        try std.testing.expect(b.isValid() and b != .air);
        try std.testing.expect(!std.mem.eql(u8, b.name(), "?"));
        try std.testing.expect(b.shape() != .none);
    }
    for (std.enums.values(Tile)) |t| try std.testing.expect(t.strip() < Tile.strips);
    // What the island is made of is all in the first strip.
    for ([_]Block{ .grass, .dirt, .stone, .sand, .sandstone, .gravel, .clay, .snow, .log, .leaves, .tall_grass, .red_flower, .yellow_flower }) |b|
        for (Face.all) |f| try std.testing.expectEqual(@as(u2, 0), b.tile(f).strip());
    try std.testing.expectEqual(Tile.grass_top, Block.grass.tile(.up));
    try std.testing.expectEqual(Tile.grass_side, Block.grass.tile(.north));
    try std.testing.expect(Block.leaves.isOpaque() and Block.leaves.passesLight());
    try std.testing.expect(!Block.glass.isOpaque() and Block.glass.isSolid());
    try std.testing.expect(!Block.water.isSolid());
    const unknown: Block = @enumFromInt(200);
    try std.testing.expect(!unknown.isValid() and unknown.shape() == .none);
}
