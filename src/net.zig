//! Playing together on the local network.
//!
//! Every game says it is there: once a second it broadcasts a beacon (UDP,
//! to everyone on the network, on `port`) with its computer's name and the
//! port to join it on, and it hears the others', which the menu lists.
//!
//! Joining is over TCP. The one joining says hello with its name; the host
//! asks its player (who answers with Y or N, or in the notification), then
//! says no, or sends its world, where to stand and the time of day. From
//! then on each side sends the other its changes to the world (as `Game.edit`
//! queues them) and where its player is, ten times a second; the host passes
//! on what each player sends to the others, and the time of day now and
//! then. A player leaving is just their connection closing.
//!
//! Each message is a frame: its length (4 bytes, little endian, counting
//! what follows), what it is (a byte) and its payload. Nothing blocks:
//! `Session.poll`, once a frame, does what there is to do.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const game_mod = @import("game.zig");
const world_mod = @import("world.zig");
const blocks = @import("blocks.zig");
const math = @import("math.zig");
const player_mod = @import("player.zig");

const Game = game_mod.Game;
const Nearby = game_mod.Nearby;
const V3 = math.V3;

/// Where games are heard and joined (UDP and TCP).
pub const port: u16 = 47153;
/// Players in a game, the host's included: one colour each.
pub const max_players = player_mod.colours;
/// Games remembered as nearby.
pub const max_nearby = 8;

const beacon_magic = "DZBN";
/// 2: palms and new plants (a world sent is the new kind). 3: the day,
/// for the weather.
const protocol_version: u8 = 3;
const beacon_every = std.time.ns_per_s;
/// A game not heard for this long has gone.
const nearby_for = 4 * std.time.ns_per_s;
/// Where a player is, this often.
const state_every = 100 * std.time.ns_per_ms;
/// The time of day (from the host), this often.
const time_every = 2 * std.time.ns_per_s;
/// How long a host may take to answer, and a new connection to say hello.
const answer_within = 60 * std.time.ns_per_s;
const hello_within = 10 * std.time.ns_per_s;
/// The biggest frame taken (a world is a few hundred KB).
const max_frame = 8 * 1024 * 1024;

const Kind = enum(u8) {
    /// Joining's first word: the name of the one joining.
    hello = 1,
    /// Yes: their id (u8), the time of day, where to stand (x, y, z, yaw),
    /// and the world.
    welcome,
    /// No.
    denied,
    /// A change: x, y, z (i16 each) and the block (u8).
    edit,
    /// A player: their id (u8), x, y, z and yaw.
    player,
    /// A player (id) left.
    leave,
    /// The time of day.
    time,
    _,
};

/// What a poll did that the game must act on (main.zig).
pub const Event = union(enum) {
    /// Joined: the host's world (as `World.encode` writes it, until the
    /// next poll), and where to stand.
    joined: struct { world: []const u8, pos: V3, yaw: f32, time: f32, day: u32 },
    /// Left the game joined, or it went away: back to this island.
    left,
    /// The host said no.
    denied,
    /// The game could not be reached.
    failed,
};

pub const Options = struct {
    /// This computer's name, as the others list it.
    name: []const u8,
    /// Where beacons are heard (0: any port, for tests).
    udp_port: u16 = port,
    /// Where to be joined (taken if free, else any).
    tcp_port: u16 = port,
    /// Where beacons go: everyone, on `port`.
    beacon_addr: [4]u8 = .{ 255, 255, 255, 255 },
    beacon_port: u16 = port,
};

/// This computer's name (the kernel's, set from the name chosen when the
/// system was set up).
pub fn hostname(buf: *[64]u8) []const u8 {
    var uts: linux.utsname = undefined;
    if (linux.errno(linux.uname(&uts)) != .SUCCESS) return "Blocks";
    const n = std.mem.indexOfScalar(u8, &uts.nodename, 0) orelse uts.nodename.len;
    if (n == 0) return "Blocks";
    const len = @min(n, buf.len);
    @memcpy(buf[0..len], uts.nodename[0..len]);
    return buf[0..len];
}

