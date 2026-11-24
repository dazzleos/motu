//! The window, as widgets: the world filling it (drawn straight into the
//! frame by the renderer), and over it the hotbar of blocks to hand, the
//! palette of every block (E), the controls, what is drawn, a word on what
//! just happened, the menu (Esc), which the game starts in, and someone
//! asking to join (over everything, the menu too, so it can be clicked).

const std = @import("std");
const kete = @import("kete");
const gfx = kete.gfx;
const gpu = @import("gpu.zig");
const platform = @import("platform").platform;
const blocks = @import("blocks.zig");
const textures = @import("textures.zig");
const game_mod = @import("game.zig");
const renderer = @import("renderer.zig");
const avatar = @import("avatar.zig");

const Block = blocks.Block;
const Game = game_mod.Game;

pub const min_size = [2]u32{ 640, 400 };

/// The size the window opens at: a 16:9 view of the world.
pub const open_size = [2]u32{ 1280, 720 };

pub const button_bg = gfx.Color.argb(0xd8182232);

/// How big the fullscreen button is.
const fullscreen_size = 40;

/// Icons for the blocks, made once.
pub const Icons = struct {
    pixels: [blocks.palette.len][textures.icon_size * textures.icon_size]u32 = undefined,
    images: [blocks.palette.len]gfx.Image = undefined,

    pub fn init(icons: *Icons) void {
        // Drawn at build time (by tools/mktiles.zig).
        @memcpy(std.mem.sliceAsBytes(&icons.pixels), @embedFile("icons.bin"));
        for (0..blocks.palette.len) |i| icons.images[i] = .init(&icons.pixels[i], textures.icon_size, textures.icon_size);
    }

    pub fn of(icons: *const Icons, b: Block) ?*const gfx.Image {
        for (blocks.palette, 0..) |p, i| if (p == b) return &icons.images[i];
        return null;
    }
};

/// Draws the world into the frame.
pub const Draw = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, frame: *Frame, area: kete.gfx.GpuArea) anyerror!void,

    /// What it draws into: on Dazzle, the window's frame being recorded;
    /// on Linux, the window's Vulkan frame (kete's), drawn into directly.
    pub const Frame = if (platform == .linux) kete.gfx.vulkan.DirectFrame else gpu.Frame;
};


/// The telescope's edge: black all round a circle as tall as the view (in
/// its middle), softening into it.
pub const Lens = struct {
    /// How far (of the radius) the edge softens over.
    const soft: f32 = 0.08;
    /// The bands it softens in.
    const bands = 12;

    pub fn paint(_: *const Lens, n: *kete.WidgetNode, p: *kete.Painter) void {
        const size = n.size;
        const c: kete.Point = .{ size.w / 2, size.h / 2 };
        const radius = @min(size.w, size.h) / 2;
        const a = n.ui.arena();
        var cv = p.canvas();
        const black = gfx.Color.argb(0xff000000);
        // The circle's edge, each band a little more see-through inwards.
        const segments = 96;
        const circle = struct {
            fn at(alloc: std.mem.Allocator, center: kete.Point, r: f32) []kete.Point {
                const pts = alloc.alloc(kete.Point, segments) catch return &.{};
                for (pts, 0..) |*pt, i| {
                    const t = @as(f32, @floatFromInt(i)) / segments * 2 * std.math.pi;
                    pt.* = .{ center[0] + r * @cos(t), center[1] + r * @sin(t) };
                }
                return pts;
            }
        }.at;
        const outer = radius;
        const inner = radius * (1 - soft);
        // Outside the circle: black (the view, and the circle as a hole).
        const all = a.dupe(kete.Point, &.{ .{ 0, 0 }, .{ size.w, 0 }, .{ size.w, size.h }, .{ 0, size.h } }) catch return;
        cv.fillPath(&.{ all, circle(a, c, outer) }, black);
        for (0..bands) |i| {
            const f0 = @as(f32, @floatFromInt(i)) / bands;
            const f1 = @as(f32, @floatFromInt(i + 1)) / bands;
            const r0 = inner + (outer - inner) * f0;
            const r1 = inner + (outer - inner) * f1;
            // Each band (a ring of its own) as dark as the edge is at its
            // middle: smoothly from clear to black.
            const want = (f0 + f1) / 2;
            cv.fillPath(&.{ circle(a, c, r1), circle(a, c, r0) }, black.withAlpha(want * want * (3 - 2 * want)));
        }
    }
};

