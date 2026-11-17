//! The window, as widgets: the world filling it (drawn straight into the
//! frame by the renderer), and over it the hotbar of blocks to hand, the
//! palette of every block (E), the controls, what is drawn, a word on what
//! just happened, the menu (Esc), which the game starts in, and someone
//! asking to join (over everything, the menu too, so it can be clicked).

const std = @import("std");
const kete = @import("kete");
const gfx = kete.gfx;
const vc4 = @import("vc4");
const blocks = @import("blocks.zig");
const textures = @import("textures.zig");
const game_mod = @import("game.zig");
const renderer = @import("renderer.zig");

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
        for (blocks.palette, 0..) |b, i| {
            textures.icon(b, &icons.pixels[i]);
            icons.images[i] = .init(&icons.pixels[i], textures.icon_size, textures.icon_size);
        }
    }

    pub fn of(icons: *const Icons, b: Block) ?*const gfx.Image {
        for (blocks.palette, 0..) |p, i| if (p == b) return &icons.images[i];
        return null;
    }
};

/// Draws the world into the frame.
pub const Draw = struct {
    ctx: *anyopaque,
    f: *const fn (ctx: *anyopaque, frame: *vc4.render.Frame, area: kete.gfx.GpuArea) anyerror!void,
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
        // The hotbar, at the bottom; what happened, above it.
        var bottom: std.ArrayList(kete.Widget) = .empty;
        if (g.messageShown()) |m| bottom.append(a, label(cx, m, 20)) catch {};
        if (!g.hud_hidden) bottom.append(a, self.hotbar(cx)) catch {};
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
    const menu_tabs = [_]kete.Tab{ .{ .label = "Islands" }, .{ .label = "Play together" }, .{ .label = "Settings" } };
    const menu_width = 520;

    /// The menu, over the game (which goes on): tabs for the islands,
    /// playing together and the settings, and a close button (as Esc).
    fn menu(self: *const Motu, cx: *kete.BuildContext) kete.Widget {
        const g = self.game;
        const t = cx.theme();
        const a = cx.arena;
        const content = switch (g.menu_tab) {
            .islands => islandsTab(cx, g),
            .play => playTogether(cx, g),
            .settings => settingsTab(cx, g),
        };
        return cx.make(kete.RoundedBox{ .color = gfx.Color.argb(0xe0202024), .radius = .all(16), .child = cx.make(kete.Padding{ .padding = .{ .left = 20, .top = 12, .right = 12, .bottom = 20 }, .child = cx.make(kete.Column{
            .fill = false,
            .spacing = 12,
            .children = a.dupe(kete.Widget, &.{
                // The title, and a close button at the top right.
                cx.make(kete.SizedBox{ .width = menu_width + 8, .child = cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
                    cx.make(kete.Text{ .text = "Menu", .style = .{ .size = 22, .color = t.primary }, .wrap = false }),
                    cx.make(kete.Expanded{ .child = cx.make(kete.SizedBox.empty) }),
                    cx.make(kete.IconButton{ .icon = .close, .size = 36, .on_press = .of(g, Game.closeMenu) }),
                }) catch &.{} }) }),
                cx.make(kete.SizedBox{ .width = menu_width, .child = cx.make(kete.TabBar{ .tabs = &menu_tabs, .selected = @intFromEnum(g.menu_tab), .on_select = .of(g, Game.showMenuTab) }) }),
                // As tall whichever tab is shown.
                cx.make(kete.SizedBox{ .width = menu_width, .height = 210, .child = content }),
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
            cx.make(kete.Expanded{ .child = cx.make(kete.Slider{ .value = g.qualitySlider(), .on_changed = .of(g, Game.setQuality) }) }),
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

/// The islands kept: play one, delete one (asked twice), or make a new
/// one.
fn islandsTab(cx: *kete.BuildContext, g: *Game) kete.Widget {
    const a = cx.arena;
    var items: std.ArrayList(kete.Widget) = .empty;
    for (0..g.islands.count) |k| {
        const i: u8 = @intCast(k);
        const act = a.create(IslandPick) catch break;
        act.* = .{ .game = g, .index = i };
        const current = i == g.islands.current;
        const trailing: ?kete.Widget = if (current) null else if (g.delete_asked == i) cx.make(kete.Row{ .fill = false, .spacing = 4, .children = a.dupe(kete.Widget, &.{
            cx.make(kete.TextButton{ .label = "Keep", .on_press = .of(g, Game.keepIsland) }),
            cx.make(kete.FilledButton{ .label = "Delete", .on_press = .of(act, IslandPick.delete) }),
        }) catch &.{} }) else cx.make(kete.IconButton{ .icon = .delete, .size = 36, .on_press = .of(act, IslandPick.delete) });
        items.append(a, cx.make(kete.ListItem{
            .headline = g.islands.name(k),
            .supporting_text = if (current) "Playing now" else if (g.delete_asked == i) "Delete it for good?" else "",
            .leading_icon = .landscape,
            .selected = current,
            .trailing = trailing,
            .on_press = if (current) null else .of(act, IslandPick.open),
        })) catch {};
    }
    return cx.make(kete.Column{ .fill = false, .spacing = 12, .cross_axis_alignment = .stretch, .children = a.dupe(kete.Widget, &.{
        cx.make(kete.SizedBox{ .height = 150, .child = cx.make(kete.ScrollView{ .child = cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 2, .children = items.items }) }) }),
        cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
            cx.make(kete.FilledButton{ .label = "New island", .on_press = .of(g, Game.newIsland) }),
        }) catch &.{} }),
    }) catch &.{} });
}

