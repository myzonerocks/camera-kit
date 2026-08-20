//! The deterministic replay world source: a synthetic camera orbit
//! around an anchor at the origin, the host-side proof feed for the
//! world seam. Same frame in, same pose out, always.

const std = @import("std");
const matrix = @import("math").matrix;

pub const Mat4 = matrix.Mat4;

pub const State = struct {
    /// 0 unavailable, 1 initializing, 2 tracking, 3 limited.
    tracking_state: u32,
    world_from_camera: Mat4,
    projection: Mat4,
    timestamp_us: i64,
};

/// The pose track: two warmup frames report initializing, then the
/// camera orbits the origin at radius 2 and height 0.6, always looking
/// at the anchor. Frame count and step are the caller's contract.
pub fn stateAt(frame_index: u32, frame_step_us: i64, aspect_ratio: f32) State {
    const timestamp_us = @as(i64, frame_index + 1) * frame_step_us;
    if (frame_index < 2) {
        return .{
            .tracking_state = 1,
            .world_from_camera = Mat4.identity,
            .projection = Mat4.perspective(std.math.degreesToRadians(60.0), aspect_ratio, 0.1, 100.0, .zero_to_one),
            .timestamp_us = timestamp_us,
        };
    }
    const angle = @as(f32, @floatFromInt(frame_index - 2)) * 0.15;
    const eye = .{ 2.0 * @sin(angle), 0.6, 2.0 * @cos(angle) };
    const camera_from_world = Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
    return .{
        .tracking_state = 2,
        .world_from_camera = camera_from_world.inverseRigid(),
        .projection = Mat4.perspective(std.math.degreesToRadians(60.0), aspect_ratio, 0.1, 100.0, .zero_to_one),
        .timestamp_us = timestamp_us,
    };
}

const t = std.testing;

test "warmup frames initialize, orbit frames track" {
    try t.expectEqual(@as(u32, 1), stateAt(0, 33_333, 1.0).tracking_state);
    try t.expectEqual(@as(u32, 2), stateAt(2, 33_333, 1.0).tracking_state);
}

test "the anchor at origin stays in front of the orbiting camera" {
    for (2..40) |i| {
        const state = stateAt(@intCast(i), 33_333, 4.0 / 3.0);
        const camera_from_world = state.world_from_camera.inverseRigid();
        const anchor_in_camera = camera_from_world.mulPoint(.{ 0.0, 0.0, 0.0 });
        // Looking down negative z: the origin must sit ahead of the
        // camera at the orbit distance.
        try t.expect(anchor_in_camera[2] < 0);
        const distance = @sqrt(anchor_in_camera[0] * anchor_in_camera[0] + anchor_in_camera[1] * anchor_in_camera[1] + anchor_in_camera[2] * anchor_in_camera[2]);
        try t.expectApproxEqAbs(@as(f32, 2.0881), distance, 0.01);
    }
}

test "determinism holds across calls" {
    const a = stateAt(17, 33_333, 1.5);
    const b = stateAt(17, 33_333, 1.5);
    try t.expectEqual(a.world_from_camera.cols, b.world_from_camera.cols);
    try t.expectEqual(a.timestamp_us, b.timestamp_us);
}
