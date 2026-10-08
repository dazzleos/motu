//! Vectors and matrices for the camera. Matrices are column-major, as the
//! shaders read them.

const std = @import("std");

pub const V3 = @Vector(3, f32);
pub const Mat4 = [16]f32;

pub fn v3(x: f32, y: f32, z: f32) V3 {
    return .{ x, y, z };
}

pub fn splat(x: f32) V3 {
    return @splat(x);
}

pub fn dot(a: V3, b: V3) f32 {
    return @reduce(.Add, a * b);
}

pub fn cross(a: V3, b: V3) V3 {
    return .{ a[1] * b[2] - a[2] * b[1], a[2] * b[0] - a[0] * b[2], a[0] * b[1] - a[1] * b[0] };
}

pub fn length(a: V3) f32 {
    return @sqrt(dot(a, a));
}

pub fn normalize(a: V3) V3 {
    const l = length(a);
    return if (l > 0) a / splat(l) else a;
}

pub const identity: Mat4 = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

pub fn mul(a: Mat4, b: Mat4) Mat4 {
    var out: Mat4 = undefined;
    for (0..4) |col| for (0..4) |row| {
        var sum: f32 = 0;
        for (0..4) |k| sum += a[k * 4 + row] * b[col * 4 + k];
        out[col * 4 + row] = sum;
    };
    return out;
}

pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32) Mat4 {
    const f = 1.0 / @tan(fovy / 2.0);
    var m: Mat4 = @splat(0);
    m[0] = f / aspect;
    m[5] = f;
    m[10] = (far + near) / (near - far);
    m[11] = -1;
    m[14] = 2 * far * near / (near - far);
    return m;
}

pub fn translation(t: V3) Mat4 {
    var m = identity;
    m[12] = t[0];
    m[13] = t[1];
    m[14] = t[2];
    return m;
}

pub fn rotationX(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ 1, 0, 0, 0, 0, c, s, 0, 0, -s, c, 0, 0, 0, 0, 1 };
}

pub fn rotationY(a: f32) Mat4 {
    const c = @cos(a);
    const s = @sin(a);
    return .{ c, 0, -s, 0, 0, 1, 0, 0, s, 0, c, 0, 0, 0, 0, 1 };
}

/// Where a point goes (x, y, z, w).
pub fn transform(m: Mat4, p: V3) [4]f32 {
    var out: [4]f32 = undefined;
    for (0..4) |r| out[r] = m[r] * p[0] + m[4 + r] * p[1] + m[8 + r] * p[2] + m[12 + r];
    return out;
}

/// A camera at `eye`, turned `yaw` to the right of looking north (-z)
/// and `pitch` up.
pub const Camera = struct {
    eye: V3,
    yaw: f32,
    pitch: f32,
    /// Vertical field of view, in radians.
    fov: f32 = std.math.degreesToRadians(70.0),
    near: f32 = 0.1,
    far: f32 = 220,

    pub fn forward(c: Camera) V3 {
        return .{ @sin(c.yaw) * @cos(c.pitch), @sin(c.pitch), -@cos(c.yaw) * @cos(c.pitch) };
    }

    pub fn right(c: Camera) V3 {
        return .{ @cos(c.yaw), 0, @sin(c.yaw) };
    }

    pub fn up(c: Camera) V3 {
        return cross(c.right(), c.forward());
    }

    /// The view's turn alone (no move): for the sky, which is always as
    /// far away.
    pub fn rotation(c: Camera) Mat4 {
        return mul(rotationX(-c.pitch), rotationY(c.yaw));
    }

    pub fn view(c: Camera) Mat4 {
        return mul(c.rotation(), translation(-c.eye));
    }

    pub fn projection(c: Camera, aspect: f32) Mat4 {
        return perspective(c.fov, aspect, c.near, c.far);
    }

    /// The direction through a point of the view (x and y from -1 to 1,
    /// y up).
    pub fn ray(c: Camera, aspect: f32, x: f32, y: f32) V3 {
        const t = @tan(c.fov / 2);
        return normalize(c.forward() + c.right() * splat(x * t * aspect) + c.up() * splat(y * t));
    }
};

/// The planes a view sees between (each as a normal pointing in, and a
/// distance), from its view-projection matrix.
pub const Frustum = struct {
    planes: [6][4]f32,

    pub fn of(m: Mat4) Frustum {
        var f: Frustum = undefined;
        const row = struct {
            fn r(mm: Mat4, i: usize) [4]f32 {
                return .{ mm[i], mm[4 + i], mm[8 + i], mm[12 + i] };
            }
        }.r;
        const r3 = row(m, 3);
        for (0..3) |i| {
            const ri = row(m, i);
            for (0..4) |k| {
                f.planes[i * 2][k] = r3[k] + ri[k];
                f.planes[i * 2 + 1][k] = r3[k] - ri[k];
            }
        }
        return f;
    }

    /// Whether any of the box (min to max) may be seen.
    pub fn sees(f: *const Frustum, min: V3, max: V3) bool {
        for (f.planes) |p| {
            // The box's corner furthest along the plane's normal.
            const x = if (p[0] >= 0) max[0] else min[0];
            const y = if (p[1] >= 0) max[1] else min[1];
            const z = if (p[2] >= 0) max[2] else min[2];
            if (p[0] * x + p[1] * y + p[2] * z + p[3] < 0) return false;
        }
        return true;
    }
};

const testing = std.testing;

test "the camera looks where it faces" {
    const c: Camera = .{ .eye = .{ 10, 20, 30 }, .yaw = 0, .pitch = 0 };
    const vp = mul(c.projection(1.5), c.view());
    // A point straight ahead is in the middle of the view.
    const p = transform(vp, .{ 10, 20, 20 });
    try testing.expectApproxEqAbs(@as(f32, 0), p[0] / p[3], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), p[1] / p[3], 1e-5);
    try testing.expect(p[3] > 0);
    // Turned right (to the east), then up.
    const east: Camera = .{ .eye = .{ 0, 0, 0 }, .yaw = std.math.pi / 2.0, .pitch = 0.3 };
    const ahead = east.forward() * splat(5);
    const q = transform(mul(east.projection(1), east.view()), ahead);
    try testing.expectApproxEqAbs(@as(f32, 0), q[0] / q[3], 1e-5);
    try testing.expectApproxEqAbs(@as(f32, 0), q[1] / q[3], 1e-5);
    try testing.expect(ahead[0] > 4 and ahead[1] > 1);
    // The middle of the view's ray is straight ahead; the right edge's
    // goes right.
    try testing.expectApproxEqAbs(@as(f32, 1), dot(c.ray(1.5, 0, 0), c.forward()), 1e-5);
    try testing.expect(c.ray(1.5, 1, 0)[0] > 0);
    try testing.expect(c.ray(1.5, 0, 1)[1] > 0);
}

test "the frustum sees what is in front, not behind or beside" {
    const c: Camera = .{ .eye = .{ 0, 0, 0 }, .yaw = 0, .pitch = 0 };
    const f = Frustum.of(mul(c.projection(1), c.view()));
    try testing.expect(f.sees(.{ -1, -1, -11 }, .{ 1, 1, -9 }));
    try testing.expect(!f.sees(.{ -1, -1, 9 }, .{ 1, 1, 11 }));
    try testing.expect(!f.sees(.{ 50, -1, -11 }, .{ 52, 1, -9 }));
    try testing.expect(!f.sees(.{ -1, -1, -400 }, .{ 1, 1, -300 }));
    // A box around the eye is seen.
    try testing.expect(f.sees(.{ -5, -5, -5 }, .{ 5, 5, 5 }));
}
