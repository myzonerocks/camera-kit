//! Unit quaternions for rotation. Stored as one `@Vector(4, f32)` in
//! x, y, z, w order (w scalar last, matching the tracking backends and
//! glTF). All functions are pure and allocation-free.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec = @import("vec.zig");
const mat = @import("mat.zig");

const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

pub const Quat = struct {
    v: Vec4,

    pub const identity: Quat = .{ .v = .{ 0.0, 0.0, 0.0, 1.0 } };

    pub fn init(x: f32, y: f32, z: f32, w: f32) Quat {
        return .{ .v = .{ x, y, z, w } };
    }

    pub fn fromAxisAngle(axis: Vec3, angle: f32) Quat {
        const half = angle * 0.5;
        const s = @sin(half);
        const a = vec.normalize(axis);
        return .{ .v = vec.vec4From3(a * vec.splat(Vec3, s), @cos(half)) };
    }

    pub fn mul(a: Quat, b: Quat) Quat {
        const av = vec.vec3From4(a.v);
        const bv = vec.vec3From4(b.v);
        const aw = a.v[3];
        const bw = b.v[3];
        const xyz = vec.cross(av, bv) + bv * vec.splat(Vec3, aw) + av * vec.splat(Vec3, bw);
        const w = aw * bw - vec.dot(av, bv);
        return .{ .v = vec.vec4From3(xyz, w) };
    }

    pub fn conjugate(q: Quat) Quat {
        return .{ .v = q.v * @as(Vec4, .{ -1.0, -1.0, -1.0, 1.0 }) };
    }

    pub fn normalize(q: Quat) Quat {
        return .{ .v = vec.normalize(q.v) };
    }

    pub fn dot(a: Quat, b: Quat) f32 {
        return vec.dot(a.v, b.v);
    }

    /// Rotates a vector; `q` must be unit length.
    pub fn rotate(q: Quat, p: Vec3) Vec3 {
        const u = vec.vec3From4(q.v);
        const w = q.v[3];
        const t = vec.cross(u, p) * vec.splat(Vec3, 2.0);
        return p + t * vec.splat(Vec3, w) + vec.cross(u, t);
    }

    /// Normalized lerp: cheap, monotonic, adequate for the small angular
    /// steps between consecutive tracking results.
    pub fn nlerp(a: Quat, b: Quat, t: f32) Quat {
        const bv = if (dot(a, b) < 0.0) -b.v else b.v;
        return .{ .v = vec.normalize(vec.lerp(a.v, bv, t)) };
    }

    /// Spherical lerp with the shortest arc; handles t outside 0..1 for
    /// extrapolation. Falls back to nlerp when the arc is tiny.
    pub fn slerp(a: Quat, b: Quat, t: f32) Quat {
        var cos_theta = dot(a, b);
        var bv = b.v;
        if (cos_theta < 0.0) {
            bv = -bv;
            cos_theta = -cos_theta;
        }
        if (cos_theta > 1.0 - 1.0e-5) {
            return .{ .v = vec.normalize(vec.lerp(a.v, bv, t)) };
        }
        const theta = std.math.acos(std.math.clamp(cos_theta, -1.0, 1.0));
        const inv_sin = 1.0 / @sin(theta);
        const wa = @sin((1.0 - t) * theta) * inv_sin;
        const wb = @sin(t * theta) * inv_sin;
        return .{ .v = vec.normalize(a.v * vec.splat(Vec4, wa) + bv * vec.splat(Vec4, wb)) };
    }

    pub fn toMat3(q: Quat) mat.Mat3 {
        const x = q.v[0];
        const y = q.v[1];
        const z = q.v[2];
        const w = q.v[3];
        const x2 = x + x;
        const y2 = y + y;
        const z2 = z + z;
        const xx = x * x2;
        const xy = x * y2;
        const xz = x * z2;
        const yy = y * y2;
        const yz = y * z2;
        const zz = z * z2;
        const wx = w * x2;
        const wy = w * y2;
        const wz = w * z2;
        return .{ .cols = .{
            .{ 1.0 - (yy + zz), xy + wz, xz - wy },
            .{ xy - wz, 1.0 - (xx + zz), yz + wx },
            .{ xz + wy, yz - wx, 1.0 - (xx + yy) },
        } };
    }

    pub fn toMat4(q: Quat) mat.Mat4 {
        const m3 = q.toMat3();
        return .{ .cols = .{
            vec.vec4From3(m3.cols[0], 0.0),
            vec.vec4From3(m3.cols[1], 0.0),
            vec.vec4From3(m3.cols[2], 0.0),
            .{ 0.0, 0.0, 0.0, 1.0 },
        } };
    }

    /// Extracts a rotation from an orthonormal 3x3 basis.
    pub fn fromMat3(m: mat.Mat3) Quat {
        const trace = m.cols[0][0] + m.cols[1][1] + m.cols[2][2];
        if (trace > 0.0) {
            const s = @sqrt(trace + 1.0) * 2.0;
            return normalize(.{ .v = .{
                (m.cols[1][2] - m.cols[2][1]) / s,
                (m.cols[2][0] - m.cols[0][2]) / s,
                (m.cols[0][1] - m.cols[1][0]) / s,
                0.25 * s,
            } });
        } else if (m.cols[0][0] > m.cols[1][1] and m.cols[0][0] > m.cols[2][2]) {
            const s = @sqrt(1.0 + m.cols[0][0] - m.cols[1][1] - m.cols[2][2]) * 2.0;
            return normalize(.{ .v = .{
                0.25 * s,
                (m.cols[1][0] + m.cols[0][1]) / s,
                (m.cols[2][0] + m.cols[0][2]) / s,
                (m.cols[1][2] - m.cols[2][1]) / s,
            } });
        } else if (m.cols[1][1] > m.cols[2][2]) {
            const s = @sqrt(1.0 + m.cols[1][1] - m.cols[0][0] - m.cols[2][2]) * 2.0;
            return normalize(.{ .v = .{
                (m.cols[1][0] + m.cols[0][1]) / s,
                0.25 * s,
                (m.cols[2][1] + m.cols[1][2]) / s,
                (m.cols[2][0] - m.cols[0][2]) / s,
            } });
        } else {
            const s = @sqrt(1.0 + m.cols[2][2] - m.cols[0][0] - m.cols[1][1]) * 2.0;
            return normalize(.{ .v = .{
                (m.cols[2][0] + m.cols[0][2]) / s,
                (m.cols[2][1] + m.cols[1][2]) / s,
                0.25 * s,
                (m.cols[0][1] - m.cols[1][0]) / s,
            } });
        }
    }

    pub fn approxEq(a: Quat, b: Quat, tolerance: f32) bool {
        // q and -q are the same rotation
        return vec.approxEq(a.v, b.v, tolerance) or vec.approxEq(a.v, -b.v, tolerance);
    }
};

