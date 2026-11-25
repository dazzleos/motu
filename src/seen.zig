//! What can be seen from a fixed eye: for a scene whose camera never moves
//! (the title scene's), the faces that can never show (behind others, or
//! out of view) are not worth drawing. See `Renderer.setFixedView`.
//!
//! The opaque faces turned towards the eye are drawn into a depth buffer,
//! as the GPU would (at pixels' centres, faces' shared edges leaving no
//! gaps), then made conservative (`finish`): each pixel takes the furthest
//! depth around it, so beside a face's edge, what is behind it counts as
//! seen, whatever the GPU's pixels. A face is hidden only if, all over a
//! rectangle around where it shows (grown by a margin for what moves:
//! leaves swaying, waves), it is behind what is there. Anything in doubt (crossing the eye's plane, say)
//! is seen. So what is left out could not have changed a pixel, at any
//! view distance (fog hides more, never less) and in any window shape up
//! to `View.widest` across (the eye fixed, what hides what is the same
//! however the view is cropped).

const std = @import("std");
const math = @import("math.zig");
const mesher = @import("mesher.zig");

const V3 = math.V3;
const Vertex = mesher.Vertex;

/// The fixed view.
pub const View = struct {
    camera: math.Camera,
    /// The widest the view is, across over down (the camera's field of
    /// view is up and down; a wider window sees more to the sides): an
    /// ultrawide screen's (21:9), and a little.
    widest: f32 = 2.4,
    /// Pixels down the view (more: what slips between faces is found more
    /// finely). The screen's: 1080.
    height: u32 = 1080,
};