pub const Motu = struct {
    game: *Game,
    icons: *const Icons,
    /// How to draw the world (none in tests).
    draw: ?Draw = null,
    on_fullscreen: ?kete.Callback = null,
    fullscreen: bool = false,

    pub fn build(self: *const Motu, cx: *kete.BuildContext) kete.Widget {
        const g = self.game;
        const a = cx.arena;
        const window = cx.window();
        const is_fullscreen = self.fullscreen or (if (window) |w| w.isFullscreen() else false);
        const on_fullscreen = self.on_fullscreen orelse
            if (window) |w| kete.Callback.of(w, toggleFullscreen) else null;

        var layers: std.ArrayList(kete.Widget) = .empty;
        layers.append(a, cx.make(WorldView{ .game = g, .draw = self.draw })) catch {};
        // Through the telescope: its round view, the rest black.
        if (g.telescope) layers.append(a, cx.make(Lens{})) catch {};
        // The hotbar, at the bottom; what happened, above it.
        var bottom: std.ArrayList(kete.Widget) = .empty;
        if (g.messageShown()) |m| bottom.append(a, label(cx, m, 20)) catch {};
        if (!g.hud_hidden and !g.title) bottom.append(a, self.hotbar(cx)) catch {};
        layers.append(a, cx.make(kete.Align{ .alignment = .bottom_center, .child = cx.make(kete.Padding{ .padding = .all(14), .child = cx.make(kete.Column{
            .fill = false,
            .spacing = 8,
            .children = bottom.items,
        }) }) })) catch {};
        const fullscreen_button = cx.make(kete.RoundedBox{
            .color = button_bg,
            .radius = kete.CornerRadii.all(fullscreen_size / 2),
            .child = cx.make(kete.IconButton{
                .size = fullscreen_size,
                .icon = if (is_fullscreen) .fullscreen_exit else .fullscreen,
                .on_press = on_fullscreen,
            }),
        });
        if (g.palette_open) layers.append(a, cx.make(kete.Align{ .alignment = .center, .child = self.palette(cx) })) catch {};
        // With the mouse taken, a mark in the middle: what it acts on.
        if (g.captured and !g.menu_open and !g.hud_hidden) layers.append(a, cx.make(kete.Align{ .child = crosshair(cx) })) catch {};
        // The menu; and fullscreen and quit, top right, where a window's
        // controls are (only with the menu: while playing, the mouse is
        // the game's).
        if (g.menu_open) {
            layers.append(a, cx.make(kete.Align{ .alignment = .center, .child = self.menu(cx) })) catch {};
            const quit_button = cx.make(kete.RoundedBox{
                .color = button_bg,
                .radius = kete.CornerRadii.all(fullscreen_size / 2),
                .child = cx.make(kete.IconButton{ .size = fullscreen_size, .icon = .close, .on_press = .of(g, Game.quit) }),
            });
            layers.append(a, cx.make(kete.Align{
                .alignment = .top_right,
                .child = cx.make(kete.Padding{ .padding = .{ .top = 12, .right = 12 }, .child = cx.make(kete.Row{ .fill = false, .spacing = 8, .children = a.dupe(kete.Widget, &.{ fullscreen_button, quit_button }) catch &.{} }) }),
            })) catch {};
        }
        // Touched (with no keyboard for Esc, no window controls in
        // fullscreen): a button, top left, opens the menu.
        if (!g.menu_open and g.touch_input) layers.append(a, cx.make(kete.Align{
            .alignment = .top_left,
            .child = cx.make(kete.Padding{ .padding = .{ .top = 12, .left = 12 }, .child = cx.make(kete.RoundedBox{
                .color = button_bg,
                .radius = kete.CornerRadii.all(fullscreen_size / 2),
                .child = cx.make(kete.IconButton{ .size = fullscreen_size, .icon = .menu, .on_press = .of(g, Game.openMenu) }),
            }) }),
        })) catch {};
        if (g.net.request) |who| layers.append(a, cx.make(kete.Align{
            .alignment = .top_center,
            .child = cx.make(kete.Padding{ .padding = .{ .top = 12 }, .child = joinRequest(cx, g, who) }),
        })) catch {};
        return cx.make(kete.Overlay{ .children = layers.items });
    }

    fn toggleFullscreen(w: *kete.App.Window) void {
        w.setFullscreen(!w.isFullscreen());
    }

    fn hotbar(self: *const Motu, cx: *kete.BuildContext) kete.Widget {
        const g = self.game;
        const t = cx.theme();
        var slots: [9]kete.Widget = undefined;
        for (&slots, g.hotbar, 0..) |*w, b, i| {
            const chosen = i == g.slot;
            const pick = cx.arena.create(Choose) catch return cx.make(kete.SizedBox.empty);
            pick.* = .{ .game = g, .slot = @intCast(i) };
            // Blocks are dragged onto it from the palette.
            w.* = cx.make(kete.DropTarget{ .on_drop = .of(pick, Choose.drop), .radius = 8, .child = cx.make(kete.Pressable{ .on_press = .of(pick, Choose.press), .child = cx.make(kete.RoundedBox{
                .color = gfx.Color.argb(if (chosen) 0xcc303030 else 0x99000000),
                .border_width = if (chosen) 3 else 1,
                .border_color = if (chosen) t.primary else gfx.Color.argb(0x66ffffff),
                .radius = .all(8),
                .child = cx.make(kete.SizedBox{ .width = 60, .height = 60, .child = cx.make(kete.Align{ .child = if (self.icons.of(b)) |img| cx.make(kete.Image{ .source = .{ .image = img } }) else cx.make(kete.SizedBox.empty) }) }),
            }) }) });
        }
        return cx.make(kete.Row{ .fill = false, .spacing = 6, .children = &slots });
    }

    /// The palette's sections' tabs.
    const tabs = blk: {
        var out: [blocks.sections.len]kete.Tab = undefined;
        for (blocks.sections, 0..) |sec, i| out[i] = .{ .label = sec.name };
        break :blk out;
    };
    /// Ten blocks across.
    const palette_width = 56 * 10 - 4;

    fn palette(self: *const Motu, cx: *kete.BuildContext) kete.Widget {
        const g = self.game;
        const t = cx.theme();
        const a = cx.arena;
        var cells: std.ArrayList(kete.Widget) = .empty;
        const section = blocks.sections[g.palette_section];
        for (section.blocks) |b| {
            const pick = a.create(FromPalette) catch break;
            pick.* = .{ .game = g, .block = b };
            // Clicked, it goes in the hotbar's slot chosen; dragged, in
            // the slot it is dropped on.
            cells.append(a, cx.make(kete.Draggable{ .data = @intFromEnum(b), .label = b.name(), .on_press = .of(pick, FromPalette.press), .child = cx.make(kete.RoundedBox{
                .color = gfx.Color.argb(if (b == g.selected()) 0x44ffffff else 0x00000000),
                .radius = .all(8),
                .child = cx.make(kete.Align{ .child = cx.make(kete.Image{ .source = .{ .image = self.icons.of(b).? } }) }),
            }) })) catch {};
        }
        // The title, and a close button at the top right, as windows have.
        const title = cx.make(kete.SizedBox{ .width = palette_width + 8, .child = cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
            cx.make(kete.Text{ .text = "Motu", .style = .{ .size = 22, .color = t.primary }, .wrap = false }),
            cx.make(kete.Expanded{ .child = cx.make(kete.SizedBox.empty) }),
            cx.make(kete.IconButton{ .icon = .close, .size = 36, .on_press = .of(g, Game.closePalette) }),
        }) catch &.{} }) });
        return cx.make(kete.RoundedBox{ .color = gfx.Color.argb(0xe0202024), .radius = .all(16), .child = cx.make(kete.Padding{ .padding = .{ .left = 20, .top = 12, .right = 12, .bottom = 20 }, .child = cx.make(kete.Column{
            .fill = false,
            .spacing = 12,
            .children = a.dupe(kete.Widget, &.{
                title,
                cx.make(kete.SizedBox{ .width = palette_width, .child = cx.make(kete.TabBar{ .tabs = &tabs, .selected = g.palette_section, .on_select = .of(g, Game.showPaletteSection) }) }),
                // Room for the biggest section's two rows.
                cx.make(kete.SizedBox{ .width = palette_width, .height = 52 * 2 + 4, .child = cx.make(kete.Grid.fixed(cx, cells.items, .{ .w = 52, .h = 52 }, 4)) }),
                // The block chosen.
                cx.make(kete.Text{ .text = g.selected().name(), .style = .{ .size = 17, .color = t.on_surface }, .wrap = false }),
            }) catch &.{},
        }) }) });
    }

    /// The menu's tabs.
    const menu_tabs = [_]kete.Tab{ .{ .label = "Islands" }, .{ .label = "Player" }, .{ .label = "Settings" } };
    const menu_width = 520;

    /// The menu, over the game (which goes on): tabs for the islands,
    /// playing together and the settings, and a close button (as Esc).
    fn menu(self: *const Motu, cx: *kete.BuildContext) kete.Widget {
        const g = self.game;
        const t = cx.theme();
        const a = cx.arena;
        const content = switch (g.menu_tab) {
            .islands => islandsTab(cx, g),
            .player => playerTab(cx, g),
            .settings => settingsTab(cx, g),
        };
        return cx.make(kete.RoundedBox{ .color = gfx.Color.argb(0xe0202024), .radius = .all(16), .child = cx.make(kete.Padding{ .padding = .{ .left = 20, .top = 12, .right = 12, .bottom = 20 }, .child = cx.make(kete.Column{
            .fill = false,
            .spacing = 12,
            .children = a.dupe(kete.Widget, &.{
                // The title, in the middle, and a close button at the top
                // right (as wide a space on the left keeps it in the
                // middle).
                cx.make(kete.SizedBox{ .width = menu_width + 8, .child = cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
                    cx.make(kete.SizedBox{ .width = 36, .height = 36 }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.Align{ .alignment = .center, .child = cx.make(kete.Text{ .text = "Motu", .style = .{ .size = 22, .color = t.primary }, .wrap = false }) }) }),
                    // (In the title scene the menu stays: an island is
                    // joined from it.)
                    if (g.title) cx.make(kete.SizedBox{ .width = 36, .height = 36 }) else cx.make(kete.IconButton{ .icon = .close, .size = 36, .on_press = .of(g, Game.closeMenu) }),
                }) catch &.{} }) }),
                cx.make(kete.SizedBox{ .width = menu_width, .child = cx.make(kete.TabBar{ .tabs = &menu_tabs, .selected = @intFromEnum(g.menu_tab), .on_select = .of(g, Game.showMenuTab) }) }),
                // As tall whichever tab is shown.
                cx.make(kete.SizedBox{ .width = menu_width, .height = 230, .child = content }),
            }) catch &.{},
        }) }) });
    }
};

