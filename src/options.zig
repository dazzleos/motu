//! The menu's options (the quality, and the player's name and look), as
//! chosen: kept in the user's files
//! (`file`) once changed. Until then, as suits the GPU: at its best for
//! the Pi 4's and 5's; the older one's (Pi Zero to Pi 3) cannot draw that
//! fast enough, so the window is drawn smaller (the display stretches it).

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const avatar = @import("avatar.zig");

pub const file = sys.system.user_dir ++ "/.motu-options";

/// The least quality: the window drawn half as big across and down.
pub const min_quality: f32 = 0.5;
/// The older GPU's to start with.
pub const slow_quality: f32 = 0.6;

pub const Options = struct {
    /// How big the window is drawn, of its size across and down (from
    /// `min_quality` to 1).
    quality: ?f32 = null,
    /// The player's name ("" for the computer's), and how they look.
    name_buf: [max_name]u8 = undefined,
    name_len: u8 = 0,
    look: avatar.Look = .{},

    pub const max_name = 24;

    pub fn name(o: *const Options) []const u8 {
        return o.name_buf[0..o.name_len];
    }

    pub fn setName(o: *Options, n: []const u8) void {
        o.name_len = @intCast(@min(n.len, max_name));
        @memcpy(o.name_buf[0..o.name_len], n[0..o.name_len]);
    }

    pub fn eql(a: *const Options, b: *const Options) bool {
        return std.meta.eql(a.quality, b.quality) and std.mem.eql(u8, a.name(), b.name()) and std.meta.eql(a.look, b.look);
    }

    pub fn parse(text: []const u8) Options {
        var o: Options = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const rest = std.mem.trim(u8, line[@min(line.len, tok.index)..], " \t\r");
            if (rest.len == 0) continue;
            if (std.mem.eql(u8, key, "quality")) {
                const q = std.fmt.parseFloat(f32, rest) catch continue;
                if (std.math.isFinite(q)) o.quality = std.math.clamp(q, min_quality, 1);
            } else if (std.mem.eql(u8, key, "name")) {
                o.setName(rest);
            } else if (std.mem.eql(u8, key, "look")) {
                o.look = .parse(rest);
            }
        }
        return o;
    }

    pub fn format(o: *const Options, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (o.quality) |q| w.print("quality {d:.2}\n", .{q}) catch {};
        if (o.name_len > 0) w.print("name {s}\n", .{o.name()}) catch {};
        if (!std.meta.eql(o.look, avatar.Look{})) {
            w.writeAll("look ") catch {};
            o.look.format(&w) catch {};
            w.writeAll("\n") catch {};
        }
        return w.buffered();
    }
};

/// The quality to start with: as chosen, or what suits the GPU (`fast`: a
/// Pi 4's or 5's).
pub fn effective(o: Options, fast: bool) f32 {
    return o.quality orelse if (fast) 1 else slow_quality;
}

pub fn load() Options {
    var buf: [256]u8 = undefined;
    return .parse(sys.readFile(file, &buf) orelse return .{});
}

pub fn save(o: *const Options) void {
    var buf: [256]u8 = undefined;
    _ = linux.unlink(file);
    sys.files.writeNew(file, o.format(&buf)) catch |err| {
        sys.print(sys.log_warning ++ "motu: cannot keep the options: {s}\n", .{@errorName(err)});
    };
}

test "the options are kept as chosen, and otherwise suit the GPU" {
    var buf: [256]u8 = undefined;
    const chosen: Options = .{ .quality = 0.75 };
    try std.testing.expectEqualStrings("quality 0.75\n", chosen.format(&buf));
    try std.testing.expect(chosen.eql(&Options.parse(chosen.format(&buf))));
    // Nothing chosen: at its best for a fast GPU, drawn smaller for the
    // older one.
    try std.testing.expectEqual(@as(f32, 1), effective(.{}, true));
    try std.testing.expectEqual(slow_quality, effective(.{}, false));
    // Chosen: as chosen, whatever the GPU; kept within what can be.
    try std.testing.expectEqual(@as(f32, 0.75), effective(chosen, true));
    try std.testing.expectEqual(min_quality, Options.parse("quality 0.1\n").quality.?);
    // Antialiasing and bumps were options once: they are forgotten.
    try std.testing.expect(Options.parse("antialias on\nbump off\n").eql(&.{}));
}

test "the player's name and look are kept" {
    var buf: [256]u8 = undefined;
    var o: Options = .{ .look = .{ .skin = .brown, .headwear = .flower } };
    o.setName("Sina Tui");
    const text = o.format(&buf);
    try std.testing.expectEqualStrings("name Sina Tui\nlook brown flower t_shirt red shorts blue\n", text);
    const back = Options.parse(text);
    try std.testing.expect(back.eql(&o));
    try std.testing.expect(back.quality == null);
}
