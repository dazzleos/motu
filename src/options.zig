//! The menu's options (the quality, bumps and ripples), as chosen: kept
//! in the user's files (`file`) once one is changed. Until then each is as
//! suits the GPU: everything at its best for the Pi 4's and 5's; the older
//! one's (Pi Zero to Pi 3) cannot draw that fast enough, so the window is
//! drawn smaller (the display stretches it) and without bumps.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const file = sys.system.user_dir ++ "/.blocks-options";

/// The least quality: the window drawn half as big across and down.
pub const min_quality: f32 = 0.5;
/// The older GPU's to start with.
pub const slow_quality: f32 = 0.6;

pub const Options = struct {
    /// How big the window is drawn, of its size across and down (from
    /// `min_quality` to 1).
    quality: ?f32 = null,
    bump: ?bool = null,

    pub fn parse(text: []const u8) Options {
        var o: Options = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const value = tok.next() orelse continue;
            if (std.mem.eql(u8, key, "quality")) {
                const q = std.fmt.parseFloat(f32, value) catch continue;
                if (std.math.isFinite(q)) o.quality = std.math.clamp(q, min_quality, 1);
            } else if (std.mem.eql(u8, key, "bump")) {
                o.bump = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else continue;
            }
        }
        return o;
    }

    pub fn format(o: Options, buf: []u8) []const u8 {
        var w: std.Io.Writer = .fixed(buf);
        if (o.quality) |q| w.print("quality {d:.2}\n", .{q}) catch {};
        if (o.bump) |on| w.print("bump {s}\n", .{if (on) "on" else "off"}) catch {};
        return w.buffered();
    }
};

/// What to start with: as chosen, or what suits the GPU (`fast`: a Pi 4's
/// or 5's).
pub fn effective(o: Options, fast: bool) struct { quality: f32, bump: bool } {
    return .{ .quality = o.quality orelse if (fast) 1 else slow_quality, .bump = o.bump orelse fast };
}

pub fn load() Options {
    var buf: [128]u8 = undefined;
    return .parse(sys.readFile(file, &buf) orelse return .{});
}

pub fn save(o: Options) void {
    var buf: [128]u8 = undefined;
    _ = linux.unlink(file);
    sys.files.writeNew(file, o.format(&buf)) catch |err| {
        sys.print(sys.log_warning ++ "dazzle-blocks: cannot keep the options: {s}\n", .{@errorName(err)});
    };
}

test "the options are kept as chosen, and otherwise suit the GPU" {
    var buf: [128]u8 = undefined;
    const chosen: Options = .{ .quality = 0.75, .bump = true };
    try std.testing.expectEqualStrings("quality 0.75\nbump on\n", chosen.format(&buf));
    try std.testing.expectEqual(chosen, Options.parse(chosen.format(&buf)));
    // Nothing chosen: at its best for a fast GPU, drawn smaller for the
    // older one.
    try std.testing.expectEqual(@as(f32, 1), effective(.{}, true).quality);
    try std.testing.expect(effective(.{}, true).bump);
    try std.testing.expectEqual(slow_quality, effective(.{}, false).quality);
    try std.testing.expect(!effective(.{}, false).bump);
    // Chosen: as chosen, whatever the GPU; kept within what can be.
    try std.testing.expect(effective(.{ .bump = true }, false).bump);
    try std.testing.expectEqual(min_quality, Options.parse("quality 0.1\n").quality.?);
    // Antialiasing was an option once: it is forgotten.
    try std.testing.expectEqual(Options{ .bump = false }, Options.parse("antialias on\nbump off\n"));
}
