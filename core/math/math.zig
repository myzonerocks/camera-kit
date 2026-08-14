//! Camera Kit math: SIMD-friendly linear algebra with zero dependencies and
//! zero allocations. Vectors are bare `@Vector`s so arithmetic operators
//! lower to SIMD.

pub const scalar = @import("scalar.zig");
pub const vec = @import("vec.zig");
pub const mat = @import("mat.zig");

pub const Vec2 = vec.Vec2;
pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;
pub const Mat3 = mat.Mat3;
pub const Mat4 = mat.Mat4;
pub const DepthRange = mat.DepthRange;

test {
    _ = scalar;
    _ = vec;
    _ = mat;
}
