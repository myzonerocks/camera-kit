//! Column-major matrices over `@Vector` columns. Column-major matches the
//! GPU-facing conventions of the render backend on every target, so uploads
//! are a straight copy. All functions are pure and allocation-free.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec = @import("vec.zig");

const Vec3 = vec.Vec3;
const Vec4 = vec.Vec4;

/// Clip-space depth convention of the projection consumer. OpenGL-style
/// backends use -1..1, Metal/Vulkan/WebGPU-style use 0..1; the render
/// backend reports which one it needs.
pub const DepthRange = enum { neg_one_to_one, zero_to_one };

pub const Mat3 = struct {
    cols: [3]Vec3,

    pub const identity: Mat3 = .{ .cols = .{
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 1.0 },
    } };

    pub fn mul(a: Mat3, b: Mat3) Mat3 {
        var out: Mat3 = undefined;
        inline for (0..3) |j| {
            var col: Vec3 = a.cols[0] * vec.splat(Vec3, b.cols[j][0]);
            col = @mulAdd(Vec3, a.cols[1], vec.splat(Vec3, b.cols[j][1]), col);
            col = @mulAdd(Vec3, a.cols[2], vec.splat(Vec3, b.cols[j][2]), col);
            out.cols[j] = col;
        }
        return out;
    }

    pub fn mulVec(m: Mat3, v: Vec3) Vec3 {
        var out: Vec3 = m.cols[0] * vec.splat(Vec3, v[0]);
        out = @mulAdd(Vec3, m.cols[1], vec.splat(Vec3, v[1]), out);
        out = @mulAdd(Vec3, m.cols[2], vec.splat(Vec3, v[2]), out);
        return out;
    }

    pub fn transpose(m: Mat3) Mat3 {
        var out: Mat3 = undefined;
        inline for (0..3) |j| {
            inline for (0..3) |i| out.cols[j][i] = m.cols[i][j];
        }
        return out;
    }

    pub fn determinant(m: Mat3) f32 {
        return vec.dot(m.cols[0], vec.cross(m.cols[1], m.cols[2]));
    }

    pub fn inverse(m: Mat3) ?Mat3 {
        const det = m.determinant();
        if (@abs(det) <= scalar.epsilon) return null;
        const inv_det = 1.0 / det;
        const r0 = vec.cross(m.cols[1], m.cols[2]);
        const r1 = vec.cross(m.cols[2], m.cols[0]);
        const r2 = vec.cross(m.cols[0], m.cols[1]);
        // rows of the adjugate are the cross products above
        return .{ .cols = .{
            .{ r0[0] * inv_det, r1[0] * inv_det, r2[0] * inv_det },
            .{ r0[1] * inv_det, r1[1] * inv_det, r2[1] * inv_det },
            .{ r0[2] * inv_det, r1[2] * inv_det, r2[2] * inv_det },
        } };
    }

    pub fn approxEq(a: Mat3, b: Mat3, tolerance: f32) bool {
        inline for (0..3) |j| {
            if (!vec.approxEq(a.cols[j], b.cols[j], tolerance)) return false;
        }
        return true;
    }
};