const IslandPick = struct {
    game: *Game,
    index: u8,

    fn open(p: *IslandPick) void {
        p.game.openIsland(p.index);
    }

    fn delete(p: *IslandPick) void {
        p.game.deleteIsland(p.index);
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

/// Games nearby listed at most (the menu must fit the smallest window).
const max_nearby_shown = 3;

/// The menu's tab for playing together: how it is going, and the games
/// nearby to join.
fn playTogether(cx: *kete.BuildContext, g: *Game) kete.Widget {
    const a = cx.arena;
    var items: std.ArrayList(kete.Widget) = .empty;
    const note = struct {
        fn f(c: *kete.BuildContext, text: []const u8) kete.Widget {
            const th = c.theme();
            return c.make(kete.Text{ .text = text, .style = .{ .size = th.body_size, .color = th.on_surface_variant } });
        }
    }.f;
    switch (g.net.status) {
        .joined => |host| {
            items.append(a, note(cx, cx.fmt("Playing on {s}'s island", .{host}))) catch {};
            items.append(a, cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
                cx.make(kete.OutlinedButton{ .label = "Leave", .on_press = .of(g, Game.leaveGame) }),
            }) catch &.{} })) catch {};
            return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 8, .children = items.items });
        },
        .asking => |host| {
            items.append(a, note(cx, cx.fmt("Asking {s}…", .{host}))) catch {};
            items.append(a, cx.make(kete.Row{ .children = a.dupe(kete.Widget, &.{
                cx.make(kete.TextButton{ .label = "Stop asking", .on_press = .of(g, Game.leaveGame) }),
            }) catch &.{} })) catch {};
            return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 8, .children = items.items });
        },
        .hosting => |n| items.append(a, note(cx, if (n == 1) "1 player has joined you" else cx.fmt("{d} players have joined you", .{n}))) catch {},
        .alone => items.append(a, note(cx, "Others on this network can ask to join you")) catch {},
    }
    if (g.net.nearby.len == 0) {
        items.append(a, note(cx, "No games nearby")) catch {};
    }
    for (g.net.nearby[0..@min(g.net.nearby.len, max_nearby_shown)]) |n| {
        const join = a.create(JoinNearby) catch break;
        join.* = .{ .game = g, .nearby = n };
        items.append(a, cx.make(kete.ListItem{
            .headline = join.nearby.name(),
            .leading_icon = .computer,
            .on_press = .of(join, JoinNearby.press),
        })) catch {};
    }
    return cx.make(kete.Column{ .fill = false, .cross_axis_alignment = .stretch, .spacing = 2, .children = items.items });
}

