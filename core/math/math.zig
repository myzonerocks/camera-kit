//! Camera Kit math: SIMD-friendly linear algebra with zero dependencies and
//! zero allocations. Vectors are bare `@Vector`s so arithmetic operators
//! lower to SIMD.

pub const scalar = @import("scalar.zig");
pub const vec = @import("vec.zig");

pub const Vec2 = vec.Vec2;
pub const Vec3 = vec.Vec3;
pub const Vec4 = vec.Vec4;

test {
    _ = scalar;
    _ = vec;
}