pub const Mat4 = struct {
    cols: [4]Vec4,

    pub const identity: Mat4 = .{ .cols = .{
        .{ 1.0, 0.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0, 0.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, 1.0 },
    } };

    pub fn mul(a: Mat4, b: Mat4) Mat4 {
        var out: Mat4 = undefined;
        inline for (0..4) |j| {
            var col: Vec4 = a.cols[0] * vec.splat(Vec4, b.cols[j][0]);
            col = @mulAdd(Vec4, a.cols[1], vec.splat(Vec4, b.cols[j][1]), col);
            col = @mulAdd(Vec4, a.cols[2], vec.splat(Vec4, b.cols[j][2]), col);
            col = @mulAdd(Vec4, a.cols[3], vec.splat(Vec4, b.cols[j][3]), col);
            out.cols[j] = col;
        }
        return out;
    }

    pub fn mulVec(m: Mat4, v: Vec4) Vec4 {
        var out: Vec4 = m.cols[0] * vec.splat(Vec4, v[0]);
        out = @mulAdd(Vec4, m.cols[1], vec.splat(Vec4, v[1]), out);
        out = @mulAdd(Vec4, m.cols[2], vec.splat(Vec4, v[2]), out);
        out = @mulAdd(Vec4, m.cols[3], vec.splat(Vec4, v[3]), out);
        return out;
    }

    /// Transforms a point, assuming the matrix's bottom row is 0 0 0 1.
    pub fn mulPoint(m: Mat4, p: Vec3) Vec3 {
        return vec.vec3From4(m.mulVec(vec.vec4From3(p, 1.0)));
    }

    /// Transforms a direction, ignoring translation.
    pub fn mulDirection(m: Mat4, d: Vec3) Vec3 {
        return vec.vec3From4(m.mulVec(vec.vec4From3(d, 0.0)));
    }

    pub fn transpose(m: Mat4) Mat4 {
        var out: Mat4 = undefined;
        inline for (0..4) |j| {
            inline for (0..4) |i| out.cols[j][i] = m.cols[i][j];
        }
        return out;
    }

    pub fn translation(t: Vec3) Mat4 {
        var out = identity;
        out.cols[3] = vec.vec4From3(t, 1.0);
        return out;
    }

    pub fn scaling(s: Vec3) Mat4 {
        var out = identity;
        out.cols[0][0] = s[0];
        out.cols[1][1] = s[1];
        out.cols[2][2] = s[2];
        return out;
    }

    pub fn rotationX(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var out = identity;
        out.cols[1] = .{ 0.0, c, s, 0.0 };
        out.cols[2] = .{ 0.0, -s, c, 0.0 };
        return out;
    }

    pub fn rotationY(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var out = identity;
        out.cols[0] = .{ c, 0.0, -s, 0.0 };
        out.cols[2] = .{ s, 0.0, c, 0.0 };
        return out;
    }

    pub fn rotationZ(angle: f32) Mat4 {
        const c = @cos(angle);
        const s = @sin(angle);
        var out = identity;
        out.cols[0] = .{ c, s, 0.0, 0.0 };
        out.cols[1] = .{ -s, c, 0.0, 0.0 };
        return out;
    }

    /// Upper-left 3x3, for normal matrices and rotation extraction.
    pub fn toMat3(m: Mat4) Mat3 {
        return .{ .cols = .{
            vec.vec3From4(m.cols[0]),
            vec.vec3From4(m.cols[1]),
            vec.vec3From4(m.cols[2]),
        } };
    }

    /// General inverse via the adjugate; null when singular. Prefer
    /// `inverseRigid` for pose matrices.
    pub fn inverse(m: Mat4) ?Mat4 {
        const a = m.cols;
        // 2x2 sub-determinants of the top two and bottom two rows
        const s0 = a[0][0] * a[1][1] - a[1][0] * a[0][1];
        const s1 = a[0][0] * a[2][1] - a[2][0] * a[0][1];
        const s2 = a[0][0] * a[3][1] - a[3][0] * a[0][1];
        const s3 = a[1][0] * a[2][1] - a[2][0] * a[1][1];
        const s4 = a[1][0] * a[3][1] - a[3][0] * a[1][1];
        const s5 = a[2][0] * a[3][1] - a[3][0] * a[2][1];
        const c5 = a[2][2] * a[3][3] - a[3][2] * a[2][3];
        const c4 = a[1][2] * a[3][3] - a[3][2] * a[1][3];
        const c3 = a[1][2] * a[2][3] - a[2][2] * a[1][3];
        const c2 = a[0][2] * a[3][3] - a[3][2] * a[0][3];
        const c1 = a[0][2] * a[2][3] - a[2][2] * a[0][3];
        const c0 = a[0][2] * a[1][3] - a[1][2] * a[0][3];

        const det = s0 * c5 - s1 * c4 + s2 * c3 + s3 * c2 - s4 * c1 + s5 * c0;
        if (@abs(det) <= scalar.epsilon) return null;
        const b = 1.0 / det;

        return .{ .cols = .{
            .{
                (a[1][1] * c5 - a[2][1] * c4 + a[3][1] * c3) * b,
                (-a[0][1] * c5 + a[2][1] * c2 - a[3][1] * c1) * b,
                (a[0][1] * c4 - a[1][1] * c2 + a[3][1] * c0) * b,
                (-a[0][1] * c3 + a[1][1] * c1 - a[2][1] * c0) * b,
            },
            .{
                (-a[1][0] * c5 + a[2][0] * c4 - a[3][0] * c3) * b,
                (a[0][0] * c5 - a[2][0] * c2 + a[3][0] * c1) * b,
                (-a[0][0] * c4 + a[1][0] * c2 - a[3][0] * c0) * b,
                (a[0][0] * c3 - a[1][0] * c1 + a[2][0] * c0) * b,
            },
            .{
                (a[1][3] * s5 - a[2][3] * s4 + a[3][3] * s3) * b,
                (-a[0][3] * s5 + a[2][3] * s2 - a[3][3] * s1) * b,
                (a[0][3] * s4 - a[1][3] * s2 + a[3][3] * s0) * b,
                (-a[0][3] * s3 + a[1][3] * s1 - a[2][3] * s0) * b,
            },
            .{
                (-a[1][2] * s5 + a[2][2] * s4 - a[3][2] * s3) * b,
                (a[0][2] * s5 - a[2][2] * s2 + a[3][2] * s1) * b,
                (-a[0][2] * s4 + a[1][2] * s2 - a[3][2] * s0) * b,
                (a[0][2] * s3 - a[1][2] * s1 + a[2][2] * s0) * b,
            },
        } };
    }

    /// Inverse of a rotation+translation matrix: transpose the rotation,
    /// rotate the negated translation. No scale allowed.
    pub fn inverseRigid(m: Mat4) Mat4 {
        const r = m.toMat3().transpose();
        const t = vec.vec3From4(m.cols[3]);
        const nt = r.mulVec(-t);
        return .{ .cols = .{
            vec.vec4From3(r.cols[0], 0.0),
            vec.vec4From3(r.cols[1], 0.0),
            vec.vec4From3(r.cols[2], 0.0),
            vec.vec4From3(nt, 1.0),
        } };
    }

    /// Right-handed perspective projection; `fovy` in radians, depth mapped
    /// per the consumer's clip convention.
    pub fn perspective(fovy: f32, aspect: f32, near: f32, far: f32, depth: DepthRange) Mat4 {
        std.debug.assert(near > 0.0 and far > near);
        const f = 1.0 / @tan(fovy * 0.5);
        var out: Mat4 = .{ .cols = .{
            .{ f / aspect, 0.0, 0.0, 0.0 },
            .{ 0.0, f, 0.0, 0.0 },
            .{ 0.0, 0.0, 0.0, -1.0 },
            .{ 0.0, 0.0, 0.0, 0.0 },
        } };
        switch (depth) {
            .neg_one_to_one => {
                out.cols[2][2] = (far + near) / (near - far);
                out.cols[3][2] = (2.0 * far * near) / (near - far);
            },
            .zero_to_one => {
                out.cols[2][2] = far / (near - far);
                out.cols[3][2] = (far * near) / (near - far);
            },
        }
        return out;
    }

    /// Right-handed orthographic projection.
    pub fn ortho(left: f32, right: f32, bottom: f32, top: f32, near: f32, far: f32, depth: DepthRange) Mat4 {
        var out = identity;
        out.cols[0][0] = 2.0 / (right - left);
        out.cols[1][1] = 2.0 / (top - bottom);
        out.cols[3][0] = -(right + left) / (right - left);
        out.cols[3][1] = -(top + bottom) / (top - bottom);
        switch (depth) {
            .neg_one_to_one => {
                out.cols[2][2] = -2.0 / (far - near);
                out.cols[3][2] = -(far + near) / (far - near);
            },
            .zero_to_one => {
                out.cols[2][2] = -1.0 / (far - near);
                out.cols[3][2] = -near / (far - near);
            },
        }
        return out;
    }

    /// Right-handed view matrix looking from `eye` toward `target`.
    pub fn lookAt(eye: Vec3, target: Vec3, up: Vec3) Mat4 {
        const fwd = vec.normalize(target - eye);
        const right = vec.normalize(vec.cross(fwd, up));
        const cam_up = vec.cross(right, fwd);
        return .{ .cols = .{
            .{ right[0], cam_up[0], -fwd[0], 0.0 },
            .{ right[1], cam_up[1], -fwd[1], 0.0 },
            .{ right[2], cam_up[2], -fwd[2], 0.0 },
            .{ -vec.dot(right, eye), -vec.dot(cam_up, eye), vec.dot(fwd, eye), 1.0 },
        } };
    }

    pub fn approxEq(a: Mat4, b: Mat4, tolerance: f32) bool {
        inline for (0..4) |j| {
            if (!vec.approxEq(a.cols[j], b.cols[j], tolerance)) return false;
        }
        return true;
    }
};