/// A connection to another game: a player joining (on the host), or the
/// host (on a player who joined).
const Peer = struct {
    fd: linux.fd_t,
    state: State,
    /// When it got to its state.
    since: u64,
    /// Its player's id (on the host).
    id: u8 = 0,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    rx: std.ArrayList(u8) = .empty,
    tx: std.ArrayList(u8) = .empty,
    dead: bool = false,

    const State = enum {
        /// Connected; not said hello yet (on the host), or not answered
        /// (on the one joining).
        hello,
        /// Waiting for the host's player to answer.
        asking,
        playing,
        /// Told no: closed once that is sent.
        closing,
    };

    fn name(p: *const Peer) []const u8 {
        return p.name_buf[0..p.name_len];
    }

    fn setName(p: *Peer, s: []const u8) void {
        p.name_len = @intCast(@min(s.len, p.name_buf.len));
        @memcpy(p.name_buf[0..p.name_len], s[0..p.name_len]);
    }

    fn deinit(p: *Peer, gpa: std.mem.Allocator) void {
        sys.close(p.fd);
        p.rx.deinit(gpa);
        p.tx.deinit(gpa);
    }

    /// Queues a frame of `parts`.
    fn send(p: *Peer, gpa: std.mem.Allocator, kind: Kind, parts: []const []const u8) void {
        var len: u32 = 1;
        for (parts) |part| len += @intCast(part.len);
        var hdr: [5]u8 = undefined;
        std.mem.writeInt(u32, hdr[0..4], len, .little);
        hdr[4] = @intFromEnum(kind);
        p.tx.appendSlice(gpa, &hdr) catch {
            p.dead = true;
            return;
        };
        for (parts) |part| p.tx.appendSlice(gpa, part) catch {
            p.dead = true;
            return;
        };
    }

    /// Sends what it can of what is queued.
    fn flush(p: *Peer) void {
        while (p.tx.items.len > 0 and !p.dead) {
            const rc = linux.sendto(p.fd, p.tx.items.ptr, p.tx.items.len, linux.MSG.NOSIGNAL, null, 0);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    const n: usize = rc;
                    std.mem.copyForwards(u8, p.tx.items[0 .. p.tx.items.len - n], p.tx.items[n..]);
                    p.tx.shrinkRetainingCapacity(p.tx.items.len - n);
                },
                // Full, or (joining) still connecting.
                .AGAIN, .NOTCONN => return,
                .INTR => {},
                else => p.dead = true,
            }
        }
    }

    /// Reads what has come.
    fn fill(p: *Peer, gpa: std.mem.Allocator) void {
        var buf: [16384]u8 = undefined;
        while (!p.dead) {
            const rc = linux.read(p.fd, &buf, buf.len);
            switch (linux.errno(rc)) {
                .SUCCESS => {
                    if (rc == 0) {
                        p.dead = true;
                        return;
                    }
                    p.rx.appendSlice(gpa, buf[0..rc]) catch {
                        p.dead = true;
                        return;
                    };
                },
                .AGAIN, .NOTCONN => return,
                .INTR => {},
                else => p.dead = true,
            }
        }
        // A connection that failed (refused, say) may only say so here.
        var err: i32 = 0;
        var len: linux.socklen_t = @sizeOf(i32);
        if (linux.errno(linux.getsockopt(p.fd, linux.SOL.SOCKET, linux.SO.ERROR, @ptrCast(&err), &len)) == .SUCCESS and err != 0) p.dead = true;
    }

    /// The first whole frame read, if there is one; `consume` it after.
    fn next(p: *Peer, at: usize) ?Frame {
        const rx = p.rx.items[at..];
        if (rx.len < 5) return null;
        const len = std.mem.readInt(u32, rx[0..4], .little);
        if (len == 0 or len > max_frame) {
            p.dead = true;
            return null;
        }
        if (rx.len < 4 + len) return null;
        return .{ .kind = @enumFromInt(rx[4]), .payload = rx[5 .. 4 + len], .size = 4 + len };
    }

    fn consume(p: *Peer, n: usize) void {
        std.mem.copyForwards(u8, p.rx.items[0 .. p.rx.items.len - n], p.rx.items[n..]);
        p.rx.shrinkRetainingCapacity(p.rx.items.len - n);
    }
};

const Frame = struct { kind: Kind, payload: []const u8, size: usize };

/// Another player, as last heard: where they are shown (eased towards
/// where they were last said to be).
const Remote = struct {
    active: bool = false,
    shown: V3 = @splat(0),
    shown_yaw: f32 = 0,
    target: V3 = @splat(0),
    target_yaw: f32 = 0,
};

