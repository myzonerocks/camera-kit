//! Gosslens math: SIMD-friendly linear algebra with zero dependencies and
//! zero allocations. Vectors are bare `@Vector`s so arithmetic operators
//! lower to SIMD.

pub const scalar = @import("scalar.zig");
pub const vec = @import("vec.zig");
pub const matrix = @import("matrix.zig");
pub const quat = @import("quat.zig");
pub const pose = @import("pose.zig");
pub const color = @import("color.zig");
pub const fit = @import("fit.zig");

pub const Vec2 = vec.Vec2;
pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;
pub const Mat3 = matrix.Mat3;
pub const Mat4 = matrix.Mat4;
pub const DepthRange = matrix.DepthRange;
pub const Quat = quat.Quat;
pub const Pose = pose.Pose;

test {
    _ = scalar;
    _ = vec;
    _ = matrix;
    _ = quat;
    _ = pose;
    _ = color;
}