/// The settings: the quality (how big the window is drawn: the display
/// stretches it), from half to all of it; under it, how fast frames come,
/// to choose it by.
fn settingsTab(cx: *kete.BuildContext, g: *Game) kete.Widget {
    const t = cx.theme();
    const arena = cx.arena;
    const quality = cx.make(kete.Row{
        .spacing = 12,
        .children = arena.dupe(kete.Widget, &.{
            cx.make(kete.Text{ .text = "Quality", .style = .{ .size = t.body_size, .color = t.on_surface }, .wrap = false }),
            cx.make(kete.Expanded{ .child = cx.make(kete.Slider{ .value = g.qualitySlider(), .on_changed = .of(g, Game.setQuality), .on_change_end = .of(g, Game.endQuality) }) }),
            cx.make(kete.SizedBox{ .width = 60, .child = cx.make(kete.Text{
                .text = cx.fmt("{d:.0}%", .{g.quality * 100}),
                .style = .{ .size = t.body_size, .color = t.on_surface_variant },
                .wrap = false,
            }) }),
        }) catch &.{},
    });
    const n = g.fps_count;
    const now: f32 = if (n > 0) g.fps_history[game_mod.fps_seconds - 1] else 0;
    const fps_label = cx.make(kete.Text{
        .text = if (n > 0) cx.fmt("{d:.0} frames a second", .{now}) else "Frames a second",
        .style = .{ .size = t.body_size - 1, .color = t.on_surface_variant },
        .wrap = false,
    });
    return cx.make(kete.Column{ .fill = false, .spacing = 8, .cross_axis_alignment = .stretch, .children = arena.dupe(kete.Widget, &.{
        quality,
        fps_label,
        cx.make(FpsGraph{ .history = g.fps_history[game_mod.fps_seconds - n ..] }),
    }) catch &.{} });
}

/// The player: how they look (as the others see them), and their name
/// (the computer's if none is given), to change.
fn playerTab(cx: *kete.BuildContext, g: *Game) kete.Widget {
    const a = cx.arena;
    const look = g.look;
    var skins: std.ArrayList(kete.Widget) = .empty;
    for (std.enums.values(avatar.Skin)) |sk| skins.append(a, swatch(cx, g, Game.setSkin, @intFromEnum(sk), sk.tile(), look.skin == sk)) catch {};
    const choices = struct {
        fn of(c: *kete.BuildContext, comptime E: type) []const kete.MenuItem {
            const vals = std.enums.values(E);
            const out = c.arena.alloc(kete.MenuItem, vals.len) catch return &.{};
            for (vals, out) |v, *item| item.* = .{ .label = v.label() };
            return out;
        }
    };
    const clothes = struct {
        fn row(c: *kete.BuildContext, game: *Game, comptime E: type, kind: E, colour: avatar.Colour, comptime set_kind: fn (*Game, usize) void, set_colour: *const fn (*Game, usize) void) kete.Widget {
            var items: std.ArrayList(kete.Widget) = .empty;
            items.append(c.arena, c.make(kete.DropdownMenu{ .options = of(c, E), .selected = @intFromEnum(kind), .on_selected = .of(game, set_kind), .width = 130 })) catch {};
            for (std.enums.values(avatar.Colour)) |col| items.append(c.arena, swatch(c, game, set_colour, @intFromEnum(col), col.tile(), col == colour)) catch {};
            return c.make(kete.Row{ .fill = false, .spacing = 2, .cross_axis_alignment = .center, .children = items.items });
        }
        const of = choices.of;
    };
    return cx.make(kete.Row{ .spacing = 12, .cross_axis_alignment = .start, .children = a.dupe(kete.Widget, &.{
        cx.make(AvatarPicture{ .look = look }),
        cx.make(kete.Expanded{ .child = cx.make(kete.Column{ .fill = false, .spacing = 8, .cross_axis_alignment = .start, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.TextField{ .placeholder = "Your name", .initial = g.playerName(), .max_len = game_mod.max_name, .emoji = false, .on_changed = .of(g, Game.setPlayerName), .width = std.math.inf(f32) }),
            cx.make(kete.Row{ .fill = false, .spacing = 3, .children = skins.items }),
            cx.make(kete.DropdownMenu{ .options = choices.of(cx, avatar.Headwear), .selected = @intFromEnum(look.headwear), .on_selected = .of(g, Game.setHeadwear), .width = 130 }),
            clothes.row(cx, g, avatar.Top, look.top, look.top_colour, Game.setTop, Game.setTopColour),
            clothes.row(cx, g, avatar.Bottom, look.bottom, look.bottom_colour, Game.setBottom, Game.setBottomColour),
        }) catch &.{} }) }),
    }) catch &.{} });
}