pub const Session = struct {
    gpa: std.mem.Allocator,
    opts: Options,
    name_buf: [64]u8 = undefined,
    name_len: u8 = 0,
    /// This game's, in its beacons (to know its own when they come back).
    id: u32,
    udp: linux.fd_t,
    listener: linux.fd_t,
    /// The port it is joined on.
    tcp_port: u16,
    nearby: [max_nearby]Nearby = undefined,
    nearby_seen: [max_nearby]u64 = undefined,
    nearby_len: usize = 0,
    /// The players who joined (on the host): slot k is id k + 1.
    peers: [max_players - 1]?Peer = @splat(null),
    /// The host (when joining or joined).
    host: ?Peer = null,
    /// This player's id: 0 on the host.
    my_id: u8 = 0,
    remotes: [max_players]Remote = @splat(.{}),
    others: [max_players]player_mod.Other = undefined,
    /// The request shown (a slot in `peers`).
    request_slot: ?usize = null,
    /// The world joined, until the next poll.
    world: std.ArrayList(u8) = .empty,
    last_poll: u64 = 0,
    last_beacon: u64 = 0,
    last_state: u64 = 0,
    last_time: u64 = 0,

    pub fn init(gpa: std.mem.Allocator, opts: Options) !Session {
        const udp: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.DGRAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)));
        errdefer sys.close(udp);
        setOpt(udp, linux.SOL.SOCKET, linux.SO.REUSEADDR);
        setOpt(udp, linux.SOL.SOCKET, linux.SO.BROADCAST);
        var any = inAddr(.{ 0, 0, 0, 0 }, opts.udp_port);
        _ = try sys.check(linux.bind(udp, @ptrCast(&any), @sizeOf(linux.sockaddr.in)));

        const listener: linux.fd_t = @intCast(try sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)));
        errdefer sys.close(listener);
        setOpt(listener, linux.SOL.SOCKET, linux.SO.REUSEADDR);
        var at = inAddr(.{ 0, 0, 0, 0 }, opts.tcp_port);
        // Another game on this computer has the port: any other.
        if (linux.errno(linux.bind(listener, @ptrCast(&at), @sizeOf(linux.sockaddr.in))) != .SUCCESS) {
            at = inAddr(.{ 0, 0, 0, 0 }, 0);
            _ = try sys.check(linux.bind(listener, @ptrCast(&at), @sizeOf(linux.sockaddr.in)));
        }
        _ = try sys.check(linux.listen(listener, 4));

        var s: Session = .{
            .gpa = gpa,
            .opts = opts,
            .id = @truncate(sys.nowNs() *% 2654435761 ^ @as(u64, @intCast(linux.getpid()))),
            .udp = udp,
            .listener = listener,
            .tcp_port = localPort(listener),
        };
        s.name_len = @intCast(@min(opts.name.len, s.name_buf.len));
        @memcpy(s.name_buf[0..s.name_len], opts.name[0..s.name_len]);
        return s;
    }

    pub fn deinit(s: *Session) void {
        for (&s.peers) |*slot| if (slot.*) |*p| p.deinit(s.gpa);
        if (s.host) |*h| h.deinit(s.gpa);
        sys.close(s.udp);
        sys.close(s.listener);
        s.world.deinit(s.gpa);
    }

    fn name(s: *const Session) []const u8 {
        return s.name_buf[0..s.name_len];
    }

    /// The port beacons are heard on.
    pub fn udpPort(s: *const Session) u16 {
        return localPort(s.udp);
    }

    /// Does what there is to do (at `now`, in ns): hears and says it is
    /// there, answers players joining, passes on changes and players, and
    /// does what the game asked (`g.net`), which it tells how things are.
    pub fn poll(s: *Session, g: *Game, now: u64) ?Event {
        const dt: f32 = if (s.last_poll == 0) 0 else @as(f32, @floatFromInt(now -| s.last_poll)) / std.time.ns_per_s;
        s.last_poll = now;
        s.world.clearRetainingCapacity();
        s.discover(g, now);
        var event: ?Event = null;
        if (s.host != null) {
            event = s.pollJoined(g, now);
        } else {
            s.pollHosting(g, now);
            if (g.net.join) |n| s.startJoin(g, n, now);
        }
        g.net.join = null;
        g.net.leave = false;
        g.net.outbox.clearRetainingCapacity();
        s.showOthers(g, dt);
        return event;
    }

    // --- Finding each other -------------------------------------------------------------

    fn discover(s: *Session, g: *Game, now: u64) void {
        // Joined (or joining), this game cannot be joined: it does not say
        // it is there.
        if (s.host == null and now -| s.last_beacon >= beacon_every) {
            s.last_beacon = now;
            var buf: [128]u8 = undefined;
            const beacon = encodeBeacon(&buf, s.id, s.tcp_port, s.name());
            var to = inAddr(s.opts.beacon_addr, s.opts.beacon_port);
            // No network: no one to hear it.
            _ = linux.sendto(s.udp, beacon.ptr, beacon.len, 0, @ptrCast(&to), @sizeOf(linux.sockaddr.in));
        }
        while (true) {
            var buf: [256]u8 = undefined;
            var from: linux.sockaddr.in = undefined;
            var from_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
            const rc = linux.recvfrom(s.udp, &buf, buf.len, 0, @ptrCast(&from), &from_len);
            if (linux.errno(rc) != .SUCCESS) break;
            const b = parseBeacon(buf[0..rc]) orelse continue;
            if (b.id == s.id) continue;
            const addr: [4]u8 = @bitCast(from.addr);
            s.heard(addr, b.port, b.name, now);
        }
        // Not heard lately: gone.
        var k: usize = 0;
        while (k < s.nearby_len) {
            if (now -| s.nearby_seen[k] > nearby_for) {
                s.nearby_len -= 1;
                s.nearby[k] = s.nearby[s.nearby_len];
                s.nearby_seen[k] = s.nearby_seen[s.nearby_len];
            } else k += 1;
        }
        g.net.nearby = s.nearby[0..s.nearby_len];
    }

    fn heard(s: *Session, addr: [4]u8, tcp_port: u16, game_name: []const u8, now: u64) void {
        for (s.nearby[0..s.nearby_len], 0..) |*n, k| if (std.mem.eql(u8, &n.addr, &addr) and n.port == tcp_port) {
            n.setName(game_name);
            s.nearby_seen[k] = now;
            return;
        };
        if (s.nearby_len == max_nearby) return;
        var n: Nearby = .{ .addr = addr, .port = tcp_port };
        n.setName(game_name);
        s.nearby[s.nearby_len] = n;
        s.nearby_seen[s.nearby_len] = now;
        s.nearby_len += 1;
    }

    // --- Hosting -----------------------------------------------------------------------

    fn pollHosting(s: *Session, g: *Game, now: u64) void {
        // Players joining.
        while (true) {
            const rc = linux.accept4(s.listener, null, null, linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC);
            if (linux.errno(rc) != .SUCCESS) break;
            const fd: linux.fd_t = @intCast(rc);
            setOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY);
            const slot = for (s.peers, 0..) |p, k| {
                if (p == null) break k;
            } else {
                // Full.
                sys.close(fd);
                continue;
            };
            s.peers[slot] = .{ .fd = fd, .state = .hello, .since = now, .id = @intCast(slot + 1) };
        }

        for (&s.peers, 0..) |*slot, k| if (slot.*) |*p| {
            p.fill(s.gpa);
            var at: usize = 0;
            while (p.next(at)) |f| : (at += f.size) s.fromPlayer(g, k, f);
            if (at > 0) p.consume(at);
            if (p.state == .hello and now -| p.since > hello_within) p.dead = true;
        };

        // The request shown, and its answer.
        if (s.request_slot) |k| {
            if (s.peers[k] == null or s.peers[k].?.dead or s.peers[k].?.state != .asking) {
                s.request_slot = null;
                g.net.request = null;
                g.net.answer = null;
            } else if (g.net.answer) |yes| {
                s.answer(g, k, yes);
                s.request_slot = null;
                g.net.request = null;
                g.net.answer = null;
            }
        }
        if (s.request_slot == null) {
            for (&s.peers, 0..) |*slot, k| if (slot.*) |*p| if (p.state == .asking and !p.dead) {
                s.request_slot = k;
                g.net.request = p.name();
                break;
            };
        }

        // Changes made here, where this player is, the time of day.
        for (g.net.outbox.items) |e| s.toPlayers(.edit, &.{&encodeEdit(e)}, null);
        if (now -| s.last_state >= state_every) {
            s.last_state = now;
            s.toPlayers(.player, &.{&encodePlayer(0, g.player.pos, g.player.yaw)}, null);
        }
        if (now -| s.last_time >= time_every) {
            s.last_time = now;
            var tb: [8]u8 = undefined;
            std.mem.writeInt(u32, tb[0..4], @bitCast(g.time_of_day), .little);
            std.mem.writeInt(u32, tb[4..8], g.day, .little);
            s.toPlayers(.time, &.{&tb}, null);
        }

        // Sent; gone.
        for (&s.peers) |*slot| if (slot.*) |*p| {
            p.flush();
            if (p.state == .closing and p.tx.items.len == 0) p.dead = true;
            if (p.dead) {
                const was_playing = p.state == .playing;
                const id = p.id;
                p.deinit(s.gpa);
                slot.* = null;
                if (was_playing) {
                    s.remotes[id].active = false;
                    s.toPlayers(.leave, &.{&.{id}}, null);
                }
            }
        };
        var playing: u8 = 0;
        for (s.peers) |p| if (p != null and p.?.state == .playing) {
            playing += 1;
        };
        g.net.status = if (playing > 0) .{ .hosting = playing } else .alone;
    }

    /// A frame from the player in slot `k`.
    fn fromPlayer(s: *Session, g: *Game, k: usize, f: Frame) void {
        const p = &s.peers[k].?;
        switch (f.kind) {
            .hello => if (p.state == .hello) {
                p.setName(f.payload);
                p.state = .asking;
                p.since = s.last_poll;
            },
            .edit => if (p.state == .playing) {
                const e = decodeEdit(f.payload) orelse return;
                g.editFromNetwork(e);
                s.toPlayers(.edit, &.{f.payload}, k);
            },
            .player => if (p.state == .playing) {
                const st = decodePlayer(f.payload) orelse return;
                // As the one it came from, whatever it says.
                s.heardPlayer(p.id, st.pos, st.yaw);
                s.toPlayers(.player, &.{&encodePlayer(p.id, st.pos, st.yaw)}, k);
            },
            else => {},
        }
    }

    fn answer(s: *Session, g: *Game, k: usize, yes: bool) void {
        const p = &s.peers[k].?;
        if (!yes) {
            p.send(s.gpa, .denied, &.{});
            p.state = .closing;
            return;
        }
        var world: std.ArrayList(u8) = .empty;
        defer world.deinit(s.gpa);
        g.world.encode(&world, s.gpa) catch {
            p.dead = true;
            return;
        };
        // Beside the host.
        const pos = g.player.pos + V3{ 1, 0, 0 };
        var hdr: [25]u8 = undefined;
        hdr[0] = p.id;
        for ([_]f32{ g.time_of_day, pos[0], pos[1], pos[2], g.player.yaw }, 0..) |v, i| std.mem.writeInt(u32, hdr[1 + i * 4 ..][0..4], @bitCast(v), .little);
        std.mem.writeInt(u32, hdr[21..25], g.day, .little);
        p.send(s.gpa, .welcome, &.{ &hdr, world.items });
        p.state = .playing;
        g.say("Someone joined");
        // Where the others are.
        for (s.peers, 0..) |other, j| if (other != null and j != k and other.?.state == .playing) {
            const r = s.remotes[other.?.id];
            p.send(s.gpa, .player, &.{&encodePlayer(other.?.id, r.target, r.target_yaw)});
        };
    }

    /// Sends to every player playing but the one in slot `except`.
    fn toPlayers(s: *Session, kind: Kind, parts: []const []const u8, except: ?usize) void {
        for (&s.peers, 0..) |*slot, k| if (slot.*) |*p| if (p.state == .playing and k != except) p.send(s.gpa, kind, parts);
    }

    // --- Joining ----------------------------------------------------------------------

    fn startJoin(s: *Session, g: *Game, n: Nearby, now: u64) void {
        const fd: linux.fd_t = @intCast(sys.check(linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.NONBLOCK | linux.SOCK.CLOEXEC, 0)) catch {
            g.say("Cannot join: no network");
            return;
        });
        setOpt(fd, linux.IPPROTO.TCP, linux.TCP.NODELAY);
        var to = inAddr(n.addr, n.port);
        switch (linux.errno(linux.connect(fd, @ptrCast(&to), @sizeOf(linux.sockaddr.in)))) {
            .SUCCESS, .INPROGRESS => {},
            else => {
                sys.close(fd);
                g.say("Cannot reach that game");
                return;
            },
        }
        // Those who joined this game cannot follow: they are let go.
        for (&s.peers) |*slot| if (slot.*) |*p| {
            p.deinit(s.gpa);
            slot.* = null;
        };
        s.request_slot = null;
        g.net.request = null;
        g.net.answer = null;
        for (&s.remotes) |*r| r.active = false;
        var h: Peer = .{ .fd = fd, .state = .hello, .since = now };
        h.setName(n.name());
        h.send(s.gpa, .hello, &.{s.name()});
        s.host = h;
        g.net.status = .{ .asking = s.host.?.name() };
    }

    fn pollJoined(s: *Session, g: *Game, now: u64) ?Event {
        const h = &s.host.?;
        if (g.net.leave) return s.endJoin(g, if (h.state == .playing) .left else null);
        h.flush();
        h.fill(s.gpa);
        var event: ?Event = null;
        var at: usize = 0;
        while (h.next(at)) |f| : (at += f.size) {
            switch (f.kind) {
                .welcome => if (h.state == .hello and f.payload.len >= 25) {
                    const p = f.payload;
                    s.my_id = p[0];
                    var v: [5]f32 = undefined;
                    for (&v, 0..) |*x, i| x.* = @bitCast(std.mem.readInt(u32, p[1 + i * 4 ..][0..4], .little));
                    const day = std.mem.readInt(u32, p[21..25], .little);
                    s.world.appendSlice(s.gpa, p[25..]) catch {
                        h.dead = true;
                        break;
                    };
                    h.state = .playing;
                    g.net.status = .{ .joined = h.name() };
                    event = .{ .joined = .{ .world = s.world.items, .pos = .{ v[1], v[2], v[3] }, .yaw = v[4], .time = v[0], .day = day } };
                },
                .denied => if (h.state == .hello) {
                    h.consume(at + f.size);
                    return s.endJoin(g, .denied);
                },
                .edit => if (h.state == .playing) {
                    if (decodeEdit(f.payload)) |e| g.editFromNetwork(e);
                },
                .player => if (h.state == .playing) {
                    if (decodePlayer(f.payload)) |st| if (st.id != s.my_id) s.heardPlayer(st.id, st.pos, st.yaw);
                },
                .leave => if (f.payload.len == 1 and f.payload[0] < max_players) {
                    s.remotes[f.payload[0]].active = false;
                },
                .time => if (h.state == .playing and f.payload.len == 8) {
                    g.time_of_day = @mod(@as(f32, @bitCast(std.mem.readInt(u32, f.payload[0..4], .little))), 1);
                    g.day = std.mem.readInt(u32, f.payload[4..8], .little);
                },
                else => {},
            }
        }
        if (at > 0) h.consume(at);
        if (h.state == .hello and now -| h.since > answer_within) h.dead = true;
        if (h.dead) return s.endJoin(g, if (h.state == .playing) .left else .failed);
        if (h.state == .playing) {
            for (g.net.outbox.items) |e| h.send(s.gpa, .edit, &.{&encodeEdit(e)});
            if (now -| s.last_state >= state_every) {
                s.last_state = now;
                h.send(s.gpa, .player, &.{&encodePlayer(s.my_id, g.player.pos, g.player.yaw)});
            }
            h.flush();
        }
        return event;
    }

    fn endJoin(s: *Session, g: *Game, event: ?Event) ?Event {
        s.host.?.deinit(s.gpa);
        s.host = null;
        s.my_id = 0;
        for (&s.remotes) |*r| r.active = false;
        g.net.status = .alone;
        return event;
    }

    // --- The others ---------------------------------------------------------------------

    fn heardPlayer(s: *Session, id: u8, pos: V3, yaw: f32) void {
        if (id >= max_players) return;
        const r = &s.remotes[id];
        if (!r.active) {
            r.* = .{ .active = true, .shown = pos, .shown_yaw = yaw };
        }
        r.target = pos;
        r.target_yaw = yaw;
    }

    /// Eases each player shown towards where they were last said to be (ten
    /// times a second), and tells the game.
    fn showOthers(s: *Session, g: *Game, dt: f32) void {
        const t = @min(dt * 12, 1);
        var n: usize = 0;
        for (&s.remotes, 0..) |*r, id| if (r.active) {
            r.shown += (r.target - r.shown) * math.splat(t);
            // The short way round.
            const turn = std.math.atan2(@sin(r.target_yaw - r.shown_yaw), @cos(r.target_yaw - r.shown_yaw));
            r.shown_yaw += turn * t;
            s.others[n] = .{ .pos = r.shown, .yaw = r.shown_yaw, .colour = @intCast(id % max_players) };
            n += 1;
        };
        g.net.others = s.others[0..n];
    }
};

