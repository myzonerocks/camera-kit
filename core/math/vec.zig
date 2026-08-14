//! Vector types are bare `@Vector`s so `+ - * /` compile straight to SIMD;
//! the functions here cover what operators cannot. All functions are pure
//! and allocation-free, and generic over the vector length where the
//! operation is length-agnostic.

const std = @import("std");
const scalar = @import("scalar.zig");

pub const Vec2 = @Vector(2, f32);
pub const Vec3 = @Vector(3, f32);
pub const Vec4 = @Vector(4, f32);

fn VecLen(comptime V: type) comptime_int {
    return @typeInfo(V).vector.len;
}

pub fn splat(comptime V: type, value: f32) V {
    return @splat(value);
}

pub fn dot(a: anytype, b: @TypeOf(a)) f32 {
    return @reduce(.Add, a * b);
}

pub fn lengthSq(v: anytype) f32 {
    return dot(v, v);
}

pub fn length(v: anytype) f32 {
    return @sqrt(lengthSq(v));
}

pub fn distance(a: anytype, b: @TypeOf(a)) f32 {
    return length(b - a);
}

/// Asserts the vector is not near zero; use `normalizeOrZero` for
/// measurement-derived data that may legitimately vanish.
pub fn normalize(v: anytype) @TypeOf(v) {
    const len = length(v);
    std.debug.assert(len > scalar.epsilon);
    return v / splat(@TypeOf(v), len);
}

pub fn normalizeOrZero(v: anytype) @TypeOf(v) {
    const len = length(v);
    if (len <= scalar.epsilon) return splat(@TypeOf(v), 0.0);
    return v / splat(@TypeOf(v), len);
}

pub fn lerp(a: anytype, b: @TypeOf(a), t: f32) @TypeOf(a) {
    const V = @TypeOf(a);
    return @mulAdd(V, b - a, splat(V, t), a);
}

pub fn cross(a: Vec3, b: Vec3) Vec3 {
    const yzx = [3]i32{ 1, 2, 0 };
    const zxy = [3]i32{ 2, 0, 1 };
    const a_yzx = @shuffle(f32, a, undefined, yzx);
    const a_zxy = @shuffle(f32, a, undefined, zxy);
    const b_yzx = @shuffle(f32, b, undefined, yzx);
    const b_zxy = @shuffle(f32, b, undefined, zxy);
    return a_yzx * b_zxy - a_zxy * b_yzx;
}

/// Reflects `v` about unit normal `n`.
pub fn reflect(v: Vec3, n: Vec3) Vec3 {
    return v - splat(Vec3, 2.0 * dot(v, n)) * n;
}

pub fn approxEq(a: anytype, b: @TypeOf(a), tolerance: f32) bool {
    inline for (0..VecLen(@TypeOf(a))) |i| {
        if (!scalar.approxEq(a[i], b[i], tolerance)) return false;
    }
    return true;
}

/// Widens a Vec3 into a Vec4 with the given w; the layout matches column
/// vectors used by `mat`.
pub fn vec4From3(v: Vec3, w: f32) Vec4 {
    return .{ v[0], v[1], v[2], w };
}

pub fn vec3From4(v: Vec4) Vec3 {
    return .{ v[0], v[1], v[2] };
}

test "dot and length" {
    const a: Vec3 = .{ 1.0, 2.0, 3.0 };
    const b: Vec3 = .{ 4.0, -5.0, 6.0 };
    try std.testing.expectEqual(@as(f32, 12.0), dot(a, b));
    try std.testing.expectEqual(@as(f32, 25.0), lengthSq(@as(Vec3, .{ 3.0, 4.0, 0.0 })));
    try std.testing.expectEqual(@as(f32, 5.0), length(@as(Vec3, .{ 3.0, 4.0, 0.0 })));
}

test "cross follows the right-hand rule" {
    const x: Vec3 = .{ 1.0, 0.0, 0.0 };
    const y: Vec3 = .{ 0.0, 1.0, 0.0 };
    const z: Vec3 = .{ 0.0, 0.0, 1.0 };
    try std.testing.expect(approxEq(cross(x, y), z, scalar.epsilon));
    try std.testing.expect(approxEq(cross(y, z), x, scalar.epsilon));
    try std.testing.expect(approxEq(cross(z, x), y, scalar.epsilon));
    try std.testing.expect(approxEq(cross(x, x), splat(Vec3, 0.0), scalar.epsilon));
}

test "normalize produces unit length and guards zero" {
    const v: Vec3 = .{ 0.0, 3.0, 4.0 };
    try std.testing.expect(scalar.approxEq(length(normalize(v)), 1.0, scalar.epsilon));
    try std.testing.expect(approxEq(normalizeOrZero(splat(Vec3, 0.0)), splat(Vec3, 0.0), 0.0));
}

test "lerp endpoints for vectors" {
    const a: Vec4 = .{ 1.0, 2.0, 3.0, 4.0 };
    const b: Vec4 = .{ 5.0, 6.0, 7.0, 8.0 };
    try std.testing.expect(approxEq(lerp(a, b, 0.0), a, 0.0));
    try std.testing.expect(approxEq(lerp(a, b, 1.0), b, 0.0));
    try std.testing.expect(approxEq(lerp(a, b, 0.5), @as(Vec4, .{ 3.0, 4.0, 5.0, 6.0 }), scalar.epsilon));
}

test "reflect bounces off a plane" {
    const v: Vec3 = .{ 1.0, -1.0, 0.0 };
    const n: Vec3 = .{ 0.0, 1.0, 0.0 };
    try std.testing.expect(approxEq(reflect(v, n), @as(Vec3, .{ 1.0, 1.0, 0.0 }), scalar.epsilon));
}
