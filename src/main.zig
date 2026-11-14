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
const app = @import("app");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");
const view = @import("view.zig");
const net = @import("net.zig");
const options = @import("options.zig");
const upscale = @import("upscale.zig");

const print = sys.print;
const Renderer = renderer_mod.Renderer(vc4.Device);

/// Where the world is kept.
pub const save_path = sys.system.user_dir ++ "/Island.blocks";
/// How often a changed world is saved, in seconds.
const save_every = 60;

pub fn main(init: std.process.Init) u8 {
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
    /// For drawing the world smaller (if it could be made), and how much.
    upscaler: ?*upscale.Upscaler = null,
    scale: upscale.Scale = .{},
    /// `app.window.gpu_waited_ns` at the last frame.
    waited_ns: u64 = 0,

    fn draw(ctx: *anyopaque, f: *vc4.render.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        const g = s.game;
        const vp = kete_vc4.renderer.viewport(area.viewport);
        const scissor = if (area.scissor) |sc| kete_vc4.renderer.viewport(sc) else null;
        // How big to draw it, from how the last frames went.
        const waited = app.window.gpu_waited_ns -% s.waited_ns;
        s.waited_ns = app.window.gpu_waited_ns;
        _ = s.scale.frame(sys.nowNs(), waited);
        const seen: renderer_mod.View = .{
            .camera = g.camera(),
            .aspect = @as(f32, @floatFromInt(vp.width)) / @as(f32, @floatFromInt(@max(vp.height, 1))),
            .time = g.clock,
            .env = renderer_mod.Environment.at(g.time_of_day),
            .underwater = g.player.underwater(g.world),
            .bump = g.bump,
            .outline = if (g.target) |t| t.cell else null,
            .avatars = g.net.others,
        };
        // Smaller, into an image stretched over the view.
        if (s.upscaler) |up| if (s.scale.k < 1) {
            const full = [2]u32{ vp.width, vp.height };
            const size = s.scale.of(full);
            if (up.begin(full, size, g.antialias)) |image| {
                try s.renderer.draw(renderer_mod.FrameSink{ .frame = image }, .{ .x = 0, .y = 0, .width = @intCast(size[0]), .height = @intCast(size[1]) }, null, seen);
                try up.finish(f, size, vp, scissor);
                return;
            }
        };
        try s.renderer.draw(renderer_mod.FrameSink{ .frame = f }, vp, scissor, seen);
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

/// Where the frames' time goes, since it was last said: each part of
/// the loop, recording the frames' draws, waiting for the GPU, and the
/// GPU's own time on them (its two stages: binning, which sorts the
/// triangles into the screen's tiles, and rendering the tiles).
const Timing = struct {
    frames: u32 = 0,
    /// The UI's step (building, recording and handing over the frame, and
    /// waiting for the shell to take one), the game's tick, and meshing.
    step_ns: u64 = 0,
    tick_ns: u64 = 0,
    mesh_ns: u64 = 0,
    record_ns: u64 = 0,
    pixels: f64 = 0,
    /// `app.window.gpu_waited_ns`, and the GPU's time, as they were.
    waited_ns: u64,
    gpu: GpuTime,

    fn report(t: *const Timing, fd: linux.fd_t, elapsed_ns: u64, antialias: bool, bump: bool, scale: f32) void {
        const n: f64 = @floatFromInt(@max(t.frames, 1));
        const ms = struct {
            fn per(ns: u64, frames: f64) f64 {
                return @as(f64, @floatFromInt(ns)) / std.time.ns_per_ms / frames;
            }
        }.per;
        const gpu_now = GpuTime.read(fd);
        var gpu_buf: [96]u8 = undefined;
        const gpu_text = if (gpu_now.known and t.gpu.known)
            std.fmt.bufPrint(&gpu_buf, "GPU binning {d:.1} ms, rendering {d:.1} ms ({d:.0}% busy)", .{
                ms(gpu_now.bin_ns -| t.gpu.bin_ns, n),
                ms(gpu_now.render_ns -| t.gpu.render_ns, n),
                100 * @as(f64, @floatFromInt(@max(gpu_now.bin_ns -| t.gpu.bin_ns, gpu_now.render_ns -| t.gpu.render_ns))) / @as(f64, @floatFromInt(@max(elapsed_ns, 1))),
            }) catch "GPU time not known"
        else
            "GPU time not known";
        print("dazzle-blocks: per frame: {s}; {d:.2} Mpixels, the world at {d:.0}%{s}{s}; CPU: step {d:.1} ms (recording {d:.1} ms, waiting for the GPU {d:.1} ms), game {d:.1} ms, meshing {d:.1} ms\n", .{
            gpu_text,
            t.pixels / n / 1e6,
            scale * 100,
            if (antialias) ", antialiased" else "",
            if (bump) ", bump mapped" else "",
            ms(t.step_ns, n),
            ms(t.record_ns, n),
            ms(app.window.gpu_waited_ns -% t.waited_ns, n),
            ms(t.tick_ns, n),
            ms(t.mesh_ns, n),
        });
    }
};

/// The GPU's time on this process's work, from the kernel's counters for
/// its GPU file (/proc/self/fdinfo): binning and rendering.
const GpuTime = struct {
    bin_ns: u64 = 0,
    render_ns: u64 = 0,
    known: bool = false,

    fn read(fd: linux.fd_t) GpuTime {
        var path_buf: [48]u8 = undefined;
        const path = std.fmt.bufPrintSentinel(&path_buf, "/proc/self/fdinfo/{d}", .{fd}, 0) catch return .{};
        var buf: [1024]u8 = undefined;
        return parse(sys.readFile(path, &buf) orelse return .{});
    }

    fn parse(text: []const u8) GpuTime {
        var t: GpuTime = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
            const key = std.mem.trim(u8, line[0..colon], " \t");
            const field: *u64 = if (std.mem.eql(u8, key, "drm-engine-bin")) &t.bin_ns else if (std.mem.eql(u8, key, "drm-engine-render")) &t.render_ns else continue;
            var toks = std.mem.tokenizeAny(u8, line[colon + 1 ..], " \t");
            const num = toks.next() orelse continue;
            if (!std.mem.eql(u8, toks.next() orelse "", "ns")) continue;
            field.* = std.fmt.parseInt(u64, num, 10) catch continue;
            t.known = true;
        }
        return t;
    }
};

test "the GPU's time is read from the kernel's counters for its file" {
    const t = GpuTime.parse("pos:\t0\nflags:\t02100002\ndrm-driver:\tvc4\ndrm-client-id:\t7\ndrm-engine-bin:\t123456 ns\ndrm-engine-render:\t7654321 ns\n");
    try std.testing.expect(t.known);
    try std.testing.expectEqual(@as(u64, 123456), t.bin_ns);
    try std.testing.expectEqual(@as(u64, 7654321), t.render_ns);
    try std.testing.expect(!GpuTime.parse("drm-driver:\tvc4\n").known);
}

/// Errors Blocks goes on from (the frame or the meshes are made again
/// later), said in the log: each kind once, and then at most every few
/// seconds, so one that keeps happening does not fill it.
const Trouble = struct {
    last_ns: u64 = 0,
    last: ?anyerror = null,
    since_said: u32 = 0,

    const quiet_ns = 5 * std.time.ns_per_s;

    fn note(t: *Trouble, what: []const u8, err: anyerror) void {
        const now = sys.nowNs();
        t.since_said += 1;
        if (t.last != null and t.last.? == err and now -| t.last_ns < quiet_ns) return;
        print(sys.log_warning ++ "dazzle-blocks: {s} failed ({s}; {d} times since last said); going on\n", .{ what, @errorName(err), t.since_said });
        t.last = err;
        t.last_ns = now;
        t.since_said = 0;
    }
};

/// Meshes up to `limit` of the chunks changed, nearest `near` first; if
/// it cannot (no memory), they are meshed later.
fn mesh(renderer: *Renderer, world: *world_mod.World, near: anytype, limit: usize, trouble: *Trouble) void {
    _ = renderer.update(world, near, limit) catch |err| trouble.note("meshing the island", err);
}

/// Whether `err` means the connection to the shell is gone (it closed it,
/// or said this did something wrong): nothing more can be shown.
fn lostShell(err: anyerror) bool {
    return err == error.Closed or err == error.ProtocolError or err == error.ServerError or err == error.SystemError or err == error.Canceled;
}

/// The window's root: the world and what is over it.
const Root = struct {
    game: *game_mod.Game,
    icons: *const view.Icons,
    scene: *Scene,
    fps: *const f32,

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Blocks{
            .game = r.game,
            .icons = r.icons,
            .draw = .{ .ctx = r.scene, .f = Scene.draw },
            .stats = r.scene.renderer.stats,
            .fps = r.fps.*,
        });
    }
};