pub const Seen = struct {
    gpa: std.mem.Allocator,
    view: View,
    width: u32,
    height: u32,
    vp: math.Mat4,
    /// Pixels per unit of tangent: how big a block is at a distance.
    focal: f32,
    /// The nearest opaque face's depth at each pixel's centre, as its
    /// reciprocal (one over the distance along the view, which goes evenly
    /// across a face on the screen; 0: none); after `finish`, the furthest
    /// (least) of those around it.
    inverse: []f32,

    pub fn init(gpa: std.mem.Allocator, view: View) !Seen {
        const width: u32 = @intFromFloat(@ceil(@as(f32, @floatFromInt(view.height)) * view.widest));
        const inverse = try gpa.alloc(f32, @as(usize, width) * view.height);
        @memset(inverse, 0);
        const cam = view.camera;
        return .{
            .gpa = gpa,
            .view = view,
            .width = width,
            .height = view.height,
            .vp = math.mul(cam.projection(view.widest), cam.view()),
            .focal = @as(f32, @floatFromInt(view.height)) / 2 / @tan(cam.fov / 2),
            .inverse = inverse,
        };
    }

    pub fn deinit(s: *Seen) void {
        s.gpa.free(s.inverse);
    }

    /// A quad's corners on the screen (pixels; y down) and how far along
    /// the view each is; null if one is at or behind the eye.
    fn project(s: *const Seen, q: *const [4]Vertex) ?[4][3]f32 {
        var out: [4][3]f32 = undefined;
        for (q, &out) |v, *o| {
            const p = math.transform(s.vp, .{ v.pos[0], v.pos[1], v.pos[2] });
            if (p[3] < s.view.camera.near) return null;
            o.* = .{
                (p[0] / p[3] * 0.5 + 0.5) * @as(f32, @floatFromInt(s.width)),
                (0.5 - p[1] / p[3] * 0.5) * @as(f32, @floatFromInt(s.height)),
                p[3],
            };
        }
        return out;
    }

    /// Whether the quad faces the eye (the GPU draws only those): counter-
    /// clockwise with y up, so its area with y down is negative.
    fn facesEye(c: [4][3]f32) bool {
        const area = (c[1][0] - c[0][0]) * (c[2][1] - c[0][1]) - (c[1][1] - c[0][1]) * (c[2][0] - c[0][0]);
        return area < 0;
    }

    /// Adds an opaque quad: what is behind it is hidden where it covers.
    pub fn addOccluder(s: *Seen, q: *const [4]Vertex) void {
        const c = s.project(q) orelse return;
        if (!facesEye(c)) return;
        for ([2][3]usize{ .{ 0, 1, 2 }, .{ 0, 2, 3 } }) |t| s.fill(.{ c[t[0]], c[t[1]], c[t[2]] });
    }

    /// Writes a triangle's depth into the pixels whose centres it covers
    /// (on its edges too, so neighbours leave no gap between them): how
    /// far into it a pixel is, and its depth's reciprocal, go evenly
    /// across the screen, so are added up along a row.
    fn fill(s: *Seen, t: [3][3]f32) void {
        const area = (t[1][0] - t[0][0]) * (t[2][1] - t[0][1]) - (t[1][1] - t[0][1]) * (t[2][0] - t[0][0]);
        if (@abs(area) < 1e-6) return;
        const w: f32 = @floatFromInt(s.width);
        const h: f32 = @floatFromInt(s.height);
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(@min(t[0][0], t[1][0], t[2][0])), 0, w));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(@max(t[0][0], t[1][0], t[2][0])), 0, w));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(@min(t[0][1], t[1][1], t[2][1])), 0, h));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(@max(t[0][1], t[1][1], t[2][1])), 0, h));
        if (x1 <= x0 or y1 <= y0) return;
        // Each corner's weight at (x, y): a x + b y + c.
        const k = 1 / area;
        const e0 = [3]f32{ (t[1][1] - t[2][1]) * k, (t[2][0] - t[1][0]) * k, (t[1][0] * t[2][1] - t[1][1] * t[2][0]) * k };
        const e1 = [3]f32{ (t[2][1] - t[0][1]) * k, (t[0][0] - t[2][0]) * k, (t[2][0] * t[0][1] - t[2][1] * t[0][0]) * k };
        // The third's is one less the others; the reciprocal depth, each
        // corner's by its weight.
        const r0 = 1 / t[0][2];
        const r1 = 1 / t[1][2];
        const r2 = 1 / t[2][2];
        const z = [3]f32{
            e0[0] * (r0 - r2) + e1[0] * (r1 - r2),
            e0[1] * (r0 - r2) + e1[1] * (r1 - r2),
            e0[2] * (r0 - r2) + e1[2] * (r1 - r2) + r2,
        };
        const on_edge = -1e-4;
        var y = y0;
        while (y < y1) : (y += 1) {
            const py = @as(f32, @floatFromInt(y)) + 0.5;
            const px = @as(f32, @floatFromInt(x0)) + 0.5;
            var b0 = e0[0] * px + e0[1] * py + e0[2];
            var b1 = e1[0] * px + e1[1] * py + e1[2];
            var iz = z[0] * px + z[1] * py + z[2];
            const row = s.inverse[@as(usize, y) * s.width ..];
            var x = x0;
            while (x < x1) : (x += 1) {
                if (b0 >= on_edge and b1 >= on_edge and 1 - b0 - b1 >= on_edge) row[x] = @max(row[x], iz);
                b0 += e0[0];
                b1 += e1[0];
                iz += z[0];
            }
        }
    }

    /// Once all the occluders are in: each pixel the furthest depth of
    /// those next to it (and itself), so that between and beside pixels'
    /// centres, what is behind an edge is not taken as hidden.
    pub fn finish(s: *Seen) !void {
        // Across, then down (the furthest of three, then of three of
        // those: of the nine around).
        const was = try s.gpa.alloc(f32, s.inverse.len);
        defer s.gpa.free(was);
        const w = s.width;
        const h = s.height;
        for (0..h) |y| {
            const row = s.inverse[y * w ..][0..w];
            const out = was[y * w ..][0..w];
            // Past the edge of the view: nothing there hides.
            for (0..w) |x| out[x] = if (x == 0 or x == w - 1) 0 else @min(row[x - 1], row[x], row[x + 1]);
        }
        for (0..h) |y| {
            const out = s.inverse[y * w ..][0..w];
            if (y == 0 or y == h - 1) {
                @memset(out, 0);
                continue;
            }
            const up = was[(y - 1) * w ..][0..w];
            const at = was[y * w ..][0..w];
            const down = was[(y + 1) * w ..][0..w];
            for (out, up, at, down) |*o, a, b, c| o.* = @min(a, b, c);
        }
    }

    /// Whether a quad can show anywhere (or might: in doubt, it can), even
    /// moved as far as `moves` (blocks) from where its corners are (as
    /// leaves sway and waves rise and fall, in the shaders).
    pub fn sees(s: *const Seen, q: *const [4]Vertex, moves: f32) bool {
        const c = s.project(q) orelse {
            // Wholly behind the eye: never on the screen; partly: in doubt.
            for (q) |v| if (math.transform(s.vp, .{ v.pos[0], v.pos[1], v.pos[2] })[3] >= s.view.camera.near) return true;
            return false;
        };
        var near: f32 = std.math.inf(f32);
        var lo: [2]f32 = .{ std.math.inf(f32), std.math.inf(f32) };
        var hi: [2]f32 = .{ -std.math.inf(f32), -std.math.inf(f32) };
        for (c) |p| {
            near = @min(near, p[2]);
            for (0..2) |k| {
                lo[k] = @min(lo[k], p[k]);
                hi[k] = @max(hi[k], p[k]);
            }
        }
        // Grown by how far it may move, at its nearest, and a pixel.
        const grow = moves * s.focal / near + 1;
        // Moved towards the eye, at or past it: in doubt.
        const nearest = near - moves;
        if (nearest <= 0) return true;
        const inverse = 1 / nearest;
        const w: f32 = @floatFromInt(s.width);
        const h: f32 = @floatFromInt(s.height);
        if (hi[0] + grow < 0 or lo[0] - grow > w or hi[1] + grow < 0 or lo[1] - grow > h) return false;
        const x0: u32 = @intFromFloat(std.math.clamp(@floor(lo[0] - grow), 0, w));
        const x1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[0] + grow), 0, w));
        const y0: u32 = @intFromFloat(std.math.clamp(@floor(lo[1] - grow), 0, h));
        const y1: u32 = @intFromFloat(std.math.clamp(@ceil(hi[1] + grow), 0, h));
        var y = y0;
        while (y < y1) : (y += 1) {
            for (s.inverse[@as(usize, y) * s.width + x0 ..][0 .. x1 - x0]) |d| if (inverse > d) return true;
        }
        return false;
    }
};