// --- Messages ---------------------------------------------------------------------------

fn encodeBeacon(buf: *[128]u8, id: u32, tcp_port: u16, game_name: []const u8) []const u8 {
    const len = @min(game_name.len, 64);
    @memcpy(buf[0..4], beacon_magic);
    buf[4] = protocol_version;
    std.mem.writeInt(u32, buf[5..9], id, .little);
    std.mem.writeInt(u16, buf[9..11], tcp_port, .little);
    @memcpy(buf[11..][0..len], game_name[0..len]);
    return buf[0 .. 11 + len];
}

const Beacon = struct { id: u32, port: u16, name: []const u8 };

fn parseBeacon(b: []const u8) ?Beacon {
    if (b.len < 12 or b.len > 11 + 64 or !std.mem.eql(u8, b[0..4], beacon_magic) or b[4] != protocol_version) return null;
    const n = b[11..];
    for (n) |c| if (c < 0x20) return null;
    return .{ .id = std.mem.readInt(u32, b[5..9], .little), .port = std.mem.readInt(u16, b[9..11], .little), .name = n };
}

fn encodeEdit(e: game_mod.Edit) [7]u8 {
    var b: [7]u8 = undefined;
    for (0..3) |i| std.mem.writeInt(i16, b[i * 2 ..][0..2], @intCast(e.cell[i]), .little);
    b[6] = @intFromEnum(e.block);
    return b;
}