test "mat4 identity multiplication" {
    const t = Mat4.translation(.{ 1.0, 2.0, 3.0 });
    try std.testing.expect(Mat4.mul(Mat4.identity, t).approxEq(t, 0.0));
    try std.testing.expect(Mat4.mul(t, Mat4.identity).approxEq(t, 0.0));
}

test "mat4 translation and scaling compose on points" {
    const m = Mat4.mul(Mat4.translation(.{ 10.0, 0.0, 0.0 }), Mat4.scaling(.{ 2.0, 2.0, 2.0 }));
    const p = m.mulPoint(.{ 1.0, 1.0, 1.0 });
    try std.testing.expect(vec.approxEq(p, @as(Vec3, .{ 12.0, 2.0, 2.0 }), scalar.epsilon));
    const d = m.mulDirection(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(d, @as(Vec3, .{ 2.0, 0.0, 0.0 }), scalar.epsilon));
}

test "mat4 rotationZ turns x into y" {
    const m = Mat4.rotationZ(scalar.radians(90.0));
    const p = m.mulPoint(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(p, @as(Vec3, .{ 0.0, 1.0, 0.0 }), 1.0e-5));
}

test "mat4 general inverse round-trips" {
    const m = Mat4.mul(
        Mat4.translation(.{ 3.0, -2.0, 5.0 }),
        Mat4.mul(Mat4.rotationY(0.7), Mat4.scaling(.{ 2.0, 3.0, 4.0 })),
    );
    const inv = m.inverse().?;
    try std.testing.expect(Mat4.mul(m, inv).approxEq(Mat4.identity, 1.0e-4));
    try std.testing.expect(Mat4.scaling(.{ 0.0, 1.0, 1.0 }).inverse() == null);
}

