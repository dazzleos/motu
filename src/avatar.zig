//! How a player looks: their skin, what they wear on their head, their
//! top and their bottom (each a kind, and a colour), as chosen in the
//! menu's Player tab, kept with the options and sent to the others in a
//! game with where the player is.
//!
//! The figure is boxes, standing on the origin and facing north (-z), as a
//! player with no yaw does: legs, a body, arms, a head with hair and eyes,
//! and what is on it. Each box is one tile (see blocks.Tile), mapped whole
//! onto each of its faces.

const std = @import("std");
const blocks = @import("blocks.zig");
const math = @import("math.zig");

const Tile = blocks.Tile;
const V3 = math.V3;

pub const Skin = enum(u8) {
    pale,
    light,
    tan,
    brown,
    dark,

    pub fn tile(s: Skin) Tile {
        return @enumFromInt(@intFromEnum(Tile.skin_pale) + @intFromEnum(s));
    }
};

pub const Headwear = enum(u8) {
    none,
    cap,
    straw_hat,
    flower,
    bandana,

    pub fn label(h: Headwear) []const u8 {
        return switch (h) {
            .none => "Nothing",
            .cap => "Cap",
            .straw_hat => "Straw hat",
            .flower => "Flower",
            .bandana => "Bandana",
        };
    }
};

pub const Top = enum(u8) {
    t_shirt,
    singlet,
    long_sleeves,

    pub fn label(t: Top) []const u8 {
        return switch (t) {
            .t_shirt => "T-shirt",
            .singlet => "Singlet",
            .long_sleeves => "Long sleeves",
        };
    }
};

pub const Bottom = enum(u8) {
    shorts,
    trousers,
    lavalava,

    pub fn label(b: Bottom) []const u8 {
        return switch (b) {
            .shorts => "Shorts",
            .trousers => "Trousers",
            .lavalava => "Lavalava",
        };
    }
};

/// What clothes can be (the fabric tiles).
pub const Colour = enum(u8) {
    red,
    orange,
    yellow,
    green,
    cyan,
    blue,
    purple,
    pink,
    white,
    black,

    pub fn tile(c: Colour) Tile {
        return switch (c) {
            .red => .red,
            .orange => .orange,
            .yellow => .yellow,
            .green => .green,
            .cyan => .cyan,
            .blue => .blue,
            .purple => .purple,
            .pink => .pink,
            .white => .white,
            .black => .black,
        };
    }
};

pub const Look = struct {
    skin: Skin = .tan,
    headwear: Headwear = .none,
    top: Top = .t_shirt,
    top_colour: Colour = .red,
    bottom: Bottom = .shorts,
    bottom_colour: Colour = .blue,

    pub const bytes = 6;

    pub fn encode(l: Look) [bytes]u8 {
        return .{ @intFromEnum(l.skin), @intFromEnum(l.headwear), @intFromEnum(l.top), @intFromEnum(l.top_colour), @intFromEnum(l.bottom), @intFromEnum(l.bottom_colour) };
    }

    /// Null if any of it is not something there is.
    pub fn decode(b: [bytes]u8) ?Look {
        return .{
            .skin = std.enums.fromInt(Skin, b[0]) orelse return null,
            .headwear = std.enums.fromInt(Headwear, b[1]) orelse return null,
            .top = std.enums.fromInt(Top, b[2]) orelse return null,
            .top_colour = std.enums.fromInt(Colour, b[3]) orelse return null,
            .bottom = std.enums.fromInt(Bottom, b[4]) orelse return null,
            .bottom_colour = std.enums.fromInt(Colour, b[5]) orelse return null,
        };
    }

    /// As the options keep it: "tan none t_shirt red shorts blue".
    pub fn format(l: Look, w: *std.Io.Writer) !void {
        try w.print("{s} {s} {s} {s} {s} {s}", .{ @tagName(l.skin), @tagName(l.headwear), @tagName(l.top), @tagName(l.top_colour), @tagName(l.bottom), @tagName(l.bottom_colour) });
    }

    /// What `format` wrote; what is not known is as it would be.
    pub fn parse(text: []const u8) Look {
        var l: Look = .{};
        var tok = std.mem.tokenizeAny(u8, text, " \t");
        if (tok.next()) |s| l.skin = std.meta.stringToEnum(Skin, s) orelse l.skin;
        if (tok.next()) |s| l.headwear = std.meta.stringToEnum(Headwear, s) orelse l.headwear;
        if (tok.next()) |s| l.top = std.meta.stringToEnum(Top, s) orelse l.top;
        if (tok.next()) |s| l.top_colour = std.meta.stringToEnum(Colour, s) orelse l.top_colour;
        if (tok.next()) |s| l.bottom = std.meta.stringToEnum(Bottom, s) orelse l.bottom;
        if (tok.next()) |s| l.bottom_colour = std.meta.stringToEnum(Colour, s) orelse l.bottom_colour;
        return l;
    }
};

pub const Box = struct { min: V3, max: V3, tile: Tile };

/// The most boxes a figure is.
pub const max_boxes = 20;