/// A colour to choose (ringed if it is chosen).
fn swatch(cx: *kete.BuildContext, g: *Game, set: *const fn (*Game, usize) void, index: usize, tile: blocks.Tile, chosen: bool) kete.Widget {
    const t = cx.theme();
    const pick = cx.arena.create(LookPick) catch return cx.make(kete.SizedBox.empty);
    pick.* = .{ .game = g, .index = index, .set = set };
    return cx.make(kete.Pressable{ .on_press = .of(pick, LookPick.press), .focus_radius = 13, .child = cx.make(kete.RoundedBox{
        .color = tileColour(tile),
        .radius = .all(13),
        .border_width = if (chosen) 3 else 1,
        .border_color = if (chosen) t.primary else gfx.Color.argb(0x60ffffff),
        .child = cx.make(kete.SizedBox{ .width = 24, .height = 24 }),
    }) });
}

const LookPick = struct {
    game: *Game,
    index: usize,
    set: *const fn (*Game, usize) void,

    fn press(p: *LookPick) void {
        p.set(p.game, p.index);
    }
};

/// A tile's colour, as a swatch or the picture shows it.
fn tileColour(tile: blocks.Tile) gfx.Color {
    const hex: u24 = textures.plainColour(tile) orelse switch (tile) {
        .thatch => 0xc8a464,
        .hibiscus => 0xd83048,
        else => 0x808080,
    };
    return gfx.Color.argb(0xff000000 | @as(u32, hex));
}

/// The player as the others see them, from the front: each box of the
/// figure (the furthest back first), lit a little from above.
const AvatarPicture = struct {
    look: avatar.Look,

    const width = 110;
    const height = 220;

    pub fn layout(_: *const AvatarPicture, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.constrain(.{ .w = width, .h = height });
    }

    pub fn paint(self: *const AvatarPicture, n: *kete.WidgetNode, p: *kete.Painter) void {
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .all(12), gfx.Color.argb(0x22ffffff));
        var buf: [avatar.max_boxes]avatar.Box = undefined;
        const bs = avatar.boxes(self.look, &buf);
        // The furthest back drawn first, so the nearer cover them.
        var order: [avatar.max_boxes]usize = undefined;
        for (order[0..bs.len], 0..) |*o, i| o.* = i;
        std.mem.sort(usize, order[0..bs.len], bs, struct {
            fn back(boxes: []const avatar.Box, x: usize, y: usize) bool {
                return boxes[x].min[2] > boxes[y].min[2];
            }
        }.back);
        // 2.1 blocks tall, on the ground near the bottom.
        const k = (h - 24) / 2.1;
        const ground = h - 14;
        c.fillRoundedRect(.{ .x = w / 2 - 0.3 * k, .y = ground - 4, .w = 0.6 * k, .h = 8 }, .all(4), gfx.Color.argb(0x40000000));
        for (order[0..bs.len]) |i| {
            const b = bs[i];
            const r: kete.Rect = .{ .x = w / 2 + b.min[0] * k, .y = ground - b.max[1] * k, .w = (b.max[0] - b.min[0]) * k, .h = (b.max[1] - b.min[1]) * k };
            const col = tileColour(b.tile);
            c.fillRect(r, col);
            // Lit from above: the top lighter, the bottom darker.
            c.fillRect(.{ .x = r.x, .y = r.y, .w = r.w, .h = @min(2, r.h) }, gfx.Color.argb(0x30ffffff));
            c.fillRect(.{ .x = r.x, .y = r.y + r.h - @min(2, r.h), .w = r.w, .h = @min(2, r.h) }, gfx.Color.argb(0x30000000));
        }
    }
};