fn decodeEdit(b: []const u8) ?game_mod.Edit {
    if (b.len != 7) return null;
    var cell: world_mod.Pos = undefined;
    for (0..3) |i| cell[i] = std.mem.readInt(i16, b[i * 2 ..][0..2], .little);
    const block: blocks.Block = @enumFromInt(b[6]);
    if (!block.isValid()) return null;
    if (cell[0] < 0 or cell[0] >= world_mod.size_x or cell[1] < 0 or cell[1] >= world_mod.size_y or cell[2] < 0 or cell[2] >= world_mod.size_z) return null;
    return .{ .cell = cell, .block = block };
}

fn encodePlayer(id: u8, pos: V3, yaw: f32) [17]u8 {
    var b: [17]u8 = undefined;
    b[0] = id;
    for ([_]f32{ pos[0], pos[1], pos[2], yaw }, 0..) |v, i| std.mem.writeInt(u32, b[1 + i * 4 ..][0..4], @bitCast(v), .little);
    return b;
}

fn decodePlayer(b: []const u8) ?struct { id: u8, pos: V3, yaw: f32 } {
    if (b.len != 17) return null;
    var v: [4]f32 = undefined;
    for (&v, 0..) |*x, i| {
        x.* = @bitCast(std.mem.readInt(u32, b[1 + i * 4 ..][0..4], .little));
        if (!std.math.isFinite(x.*)) return null;
    }
    return .{ .id = b[0], .pos = .{ v[0], v[1], v[2] }, .yaw = v[3] };
}