test "mat4 rigid inverse matches general inverse" {
    const m = Mat4.mul(Mat4.translation(.{ 1.0, 2.0, 3.0 }), Mat4.rotationX(0.5));
    const a = m.inverseRigid();
    const b = m.inverse().?;
    try std.testing.expect(a.approxEq(b, 1.0e-5));
}

test "perspective maps near and far per depth convention" {
    const p01 = Mat4.perspective(scalar.radians(60.0), 16.0 / 9.0, 0.1, 100.0, .zero_to_one);
    const near01 = p01.mulVec(.{ 0.0, 0.0, -0.1, 1.0 });
    const far01 = p01.mulVec(.{ 0.0, 0.0, -100.0, 1.0 });
    try std.testing.expect(scalar.approxEq(near01[2] / near01[3], 0.0, 1.0e-5));
    try std.testing.expect(scalar.approxEq(far01[2] / far01[3], 1.0, 1.0e-5));

    const p11 = Mat4.perspective(scalar.radians(60.0), 16.0 / 9.0, 0.1, 100.0, .neg_one_to_one);
    const near11 = p11.mulVec(.{ 0.0, 0.0, -0.1, 1.0 });
    const far11 = p11.mulVec(.{ 0.0, 0.0, -100.0, 1.0 });
    try std.testing.expect(scalar.approxEq(near11[2] / near11[3], -1.0, 1.0e-5));
    try std.testing.expect(scalar.approxEq(far11[2] / far11[3], 1.0, 1.0e-4));
}

test "ortho maps the box corners" {
    const m = Mat4.ortho(-2.0, 2.0, -1.0, 1.0, 0.0, 10.0, .zero_to_one);
    const c = m.mulVec(.{ 2.0, 1.0, -10.0, 1.0 });
    try std.testing.expect(vec.approxEq(c, @as(Vec4, .{ 1.0, 1.0, 1.0, 1.0 }), 1.0e-5));
}

test "lookAt places the eye at the origin looking down negative z" {
    const m = Mat4.lookAt(.{ 0.0, 0.0, 5.0 }, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
    const p = m.mulPoint(.{ 0.0, 0.0, 0.0 });
    try std.testing.expect(vec.approxEq(p, @as(Vec3, .{ 0.0, 0.0, -5.0 }), scalar.epsilon));
}

test "mat3 inverse round-trips and rejects singular" {
    const r = Mat4.rotationY(1.1).toMat3();
    const m = Mat3.mul(r, .{ .cols = .{ .{ 2.0, 0.0, 0.0 }, .{ 0.0, 3.0, 0.0 }, .{ 0.0, 0.0, 4.0 } } });
    const inv = m.inverse().?;
    try std.testing.expect(Mat3.mul(m, inv).approxEq(Mat3.identity, 1.0e-5));
    const singular: Mat3 = .{ .cols = .{ .{ 1.0, 0.0, 0.0 }, .{ 2.0, 0.0, 0.0 }, .{ 0.0, 0.0, 1.0 } } };
    try std.testing.expect(singular.inverse() == null);
}

test "transpose is an involution" {
    const m = Mat4.perspective(1.0, 1.5, 0.1, 50.0, .zero_to_one);
    try std.testing.expect(m.transpose().transpose().approxEq(m, 0.0));
}
