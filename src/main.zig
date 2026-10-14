//! Blocks: a voxel building game on an island (see game.zig for how it is
//! played, world.zig for the world, renderer.zig for how it is drawn).
//!
//!     dazzle-blocks
//!
//! The world is kept in the user's files (`save_path`): loaded when the
//! game starts (or a new island made), and saved every minute it has
//! changed and when the window closes, also while others play in it
//! (their changes too: the host saves). Playing in another's game (see
//! net.zig), their world is not saved here: this island is saved before
//! joining, and loaded again on leaving.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const vc4 = @import("vc4");
const ui = @import("ui");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");
const view = @import("view.zig");
const net = @import("net.zig");

const print = sys.print;
const Renderer = renderer_mod.Renderer(vc4.Device);

/// Where the world is kept.
pub const save_path = sys.system.user_dir ++ "/Island.blocks";
/// How often a changed world is saved, in seconds.
const save_every = 60;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "dazzle-blocks: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// What drawing the world needs (the view widget calls `draw`).
const Scene = struct {
    game: *game_mod.Game,
    renderer: *Renderer,

    fn draw(ctx: *anyopaque, f: *vc4.render.Frame, area: ui.GpuArea) anyerror!void {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        const g = s.game;
        const vp = area.viewport;
        try s.renderer.draw(renderer_mod.FrameSink{ .frame = f }, vp, area.scissor, .{
            .camera = g.camera(),
            .aspect = @as(f32, @floatFromInt(vp.width)) / @as(f32, @floatFromInt(@max(vp.height, 1))),
            .time = g.clock,
            .env = renderer_mod.Environment.at(g.time_of_day),
            .underwater = g.player.underwater(g.world),
            .bump = g.bump,
            .outline = if (g.target) |t| t.cell else null,
            .avatars = g.net.others,
        });
    }
};

