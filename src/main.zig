//! Motu: a voxel building game on an island (see game.zig for how it is
//! played, world.zig for the world, renderer.zig for how it is drawn).
//!
//!     motu
//!
//! Islands are kept in the user's files, each a file named for it (`Island
//! 2.blocks`): the one played last is loaded when the game starts (or, the
//! first time, an island made and kept), and saved every minute it has
//! changed, when another is played, and on quitting, also while others
//! play in it (their changes too: the host saves). The menu lists them, to
//! play another, make a new one or delete one. Playing in another's game
//! (see net.zig), their world is not saved here: this island is saved
//! before joining, and loaded again on leaving.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const locale = @import("locale");
const gpu = @import("gpu.zig");
const app = @import("app");
const kete = @import("kete");
const kete_vc4 = @import("kete_vc4");
const world_mod = @import("world.zig");
const game_mod = @import("game.zig");
const renderer_mod = @import("renderer.zig");
const view = @import("view.zig");
const net = @import("net.zig");
const options = @import("options.zig");
const reach_mod = @import("reach.zig");
const upscale = @import("upscale.zig");
const boat_mod = @import("boat.zig");
const places = @import("places.zig");
const platform = @import("platform").platform;
const on_linux = @import("linux.zig");

const print = sys.print;
pub const Renderer = renderer_mod.Renderer(gpu.Device);

/// How the islands' files end (they are kept in places.dir()).
const island_ext = ".motu";

/// The island played now: its name (its file's, less the ending); none
/// in the title scene, or in another's game.
pub const Current = struct {
    buf: [48]u8 = undefined,
    len: usize = 0,

    pub fn name(c: *const Current) []const u8 {
        return c.buf[0..c.len];
    }

    pub fn set(c: *Current, n: []const u8) void {
        c.len = @min(n.len, c.buf.len);
        @memcpy(c.buf[0..c.len], n[0..c.len]);
    }

    /// Its file's path.
    fn path(c: *const Current, buf: *[256]u8) [:0]const u8 {
        return pathOf(c.name(), buf);
    }
};

fn pathOf(n: []const u8, buf: *[256]u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(buf, "{s}/{s}{s}", .{ places.dir(), n, island_ext }, 0) catch buf[0..0 :0];
}

/// The islands kept, by name, into `g.islands` (the current one marked);
/// returns the one changed most recently, if any.
pub fn findIslands(g: *game_mod.Game, current: []const u8) ?u8 {
    g.islands = .{};
    var newest: ?u8 = null;
    var newest_time: i64 = std.math.minInt(i64);
    const dir = sys.open(places.dir(), .{ .ACCMODE = .RDONLY, .DIRECTORY = true, .CLOEXEC = true }) catch return null;
    defer sys.close(dir);
    var buf: [4096]u8 align(8) = undefined;
    while (true) {
        const len = sys.check(linux.getdents64(dir, &buf, buf.len)) catch break;
        if (len == 0) break;
        var at: usize = 0;
        while (at < len) {
            const reclen = std.mem.readInt(u16, buf[at + 16 ..][0..2], .little);
            const file = std.mem.sliceTo(buf[at + 19 .. at + reclen], 0);
            at += reclen;
            if (!std.mem.endsWith(u8, file, island_ext) or file.len == island_ext.len) continue;
            const n = file[0 .. file.len - island_ext.len];
            if (n.len > 48 or g.islands.count == game_mod.Islands.max) continue;
            // In order of name.
            var k: usize = g.islands.count;
            while (k > 0 and std.mem.order(u8, g.islands.name(k - 1), n) == .gt) : (k -= 1) {}
            g.islands.add(n);
            var j: usize = g.islands.count - 1;
            while (j > k) : (j -= 1) {
                std.mem.swap([48]u8, &g.islands.names[j], &g.islands.names[j - 1]);
                std.mem.swap(u8, &g.islands.lens[j], &g.islands.lens[j - 1]);
            }
            if (newest) |nw| {
                if (nw >= k) newest = nw + 1;
            }
            var pbuf: [256]u8 = undefined;
            var st: linux.Statx = undefined;
            if (linux.errno(linux.statx(linux.AT.FDCWD, pathOf(n, &pbuf), 0, .{ .MTIME = true }, &st)) == .SUCCESS and st.mtime.sec > newest_time) {
                newest_time = st.mtime.sec;
                newest = @intCast(k);
            }
        }
    }
    for (0..g.islands.count) |k| if (current.len > 0 and std.mem.eql(u8, g.islands.name(k), current)) {
        g.islands.current = @intCast(k);
    };
    // The one chosen in the menu: the one played, else the newest.
    g.islands.selected = g.islands.current orelse newest;
    return newest;
}

