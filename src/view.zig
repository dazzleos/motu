//! The window, as widgets: the world filling it (drawn straight into the
//! frame by the renderer), and over it the hotbar of blocks to hand, the
//! palette of every block (E), the help (F1), what is drawn (F3) and a
//! word on what just happened.

const std = @import("std");
const ui = @import("ui");
const gfx = @import("gfx");
const vc4 = @import("vc4");
const blocks = @import("blocks.zig");
const textures = @import("textures.zig");
const game_mod = @import("game.zig");
const renderer = @import("renderer.zig");

const Block = blocks.Block;
const Game = game_mod.Game;

pub const min_size = [2]u32{ 640, 400 };

/// The middle button (a Linux button code).
const btn_middle = 0x112;

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
    f: *const fn (ctx: *anyopaque, frame: *vc4.render.Frame, area: ui.GpuArea) anyerror!void,
};

pub const Blocks = struct {
    game: *Game,
    icons: *const Icons,
    /// How to draw the world (none in tests).
    draw: ?Draw = null,
    /// What the last frame drew, and how fast frames come.
    stats: renderer.Stats = .{},
    fps: f32 = 0,
    on_close: ?ui.Callback = null,
    on_maximize: ?ui.Callback = null,
    on_drag: ?ui.Callback = null,
    maximized: bool = true,

    pub fn build(self: *const Blocks, cx: *ui.Context) ui.Widget {
        const g = self.game;
        const a = cx.ui.arena();
        var layers: std.ArrayList(ui.Widget) = .empty;
        layers.append(a, cx.make(WorldView{ .game = g, .draw = self.draw })) catch {};
        // The hotbar, at the bottom; what happened, above it.
        var bottom: std.ArrayList(ui.Widget) = .empty;
        if (g.messageShown()) |m| bottom.append(a, label(cx, m, 20)) catch {};
        bottom.append(a, self.hotbar(cx)) catch {};
        layers.append(a, cx.make(ui.Align{ .alignment = .bottom_center, .child = cx.make(ui.Padding{ .padding = .all(14), .child = cx.make(ui.Column{
            .main_axis_size = .min,
            .spacing = 8,
            .children = bottom.items,
        }) }) })) catch {};
        if (g.help) layers.append(a, cx.make(ui.Align{ .alignment = .top_left, .child = cx.make(ui.Padding{ .padding = .all(14), .child = help(cx) }) })) catch {};
        if (g.stats) layers.append(a, cx.make(ui.Align{ .alignment = .top_right, .child = cx.make(ui.Padding{ .padding = .all(14), .child = self.statsPanel(cx) }) })) catch {};
        if (g.palette_open) layers.append(a, cx.make(ui.Align{ .alignment = .center, .child = self.palette(cx) })) catch {};
        return cx.make(ui.Column{ .cross_axis_alignment = .stretch, .children = &.{
            cx.make(ui.TitleBar{
                .title = "Blocks",
                .on_close = self.on_close,
                .on_maximize = self.on_maximize,
                .on_drag = self.on_drag,
                .maximized = self.maximized,
            }),
            cx.make(ui.Expanded{ .child = cx.make(ui.Overlay{ .children = layers.items }) }),
        } });
    }

    fn hotbar(self: *const Blocks, cx: *ui.Context) ui.Widget {
        const g = self.game;
        const t = cx.theme();
        var slots: [9]ui.Widget = undefined;
        for (&slots, g.hotbar, 0..) |*w, b, i| {
            const chosen = i == g.slot;
            const pick = cx.ui.arena().create(Choose) catch return cx.make(ui.Empty{});
            pick.* = .{ .game = g, .slot = @intCast(i) };
            w.* = cx.make(ui.Pressable{ .on_press = .of(pick, Choose.press), .child = cx.make(ui.Decorated{
                .color = gfx.Color.argb(if (chosen) 0xcc303030 else 0x99000000),
                .border = .{ .width = if (chosen) 3 else 1, .color = if (chosen) t.primary else gfx.Color.argb(0x66ffffff) },
                .radius = .all(8),
                .child = cx.make(ui.SizedBox{ .width = 60, .height = 60, .child = cx.make(ui.Center{ .child = if (self.icons.of(b)) |img| cx.make(ui.Image{ .image = img }) else cx.make(ui.Empty{}) }) }),
            }) });
        }
        return cx.make(ui.Row{ .main_axis_size = .min, .spacing = 6, .children = &slots });
    }

    fn palette(self: *const Blocks, cx: *ui.Context) ui.Widget {
        const g = self.game;
        const t = cx.theme();
        const a = cx.ui.arena();
        var cells: std.ArrayList(ui.Widget) = .empty;
        for (blocks.palette) |b| {
            const pick = a.create(FromPalette) catch break;
            pick.* = .{ .game = g, .block = b };
            cells.append(a, cx.make(ui.Pressable{ .on_press = .of(pick, FromPalette.press), .child = cx.make(ui.Decorated{
                .color = gfx.Color.argb(if (b == g.selected()) 0x44ffffff else 0x00000000),
                .radius = .all(8),
                .child = cx.make(ui.Center{ .child = cx.make(ui.Image{ .image = self.icons.of(b).? }) }),
            }) })) catch {};
        }
        return cx.make(ui.Decorated{ .color = gfx.Color.argb(0xe0202024), .radius = .all(16), .child = cx.make(ui.Padding{ .padding = .all(20), .child = cx.make(ui.Column{
            .main_axis_size = .min,
            .spacing = 12,
            .children = &.{
                cx.make(ui.Text{ .text = "Blocks", .style = .{ .size = 22, .color = t.primary }, .wrap = false }),
                cx.make(ui.Grid{ .children = cells.items, .cell = .{ .w = 52, .h = 52 }, .spacing = 4 }),
                cx.make(ui.Text{ .text = "Pick one for the hotbar's chosen slot  ·  E or Esc to close", .style = .{ .size = 15, .color = gfx.Color.argb(0xffc8c8c8) }, .wrap = false }),
            },
        }) }) });
    }

    fn statsPanel(self: *const Blocks, cx: *ui.Context) ui.Widget {
        const s = self.stats;
        const p = self.game.player.pos;
        const text = cx.fmt("{d:.0} fps{s}{s}\n{d} chunks, {d} draws ({d} detailed)\n{d}k triangles\n{d:.0}, {d:.0}, {d:.0}  ·  {s}", .{
            self.fps,
            if (self.game.antialias) "  ·  4x antialiased" else "",
            if (self.game.bump) "  ·  bump mapped" else "",
            s.chunks,
            s.draws,
            s.detailed,
            s.triangles / 1000,
            p[0],
            p[1],
            p[2],
            game_mod.timeName(self.game.time_of_day),
        });
        return panel(cx, cx.make(ui.Text{ .text = text, .style = .{ .size = 15, .color = gfx.Color.argb(0xffffffff) } }));
    }
};

