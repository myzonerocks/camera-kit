//! Rigid transforms as rotation + translation, the currency of tracking
//! results and anchors. Kept separate from Mat4 so composition and
//! interpolation stay exact and cheap; conversion to a matrix happens once,
//! at the render boundary.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec = @import("vec.zig");
const mat = @import("mat.zig");
const quat = @import("quat.zig");

const Vec3 = vec.Vec3;
const Quat = quat.Quat;

pub const Pose = struct {
    rot: Quat,
    pos: Vec3,

    pub const identity: Pose = .{ .rot = Quat.identity, .pos = .{ 0.0, 0.0, 0.0 } };

    /// Applies `b` in the space of `a`: the result maps a point through `b`,
    /// then through `a`.
    pub fn compose(a: Pose, b: Pose) Pose {
        return .{
            .rot = Quat.mul(a.rot, b.rot),
            .pos = a.rot.rotate(b.pos) + a.pos,
        };
    }

    pub fn inverse(p: Pose) Pose {
        const inv_rot = p.rot.conjugate();
        return .{ .rot = inv_rot, .pos = inv_rot.rotate(-p.pos) };
    }

    pub fn transformPoint(p: Pose, point: Vec3) Vec3 {
        return p.rot.rotate(point) + p.pos;
    }

    pub fn toMat4(p: Pose) mat.Mat4 {
        var m = p.rot.toMat4();
        m.cols[3] = vec.vec4From3(p.pos, 1.0);
        return m;
    }

    /// Interpolates between two poses: slerp on rotation, lerp on position.
    pub fn interpolate(a: Pose, b: Pose, t: f32) Pose {
        return .{
            .rot = a.rot.slerp(b.rot, t),
            .pos = vec.lerp(a.pos, b.pos, t),
        };
    }

    /// Predicts the pose `t` steps past `curr`, where one step is the
    /// interval from `prev` to `curr`. The render loop uses this to carry an
    /// asynchronous tracking result forward to the frame being drawn; t is
    /// clamped so a stalled tracker cannot fling an anchor off-screen, and
    /// staleness beyond the clamp is the degradation ladder's job, not
    /// extrapolation's.
    pub fn extrapolate(prev: Pose, curr: Pose, t: f32) Pose {
        const tc = std.math.clamp(t, 0.0, 1.0);
        return interpolate(prev, curr, 1.0 + tc);
    }

    pub fn approxEq(a: Pose, b: Pose, tolerance: f32) bool {
        return a.rot.approxEq(b.rot, tolerance) and vec.approxEq(a.pos, b.pos, tolerance);
    }
};

test "compose then invert is identity" {
    const a: Pose = .{
        .rot = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, 0.8),
        .pos = .{ 1.0, 2.0, 3.0 },
    };
    const round_trip = Pose.compose(a, a.inverse());
    try std.testing.expect(round_trip.approxEq(Pose.identity, 1.0e-5));
}

test "transformPoint matches the matrix path" {
    const p: Pose = .{
        .rot = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(90.0)),
        .pos = .{ 10.0, 0.0, 0.0 },
    };
    const direct = p.transformPoint(.{ 1.0, 0.0, 0.0 });
    const via_mat = p.toMat4().mulPoint(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(direct, via_mat, 1.0e-5));
    try std.testing.expect(vec.approxEq(direct, @as(Vec3, .{ 10.0, 1.0, 0.0 }), 1.0e-5));
}

test "compose applies child then parent" {
    const parent: Pose = .{ .rot = Quat.identity, .pos = .{ 5.0, 0.0, 0.0 } };
    const child: Pose = .{
        .rot = Quat.fromAxisAngle(.{ 0.0, 0.0, 1.0 }, scalar.radians(90.0)),
        .pos = .{ 0.0, 0.0, 0.0 },
    };
    const world = Pose.compose(parent, child);
    const q = world.transformPoint(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(q, @as(Vec3, .{ 5.0, 1.0, 0.0 }), 1.0e-5));
}

test "interpolate endpoints and extrapolate continues the motion" {
    const a: Pose = .{ .rot = Quat.identity, .pos = .{ 0.0, 0.0, 0.0 } };
    const b: Pose = .{
        .rot = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, scalar.radians(30.0)),
        .pos = .{ 1.0, 0.0, 0.0 },
    };
    try std.testing.expect(Pose.interpolate(a, b, 0.0).approxEq(a, 1.0e-5));
    try std.testing.expect(Pose.interpolate(a, b, 1.0).approxEq(b, 1.0e-5));

    const predicted = Pose.extrapolate(a, b, 1.0);
    const expected: Pose = .{
        .rot = Quat.fromAxisAngle(.{ 0.0, 1.0, 0.0 }, scalar.radians(60.0)),
        .pos = .{ 2.0, 0.0, 0.0 },
    };
    try std.testing.expect(predicted.approxEq(expected, 1.0e-4));
}

test "extrapolate clamps runaway prediction" {
    const a: Pose = .{ .rot = Quat.identity, .pos = .{ 0.0, 0.0, 0.0 } };
    const b: Pose = .{ .rot = Quat.identity, .pos = .{ 1.0, 0.0, 0.0 } };
    const clamped = Pose.extrapolate(a, b, 50.0);
    try std.testing.expect(vec.approxEq(clamped.pos, @as(Vec3, .{ 2.0, 0.0, 0.0 }), 1.0e-5));
}