/// A name for a new island: "Island", or the first "Island N" not kept.
fn newName(g: *const game_mod.Game, buf: []u8) []const u8 {
    var k: u32 = 1;
    while (true) : (k += 1) {
        const n = if (k == 1) "Island" else std.fmt.bufPrint(buf, "Island {d}", .{k}) catch "Island";
        const taken = for (0..g.islands.count) |i| {
            if (std.mem.eql(u8, g.islands.name(i), n)) break true;
        } else false;
        if (!taken) return n;
    }
}

/// The canoes being paddled: this player's, and the others'.
pub const Boats = struct {
    list: [net.max_players + 1]boat_mod.Shown = undefined,

    pub fn items(b: *Boats, g: *const game_mod.Game) []const boat_mod.Shown {
        var n: usize = 0;
        if (g.boat) |mine| {
            b.list[n] = mine.shown();
            n += 1;
        }
        for (g.net.others) |o| {
            if (o.boat == 0 or n == b.list.len) continue;
            b.list[n] = .{ .pos = o.pos + @as(@TypeOf(o.pos), .{ 0, boat_mod.seat_drop, 0 }), .yaw = o.boat_yaw, .len = o.boat };
            n += 1;
        }
        return b.list[0..n];
    }
};

/// Makes a new island (from `seed`), to play from its start.
pub fn makeIsland(g: *game_mod.Game, seed: u32) !void {
    const started = sys.nowNs();
    try g.world.generate(seed);
    g.player = .{ .pos = g.world.spawn, .yaw = g.world.spawn_yaw };
    g.boat = null;
    g.time_of_day = 0.34;
    g.day = 0;
    g.target = null;
    print("motu: made an island in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
}
/// How often a changed world is saved, in seconds.
pub const save_every = 60;

pub fn main(init: std.process.Init) u8 {
    if (platform == .linux) {
        on_linux.run(init) catch |err| {
            print("motu: error: {s}\n", .{@errorName(err)});
            return 1;
        };
        return 0;
    }
    sys.logToKmsgIfStderr();
    run(init) catch |err| {
        print(sys.log_error ++ "motu: error: {s}\n", .{@errorName(err)});
        return 1;
    };
    return 0;
}

/// What drawing the world needs (the view widget calls `draw`).
const Scene = struct {
    game: *game_mod.Game,
    renderer: *Renderer,
    /// The window's renderer: how much smaller than the window its buffer
    /// is (the quality chosen), which the world is drawn in.
    window_renderer: *const kete_vc4.Renderer,
    /// While the window's buffer is its full size (the menu or a title
    /// bar is drawn sharp in it): the world drawn `quality` as big, and
    /// stretched over the view (see upscale.zig).
    upscaler: *upscale.Upscaler,
    stretch: bool = false,
    quality: f32 = 1,
    reach: reach_mod.Reach = .{},
    /// `app.window.gpu_waited_ns` at the last frame.
    waited_ns: u64 = 0,

    fn draw(ctx: *anyopaque, f: *gpu.Frame, area: kete.gfx.GpuArea) anyerror!void {
        const s: *Scene = @ptrCast(@alignCast(ctx));
        const g = s.game;
        // Laid out at the window's size; drawn in its buffer, perhaps
        // smaller (the shell, or the display, stretches it).
        const vp = s.window_renderer.scaled(area.viewport);
        const scissor = if (area.scissor) |sc| s.window_renderer.scaled(sc) else null;
        // How far to see, from how the last frames went.
        const waited = app.window.gpu_waited_ns -% s.waited_ns;
        s.waited_ns = app.window.gpu_waited_ns;
        _ = s.reach.frame(sys.nowNs(), waited);
        var boats: Boats = .{};
        const v: renderer_mod.View = .{
            .camera = g.camera(),
            .aspect = @as(f32, @floatFromInt(vp.width)) / @as(f32, @floatFromInt(@max(vp.height, 1))),
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
        if (s.stretch and s.quality < 1) {
            const size = upscale.sizeOf(.{ vp.width, vp.height }, s.quality);
            if (s.upscaler.begin(.{ vp.width, vp.height }, size)) |image| {
                const all: gpu.Viewport = .{ .x = 0, .y = 0, .width = size[0], .height = size[1] };
                try s.renderer.draw(renderer_mod.FrameSink{ .frame = image }, all, if (g.telescope) lens(all, null) else null, v);
                return s.upscaler.finish(f, size, vp, if (g.telescope) lens(vp, scissor) else scissor);
            }
        }
        // Without memory for the image: as big as the view.
        try s.renderer.draw(renderer_mod.FrameSink{ .frame = f }, vp, if (g.telescope) lens(vp, scissor) else scissor, v);
    }
};

/// What the telescope shows of `vp`: the square its circle is in (the
/// view's height, in the middle), within `scissor` if there is one; the
/// rest is not drawn (it is black).
pub fn lens(vp: gpu.Viewport, scissor: ?gpu.Viewport) gpu.Viewport {
    const side = @min(vp.width, vp.height);
    var x0: i32 = vp.x + @as(i32, @intCast((vp.width - side) / 2));
    var y0: i32 = vp.y + @as(i32, @intCast((vp.height - side) / 2));
    var x1: i32 = x0 + @as(i32, @intCast(side));
    var y1: i32 = y0 + @as(i32, @intCast(side));
    if (scissor) |sc| {
        x0 = @max(x0, sc.x);
        y0 = @max(y0, sc.y);
        x1 = @min(x1, sc.x + @as(i32, @intCast(sc.width)));
        y1 = @min(y1, sc.y + @as(i32, @intCast(sc.height)));
    }
    return .{ .x = x0, .y = y0, .width = @intCast(@max(x1 - x0, 0)), .height = @intCast(@max(y1 - y0, 0)) };
}

pub fn load(gpa: std.mem.Allocator, g: *game_mod.Game, cur: *const Current) !void {
    var pbuf: [256]u8 = undefined;
    const save_path = cur.path(&pbuf);
    const data = sys.readFileAlloc(gpa, save_path, 64 * 1024 * 1024) catch |err| {
        if (err != error.FileNotFound) print(sys.log_warning ++ "motu: cannot read {s} ({s})\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
    defer gpa.free(data);
    g.decode(data) catch |err| {
        print("motu: {s} is not a world this can read ({s})\n", .{ save_path, @errorName(err) });
        return error.NoSave;
    };
}

/// The title scene, behind the menu: no island played (the one played
/// is saved first).
pub fn toTitle(gpa: std.mem.Allocator, g: *game_mod.Game, cur: *Current) void {
    if (g.wantsSave()) save(gpa, g, cur);
    cur.len = 0;
    g.world.generateTitle() catch |err| print(sys.log_warning ++ "motu: cannot make the title scene ({s})\n", .{@errorName(err)});
    g.showTitle();
    _ = findIslands(g, "");
}

/// Joined another's game: this island saved, and none played here.
pub fn joined(gpa: std.mem.Allocator, g: *game_mod.Game, cur: *Current) void {
    if (g.wantsSave()) save(gpa, g, cur);
    cur.len = 0;
}

/// Does what the menu asked with the islands.
pub fn islandAction(gpa: std.mem.Allocator, g: *game_mod.Game, cur: *Current, action: game_mod.IslandAction) void {
    if (g.net.status != .alone) {
        g.say("Not while playing together");
        return;
    }
    switch (action) {
        .new => {
            if (g.wantsSave()) save(gpa, g, cur);
            var nbuf: [48]u8 = undefined;
            cur.set(newName(g, &nbuf));
            makeIsland(g, @truncate(sys.nowNs() *% 0x9e3779b97f4a7c15 >> 32)) catch |err| {
                print(sys.log_warning ++ "motu: cannot make an island ({s})\n", .{@errorName(err)});
                return;
            };
            g.title = false;
            save(gpa, g, cur);
            g.say(cur.name());
        },
        .open => |i| {
            if (i >= g.islands.count) return;
            if (g.wantsSave()) save(gpa, g, cur);
            var nbuf: [48]u8 = undefined;
            const n = g.islands.name(i);
            @memcpy(nbuf[0..n.len], n);
            cur.set(nbuf[0..n.len]);
            load(gpa, g, cur) catch {
                // Not readable: the title scene still.
                g.say("Cannot open that island");
                cur.len = 0;
                return;
            };
            g.title = false;
            g.unsaved = false;
            g.say(cur.name());
        },
        .leave => {
            toTitle(gpa, g, cur);
            return;
        },
        .delete => |i| {
            if (i >= g.islands.count or i == g.islands.current) return;
            if (g.islands.selected == i) g.islands.selected = null;
            var pbuf: [256]u8 = undefined;
            _ = linux.unlink(pathOf(g.islands.name(i), &pbuf));
            print("motu: deleted {s}\n", .{g.islands.name(i)});
        },
    }
    _ = findIslands(g, cur.name());
    if (action != .delete) {
        g.hideIslands();
        g.closeMenu();
    }
}

pub fn save(gpa: std.mem.Allocator, g: *game_mod.Game, cur: *const Current) void {
    // No island played (the title scene, another's game): nothing kept.
    if (cur.len == 0) return;
    var pbuf: [256]u8 = undefined;
    const save_path = cur.path(&pbuf);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    g.encode(&out) catch |err| {
        print(sys.log_warning ++ "motu: cannot save: {s}\n", .{@errorName(err)});
        return;
    };
    // Written whole, then put in place of the old.
    var tbuf: [260]u8 = undefined;
    const tmp = std.fmt.bufPrintSentinel(&tbuf, "{s}.new", .{save_path}, 0) catch return;
    _ = linux.unlink(tmp);
    sys.files.writeNew(tmp, out.items) catch |err| {
        print(sys.log_warning ++ "motu: cannot save {s}: {s}\n", .{ save_path, @errorName(err) });
        return;
    };
    _ = linux.rename(tmp, save_path);
    g.unsaved = false;
    print("motu: saved {s} ({d} KB)\n", .{ cur.name(), out.items.len / 1024 });
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
    /// From handing the window's frames to the GPU to their being drawn:
    /// their GPU time when they are not overlapped (while measuring).
    window_gpu_ns: u64 = 0,
    pixels: f64 = 0,
    /// `app.window.gpu_waited_ns`, and the GPU's time, as they were.
    waited_ns: u64,
    gpu: GpuTime,

    fn report(t: *const Timing, fd: linux.fd_t, elapsed_ns: u64, quality: f32, reach: f32) void {
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
        print("motu: per frame: {s}; {d:.2} Mpixels (drawn at {d:.0}%), seen {d:.0} blocks away; CPU: step {d:.1} ms (recording {d:.1} ms, waiting for the GPU {d:.1} ms), game {d:.1} ms, meshing {d:.1} ms\n", .{
            gpu_text,
            t.pixels / n / 1e6,
            quality * 100,
            renderer_mod.view_distance * reach,
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

/// Errors Motu goes on from (the frame or the meshes are made again
/// later), said in the log: each kind once, and then at most every few
/// seconds, so one that keeps happening does not fill it.
pub const Trouble = struct {
    last_ns: u64 = 0,
    last: ?anyerror = null,
    since_said: u32 = 0,

    const quiet_ns = 5 * std.time.ns_per_s;

    pub fn note(t: *Trouble, what: []const u8, err: anyerror) void {
        const now = sys.nowNs();
        t.since_said += 1;
        if (t.last != null and t.last.? == err and now -| t.last_ns < quiet_ns) return;
        print(sys.log_warning ++ "motu: {s} failed ({s}; {d} times since last said); going on\n", .{ what, @errorName(err), t.since_said });
        t.last = err;
        t.last_ns = now;
        t.since_said = 0;
    }
};

/// Meshes up to `limit` of the chunks changed, nearest `near` first; if
/// it cannot (no memory), they are meshed later.
pub fn mesh(renderer: *Renderer, world: *world_mod.World, near: anytype, limit: usize, trouble: *Trouble) void {
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

    pub fn build(r: *const Root, cx: *kete.BuildContext) kete.Widget {
        return cx.make(view.Motu{
            .game = r.game,
            .icons = r.icons,
            .draw = .{ .ctx = r.scene, .f = Scene.draw },
        });
    }
};

/// The input the game takes before the widgets see it: all the keys, and
/// with the mouse taken, the mouse too (it turns the view, and its buttons
/// act on the middle of it).
pub const Input = struct {
    game: *game_mod.Game,
    win: ?*app.Window = null,
    /// On Linux: kete's window (Dazzle's is `win`).
    linux_win: if (platform == .linux) ?*kete.App.Window else void = if (platform == .linux) null else {},

    pub fn filter(in: *Input, e: kete.window.InputEvent) bool {
        const game = in.game;
        switch (e) {
            .key => |k| {
                // Typing a name: the keys are its, but Esc and Tab.
                if (game.typing() and k.key != .escape and k.key != .tab) return false;
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
                if (!locked) {
                    if (platform == .linux) {
                        if (in.linux_win) |w| w.win.unlockPointer();
                    } else if (in.win) |w| w.unlockPointer();
                }
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
    try host.init(gpa, init.io, init.minimal.environ, .{ .app_id = "motu", .pipelined = true });
    defer host.deinit();

    // The title scene, behind the menu, to choose an island from.
    const world = try world_mod.World.create(gpa);
    var game = game_mod.Game.init(gpa, world);
    defer game.deinit();
    var cur: Current = .{};
    toTitle(gpa, &game, &cur);
    // The options as chosen, or as suit the GPU (the Pi 4's and 5's draws
    // them fast enough; the older one's does not).
    var opts = options.load();
    var kept = options.effective(opts, host.dev.is_v3d);
    game.quality = kept;
    // The quality the window's buffer is drawn at (see below).
    var shown_quality = kept;
    game.look = opts.look;
    game.setPlayerName(opts.name());
    const renderer_started = sys.nowNs();
    const renderer = try Renderer.init(gpa, host.dev);
    print("motu: ready to draw in {d} ms\n", .{(sys.nowNs() - renderer_started) / std.time.ns_per_ms});
    var trouble: Trouble = .{};
    {
        // The chunks around the player now; the rest a few a frame, from
        // the nearest (they are further off, in the fog, at first).
        const started = sys.nowNs();
        mesh(renderer, world, game.player.eye(), 12, &trouble);
        print("motu: meshed the nearest chunks in {d} ms\n", .{(sys.nowNs() - started) / std.time.ns_per_ms});
    }
    var upscaler = try upscale.Upscaler.init(gpa, host.dev);
    defer upscaler.deinit();
    var scene: Scene = .{ .game = &game, .renderer = renderer, .window_renderer = &host.renderer, .upscaler = &upscaler };
    const icons = try gpa.create(view.Icons);
    icons.init();

    // Playing together: said to be here, and joinable, on the network.
    var name_buf: [64]u8 = undefined;
    var session: ?net.Session = net.Session.init(gpa, .{ .name = net.hostname(&name_buf) }) catch |err| blk: {
        print(sys.log_warning ++ "motu: no playing together ({s})\n", .{@errorName(err)});
        break :blk null;
    };
    defer if (session) |*s| s.deinit();

    var fps: f32 = 0;
    const root: Root = .{ .game = &game, .icons = icons, .scene = &scene };
    var input: Input = .{ .game = &game };
    const window = try host.app.openWindow(.{
        .title = "Motu",
        .root = .of(&root),
        .size = view.open_size,
        .min_size = view.min_size,
        .clear_color = 0xff000000,
        .on_close_request = .close,
        .on_input = .of(&input, Input.filter),
    });
    const win = &host.display.window.?;
    input.win = win.win;
    // Fullscreen to start with (the menu's button leaves it).
    win.setFullscreen(true);

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
                if (game.wantsSave()) save(gpa, &game, &cur);
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
            if (game.wantsSave()) save(gpa, &game, &cur);
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
                joined(gpa, &game, &cur);
                game.joinWorld(j.world, j.pos, j.yaw, j.time, j.day) catch |err| {
                    print(sys.log_warning ++ "motu: cannot play in that world ({s})\n", .{@errorName(err)});
                    game.leaveGame();
                };
                mesh(renderer, world, game.player.eye(), 12, &trouble);
            },
            .left => {
                toTitle(gpa, &game, &cur);
                mesh(renderer, world, game.player.eye(), 12, &trouble);
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
            save(gpa, &game, &cur);
            last_save = now;
        }
        // Changed in the menu: kept.
        if (game.quality != kept or !std.meta.eql(game.look, opts.look) or !std.mem.eql(u8, game.playerName(), opts.name())) {
            if (game.quality != kept) opts.quality = game.quality;
            kept = game.quality;
            opts.look = game.look;
            opts.setName(game.playerName());
            options.save(&opts);
        }
        // The world drawn as big as the quality chosen. On the whole
        // screen, the window's buffer is drawn that much smaller (the
        // hotbar, menu and palette with it), and the display stretches it:
        // one buffer, shown as it is. Its size stays the same as the menu
        // and palette come and go: making buffers of another size each
        // time (and an image to draw the world into, to keep the menu
        // sharp), with the GPU's memory nearly all used, hung the GPU. A
        // quality chosen in the menu applies when it closes, not at each
        // step of the slider. In a window (its title bar), the buffer is
        // the window's full size, and the world is stretched into it by
        // the GPU.
        if (!game.menu_open) shown_quality = game.quality;
        const whole_screen = win.win.fullscreen;
        win.win.render_scale = if (whole_screen) shown_quality else 1;
        scene.stretch = !whole_screen;
        scene.quality = shown_quality;
        if (whole_screen) upscaler.release();
        // Asked for in the menu.
        if (game.island_action) |action| {
            game.island_action = null;
            islandAction(gpa, &game, &cur, action);
            mesh(renderer, world, game.player.eye(), 12, &trouble);
        }
        if (game.quit_asked) {
            if (game.wantsSave()) save(gpa, &game, &cur);
            return;
        }
        const stats = host.renderer.takeStats();
        frames += stats.frames;
        timing.frames += stats.frames;
        timing.record_ns += stats.cpu_ns;
        timing.window_gpu_ns += stats.gpu_ns;
        timing.pixels += stats.pixels;
        if (now - fps_since >= std.time.ns_per_s) {
            fps = @as(f32, @floatFromInt(frames)) / (@as(f32, @floatFromInt(now - fps_since)) / std.time.ns_per_s);
            game.noteFps(fps);
            frames = 0;
            fps_since = now;
        }
        if (now - log_since >= 10 * std.time.ns_per_s) {
            const s = renderer.stats;
            print("motu: {d:.1} fps; {d} chunks, {d} draws, {d} triangles\n", .{ fps, s.chunks, s.draws, s.triangles });
            const vm = renderer.videoMemory();
            print("motu: video memory: meshes {d} MB ({d} regions of {d}), tiles {d} MB, the rest {d} MB\n", .{ vm.meshes >> 20, vm.regions, renderer_mod.region_count, vm.tiles >> 20, vm.other >> 20 });
            timing.report(host.dev.fd, now - log_since, game.quality, scene.reach.k * game.seeing());
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
    _ = @import("plants.zig");
    _ = @import("furniture.zig");
    _ = @import("weather.zig");
    _ = @import("math.zig");
    _ = @import("player.zig");
    _ = @import("boat.zig");
    _ = @import("creatures.zig");
    _ = @import("renderer.zig");
    _ = @import("preview.zig");
    _ = @import("game.zig");
    _ = @import("view.zig");
    _ = @import("net.zig");
    _ = @import("options.zig");
    _ = @import("reach.zig");
    _ = @import("upscale.zig");
}