fn load(gpa: std.mem.Allocator, g: *game_mod.Game) !void {
    const data = sys.readFileAlloc(gpa, save_path, 64 * 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) print(sys.log_warning ++ "dazzle-blocks: cannot read {s} ({s}): a new island\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
    defer gpa.free(data);
    g.decode(data) catch |err| {
        print("dazzle-blocks: {s} is not a world this can read ({s}): a new island\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
}

/// Back from another's game: this island, as saved before joining.
fn backHome(gpa: std.mem.Allocator, g: *game_mod.Game) void {
    load(gpa, g) catch {
        g.world.generate(world_mod.default_seed) catch {};
        g.player = .{ .pos = g.world.spawn, .yaw = g.world.spawn_yaw };
    };
    g.unsaved = false;
}

fn save(gpa: std.mem.Allocator, g: *game_mod.Game) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    g.encode(&out) catch |err| {
        print(sys.log_warning ++ "dazzle-blocks: cannot save: {s}\n", .{@errorName(err)});
        return;
    };
    // Written whole, then put in place of the old.
    const tmp = save_path ++ ".new";
    _ = linux.unlink(tmp);
    sys.files.writeNew(tmp, out.items) catch |err| {
        print(sys.log_warning ++ "dazzle-blocks: cannot save {s}: {s}\n", .{ save_path, @errorName(err) });
        return;
    };
    _ = linux.rename(tmp, save_path);
    g.unsaved = false;
    print("dazzle-blocks: saved ({d} KB)\n", .{out.items.len / 1024});
}

fn run(init: std.process.Init.Minimal) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    // A frame in flight: the next is recorded while the GPU renders this
    // one (with a third buffer, while the GPU's memory allows).
    const a = try ui.App.open(gpa, init.environ, .{
        .title = "Blocks",
        .app_id = "dazzle-blocks",
        .size = view.open_size,
        .min_size = view.min_size,
        .pipelined = true,
    });
    defer a.close();

    // The world: as it was left, or a new island.
    const world = try world_mod.World.create(gpa);
    var game = game_mod.Game.init(gpa, world);
    defer game.deinit();
    load(gpa, &game) catch {
        const started = sys.nowNs();
        try world.generate(world_mod.default_seed);
        game = game_mod.Game.init(gpa, world);
        print("dazzle-blocks: made an island in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
    };
    const renderer = try Renderer.init(gpa, a.dev);
    {
        // The chunks around the player now; the rest a few a frame, from
        // the nearest (they are further off, in the fog, at first).
        const started = sys.nowNs();
        _ = try renderer.update(world, game.player.eye(), 12);
        print("dazzle-blocks: meshed the nearest chunks in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
    }
    var scene: Scene = .{ .game = &game, .renderer = renderer };
    const icons = try gpa.create(view.Icons);
    icons.init();

    // Playing together: said to be here, and joinable, on the network.
    var name_buf: [64]u8 = undefined;
    var session: ?net.Session = net.Session.init(gpa, .{ .name = net.hostname(&name_buf) }) catch |err| blk: {
        print(sys.log_warning ++ "dazzle-blocks: no playing together ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (session) |*s| s.deinit();

    var last = sys.nowNs();
    var last_save = last;
    var fps: f32 = 0;
    var frames: u32 = 0;
    var fps_since = last;
    var log_since = last;
    while (true) {
        // While shown, a frame as often as the shell takes them; covered,
        // nothing to do but wait.
        a.idle = a.suspended;
        if (!try a.step(std.time.ns_per_s)) {
            if (game.wantsSave()) save(gpa, &game);
            return;
        }
        // The mouse can be taken if the shell can lock the pointer.
        game.can_capture = a.win.pointer_constraints != null and a.win.relative_pointer_manager != null;
        for (a.win.takeInput()) |e| switch (e) {
            // With the mouse taken, it turns the view and its buttons act
            // on the middle of it; the widgets do not see it.
            .motion => |pos| if (!game.captured) a.ui.pointerMotion(pos),
            .button => |b| if (game.captured) game.mouseButton(b.code, b.pressed) else a.ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| game.key(k.code, k.pressed),
            .scroll => |sc| if (game.captured) {
                if (sc.dy != 0) game.scroll(sc.dy);
            } else a.ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => if (!game.captured) a.ui.pointerLeave(),
            .relative_motion => |d| if (game.captured) game.mouseMoved(d[0], d[1]),
            .pointer_locked => |locked| {
                // Given back (the shell took it): the menu.
                game.pointerLocked(locked);
                if (!locked) a.win.unlockPointer();
            },
            else => a.ui.handleInput(e),
        };

        if (game.capture_wanted) |take| {
            game.capture_wanted = null;
            if (take) {
                if (!a.win.lockPointer()) game.can_capture = false;
            } else {
                a.win.unlockPointer();
                game.captured = false;
            }
        }

        const now = sys.nowNs();
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now - last)) / std.time.ns_per_s);
        last = now;
        // The others, even behind the menu (they play on).
        if (session) |*s| if (s.poll(&game, now)) |event| switch (event) {
            .joined => |j| {
                // This island, kept for coming back to.
                save(gpa, &game);
                game.joinWorld(j.world, j.pos, j.yaw, j.time) catch |err| {
                    print(sys.log_warning ++ "dazzle-blocks: cannot play in that world ({s})\n", .{@errorName(err)});
                    game.leaveGame();
                };
                _ = try renderer.update(world, game.player.eye(), 12);
            },
            .left => {
                backHome(gpa, &game);
                _ = try renderer.update(world, game.player.eye(), 12);
                game.say("Back on your island");
            },
            .denied => game.say("They said no"),
            .failed => game.say("Cannot reach that game"),
        };
        game.tick(dt);
        // What changed, meshed again (a few chunks a frame, so a big change
        // does not stall a frame).
        _ = try renderer.update(world, game.player.eye(), 3);
        if (game.wantsSave() and now - last_save > save_every * std.time.ns_per_s) {
            save(gpa, &game);
            last_save = now;
        }
        if (a.suspended) continue;

        a.ui.frame(a.width, a.height, a.win.nextPresentationNs(now), view.Blocks{
            .game = &game,
            .icons = icons,
            .draw = .{ .ctx = &scene, .f = Scene.draw },
            .stats = renderer.stats,
            .fps = fps,
        });
        if (a.ui.changed()) {
            const target = try a.win.beginFrame();
            const region = a.ui.repaint(a.win.bufferAge());
            // Antialiased: 4x multisampled (see vc4.render.Frame).
            if (game.antialias) a.frame.beginMultisampled(target, 0xff000000) else a.frame.begin(target, .{ .clear = 0xff000000 });
            ui.Ui.limit(&a.frame, &region);
            try a.ui.render(&a.frame, a.win.flusher());
            var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
            // To the GPU, showing the frame before while it renders this.
            try a.win.submit(&a.frame, a.ui.damagedViewports(&damage));
            frames += 1;
        }
        if (now - fps_since >= std.time.ns_per_s) {
            fps = @as(f32, @floatFromInt(frames)) / (@as(f32, @floatFromInt(now - fps_since)) / std.time.ns_per_s);
            frames = 0;
            fps_since = now;
        }
        if (now - log_since >= 10 * std.time.ns_per_s) {
            const s = renderer.stats;
            print("dazzle-blocks: {d:.1} fps; {d} chunks, {d} draws, {d} triangles\n", .{ fps, s.chunks, s.draws, s.triangles });
            log_since = now;
        }
    }
}

test {
    _ = @import("blocks.zig");
    _ = @import("textures.zig");
    _ = @import("world.zig");
    _ = @import("mesher.zig");
    _ = @import("math.zig");
    _ = @import("player.zig");
    _ = @import("creatures.zig");
    _ = @import("renderer.zig");
    _ = @import("preview.zig");
    _ = @import("game.zig");
    _ = @import("view.zig");
    _ = @import("net.zig");
}