/// The islands. In the title scene: those kept here, and under them those
/// nearby, on other computers on the network (a plane on their icon, the
/// computer's name under theirs), each played with its own button; ours
/// renamed, or deleted (asked twice), and a row under them for a new one.
/// On an island: it, a switch to let others on the network join (and who
/// has, to remove), and leaving it (back to the title scene, to choose
/// another); in another's game, leaving it.
fn islandsTab(cx: *kete.BuildContext, g: *Game) kete.Widget {
    const a = cx.arena;
    const note = struct {
        fn f(c: *kete.BuildContext, text: []const u8) kete.Widget {
            const th = c.theme();
            return c.make(kete.Text{ .text = text, .style = .{ .size = th.body_size, .color = th.on_surface_variant } });
        }
    }.f;
    if (!g.title) {
        var rows: std.ArrayList(kete.Widget) = .empty;
        // The island played, and (at its end) leaving it.
        const leave = cx.make(kete.FilledButton{ .label = "Leave", .on_press = .of(g, Game.leaveIsland) });
        switch (g.net.status) {
            .joined => |island| rows.append(a, cx.make(kete.ListItem{ .headline = island, .supporting_text = "Playing now", .leading = remoteIcon(cx), .selected = true, .trailing = leave })) catch {},
            else => {
                const name = if (g.islands.current) |i| g.islands.name(i) else "Island";
                rows.append(a, cx.make(kete.ListItem{ .headline = name, .supporting_text = "Playing now", .leading_icon = .landscape, .selected = true, .trailing = leave })) catch {};
                rows.append(a, cx.make(kete.SwitchRow{ .value = g.net.open, .label = "Let others on this network join", .on_changed = .of(g, Game.setOpen) })) catch {};
                // Those who have joined, each with a button to remove
                // them.
                if (g.net.players.len > 0) {
                    var players: std.ArrayList(kete.Widget) = .empty;
                    for (g.net.players) |pl| {
                        const rm = a.create(RemovePlayer) catch break;
                        rm.* = .{ .game = g, .id = pl.id };
                        players.append(a, cx.make(kete.ListItem{
                            .headline = a.dupe(u8, pl.name()) catch "",
                            .leading_icon = .person,
                            .trailing = cx.make(kete.TextButton{ .label = "Remove", .on_press = .of(rm, RemovePlayer.press) }),
                        })) catch {};
                    }
                    rows.append(a, cx.make(kete.SizedBox{ .height = 52 * @as(f32, @floatFromInt(@min(players.items.len, 2))), .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .children = players.items }) }) })) catch {};
                }
            },
        }
        return cx.make(kete.Column{ .fill = false, .spacing = 12, .cross_axis_alignment = .stretch, .children = rows.items });
    }
    var items: std.ArrayList(kete.Widget) = .empty;
    for (0..g.islands.count) |k| {
        const i: u8 = @intCast(k);
        const act = a.create(IslandPick) catch break;
        act.* = .{ .game = g, .index = i };
        // Being renamed: its name in a box, to save or not.
        if (g.renaming == i) {
            items.append(a, cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 8, .top = 6, .bottom = 6 }, .child = cx.make(kete.Row{ .spacing = 8, .children = a.dupe(kete.Widget, &.{
                cx.make(kete.Icon{ .icon = .landscape }),
                cx.make(kete.Expanded{ .child = cx.make(kete.TextField{ .placeholder = "Its name", .initial = g.islands.name(k), .max_len = 48, .emoji = false, .autofocus = true, .on_changed = .of(g, Game.setRenameText), .on_submit = .of(g, Game.finishRename), .width = std.math.inf(f32) }) }),
                cx.make(kete.IconButton{ .icon = .check, .size = 36, .on_press = .of(g, Game.finishRename) }),
                cx.make(kete.IconButton{ .icon = .close, .size = 36, .on_press = .of(g, Game.cancelRename) }),
            }) catch &.{} }) })) catch {};
            continue;
        }
        // Rename it, play it, or delete it (asked twice).
        const trailing: kete.Widget = if (g.delete_asked == i) cx.make(kete.Row{ .fill = false, .spacing = 4, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.TextButton{ .label = "Keep", .on_press = .of(g, Game.keepIsland) }),
            cx.make(kete.FilledButton{ .label = "Delete", .on_press = .of(act, IslandPick.delete) }),
        }) catch &.{} }) else cx.make(kete.Row{ .fill = false, .spacing = 4, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.IconButton{ .icon = .edit, .size = 36, .on_press = .of(act, IslandPick.rename) }),
            cx.make(kete.IconButton{ .icon = .play_arrow, .size = 36, .on_press = .of(act, IslandPick.play) }),
            cx.make(kete.IconButton{ .icon = .delete, .size = 36, .on_press = .of(act, IslandPick.delete) }),
        }) catch &.{} });
        items.append(a, cx.make(kete.ListItem{
            .headline = g.islands.name(k),
            .supporting_text = if (g.delete_asked == i) "Delete it for good?" else "",
            .leading_icon = .landscape,
            .trailing = trailing,
        })) catch {};
    }
    // A new one, under ours.
    items.append(a, cx.make(kete.ListItem{ .headline = "New island", .leading_icon = .add, .on_press = .of(g, Game.newIsland) })) catch {};
    // Those nearby, on other computers.
    for (g.net.nearby) |n| {
        const pick = a.create(RemotePick) catch break;
        pick.* = .{ .game = g, .nearby = n };
        items.append(a, cx.make(kete.ListItem{
            .headline = pick.nearby.name(),
            .supporting_text = pick.nearby.machine(),
            .leading = remoteIcon(cx),
            .trailing = cx.make(kete.IconButton{ .icon = .play_arrow, .size = 36, .on_press = if (g.net.status == .alone) .of(pick, RemotePick.play) else null }),
        })) catch {};
    }
    var column: std.ArrayList(kete.Widget) = .empty;
    // Asking one nearby to join it: waiting for its answer.
    const list_height: f32 = if (g.net.status == .asking) 170 else 222;
    column.append(a, cx.make(kete.SizedBox{ .height = list_height, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 2, .children = items.items }) }) })) catch {};
    switch (g.net.status) {
        .asking => |island| column.append(a, cx.make(kete.Row{ .spacing = 8, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.Expanded{ .child = note(cx, cx.fmt("Asking to join {s}…", .{island})) }),
            cx.make(kete.TextButton{ .label = "Stop asking", .on_press = .of(g, Game.leaveGame) }),
        }) catch &.{} })) catch {},
        else => {},
    }
    return cx.make(kete.Column{ .fill = false, .spacing = 8, .cross_axis_alignment = .stretch, .children = column.items });
}

/// An island's icon with a plane on its corner: one on another computer.
fn remoteIcon(cx: *kete.BuildContext) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.SizedBox{ .width = 28, .height = 24, .child = cx.make(kete.Overlay{ .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.Align{ .alignment = .center_left, .child = cx.make(kete.Icon{ .icon = .landscape }) }),
        cx.make(kete.Align{ .alignment = .top_right, .child = cx.make(kete.RoundedBox{
            .color = t.primary,
            .radius = .all(7),
            .child = cx.make(kete.Padding{ .padding = .all(1), .child = cx.make(kete.Icon{ .icon = .flight, .size = 12, .color = t.on_primary }) }),
        }) }),
    }) catch &.{} }) });
}

const IslandPick = struct {
    game: *Game,
    index: u8,

    fn play(p: *IslandPick) void {
        p.game.openIsland(p.index);
    }

    fn rename(p: *IslandPick) void {
        p.game.startRename(p.index);
    }

    fn delete(p: *IslandPick) void {
        p.game.deleteIsland(p.index);
    }
};

const RemovePlayer = struct {
    game: *Game,
    id: u8,

    fn press(r: *RemovePlayer) void {
        r.game.removePlayer(r.id);
    }
};

const RemotePick = struct {
    game: *Game,
    nearby: game_mod.Nearby,

    fn play(p: *RemotePick) void {
        p.game.joinNearby(p.nearby);
    }
};

/// The frame rate over the last seconds, a bar a second (the newest on the
/// right): green where it was good, yellow where it was all right, red
/// where it was slow.
const FpsGraph = struct {
    history: []const f32,

    const height = 56;
    /// At this or more, good; at `ok` or more, all right.
    pub const good: f32 = 50;
    pub const ok: f32 = 30;

    pub fn colorOf(fps: f32) gfx.Color {
        return gfx.Color.argb(if (fps >= good) 0xff4caf50 else if (fps >= ok) 0xffffc107 else 0xfff44336);
    }

    pub fn layout(_: *const FpsGraph, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        return c.constrain(.{ .w = if (std.math.isFinite(c.max_w)) c.max_w else 300, .h = height });
    }

    pub fn paint(self: *const FpsGraph, n: *kete.WidgetNode, p: *kete.Painter) void {
        const c = p.canvas();
        const w = n.size.w;
        const h = n.size.h;
        c.fillRoundedRect(.{ .x = 0, .y = 0, .w = w, .h = h }, .all(6), gfx.Color.argb(0x22ffffff));
        const slot = w / game_mod.fps_seconds;
        // 60 frames a second at the top.
        for (self.history, 0..) |fps, i| {
            const bh = @max(2, @min(fps / 60, 1) * (h - 4));
            const x = w - @as(f32, @floatFromInt(self.history.len - i)) * slot;
            c.fillRect(.{ .x = x + 1, .y = h - 2 - bh, .w = slot - 2, .h = bh }, colorOf(fps));
        }
    }
};