/// The input the game takes before the widgets see it: all the keys, and
/// with the mouse taken, the mouse too (it turns the view, and its buttons
/// act on the middle of it).
const Input = struct {
    game: *game_mod.Game,
    win: ?*app.Window = null,

    fn filter(in: *Input, e: kete.window.InputEvent) bool {
        const game = in.game;
        switch (e) {
            .key => |k| {
                game.key(k.key, k.pressed);
                return true;
            },
            .button => |b| if (game.captured) {
                game.mouseButton(b.button, b.pressed);
                return true;
            },
            .scroll => |sc| if (game.captured) {
                if (sc.dy != 0) game.scroll(sc.dy);
                return true;
            },
            .motion, .leave => return game.captured,
            .relative_motion => |d| {
                if (game.captured) game.mouseMoved(d[0], d[1]);
                return true;
            },
            .pointer_locked => |locked| {
                // Given back (the shell took it): the menu.
                game.pointerLocked(locked);
                if (!locked) if (in.win) |w| w.unlockPointer();
                return true;
            },
            else => {},
        }
        return false;
    }
};

fn run(init: std.process.Init) !void {
    locale.current = locale.load().language;
    const gpa = std.heap.page_allocator;
    var host: kete_vc4.Host = undefined;
    // A frame in flight: the next is recorded while the GPU renders this
    // one (with a third buffer, while the GPU's memory allows).
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "dazzle-blocks", .pipelined = true });
    defer host.deinit();

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
    // The options as chosen, or as suit the GPU (the Pi 4's and 5's draws
    // them fast enough; the older one's does not).
    var kept = options.effective(options.load(), host.dev.is_v3d);
    game.antialias = kept.antialias;
    game.bump = kept.bump;
    const renderer = try Renderer.init(gpa, host.dev);
    var trouble: Trouble = .{};
    {
        // The chunks around the player now; the rest a few a frame, from
        // the nearest (they are further off, in the fog, at first).
        const started = sys.nowNs();
        mesh(renderer, world, game.player.eye(), 12, &trouble);
        print("dazzle-blocks: meshed the nearest chunks in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
    }
    // For drawing the world smaller when the GPU cannot keep up.
    var upscaler: ?upscale.Upscaler = upscale.Upscaler.init(gpa, host.dev) catch |err| blk: {
        print(sys.log_warning ++ "dazzle-blocks: the world is always drawn whole ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (upscaler) |*u| u.deinit();
    var scene: Scene = .{ .game = &game, .renderer = renderer, .upscaler = if (upscaler) |*u| u else null };
    const icons = try gpa.create(view.Icons);
    icons.init();

    // Playing together: said to be here, and joinable, on the network.
    var name_buf: [64]u8 = undefined;
    var session: ?net.Session = net.Session.init(gpa, .{ .name = net.hostname(&name_buf) }) catch |err| blk: {
        print(sys.log_warning ++ "dazzle-blocks: no playing together ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (session) |*s| s.deinit();

    var fps: f32 = 0;
    const root: Root = .{ .game = &game, .icons = icons, .scene = &scene, .fps = &fps };
    var input: Input = .{ .game = &game };
    const window = try host.app.openWindow(.{
        .title = "Blocks",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .clear_color = 0xff000000,
        .on_close_request = .close,
        .on_input = .of(&input, Input.filter),
    });
    const win = &host.display.window.?;
    input.win = win.win;

    var last = sys.nowNs();
    var last_save = last;
    var frames: u32 = 0;
    var fps_since = last;
    var log_since = last;
    // Where the frames' time goes, said with the frame rate.
    var timing: Timing = .{ .gpu = .read(host.dev.fd), .waited_ns = app.window.gpu_waited_ns };
    while (true) {
        // While shown, a frame as often as the shell takes them; covered,
        // nothing to do but wait.
        if (!window.suspended) host.redraw();
        const step_started = sys.nowNs();
        const going = host.step(std.time.ns_per_s) catch |err| blk: {
            // The shell is gone: nothing more can be shown. The island is
            // kept first.
            if (lostShell(err)) {
                if (game.wantsSave()) save(gpa, &game);
                return err;
            }
            // Anything else (the GPU slow, or out of memory for a frame):
            // the frame is drawn again, after a moment.
            trouble.note("a frame", err);
            sys.sleepMs(50);
            break :blk true;
        };
        timing.step_ns += sys.nowNs() - step_started;
        if (!going) {
            if (game.wantsSave()) save(gpa, &game);
            return;
        }
        // The mouse can be taken if the shell can lock the pointer.
        game.can_capture = win.win.pointer_constraints != null and win.win.relative_pointer_manager != null;

        if (game.capture_wanted) |take| {
            game.capture_wanted = null;
            if (take) {
                if (!win.win.lockPointer()) game.can_capture = false;
            } else {
                win.win.unlockPointer();
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
                mesh(renderer, world, game.player.eye(), 12, &trouble);
            },
            .left => {
                backHome(gpa, &game);
                mesh(renderer, world, game.player.eye(), 12, &trouble);
                game.say("Back on your island");
            },
            .denied => game.say("They said no"),
            .failed => game.say("Cannot reach that game"),
        };
        const tick_started = sys.nowNs();
        game.tick(dt);
        const mesh_started = sys.nowNs();
        // What changed, meshed again (a few chunks a frame, so a big change
        // does not stall a frame).
        mesh(renderer, world, game.player.eye(), 3, &trouble);
        timing.tick_ns += mesh_started - tick_started;
        timing.mesh_ns += sys.nowNs() - mesh_started;
        if (game.wantsSave() and now - last_save > save_every * std.time.ns_per_s) {
            save(gpa, &game);
            last_save = now;
        }
        // Changed in the menu: kept.
        if (game.antialias != kept.antialias or game.bump != kept.bump) {
            kept = .{ .antialias = game.antialias, .bump = game.bump };
            options.save(.{ .antialias = kept.antialias, .bump = kept.bump });
        }
        // Antialiased: 4x multisampled (see vc4.render.Frame).
        host.renderer.multisampled = game.antialias;
        const stats = host.renderer.takeStats();
        frames += stats.frames;
        timing.frames += stats.frames;
        timing.record_ns += stats.cpu_ns;
        timing.pixels += stats.pixels;
        if (now - fps_since >= std.time.ns_per_s) {
            fps = @as(f32, @floatFromInt(frames)) / (@as(f32, @floatFromInt(now - fps_since)) / std.time.ns_per_s);
            frames = 0;
            fps_since = now;
        }
        if (now - log_since >= 10 * std.time.ns_per_s) {
            const s = renderer.stats;
            print("dazzle-blocks: {d:.1} fps; {d} chunks, {d} draws, {d} triangles\n", .{ fps, s.chunks, s.draws, s.triangles });
            timing.report(host.dev.fd, now - log_since, game.antialias, game.bump, scene.scale.k);
            timing = .{ .gpu = timing.gpu, .waited_ns = app.window.gpu_waited_ns };
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
    _ = @import("options.zig");
    _ = @import("upscale.zig");
}
