//! Scalar helpers shared across the math module. Everything here is pure,
//! allocation-free, and deterministic for identical inputs on a target.

const std = @import("std");

pub const epsilon: f32 = 1.0e-6;

pub fn radians(degrees_in: f32) f32 {
    return degrees_in * (std.math.pi / 180.0);
}

pub fn degrees(radians_in: f32) f32 {
    return radians_in * (180.0 / std.math.pi);
}

pub fn lerp(a: f32, b: f32, t: f32) f32 {
    return @mulAdd(f32, b - a, t, a);
}

pub fn clamp01(x: f32) f32 {
    return std.math.clamp(x, 0.0, 1.0);
}

/// Hermite smoothing between two edges; clamps outside the range.
pub fn smoothstep(edge0: f32, edge1: f32, x: f32) f32 {
    const t = clamp01((x - edge0) / (edge1 - edge0));
    return t * t * (3.0 - 2.0 * t);
}

pub fn approxEq(a: f32, b: f32, tolerance: f32) bool {
    return @abs(a - b) <= tolerance;
}

test "lerp endpoints and midpoint" {
    try std.testing.expectEqual(@as(f32, 2.0), lerp(2.0, 8.0, 0.0));
    try std.testing.expectEqual(@as(f32, 8.0), lerp(2.0, 8.0, 1.0));
    try std.testing.expectEqual(@as(f32, 5.0), lerp(2.0, 8.0, 0.5));
}

test "smoothstep clamps and is monotonic at edges" {
    try std.testing.expectEqual(@as(f32, 0.0), smoothstep(0.0, 1.0, -1.0));
    try std.testing.expectEqual(@as(f32, 1.0), smoothstep(0.0, 1.0, 2.0));
    try std.testing.expectEqual(@as(f32, 0.5), smoothstep(0.0, 1.0, 0.5));
}

test "radians and degrees round-trip" {
    try std.testing.expect(approxEq(degrees(radians(73.5)), 73.5, 1.0e-4));
}