// --- Sockets ---------------------------------------------------------------------------

fn inAddr(addr: [4]u8, p: u16) linux.sockaddr.in {
    return .{ .port = std.mem.nativeToBig(u16, p), .addr = @bitCast(addr) };
}

fn localPort(fd: linux.fd_t) u16 {
    var a: linux.sockaddr.in = undefined;
    var len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    if (linux.errno(linux.getsockname(fd, @ptrCast(&a), &len)) != .SUCCESS) return 0;
    return std.mem.bigToNative(u16, a.port);
}

fn setOpt(fd: linux.fd_t, level: i32, opt: u32) void {
    const one: i32 = 1;
    _ = linux.setsockopt(fd, level, opt, std.mem.asBytes(&one), @sizeOf(i32));
}

// --- Tests -----------------------------------------------------------------------------

const testing = std.testing;

test "beacons, changes and players, there and back" {
    var buf: [128]u8 = undefined;
    const b = parseBeacon(encodeBeacon(&buf, 0xdeadbeef, 47153, "awesome-elephant")).?;
    try testing.expectEqual(@as(u32, 0xdeadbeef), b.id);
    try testing.expectEqual(@as(u16, 47153), b.port);
    try testing.expectEqualStrings("awesome-elephant", b.name);
    try testing.expect(parseBeacon("DZBN") == null);
    try testing.expect(parseBeacon("XXXX\x01\x00\x00\x00\x00\x00\x00a") == null);

    const e: game_mod.Edit = .{ .cell = .{ 10, 31, 127 }, .block = .volcanic_wall };
    try testing.expectEqual(e, decodeEdit(&encodeEdit(e)).?);
    // Outside the world, or not a block: not taken.
    try testing.expect(decodeEdit(&encodeEdit(.{ .cell = .{ 128, 0, 0 }, .block = .volcanic_rock })) == null);
    var bad = encodeEdit(e);
    bad[6] = 255;
    try testing.expect(decodeEdit(&bad) == null);

    const p = decodePlayer(&encodePlayer(3, .{ 1.5, 31, -2 }, 0.25)).?;
    try testing.expectEqual(@as(u8, 3), p.id);
    try testing.expectEqual(V3{ 1.5, 31, -2 }, p.pos);
    try testing.expectEqual(@as(f32, 0.25), p.yaw);
}

