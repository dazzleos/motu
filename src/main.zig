//! Blocks: a voxel building game on an island (see game.zig for how it is
//! played, world.zig for the world, renderer.zig for how it is drawn).
//!
//!     dazzle-blocks
//!
//! The world is kept in the user's files (`save_path`): loaded when the
//! game starts (or a new island made), and saved every minute it has
//! changed and when the window closes.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const font = @import("font");
const vc4 = @import("vc4");
const app = @import("app");
const ui = @import("ui");
const wayland = @import("wayland");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");
const view = @import("view.zig");

const print = sys.print;
const Renderer = renderer_mod.Renderer(vc4.Device);

/// Where the world is kept.
pub const save_path = sys.system.user_dir ++ "/Island.blocks";
/// How often a changed world is saved, in seconds.
const save_every = 60;

var frame: vc4.render.Frame = undefined;

pub fn main(init: std.process.Init.Minimal) u8 {
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print("dazzle-blocks: error: {s}\n", .{@errorName(err)});
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
            .outline = if (g.target) |t| t.cell else null,
        });
    }
};

fn load(gpa: std.mem.Allocator, g: *game_mod.Game) !void {
    const data = sys.readFileAlloc(gpa, save_path, 64 * 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) print("dazzle-blocks: cannot read {s} ({s}): a new island\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
    defer gpa.free(data);
    g.decode(data) catch |err| {
        print("dazzle-blocks: {s} is not a world this can read ({s}): a new island\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
}

fn save(gpa: std.mem.Allocator, g: *game_mod.Game) void {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    g.encode(&out) catch |err| {
        print("dazzle-blocks: cannot save: {s}\n", .{@errorName(err)});
        return;
    };
    // Written whole, then put in place of the old.
    const tmp = save_path ++ ".new";
    _ = linux.unlink(tmp);
    sys.files.writeNew(tmp, out.items) catch |err| {
        print("dazzle-blocks: cannot save {s}: {s}\n", .{ save_path, @errorName(err) });
        return;
    };
    _ = linux.rename(tmp, save_path);
    g.unsaved = false;
    print("dazzle-blocks: saved ({d} KB)\n", .{out.items.len / 1024});
}

fn run(init: std.process.Init.Minimal) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var dev = vc4.device.openRender() catch |err| {
        print("dazzle-blocks: no GPU ({s})\n", .{@errorName(err)});
        return err;
    };
    const win = try openWindow(gpa, init, &dev);
    var width = win.width;
    var height = win.height;

    var font_buf: [512]u8 = undefined;
    var f: ?font.Font = blk: {
        const data = sys.readFileAlloc(gpa, sys.fontFile(&font_buf, font.default_font_file), 32 * 1024 * 1024) catch break :blk null;
        break :blk font.Font.init(data) catch null;
    };
    const window_ui = try ui.Ui.create(gpa, if (f) |*fnt| fnt else null);
    try window_ui.attachGpu(dev);

    // The world: as it was left, or a new island.
    const world = try world_mod.World.create(gpa);
    var game = game_mod.Game.init(gpa, world);
    load(gpa, &game) catch {
        const started = sys.nowNs();
        try world.generate(world_mod.default_seed);
        game = game_mod.Game.init(gpa, world);
        print("dazzle-blocks: made an island in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
    };
    const renderer = try Renderer.init(gpa, dev);
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

    var controls: app.Controls = .{ .win = win };
    win.setMinSize(view.min_size[0], view.min_size[1]);

    var suspended = false;
    var last = sys.nowNs();
    var last_save = last;
    var fps: f32 = 0;
    var frames: u32 = 0;
    var fps_since = last;
    var log_since = last;
    while (true) {
        // While shown, a frame as often as the shell takes them; covered,
        // nothing to do but wait.
        const waited = if (suspended) win.wait(std.time.ns_per_s) else win.poll();
        waited catch |err| {
            if (err == error.ServerError) print("dazzle-blocks: compositor error: {s}\n", .{win.conn.errorMessage()});
            return err;
        };
        if (win.closed or controls.quit) {
            if (game.unsaved) save(gpa, &game);
            return;
        }
        if (try win.applyConfigure()) |size| {
            width = size[0];
            height = size[1];
        }
        if (win.suspended != suspended) {
            suspended = win.suspended;
            if (suspended) win.releaseSpareBuffers();
        }
        window_ui.keyboard = win.layout;
        for (win.takeInput()) |e| switch (e) {
            .motion => |pos| window_ui.pointerMotion(pos),
            .button => |b| window_ui.pointerButton(b.pos, b.code, b.pressed),
            .key => |k| game.key(k.code, k.pressed),
            .scroll => |sc| window_ui.pointerScroll(sc.pos, sc.dx, sc.dy),
            .leave => window_ui.pointerLeave(),
            .touch_down => |t| window_ui.touchDown(t.id, t.pos),
            .touch_motion => |t| window_ui.touchMotion(t.id, t.pos),
            .touch_up => |id| window_ui.touchUp(id),
            .touch_cancel => window_ui.touchCancel(),
        };

        const now = sys.nowNs();
        const dt: f32 = @floatCast(@as(f64, @floatFromInt(now - last)) / std.time.ns_per_s);
        last = now;
        game.tick(dt);
        // What changed, meshed again (a few chunks a frame, so a big change
        // does not stall a frame).
        _ = try renderer.update(world, game.player.eye(), 3);
        if (game.unsaved and now - last_save > save_every * std.time.ns_per_s) {
            save(gpa, &game);
            last_save = now;
        }
        if (suspended) continue;

        window_ui.frame(width, height, now, view.Blocks{
            .game = &game,
            .icons = icons,
            .draw = .{ .ctx = &scene, .f = Scene.draw },
            .stats = renderer.stats,
            .fps = fps,
            .on_close = .of(&controls, app.Controls.close),
            .on_maximize = .of(&controls, app.Controls.toggleMaximized),
            .on_drag = .of(&controls, app.Controls.drag),
            .maximized = win.maximized,
        });
        if (window_ui.changed()) {
            const target = try win.beginFrame();
            const region = window_ui.repaint(win.bufferAge());
            frame.begin(target, .{ .clear = 0xff000000 });
            ui.Ui.limit(&frame, &region);
            try window_ui.render(&frame, win.flusher());
            try win.render(&frame);
            var damage: [ui.damage.Region.max_rects]vc4.render.Viewport = undefined;
            const changed = window_ui.damaged();
            for (changed, damage[0..changed.len]) |r, *v| v.* = .{ .x = @intFromFloat(r.x), .y = @intFromFloat(r.y), .width = @intFromFloat(r.w), .height = @intFromFloat(r.h) };
            try win.showDamaged(damage[0..changed.len]);
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

fn openWindow(gpa: std.mem.Allocator, init: std.process.Init.Minimal, dev: *vc4.Device) !*app.Window {
    const Environ = std.process.Environ;
    var path_buf: [128]u8 = undefined;
    const path = wayland.client.socketPath(&path_buf, Environ.getPosix(init.environ, "XDG_RUNTIME_DIR"), Environ.getPosix(init.environ, "WAYLAND_DISPLAY")) catch {
        print("dazzle-blocks: WAYLAND_DISPLAY needs XDG_RUNTIME_DIR\n", .{});
        return error.NoCompositor;
    };
    const win = app.Window.open(gpa, .device(dev), path, "Blocks") catch |err| {
        print("dazzle-blocks: cannot open a window on {s} ({s})\n", .{ path, @errorName(err) });
        return err;
    };
    try win.setAppId("dazzle-blocks");
    return win;
}

test {
    _ = @import("blocks.zig");
    _ = @import("textures.zig");
    _ = @import("world.zig");
    _ = @import("mesher.zig");
    _ = @import("math.zig");
    _ = @import("player.zig");
    _ = @import("renderer.zig");
    _ = @import("preview.zig");
    _ = @import("game.zig");
    _ = @import("view.zig");
}
