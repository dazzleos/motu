//! How far the world is seen (`Reach`): as far as the GPU allows, from
//! how the frames go. While the GPU holds them up (they are waited for,
//! and come slower than the display shows them), the fog comes nearer,
//! down to half the view distance; while it is idle when they are asked
//! for, it goes back out. (How big the window is drawn is the player's
//! choice: the quality, in the menu.)

const std = @import("std");

pub const Reach = struct {
    /// How far one sees, of the whole view distance.
    k: f32 = 1,
    /// The frames since it last changed, and how they went: how long
    /// apart they came, and how long each waited for the GPU.
    frames: u32 = 0,
    interval_ns: u64 = 0,
    waited_ns: u64 = 0,
    last_ns: ?u64 = null,

    pub const min: f32 = 0.5;
    /// The frames it waits for before changing.
    const window = 12;
    /// The display's rate: 60 frames a second.
    const frame_ns = std.time.ns_per_s / 60;

    /// A frame is being drawn, at `now`, `waited_ns` having been spent
    /// waiting for the GPU since the last. Returns whether `k` changed.
    pub fn frame(r: *Reach, now: u64, waited_ns: u64) bool {
        const last = r.last_ns orelse {
            r.last_ns = now;
            return false;
        };
        r.last_ns = now;
        // A gap (the window was covered, or the game paused): not counted.
        if (now -| last > 200 * std.time.ns_per_ms) return false;
        r.frames += 1;
        r.interval_ns += now -| last;
        r.waited_ns += waited_ns;
        if (r.frames < window) return false;
        const interval = r.interval_ns / r.frames;
        const waited = r.waited_ns / r.frames;
        r.frames = 0;
        r.interval_ns = 0;
        r.waited_ns = 0;
        const was = r.k;
        if (interval > frame_ns + frame_ns / 10 and waited > 2 * std.time.ns_per_ms) {
            r.k = @max(min, r.k - 0.05);
        } else if (waited < std.time.ns_per_ms / 2) {
            r.k = @min(1, r.k + 0.025);
        }
        return r.k != was;
    }
};

const testing = std.testing;

test "the fog comes nearer while the GPU holds the frames up, and goes back out when it does not" {
    var r: Reach = .{};
    const ms = std.time.ns_per_ms;
    var t: u64 = 0;
    for (0..13) |_| {
        t += 33 * ms;
        _ = r.frame(t, 20 * ms);
    }
    try testing.expect(r.k < 1);
    for (0..400) |_| {
        t += 50 * ms;
        _ = r.frame(t, 30 * ms);
    }
    try testing.expectEqual(Reach.min, r.k);
    for (0..2000) |_| {
        t += 16 * ms;
        _ = r.frame(t, 0);
    }
    try testing.expectEqual(@as(f32, 1), r.k);
    // A pause is not counted as a slow frame.
    t += 5 * std.time.ns_per_s;
    try testing.expect(!r.frame(t, 0));
}