test "identity rotates nothing" {
    const p: Vec3 = .{ 1.0, 2.0, 3.0 };
    try std.testing.expect(vec.approxEq(Quat.identity.rotate(p), p, scalar.epsilon));
}

test "axis-angle rotation matches the matrix path" {
    const q = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(90.0));
    const p = q.rotate(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(p, @as(Vec3, .{ 0.0, 1.0, 0.0 }), 1.0e-5));
    const pm = q.toMat3().mulVec(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(p, pm, 1.0e-5));
}

test "composition applies right-to-left" {
    const rx = Quat.fromAxisAngle(.{ 1.0, 0.0, 0.0 }, 0.4);
    const ry = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, 0.9);
    const p: Vec3 = .{ 0.3, -0.7, 1.1 };
    const composed = Quat.mul(ry, rx).rotate(p);
    const sequential = ry.rotate(rx.rotate(p));
    try std.testing.expect(vec.approxEq(composed, sequential, 1.0e-5));
}

test "conjugate undoes the rotation" {
    const q = Quat.fromAxisAngle(vec.normalize(@as(Vec3, .{ 1.0, 1.0, 0.0 })), 1.2);
    const p: Vec3 = .{ 5.0, -3.0, 2.0 };
    try std.testing.expect(vec.approxEq(q.conjugate().rotate(q.rotate(p)), p, 1.0e-4));
}

test "slerp hits endpoints, midpoint, and extrapolates" {
    const a = Quat.identity;
    const b = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(90.0));
    try std.testing.expect(a.slerp(b, 0.0).approxEq(a, 1.0e-5));
    try std.testing.expect(a.slerp(b, 1.0).approxEq(b, 1.0e-5));
    const mid = a.slerp(b, 0.5);
    const expected_mid = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(45.0));
    try std.testing.expect(mid.approxEq(expected_mid, 1.0e-5));
    const extra = a.slerp(b, 2.0);
    const expected_extra = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(180.0));
    try std.testing.expect(extra.approxEq(expected_extra, 1.0e-4));
}

test "slerp takes the short way around" {
    const a = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, scalar.radians(10.0));
    const b_long = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, scalar.radians(350.0));
    const mid = a.slerp(b_long, 0.5);
    const expected = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, 0.0);
    try std.testing.expect(mid.approxEq(expected, 1.0e-4));
}

test "mat3 round-trip through quaternion" {
    const q = Quat.fromAxisAngle(vec.normalize(@as(Vec3, .{ 0.2, 0.8, -0.5 })), 2.1);
    const back = Quat.fromMat3(q.toMat3());
    try std.testing.expect(back.approxEq(q, 1.0e-4));
}