/// The figure's boxes, in `out`.
pub fn boxes(l: Look, out: *[max_boxes]Box) []const Box {
    var n: usize = 0;
    const put = struct {
        fn f(o: *[max_boxes]Box, k: *usize, min: V3, max: V3, tile: Tile) void {
            o[k.*] = .{ .min = min, .max = max, .tile = tile };
            k.* += 1;
        }
    }.f;
    const skin = l.skin.tile();
    const top = l.top_colour.tile();
    const bottom = l.bottom_colour.tile();
    // Legs: shorts to above the knee, trousers to the feet; a lavalava
    // wrapped round from the waist, the legs bare under it.
    for ([_]f32{ -1, 1 }) |side| {
        const x0: f32 = if (side < 0) -0.2 else 0.01;
        const x1: f32 = if (side < 0) -0.01 else 0.2;
        switch (l.bottom) {
            .shorts => {
                put(out, &n, .{ x0, 0, -0.12 }, .{ x1, 0.42, 0.12 }, skin);
                put(out, &n, .{ x0, 0.42, -0.12 }, .{ x1, 0.75, 0.12 }, bottom);
            },
            .trousers => put(out, &n, .{ x0, 0, -0.12 }, .{ x1, 0.75, 0.12 }, bottom),
            .lavalava => put(out, &n, .{ x0, 0, -0.12 }, .{ x1, 0.3, 0.12 }, skin),
        }
    }
    if (l.bottom == .lavalava) put(out, &n, .{ -0.23, 0.3, -0.14 }, .{ 0.23, 0.78, 0.14 }, bottom);
    // The body, and the arms at its sides: a T-shirt's sleeves short, a
    // singlet's none, long sleeves to the hands.
    put(out, &n, .{ -0.26, 0.75, -0.15 }, .{ 0.26, 1.4, 0.15 }, top);
    for ([_]f32{ -1, 1 }) |side| {
        const x0: f32 = if (side < 0) -0.38 else 0.26;
        const x1: f32 = if (side < 0) -0.26 else 0.38;
        const sleeve_to: f32 = switch (l.top) {
            .t_shirt => 1.18,
            .singlet => 1.4,
            .long_sleeves => 0.86,
        };
        if (sleeve_to > 0.8) put(out, &n, .{ x0, 0.8, -0.07 }, .{ x1, sleeve_to, 0.07 }, skin);
        if (sleeve_to < 1.4) put(out, &n, .{ x0, sleeve_to, -0.07 }, .{ x1, 1.4, 0.07 }, top);
    }
    // The head, hair over its top, and eyes on its front.
    put(out, &n, .{ -0.22, 1.4, -0.22 }, .{ 0.22, 1.84, 0.22 }, skin);
    put(out, &n, .{ -0.23, 1.74, -0.23 }, .{ 0.23, 1.86, 0.23 }, .black);
    put(out, &n, .{ -0.13, 1.6, -0.226 }, .{ -0.06, 1.67, -0.22 }, .black);
    put(out, &n, .{ 0.06, 1.6, -0.226 }, .{ 0.13, 1.67, -0.22 }, .black);
    switch (l.headwear) {
        .none => {},
        .cap => {
            put(out, &n, .{ -0.24, 1.76, -0.24 }, .{ 0.24, 1.92, 0.24 }, top);
            put(out, &n, .{ -0.18, 1.76, -0.42 }, .{ 0.18, 1.8, -0.24 }, top);
        },
        .straw_hat => {
            put(out, &n, .{ -0.42, 1.8, -0.42 }, .{ 0.42, 1.84, 0.42 }, .thatch);
            put(out, &n, .{ -0.25, 1.84, -0.25 }, .{ 0.25, 2.0, 0.25 }, .thatch);
        },
        .flower => put(out, &n, .{ 0.14, 1.68, -0.1 }, .{ 0.28, 1.82, 0.04 }, .hibiscus),
        .bandana => put(out, &n, .{ -0.24, 1.7, -0.24 }, .{ 0.24, 1.8, 0.24 }, top),
    }
    return out[0..n];
}

const testing = std.testing;

test "a look kept and sent is as it was, and nonsense is not taken" {
    const l: Look = .{ .skin = .dark, .headwear = .straw_hat, .top = .singlet, .top_colour = .yellow, .bottom = .lavalava, .bottom_colour = .green };
    try testing.expectEqual(l, Look.decode(l.encode()).?);
    var buf: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    try l.format(&w);
    try testing.expectEqualStrings("dark straw_hat singlet yellow lavalava green", w.buffered());
    try testing.expectEqual(l, Look.parse(w.buffered()));
    try testing.expectEqual(Look{}, Look.parse("nonsense"));
    var bad = l.encode();
    bad[1] = 200;
    try testing.expect(Look.decode(bad) == null);
}

test "every look's figure fits, stands on the ground, and is skin, cloth and hair" {
    var out: [max_boxes]Box = undefined;
    for (std.enums.values(Headwear)) |h| for (std.enums.values(Top)) |t| for (std.enums.values(Bottom)) |b| {
        const bs = boxes(.{ .headwear = h, .top = t, .bottom = b }, &out);
        var lowest: f32 = 10;
        for (bs) |x| {
            lowest = @min(lowest, x.min[1]);
            try testing.expect(@reduce(.And, x.min < x.max));
        }
        try testing.expectEqual(@as(f32, 0), lowest);
    };
    // A singlet: bare arms; long sleeves: only the hands.
    const bare = boxes(.{ .top = .singlet, .skin = .pale }, &out);
    var skin_boxes: usize = 0;
    for (bare) |x| if (x.tile == .skin_pale) {
        skin_boxes += 1;
    };
    try testing.expectEqual(@as(usize, 5), skin_boxes);
}