/// Someone asking to join: Y or N, or (with the mouse, after Esc) its
/// buttons.
fn joinRequest(cx: *kete.BuildContext, g: *Game, who: []const u8) kete.Widget {
    const t = cx.theme();
    return cx.make(kete.RoundedBox{
        .color = t.surface_container_highest,
        .border_width = 1,
        .border_color = t.outline_variant,
        .radius = .all(16),
        .child = cx.make(kete.Padding{ .padding = .{ .left = 16, .right = 12, .top = 10, .bottom = 10 }, .child = cx.make(kete.Row{
            .fill = false,
            .cross_axis_alignment = .center,
            .spacing = 12,
            .children = cx.arena.dupe(kete.Widget, &.{
                cx.make(kete.Icon{ .icon = .person_add, .size = 24, .color = t.primary }),
                cx.make(kete.Text{ .text = cx.fmt("{s} wants to join", .{who}), .style = .{ .size = t.body_size, .color = t.on_surface }, .wrap = false }),
                cx.make(kete.TextButton{ .label = "Deny (N)", .on_press = .of(g, Game.denyJoin) }),
                cx.make(kete.FilledButton{ .label = "Allow (Y)", .on_press = .of(g, Game.allowJoin) }),
            }) catch &.{},
        }) }),
    });
}

/// A small cross, white with a dark edge so it shows on sky and snow.
fn crosshair(cx: *kete.BuildContext) kete.Widget {
    const bar = struct {
        fn f(c: *kete.BuildContext, w: f32, h: f32) kete.Widget {
            return c.make(kete.RoundedBox{
                .color = gfx.Color.argb(0xeeffffff),
                .border_width = 1,
                .border_color = gfx.Color.argb(0x88000000),
                .child = c.make(kete.SizedBox{ .width = w, .height = h, .child = c.make(kete.SizedBox.empty) }),
            });
        }
    }.f;
    return cx.make(kete.Overlay{ .children = cx.arena.dupe(kete.Widget, &.{
        cx.make(kete.Align{ .child = bar(cx, 22, 4) }),
        cx.make(kete.Align{ .child = bar(cx, 4, 22) }),
    }) catch &.{} });
}

fn panel(cx: *kete.BuildContext, child: kete.Widget) kete.Widget {
    return cx.make(kete.RoundedBox{ .color = gfx.Color.argb(0xa0000000), .radius = .all(10), .child = cx.make(kete.Padding{ .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 }, .child = child }) });
}

fn label(cx: *kete.BuildContext, text: []const u8, size: f32) kete.Widget {
    return cx.make(kete.Align{ .child = panel(cx, cx.make(kete.Text{ .text = text, .style = .{ .size = size, .color = gfx.Color.argb(0xffffffff) }, .wrap = false })) });
}

const Choose = struct {
    game: *Game,
    slot: u8,

    fn press(c: *Choose) void {
        c.game.choose(c.slot);
    }

    fn drop(c: *Choose, data: usize) void {
        if (data > std.math.maxInt(u8)) return;
        c.game.dropOnSlot(c.slot, @enumFromInt(@as(u8, @intCast(data))));
    }
};

const FromPalette = struct {
    game: *Game,
    block: Block,

    fn press(c: *FromPalette) void {
        c.game.pickFromPalette(c.block);
    }
};

/// The world: drawn by the renderer, and the pointer on it builds and
/// looks around.
const WorldView = struct {
    game: *Game,
    draw: ?Draw,

    pub fn layout(self: *const WorldView, _: *kete.WidgetNode, c: kete.Constraints) kete.Size {
        const size = c.biggest();
        self.game.view_size = .{ size.w, size.h };
        return size;
    }

    pub fn paint(self: *const WorldView, n: *kete.WidgetNode, p: *kete.Painter) void {
        // A new picture every frame (things move, even standing still).
        if (self.draw != null) {
            if (platform == .linux) p.gpuWithDirect(.{ .fills = true }, self, drawNothing, drawDirect) else p.gpu(self, drawWorld);
        }
        // (On Dazzle, the host draws a frame each time round; on Linux,
        // kete draws when asked.)
        if (platform == .linux) n.ui.needs_frame = true;
    }

    fn drawWorld(self: *const WorldView, frame: *gpu.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const d = self.draw.?;
        try d.f(d.ctx, frame, area);
    }

    /// On Linux, into the window's frame on its GPU (with Vulkan); with
    /// anything else, the world is not drawn.
    fn drawDirect(self: *const WorldView, backend: kete.gfx.RenderBackend, frame: *const anyopaque, area: kete.gfx.GpuArea) anyerror!bool {
        if (backend != .vulkan) return false;
        const d = self.draw.?;
        try d.f(d.ctx, @ptrCast(@alignCast(@constCast(frame))), area);
        return true;
    }

    fn drawNothing(_: *const WorldView, _: *anyopaque, _: kete.gfx.GpuArea) anyerror!void {}

    pub fn event(self: *const WorldView, _: *kete.WidgetNode, e: kete.Event) bool {
        const g = self.game;
        // Behind the menu, the world is only looked at.
        if (g.menu_open) return false;
        switch (e) {
            .motion => |pos| g.pointerAt(pos),
            .leave => if (g.press == null) g.pointerAt(null),
            .press => |pr| {
                if (pr.button == .middle) {
                    g.pointerAt(pr.pos);
                    g.pickAtPointer();
                    return true;
                }
                if (pr.button != .left) return false;
                g.pointerDown(pr.pos);
                return true;
            },
            .release => |r| {
                if (r.button == .middle) return true;
                // Let go outside (or cancelled, as a touch that turned
                // into turning the view): nothing is built.
                if (!r.inside) {
                    g.press = null;
                    return true;
                }
                g.pointerUp();
                return true;
            },
            .context => |pos| {
                g.pointerAt(pos);
                g.removeAtPointer();
                return true;
            },
            .scroll => |s| {
                if (s.touch) {
                    // A finger dragged: turn the view with it.
                    g.player.look(-s.dx * 0.006, s.dy * 0.006);
                } else if (s.dy != 0) g.scroll(s.dy);
                return true;
            },
            else => {},
        }
        return false;
    }
};

// --- Tests ---------------------------------------------------------------------------------

const testing = std.testing;
const font = kete.font;
const world_mod = @import("world.zig");

fn overflows(node: *kete.WidgetNode) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

/// The icon buttons with `icon` (the first eight).
fn withIcon(n: *kete.WidgetNode, icon: @FieldType(kete.IconButton, "icon")) []*kete.WidgetNode {
    const S = struct {
        var found: [8]*kete.WidgetNode = undefined;
        var len: usize = 0;
        fn walk(node: *kete.WidgetNode, ic: @FieldType(kete.IconButton, "icon")) void {
            if (node.widget.as(kete.IconButton)) |b| if (b.icon == ic and len < found.len) {
                found[len] = node;
                len += 1;
            };
            for (node.children.items) |ch| walk(ch, ic);
        }
    };
    S.len = 0;
    S.walk(n, icon);
    return S.found[0..S.len];
}