const help_text =
    \\W A S D  walk  ·  Space  jump  ·  F  fly (Space, Shift: up, down)
    \\Drag  look around  ·  Click  build  ·  Right click or hold  take away
    \\1–9 or wheel  choose  ·  Middle click  copy a block  ·  E  all blocks
    \\T  later in the day  ·  M  antialiasing  ·  N  bump mapping, ripples
    \\F3  what is drawn  ·  F1  this help
;

fn help(cx: *ui.Context) ui.Widget {
    return panel(cx, cx.make(ui.Text{ .text = help_text, .style = .{ .size = 15, .color = gfx.Color.argb(0xffffffff) } }));
}

fn panel(cx: *ui.Context, child: ui.Widget) ui.Widget {
    return cx.make(ui.Decorated{ .color = gfx.Color.argb(0xa0000000), .radius = .all(10), .child = cx.make(ui.Padding{ .padding = .{ .left = 14, .right = 14, .top = 10, .bottom = 10 }, .child = child }) });
}

fn label(cx: *ui.Context, text: []const u8, size: f32) ui.Widget {
    return cx.make(ui.Center{ .child = panel(cx, cx.make(ui.Text{ .text = text, .style = .{ .size = size, .color = gfx.Color.argb(0xffffffff) }, .wrap = false })) });
}

const Choose = struct {
    game: *Game,
    slot: u8,

    fn press(c: *Choose) void {
        c.game.choose(c.slot);
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

    pub fn layout(self: *const WorldView, _: *ui.Node, c: ui.Constraints) ui.Size {
        const size = c.biggest();
        self.game.view_size = .{ size.w, size.h };
        return size;
    }

    pub fn paint(self: *const WorldView, _: *ui.Node, p: *ui.Painter) void {
        // A new picture every frame (things move, even standing still).
        if (self.draw != null) p.gpu(self, drawWorld);
    }

    fn drawWorld(self: *const WorldView, frame: *vc4.render.Frame, area: ui.GpuArea) anyerror!void {
        const d = self.draw.?;
        try d.f(d.ctx, frame, area);
    }

    pub fn event(self: *const WorldView, _: *ui.Node, e: ui.Event) bool {
        const g = self.game;
        switch (e) {
            .motion => |pos| g.pointerAt(pos),
            .leave => if (g.press == null) g.pointerAt(null),
            .press => |pr| {
                if (pr.button == btn_middle) {
                    g.pointerAt(pr.pos);
                    g.pickAtPointer();
                    return true;
                }
                if (pr.button != ui.btn_left) return false;
                g.pointerDown(pr.pos);
                return true;
            },
            .release => |r| {
                if (r.button == btn_middle) return true;
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
const font = @import("font");
const world_mod = @import("world.zig");

fn overflows(node: *ui.Node) bool {
    if (node.overflow.any()) return true;
    for (node.children.items) |ch| if (overflows(ch)) return true;
    return false;
}

fn findText(n: *ui.Node, text: []const u8) ?*ui.Node {
    if (n.widget.as(ui.Text)) |tx| if (std.mem.indexOf(u8, tx.text, text) != null) return n;
    for (n.children.items) |ch| if (findText(ch, text)) |f| return f;
    return null;
}

test "the hotbar, palette, help and stats fit from the smallest window up; clicking them chooses" {
    const f = try font.Font.init(@embedFile("FiraSans-Regular.ttf"));
    const u = try ui.Ui.create(testing.allocator, &f);
    defer u.destroy();
    const w = try world_mod.World.create(testing.allocator);
    defer w.destroy();
    try w.computeLight();
    var g = Game.init(testing.allocator, w);
    g.stats = true;
    g.palette_open = true;
    g.message = "Bricks";
    g.message_until = 10;
    const icons = try testing.allocator.create(Icons);
    defer testing.allocator.destroy(icons);
    icons.init();
    const view: Blocks = .{ .game = &g, .icons = icons };
    for ([_][2]u32{ min_size, .{ 1280, 720 }, .{ 1920, 1036 } }) |size| {
        u.frame(size[0], size[1], 0, view);
        try testing.expect(!overflows(u.root.?));
    }
    try testing.expect(findText(u.root.?, "Bricks") != null);
    try testing.expect(findText(u.root.?, "fps") != null);
    try testing.expect(findText(u.root.?, "W A S D") != null);
    // The world's view is the window below the title bar.
    try testing.expect(g.view_size[0] == 1920 and g.view_size[1] > 900);
}
