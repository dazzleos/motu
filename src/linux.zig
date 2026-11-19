//! Motu on Linux (built with -Dplatform=linux): its window is kete's own,
//! on Wayland, and kete draws it (with Vulkan, where it can). The game is
//! the same as on Dazzle: its islands (kept in places.dir()), the menu,
//! playing together on the network.
//!
//! The world is drawn with Vulkan (see vulkan.zig), on the GPU kete draws
//! the window with, straight into its frames (nothing copied).

const std = @import("std");
const sys = @import("sys");
const kete = @import("kete");
const main = @import("main.zig");
const places = @import("places.zig");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const view = @import("view.zig");
const net = @import("net.zig");
const options = @import("options.zig");
const gpu = @import("gpu.zig");
const vulkan = @import("vulkan.zig");
const renderer_mod = @import("renderer.zig");
const reach_mod = @import("reach.zig");

const print = sys.print;

/// The window's root: the menu, the hotbar and the rest over the world.
const Root = struct {
    game: *game_mod.Game,
    icons: *const view.Icons,
    scene: *Scene,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Motu{ .game = r.game, .icons = r.icons, .draw = .{ .ctx = r.scene, .f = Scene.draw } });
    }
};

/// What drawing the world needs: the renderer, made on kete's Vulkan
/// device once the window has one.
const Scene = struct {
    gpa: std.mem.Allocator,
    app: *kete.App,
    game: *game_mod.Game,
    dev: ?gpu.Device = null,
    renderer: ?*main.Renderer = null,
    /// Vulkan could not be had (or the renderer made): not tried again.
    failed: bool = false,
    reach: reach_mod.Reach = .{},
    trouble: main.Trouble = .{},

    fn deinit(s: *Scene) void {
        if (s.renderer) |r| r.deinit();
        if (s.dev) |d| d.deinit();
    }

    /// The renderer, if there is one (made the first time).
    fn ready(s: *Scene) ?*main.Renderer {
        if (s.renderer) |r| return r;
        if (s.failed) return null;
        const shared = (s.app.gpuDevice() orelse return null);
        if (shared != .vulkan) {
            print("motu: the window is not drawn with Vulkan: the world cannot be shown\n", .{});
            s.failed = true;
            return null;
        }
        const dev = vulkan.State.init(s.gpa, shared.vulkan) catch |err| {
            print("motu: no Vulkan ({s})\n", .{@errorName(err)});
            s.failed = true;
            return null;
        };
        s.renderer = main.Renderer.init(s.gpa, dev) catch |err| {
            print("motu: cannot draw the world ({s})\n", .{@errorName(err)});
            dev.deinit();
            s.failed = true;
            return null;
        };
        s.dev = dev;
        return s.renderer;
    }

    fn draw(ctx: *anyopaque, frame: *view.Draw.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        const r = s.ready() orelse return;
        const g = s.game;
        const dev = s.dev.?;
        const box = area.viewport;
        if (box.width == 0 or box.height == 0) return;
        _ = s.reach.frame(sys.nowNs(), 0);
        // Straight into the window's frame, where the view is (the
        // renderer's viewport and scissor are within the view: at 0, 0).
        const vp: gpu.Viewport = .{ .x = 0, .y = 0, .width = box.width, .height = box.height };
        const scissor: ?gpu.Viewport = if (area.scissor) |sc| .{ .x = sc.x - box.x, .y = sc.y - box.y, .width = sc.width, .height = sc.height } else null;
        var boats: main.Boats = .{};
        const v: renderer_mod.View = .{
            .camera = g.camera(),
            .aspect = @as(f32, @floatFromInt(vp.width)) / @as(f32, @floatFromInt(vp.height)),
            .time = g.clock,
            .env = renderer_mod.Environment.at(g.time_of_day).withWeather(g.weather()),
            .weather = g.weather(),
            .day = g.day,
            .day_seconds = g.time_of_day * game_mod.day_length,
            .underwater = g.player.underwater(g.world),
            .outline = if (g.target) |t| t.cell else null,
            .avatars = g.net.others,
            .boats = boats.items(g),
            .reach = s.reach.k * g.seeing(),
        };
        // Cleared within what may be drawn on (outside the telescope's
        // square, black).
        const within = area.scissor orelse box;
        try dev.begin(frame, .{ .x = box.x, .y = box.y, .width = box.width, .height = box.height }, .{ .x = within.x, .y = within.y, .width = within.width, .height = within.height });
        defer dev.end();
        const cut = if (g.telescope) main.lens(vp, scissor) else scissor;
        r.draw(renderer_mod.FrameSink{ .frame = dev }, vp, cut, v) catch |err| s.trouble.note("drawing the world", err);
    }
};