fn findText(n: *kete.WidgetNode, text: []const u8) ?*kete.WidgetNode {
    if (n.widget.as(kete.Text)) |tx| if (std.mem.indexOf(u8, tx.text, text) != null) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

/// Clicks `node` in its middle.
fn clickNode(u: *kete.ui.WindowUi, node: *kete.WidgetNode) void {
    const pos = node.position();
    const p: kete.Point = .{ pos[0] + node.size.w / 2, pos[1] + node.size.h / 2 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

/// Clicks `node` (its top left corner, a little in).
fn click(u: *kete.ui.WindowUi, node: *kete.WidgetNode) void {
    const pos = node.position();
    const p: kete.Point = .{ pos[0] + 4, pos[1] + 4 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
}

test "the hotbar and palette fit from the smallest window up; clicking them chooses" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    try w.computeLight();
    var g = Game.init(testing.allocator, w);
    g.palette_open = true;
    g.message = "Bricks";
    g.message_until = 10;
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Bricks") != null);
    // The world's view is the whole window (kete draws the title bar outside it).
    try testing.expect(g.view_size[0] == 1920 and g.view_size[1] > 900);
}

test "the menu fits from the smallest window up, and its switches set the options" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    // As it starts: the title scene.
    g.title = true;
    g.openMenu();
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Motu") != null);
    // Its tabs: the islands first; the player; the settings the last
    // (Tab, Tab, Tab).
    try testing.expect(findText(u.root.?, "New island") != null);
    g.key(.tab, true);
    g.key(.tab, false);
    try testing.expectEqual(game_mod.MenuTab.player, g.menu_tab);
    try testing.expect(g.typing());
    for ([_][2]u32{ min_size, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "T-shirt") != null);
    try testing.expect(findText(u.root.?, "Shorts") != null);
    g.setHeadwear(@intFromEnum(avatar.Headwear.straw_hat));
    g.setTopColour(@intFromEnum(avatar.Colour.green));
    g.setPlayerName("Sina\x01 Tui, who has a name far too long to keep");
    try testing.expectEqual(avatar.Headwear.straw_hat, g.look.headwear);
    try testing.expectEqual(avatar.Colour.green, g.look.top_colour);
    try testing.expectEqualStrings("Sina Tui, who has a name", g.playerName());
    u.frame(1920, 1036, 0, view);
    try testing.expect(findText(u.root.?, "Straw hat") != null);
    g.key(.tab, true);
    g.key(.tab, false);
    try testing.expectEqual(game_mod.MenuTab.settings, g.menu_tab);
    try testing.expect(!g.typing());
    for ([_][2]u32{ min_size, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    // The quality: as big as the window, to start with; the slider goes
    // down to half.
    try testing.expect(findText(u.root.?, "100%") != null);
    g.setQuality(0);
    try testing.expectEqual(@as(f32, 0.5), g.quality);
    g.setQuality(0.42);
    try testing.expectEqual(@as(f32, 0.7), g.quality);
    try testing.expectApproxEqAbs(@as(f32, 0.4), g.qualitySlider(), 0.001);
    // Drawn so once it is let go.
    try testing.expectEqual(@as(f32, 1), g.quality_drawn);
    g.endQuality(0.42);
    try testing.expectEqual(@as(f32, 0.7), g.quality_drawn);
    // In the title scene, only the one top right (quit); on an island,
    // its close button goes back to the game too.
    u.frame(1920, 1036, 0, view);
    try testing.expectEqual(@as(usize, 1), withIcon(u.root.?, .close).len);
    g.title = false;
    u.frame(1920, 1036, 0, view);
    const closes = withIcon(u.root.?, .close);
    try testing.expectEqual(@as(usize, 2), closes.len);
    var quit_at: kete.Point = undefined;
    var close_at: kete.Point = undefined;
    for (closes) |n| {
        const at = n.position();
        if (at[1] < 30) quit_at = at else close_at = at;
    }
    try testing.expect(quit_at[0] > 1800);
    const press = struct {
        fn at(ui_: *kete.ui.WindowUi, pos: kete.Point) void {
            const p: kete.Point = .{ pos[0] + 10, pos[1] + 10 };
            ui_.pointerMotion(p);
            ui_.pointerButton(p, .left, true);
            ui_.pointerButton(p, .left, false);
        }
    }.at;
    press(u, close_at);
    try testing.expect(!g.menu_open and !g.quit_asked);
    g.openMenu();
    u.frame(1920, 1036, 1, view);
    press(u, quit_at);
    try testing.expect(g.quit_asked);
}

test "playing together: islands nearby listed under ours and joined, the switch to let others join, someone asking, and leaving" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    g.islands.add("Home");
    var nearby: [2]game_mod.Nearby = undefined;
    for (&nearby, [_][]const u8{ "awesome-elephant", "brave-otter" }, [_][]const u8{ "Lagoon", "Reef" }, 0..) |*n, machine, island, i| {
        n.* = .{ .addr = .{ 192, 168, 1, @intCast(10 + i) }, .port = 47153 };
        n.setName(island);
        n.setMachine(machine);
    }
    g.net.nearby = &nearby;
    g.title = true;
    g.showIslands();
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    // No tab of its own: the islands nearby are with ours, their
    // computers' names under them.
    try testing.expect(findText(u.root.?, "Play together") == null);
    try testing.expect(findText(u.root.?, "Home") != null);
    try testing.expect(findText(u.root.?, "Lagoon") != null);
    try testing.expect(findText(u.root.?, "awesome-elephant") != null);
    try testing.expect(findText(u.root.?, "Reef") != null);
    // Played: asked to join (ours first, then a row for a new one, then
    // those nearby).
    clickNode(u, withIcon(u.root.?, .play_arrow)[1]);
    try testing.expectEqualStrings("Lagoon", g.net.join.?.name());
    try testing.expectEqual([4]u8{ 192, 168, 1, 10 }, g.net.join.?.addr);
    // Asking: it can be stopped.
    g.net.join = null;
    g.net.status = .{ .asking = "Lagoon" };
    u.frame(1920, 1036, 0, view);
    try testing.expect(!overflows(u.root.?));
    click(u, findText(u.root.?, "Stop asking").?);
    try testing.expect(g.net.leave);
    // On our island: the switch, off to start with, lets others join; and
    // someone asking, over the menu.
    g.net.leave = false;
    g.net.status = .{ .hosting = 1 };
    var joined: [1]game_mod.Net.Joined = .{.{ .id = 2 }};
    joined[0].setName("calm-heron");
    g.net.players = &joined;
    g.title = false;
    g.islands.current = 0;
    g.net.request = "brave-otter";
    for ([_][2]u32{ min_size, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(!g.net.open);
    try testing.expect(findText(u.root.?, "Let others on this network join") != null);
    click(u, findText(u.root.?, "Let others on this network join").?);
    try testing.expect(g.net.open);
    // Who has joined, each with a button to remove them.
    try testing.expect(findText(u.root.?, "calm-heron") != null);
    click(u, findText(u.root.?, "Remove").?);
    try testing.expectEqual(@as(?u8, 2), g.net.remove);
    try testing.expect(findText(u.root.?, "brave-otter wants to join") != null);
    click(u, findText(u.root.?, "Allow (Y)").?);
    try testing.expectEqual(@as(?bool, true), g.net.answer);
    // In another's game: leave it.
    g.net.request = null;
    g.net.status = .{ .joined = "Lagoon" };
    g.islands.current = null;
    u.frame(min_size[0], min_size[1], 0, view);
    try testing.expect(!overflows(u.root.?));
    try testing.expect(findText(u.root.?, "Lagoon") != null);
    click(u, findText(u.root.?, "Leave").?);
    try testing.expect(g.net.leave);
}

test "the top-right fullscreen button toggles fullscreen, and shows only with the menu" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const Toggle = struct {
        toggled: bool = false,
        fn call(t: *@This()) void {
            t.toggled = !t.toggled;
        }
    };
    var toggle: Toggle = .{};
    const view: Motu = .{
        .game = &g,
        .icons = icons,
        .on_fullscreen = .of(&toggle, Toggle.call),
    };
    const Find = struct {
        fn first(node: *kete.WidgetNode, comptime T: type) ?*kete.WidgetNode {
            if (node.widget.is(T)) return node;
            for (node.children.items) |ch| if (first(ch, T)) |n| return n;
            return null;
        }
    };
    // Playing: none.
    g.closeMenu();
    u.frame(800, 600, 0, view);
    try testing.expect(Find.first(u.root.?, kete.IconButton) == null);
    // In the menu: top right, beside quitting.
    g.openMenu();
    u.frame(800, 600, 1, view);
    const btn = withIcon(u.root.?, .fullscreen)[0];
    const at = btn.position();
    // Top right of the world view (below the title bar).
    try testing.expect(at[0] > 650 and at[1] < 100);
    const p: kete.Point = .{ at[0] + 10, at[1] + 10 };
    u.pointerMotion(p);
    u.pointerButton(p, .left, true);
    u.pointerButton(p, .left, false);
    try testing.expect(toggle.toggled);
}

test "touched, a button top left opens the menu" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Motu = .{ .game = &g, .icons = icons, .fullscreen = true };
    g.closeMenu();
    // With a keyboard or a mouse: none.
    u.frame(800, 600, 0, view);
    try testing.expectEqual(@as(usize, 0), withIcon(u.root.?, .menu).len);
    g.touch_input = true;
    u.frame(800, 600, 1, view);
    const btn = withIcon(u.root.?, .menu)[0];
    const at = btn.position();
    try testing.expect(at[0] < 100 and at[1] < 100);
    clickNode(u, btn);
    try testing.expect(g.menu_open);
    // In the menu, it is not needed.
    u.frame(800, 600, 2, view);
    try testing.expectEqual(@as(usize, 0), withIcon(u.root.?, .menu).len);
}

test "the menu's islands: chosen and joined from the title scene, left, deleted only when asked twice, and a frame rate graph" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    g.openMenu();
    for (0..40) |i| g.noteFps(@floatFromInt(i * 2));
    try testing.expectEqual(@as(u8, game_mod.fps_seconds), g.fps_count);
    try testing.expectEqual(@as(f32, 78), g.fps_history[game_mod.fps_seconds - 1]);
    try testing.expect(FpsGraph.colorOf(58).toArgb() != FpsGraph.colorOf(40).toArgb() and FpsGraph.colorOf(40).toArgb() != FpsGraph.colorOf(10).toArgb());
    for ([_][]const u8{ "Island", "Island 2", "Island 3" }) |n| g.islands.add(n);
    g.title = true;
    g.showIslands();
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Island 3") != null);
    try testing.expect(findText(u.root.?, "Playing now") == null);
    // In the title scene the menu stays (no close button, Esc does
    // nothing), and there is no hotbar.
    g.closeMenu();
    g.key(.escape, true);
    g.key(.escape, false);
    try testing.expect(g.menu_open);
    // Rows are not chosen: each has its own play button (and a row
    // under them makes a new one).
    click(u, findText(u.root.?, "Island 2").?);
    try testing.expect(g.island_action == null);
    try testing.expectEqual(@as(usize, 3), withIcon(u.root.?, .play_arrow).len);
    clickNode(u, withIcon(u.root.?, .play_arrow)[1]);
    try testing.expectEqual(game_mod.IslandAction{ .open = 1 }, g.island_action.?);
    g.island_action = null;
    click(u, findText(u.root.?, "New island").?);
    try testing.expectEqual(game_mod.IslandAction.new, g.island_action.?);
    g.island_action = null;
    // Renamed: its name in a box, typed into, then saved.
    clickNode(u, withIcon(u.root.?, .edit)[0]);
    try testing.expectEqual(@as(?u8, 0), g.renaming);
    try testing.expect(g.typing());
    u.frame(1920, 1036, 0, view);
    try testing.expect(!overflows(u.root.?));
    try testing.expectEqual(@as(usize, 2), withIcon(u.root.?, .play_arrow).len);
    g.setRenameText("  Moana's Isle ");
    clickNode(u, withIcon(u.root.?, .check)[0]);
    try testing.expectEqual(game_mod.IslandAction{ .rename = 0 }, g.island_action.?);
    try testing.expectEqualStrings("Moana's Isle", g.renameText());
    try testing.expect(g.renaming == null);
    g.island_action = null;
    u.frame(1920, 1036, 0, view);
    g.deleteIsland(2);
    try testing.expect(g.island_action == null);
    g.deleteIsland(2);
    try testing.expectEqual(game_mod.IslandAction{ .delete = 2 }, g.island_action.?);
    g.island_action = null;
    // On an island: it, and Leave (back to the title scene).
    g.title = false;
    g.islands.current = 1;
    u.frame(1920, 1036, 0, view);
    try testing.expect(!overflows(u.root.?));
    try testing.expect(findText(u.root.?, "Playing now") != null);
    try testing.expect(findText(u.root.?, "Island 3") == null);
    click(u, findText(u.root.?, "Leave").?);
    try testing.expectEqual(game_mod.IslandAction.leave, g.island_action.?);
}
