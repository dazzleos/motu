//! The menu's options (antialiasing, bumps and ripples), as chosen:
//! kept in the user's files (`file`) once one is changed. Until then
//! each is as suits the GPU: on for the Pi 4's and 5's, off for the older
//! one (Pi Zero to Pi 3), which cannot draw them fast enough.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");

pub const file = sys.system.user_dir ++ "/.blocks-options";

pub const Options = struct {
    antialias: ?bool = null,
    bump: ?bool = null,

    pub fn parse(text: []const u8) Options {
        var o: Options = .{};
        var lines = std.mem.tokenizeScalar(u8, text, '\n');
        while (lines.next()) |line| {
            var tok = std.mem.tokenizeAny(u8, line, " \t\r");
            const key = tok.next() orelse continue;
            const value = tok.next() orelse continue;
            const on = if (std.mem.eql(u8, value, "on")) true else if (std.mem.eql(u8, value, "off")) false else continue;
            if (std.mem.eql(u8, key, "antialias")) o.antialias = on else if (std.mem.eql(u8, key, "bump")) o.bump = on;
        }
        return o;
    }

    pub fn format(o: Options, buf: []u8) []const u8 {
        const word = struct {
            fn f(v: ?bool) []const u8 {
                return if (v) |on| (if (on) "on" else "off") else "";
            }
        }.f;
        var w: std.Io.Writer = .fixed(buf);
        if (o.antialias != null) w.print("antialias {s}\n", .{word(o.antialias)}) catch {};
        if (o.bump != null) w.print("bump {s}\n", .{word(o.bump)}) catch {};
        return w.buffered();
    }
};

/// What to start with: as chosen, or what suits the GPU (`fast`: a Pi 4's
/// or 5's).
pub fn effective(o: Options, fast: bool) struct { antialias: bool, bump: bool } {
    return .{ .antialias = o.antialias orelse fast, .bump = o.bump orelse fast };
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
    const chosen: Options = .{ .antialias = false, .bump = true };
    try std.testing.expectEqualStrings("antialias off\nbump on\n", chosen.format(&buf));
    try std.testing.expectEqual(chosen, Options.parse(chosen.format(&buf)));
    // Nothing chosen: on for a fast GPU, off for the older one.
    try std.testing.expect(effective(.{}, true).antialias and effective(.{}, true).bump);
    try std.testing.expect(!effective(.{}, false).antialias and !effective(.{}, false).bump);
    // Chosen: as chosen, whatever the GPU.
    try std.testing.expect(effective(.{ .bump = true }, false).bump);
    try std.testing.expectEqual(Options{}, Options.parse("antialias maybe\n"));
}
