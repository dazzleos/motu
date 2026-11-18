//! Motu on Linux (built with -Dplatform=linux): its window is kete's own,
//! on Wayland, and kete draws it (with Vulkan, where it can). The game is
//! the same as on Dazzle: its islands (kept in places.dir()), the menu,
//! playing together on the network.
//!
//! The world itself is not drawn yet (the view is black): that is
//! gpu.zig's Vulkan backend's, to come.

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

const print = sys.print;

/// The window's root: the menu, the hotbar and the rest over the world
/// (not drawn yet).
const Root = struct {
    game: *game_mod.Game,
    icons: *const view.Icons,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Motu{ .game = r.game, .icons = r.icons, .draw = null });
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

    // The world: as it was left, or a new island (as on Dazzle).
    const world = try world_mod.World.create(gpa);
    var game = game_mod.Game.init(gpa, world);
    defer game.deinit();
    var cur: main.Current = .{};
    if (main.findIslands(&game, "")) |newest| cur.set(game.islands.name(newest));
    if (cur.len == 0 or (main.load(gpa, &game, &cur) catch null) == null) {
        if (cur.len == 0) cur.set("Island");
        try main.makeIsland(&game, world_mod.default_seed);
        main.save(gpa, &game, &cur);
    }
    _ = main.findIslands(&game, cur.name());
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

    const root: Root = .{ .game = &game, .icons = icons };
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
    print("motu: keeping islands in {s}\n", .{places.dir()});

    var last = sys.nowNs();
    var last_save = last;
    // The mouse is not taken yet (kete's Wayland windows cannot lock the
    // pointer): the view is turned with the keys.
    game.can_capture = false;
    while (try app.step(std.time.ns_per_s / 60)) {
        const now = sys.nowNs();
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now - last)) / std.time.ns_per_s);
        last = now;
        if (session) |*s| if (s.poll(&game, now)) |event| switch (event) {
            .joined => |j| {
                main.save(gpa, &game, &cur);
                game.joinWorld(j.world, j.pos, j.yaw, j.time, j.day) catch |err| {
                    print("motu: cannot play in that world ({s})\n", .{@errorName(err)});
                    game.leaveGame();
                };
            },
            .left => {
                main.backHome(gpa, &game, &cur);
                game.say("Back on your island");
            },
            .denied => game.say("They said no"),
            .failed => game.say("Cannot reach that game"),
        };
        game.tick(dt);
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