const testing = std.testing;

fn quad(corners: [4][3]f32) [4]Vertex {
    var q: [4]Vertex = undefined;
    for (&q, corners) |*v, c| v.* = .{ .pos = c, .uv = .{ 0, 0 }, .info = 0 };
    return q;
}

test "a face behind a wall is hidden; beside it, above it, or in front, it is seen" {
    // Looking north (-z) from the origin.
    var s = try Seen.init(testing.allocator, .{ .camera = .{ .eye = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 }, .height = 270 });
    defer s.deinit();
    // A wall 10 north, facing the eye (south), 8 across and up.
    const wall = quad(.{ .{ -4, -4, -10 }, .{ 4, -4, -10 }, .{ 4, 4, -10 }, .{ -4, 4, -10 } });
    // Facing the other way (as seen from the eye): it hides nothing.
    const back = quad(.{ .{ -4, -4, -10 }, .{ -4, 4, -10 }, .{ 4, 4, -10 }, .{ 4, -4, -10 } });
    s.addOccluder(&back);
    try s.finish();
    const behind = quad(.{ .{ -1, -1, -20 }, .{ 1, -1, -20 }, .{ 1, 1, -20 }, .{ -1, 1, -20 } });
    try testing.expect(s.sees(&behind, 0.25));
    // The wall in two halves (as faces side by side are): no gap between.
    @memset(s.inverse, 0);
    s.addOccluder(&quad(.{ .{ -4, -4, -10 }, .{ 0, -4, -10 }, .{ 0, 4, -10 }, .{ -4, 4, -10 } }));
    s.addOccluder(&quad(.{ .{ 0, -4, -10 }, .{ 4, -4, -10 }, .{ 4, 4, -10 }, .{ 0, 4, -10 } }));
    try s.finish();
    try testing.expect(!s.sees(&behind, 0.25));
    _ = wall;
    // Out beside it (past its edge, as seen): seen.
    const beside = quad(.{ .{ 8, -1, -20 }, .{ 10, -1, -20 }, .{ 10, 1, -20 }, .{ 8, 1, -20 } });
    try testing.expect(s.sees(&beside, 0.25));
    // In front of it: seen.
    const front = quad(.{ .{ -1, -1, -5 }, .{ 1, -1, -5 }, .{ 1, 1, -5 }, .{ -1, 1, -5 } });
    try testing.expect(s.sees(&front, 0.25));
    // Just behind it, by less than things move: seen (it may sway out).
    const touching = quad(.{ .{ -1, -1, -10.1 }, .{ 1, -1, -10.1 }, .{ 1, 1, -10.1 }, .{ -1, 1, -10.1 } });
    try testing.expect(s.sees(&touching, 0.25));
    // Behind the eye: never on the screen.
    const back_of_eye = quad(.{ .{ -1, -1, 5 }, .{ 1, -1, 5 }, .{ 1, 1, 5 }, .{ -1, 1, 5 } });
    try testing.expect(!s.sees(&back_of_eye, 0.25));
    // Crossing the eye's plane: in doubt, seen.
    const crossing = quad(.{ .{ -1, -1, 5 }, .{ 1, -1, 5 }, .{ 1, -1, -5 }, .{ -1, -1, -5 } });
    try testing.expect(s.sees(&crossing, 0.25));
}

test "far off to the side, in a wide window: seen; straight up, out of every view: hidden" {
    var s = try Seen.init(testing.allocator, .{ .camera = .{ .eye = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 }, .height = 270, .widest = 3 });
    defer s.deinit();
    try s.finish();
    // 60° to the side: out of a 16:9 view (70° up and down: 51° to the
    // side), in a 3:1 one.
    const side = quad(.{ .{ 17, -1, -10 }, .{ 17, -1, -11 }, .{ 17, 1, -11 }, .{ 17, 1, -10 } });
    try testing.expect(s.sees(&side, 0.25));
    const up = quad(.{ .{ -1, 20, -1 }, .{ 1, 20, -1 }, .{ 1, 20, -3 }, .{ -1, 20, -3 } });
    try testing.expect(!s.sees(&up, 0.25));
}