fn flatWorld() !*world_mod.World {
    const w = try world_mod.World.create(testing.allocator);
    errdefer w.destroy();
    for (0..world_mod.size_z) |z| for (0..world_mod.size_x) |x| {
        w.blocks[world_mod.World.index(@intCast(x), 30, @intCast(z))] = .grass;
    };
    try w.computeLight();
    w.spawn = .{ 64.5, 31, 64.5 };
    return w;
}

/// Two games on this computer, over the loopback: each hears the other's
/// beacons on the other's port.
const Pair = struct {
    a: Session,
    b: Session,
    ga: Game,
    gb: Game,

    fn init(pair: *Pair) !void {
        const lo: [4]u8 = .{ 127, 0, 0, 1 };
        pair.a = try Session.init(testing.allocator, .{ .name = "host-pi", .udp_port = 0, .tcp_port = 0, .beacon_addr = lo });
        errdefer pair.a.deinit();
        pair.b = try Session.init(testing.allocator, .{ .name = "guest-pi", .udp_port = 0, .tcp_port = 0, .beacon_addr = lo });
        pair.a.opts.beacon_port = pair.b.udpPort();
        pair.b.opts.beacon_port = pair.a.udpPort();
        pair.ga = Game.init(testing.allocator, try flatWorld());
        pair.gb = Game.init(testing.allocator, try flatWorld());
        pair.ga.menu_open = false;
    }

    fn deinit(pair: *Pair) void {
        pair.a.deinit();
        pair.b.deinit();
        pair.ga.world.destroy();
        pair.gb.world.destroy();
        pair.ga.deinit();
        pair.gb.deinit();
    }

    /// Polls both until `done` (or a few seconds go by); returns the last
    /// event b had.
    fn until(pair: *Pair, comptime done: fn (*Pair) bool) !?Event {
        var event: ?Event = null;
        for (0..3000) |_| {
            const now = sys.nowNs();
            _ = pair.a.poll(&pair.ga, now);
            if (pair.b.poll(&pair.gb, now)) |e| {
                event = e;
                if (e == .joined) try pair.gb.joinWorld(e.joined.world, e.joined.pos, e.joined.yaw, e.joined.time, e.joined.day);
            }
            if (done(pair)) return event;
            var ts: linux.timespec = .{ .sec = 0, .nsec = std.time.ns_per_ms };
            _ = linux.nanosleep(&ts, null);
        }
        return error.Timeout;
    }
};