const JoinNearby = struct {
    game: *Game,
    nearby: game_mod.Nearby,

    fn press(j: *JoinNearby) void {
        j.game.joinNearby(j.nearby);
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

    pub fn paint(self: *const WorldView, _: *kete.WidgetNode, p: *kete.Painter) void {
        // A new picture every frame (things move, even standing still).
        if (self.draw != null) p.gpu(self, drawWorld);
    }

    fn drawWorld(self: *const WorldView, frame: *vc4.render.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const d = self.draw.?;
        try d.f(d.ctx, frame, area);
    }

    pub fn event(self: *const WorldView, _: *kete.WidgetNode, e: kete.Event) bool {
        const g = self.game;
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
    g.openMenu();
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Menu") != null);
    // Its tabs: the islands first; the settings the last (Tab, Tab).
    try testing.expect(findText(u.root.?, "New island") != null);
    g.key(.tab, true);
    g.key(.tab, false);
    try testing.expectEqual(game_mod.MenuTab.play, g.menu_tab);
    g.key(.tab, true);
    g.key(.tab, false);
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
    // Its close button goes back to the game; the one top right quits.
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

test "playing together: games nearby to join, someone asking to join, and leaving" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try kete.ui.WindowUi.create(testing.allocator, testing.io, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    var g = Game.init(testing.allocator, w);
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    var nearby: [4]game_mod.Nearby = undefined;
    for (&nearby, [_][]const u8{ "awesome-elephant", "brave-otter", "calm-heron", "daring-lynx" }, 0..) |*n, name, i| {
        n.* = .{ .addr = .{ 192, 168, 1, @intCast(10 + i) }, .port = 47153 };
        n.setName(name);
    }
    g.net.nearby = &nearby;
    g.net.status = .{ .hosting = 1 };
    g.net.request = "brave-otter";
    g.showMenuTab(@intFromEnum(game_mod.MenuTab.play));
    const view: Motu = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "1 player has joined you") != null);
    try testing.expect(findText(u.root.?, "brave-otter wants to join") != null);
    // Three listed at most.
    try testing.expect(findText(u.root.?, "calm-heron") != null);
    try testing.expect(findText(u.root.?, "daring-lynx") == null);
    const click = struct {
        fn at(ui_: *kete.ui.WindowUi, node: *kete.WidgetNode) void {
            const pos = node.position();
            const p: kete.Point = .{ pos[0] + 4, pos[1] + 4 };
            ui_.pointerMotion(p);
            ui_.pointerButton(p, .left, true);
            ui_.pointerButton(p, .left, false);
        }
    }.at;
    // The request's Allow, over the menu.
    click(u, findText(u.root.?, "Allow (Y)").?);
    try testing.expectEqual(@as(?bool, true), g.net.answer);
    // A game nearby: asked to join.
    u.frame(1920, 1036, 0, view);
    click(u, findText(u.root.?, "awesome-elephant").?);
    try testing.expectEqualStrings("awesome-elephant", g.net.join.?.name());
    try testing.expectEqual([4]u8{ 192, 168, 1, 10 }, g.net.join.?.addr);
    // Joined: leave.
    g.net.request = null;
    g.net.status = .{ .joined = "awesome-elephant" };
    u.frame(min_size[0], min_size[1], 0, view);
    try testing.expect(!overflows(u.root.?));
    try testing.expect(findText(u.root.?, "Playing on awesome-elephant's island") != null);
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

test "the menu's islands: listed, played, deleted only when asked twice, and a frame rate graph" {
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
    try testing.expect(findText(u.root.?, "Playing now") != null);
    g.deleteIsland(2);
    try testing.expect(g.island_action == null);
    g.deleteIsland(2);
    try testing.expectEqual(game_mod.IslandAction{ .delete = 2 }, g.island_action.?);
    g.openIsland(1);
    try testing.expectEqual(game_mod.IslandAction{ .open = 1 }, g.island_action.?);
}