pub fn run(init: std.process.Init) !void {
    places.init(init.minimal.environ);
    const gpa = std.heap.page_allocator;
    const app = try kete.App.init(gpa, init.io, init.minimal.environ, .{
        .on_quit_request = .quit,
        .on_last_window_closed = .quit,
    });
    defer app.deinit();

    // The title scene, behind the menu, to choose an island from (as on
    // Dazzle).
    const world = try world_mod.World.create(gpa);
    var game = game_mod.Game.init(gpa, world);
    defer game.deinit();
    var cur: main.Current = .{};
    main.toTitle(gpa, &game, &cur);
    var opts = options.load();
    game.quality = 1;
    game.look = opts.look;
    game.setPlayerName(opts.name());
    const icons = try gpa.create(view.Icons);
    icons.init();

    var name_buf: [64]u8 = undefined;
    var session: ?net.Session = net.Session.init(gpa, .{ .name = net.hostname(&name_buf) }) catch |err| blk: {
        print("motu: no playing together ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (session) |*s| s.deinit();

    var scene: Scene = .{ .gpa = gpa, .app = app, .game = &game };
    defer scene.deinit();
    const root: Root = .{ .game = &game, .icons = icons, .scene = &scene };
    var input: main.Input = .{ .game = &game };
    const window = try app.openWindow(.{
        .title = "Motu",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .on_close_request = .close,
        .on_input = .of(&input, main.Input.filter),
    });
    window.setFullscreen(true);
    input.linux_win = window;
    print("motu: keeping islands in {s}\n", .{places.dir()});

    var last = sys.nowNs();
    var last_save = last;
    // The mouse can be taken (it turns the view) if the compositor can
    // lock the pointer: until it says it cannot.
    game.can_capture = true;
    while (try app.step(std.time.ns_per_s / 60)) {
        const now = sys.nowNs();
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now - last)) / std.time.ns_per_s);
        last = now;
        if (session) |*s| if (s.poll(&game, now)) |event| switch (event) {
            .joined => |j| {
                main.joined(gpa, &game, &cur);
                game.joinWorld(j.world, j.pos, j.yaw, j.time, j.day) catch |err| {
                    print("motu: cannot play in that world ({s})\n", .{@errorName(err)});
                    game.leaveGame();
                };
            },
            .left => main.toTitle(gpa, &game, &cur),
            .denied => game.say("They said no"),
            .failed => game.say("Cannot reach that game"),
        };
        game.tick(dt);
        if (game.capture_wanted) |take| {
            game.capture_wanted = null;
            if (take) {
                if (!window.win.lockPointer()) game.can_capture = false;
            } else {
                window.win.unlockPointer();
                game.captured = false;
            }
        }
        if (scene.renderer) |r| main.mesh(r, world, game.player.eye(), 12, &scene.trouble);
        if (game.wantsSave() and now - last_save > main.save_every * std.time.ns_per_s) {
            main.save(gpa, &game, &cur);
            last_save = now;
        }
        if (!std.meta.eql(game.look, opts.look) or !std.mem.eql(u8, game.playerName(), opts.name())) {
            opts.look = game.look;
            opts.setName(game.playerName());
            options.save(&opts);
        }
        if (game.island_action) |action| {
            game.island_action = null;
            main.islandAction(gpa, &game, &cur, action);
        }
        if (game.quit_asked or window.isClosed()) break;
    }
    if (game.wantsSave()) main.save(gpa, &game, &cur);
}
