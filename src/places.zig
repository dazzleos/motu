//! Where Motu keeps its islands and options: on Dazzle, the user's
//! folder; on Linux, Motu's own folder (in a snap, its folder for all of
//! its versions; otherwise $XDG_DATA_HOME/motu, or ~/.local/share/motu),
//! made if it is not there.

const std = @import("std");
const linux = std.os.linux;
const sys = @import("sys");
const platform = @import("platform").platform;

var buf: [256:0]u8 = undefined;
var linux_dir: [:0]const u8 = ".";

/// The folder (on Linux, as `init` found it).
pub fn dir() [:0]const u8 {
    return if (platform == .dazzle) sys.system.user_dir else linux_dir;
}

/// On Linux: finds (and makes) Motu's folder, from the environment.
pub fn init(environ: std.process.Environ) void {
    if (platform != .linux) return;
    const get = std.process.Environ.getPosix;
    const found = if (get(environ, "SNAP_USER_COMMON")) |d|
        std.fmt.bufPrintSentinel(&buf, "{s}", .{d}, 0)
    else if (get(environ, "XDG_DATA_HOME")) |d|
        std.fmt.bufPrintSentinel(&buf, "{s}/motu", .{d}, 0)
    else if (get(environ, "HOME")) |h|
        std.fmt.bufPrintSentinel(&buf, "{s}/.local/share/motu", .{h}, 0)
    else
        return;
    linux_dir = found catch return;
    makeAll(linux_dir);
}

/// Makes `path`, and the folders it is in.
fn makeAll(path: [:0]const u8) void {
    var part: [256:0]u8 = undefined;
    for (path, 0..) |c, i| {
        if (c != '/' or i == 0) continue;
        @memcpy(part[0..i], path[0..i]);
        part[i] = 0;
        _ = linux.mkdir(part[0..i :0], 0o755);
    }
    _ = linux.mkdir(path, 0o755);
}

/// The options' file.
pub fn optionsFile(out: *[256]u8) [:0]const u8 {
    return std.fmt.bufPrintSentinel(out, "{s}/.motu-options", .{dir()}, 0) catch out[0..0 :0];
}