test "a game nearby is heard, asked to join, lets the player in, and they play together" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    // Something built on the host before: the guest gets it with the world.
    _ = pair.ga.edit(.{ 20, 31, 20 }, .thatch);

    // Heard: the host is nearby (and the guest is to it).
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.net.nearby.len == 1 and p.ga.net.nearby.len == 1;
        }
    }.f);
    try testing.expectEqualStrings("host-pi", pair.gb.net.nearby[0].name());
    try testing.expectEqualStrings("guest-pi", pair.ga.net.nearby[0].name());

    // Asked: the host's player is asked.
    pair.gb.joinNearby(pair.gb.net.nearby[0]);
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.ga.net.request != null;
        }
    }.f);
    try testing.expectEqualStrings("guest-pi", pair.ga.net.request.?);
    try testing.expectEqualStrings("host-pi", pair.gb.net.status.asking);

    // Y: let in, with the host's world.
    pair.ga.key(.y, true);
    pair.ga.key(.y, false);
    const joined = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.net.status == .joined and p.gb.net.others.len == 1 and p.ga.net.others.len == 1;
        }
    }.f);
    try testing.expect(joined != null and joined.? == .joined);
    try testing.expectEqual(blocks.Block.thatch, pair.gb.world.get(20, 31, 20));
    try testing.expectEqual(@as(u8, 1), pair.ga.net.status.hosting);
    try testing.expect(pair.ga.net.request == null);
    // The guest stands beside the host.
    try testing.expect(math.length(pair.gb.player.pos - pair.ga.player.pos) < 2);

    // Changes on either side reach the other.
    _ = pair.ga.edit(.{ 30, 31, 30 }, .volcanic_wall);
    _ = pair.gb.edit(.{ 40, 31, 40 }, .lamp);
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.world.get(30, 31, 30) == .volcanic_wall and p.ga.world.get(40, 31, 40) == .lamp;
        }
    }.f);

    // Each sees the other where they are.
    pair.ga.player.pos = .{ 50, 31, 50 };
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.net.others.len == 1 and math.length(p.gb.net.others[0].pos - V3{ 50, 31, 50 }) < 0.1;
        }
    }.f);

    // The guest leaves: back alone, both.
    pair.gb.leaveGame();
    const left = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.ga.net.status == .alone and p.ga.net.others.len == 0 and p.gb.net.status == .alone;
        }
    }.f);
    try testing.expect(left != null and left.? == .left);
}

test "a host can say no" {
    var pair: Pair = undefined;
    try pair.init();
    defer pair.deinit();
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.net.nearby.len == 1;
        }
    }.f);
    pair.gb.joinNearby(pair.gb.net.nearby[0]);
    _ = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.ga.net.request != null;
        }
    }.f);
    // N.
    pair.ga.key(.n, true);
    const denied = try pair.until(struct {
        fn f(p: *Pair) bool {
            return p.gb.net.status == .alone;
        }
    }.f);
    try testing.expect(denied != null and denied.? == .denied);
    try testing.expect(pair.ga.net.request == null);
    // The guest's world is its own still.
    try testing.expectEqual(blocks.Block.grass, pair.gb.world.get(20, 30, 20));
}
