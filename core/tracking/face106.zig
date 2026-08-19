//! The face contour convention the beauty effects consume: one hundred
//! and six points in a fixed order, jaw and brows and eyes and nose and
//! mouth, each expressed here as the mesh vertex closest to it on the
//! canonical face. The table was solved by similarity-aligning the effect
//! engine's own canonical coordinates to the mesh's canonical geometry
//! from the model bundle, nearest vertices taken, the three center line
//! anchors pinned exactly, and every symmetric pair verified to land on
//! mirrored mesh vertices.
//!
//! Five more points follow the raw 106, for regions the face-makeup mesh
//! (lipstick, blush) needs a center point for but no single landmark
//! covers - the mouth opening, each eyebrow, each cheek. Each is that
//! region's own centroid rather than a tracked vertex.

const std = @import("std");
const face = @import("face");

pub const base_point_count = 106;
pub const point_count = 111;

pub const mesh_index = [base_point_count]u16{
    139, 34, 34, 116, 123, 147, 147, 213, 192, 135, 135, 169, 170,
    140, 140, 171, 152, 396, 369, 369, 395, 394, 364, 364, 416, 433,
    376, 376, 352, 345, 264, 264, 368, 71, 68, 104, 105, 66, 296,
    334, 333, 298, 301, 168, 197, 5, 1, 165, 167, 0, 393, 391,
    113, 30, 158, 154, 153, 25, 381, 385, 260, 342, 255, 380, 63,
    63, 52, 65, 295, 282, 293, 293, 29, 144, 160, 259, 373, 387,
    244, 464, 49, 279, 203, 423, 43, 96, 87, 14, 317, 325, 273,
    335, 421, 200, 201, 106, 43, 181, 16, 405, 273, 405, 17, 181,
    160, 387,
};

/// Each hub point (106-110) as the centroid of these already-filled
/// contour indices (0-105), not raw mediapipe landmarks.
const hub_neighbors = [point_count - base_point_count][]const u16{
    &.{ 97, 98, 99, 101, 102, 103 }, // 106: mouth-opening center
    &.{ 34, 35, 36, 65, 66 }, // 107: left eyebrow hub
    &.{ 39, 40, 41, 69, 70 }, // 108: right eyebrow hub
    &.{ 4, 5, 6, 7, 56, 57, 74, 80, 82 }, // 109: left cheek hub
    &.{ 25, 26, 27, 28, 62, 63, 76, 81, 83 }, // 110: right cheek hub
};

/// Fills the effect engine's landmark layout from tracked mesh landmarks:
/// x then y per point, normalized by the frame size, the raw 106 first
/// and then the five derived hub points.
pub fn fill(landmarks: *const [face.landmark_count]face.Landmark, width: f32, height: f32, out: *[point_count * 2]f32) void {
    for (mesh_index, 0..) |vertex, at| {
        out[at * 2] = landmarks[vertex].x / width;
        out[at * 2 + 1] = landmarks[vertex].y / height;
    }
    for (hub_neighbors, 0..) |neighbors, at| {
        var sum_x: f32 = 0;
        var sum_y: f32 = 0;
        for (neighbors) |n| {
            sum_x += out[n * 2];
            sum_y += out[n * 2 + 1];
        }
        const count: f32 = @floatFromInt(neighbors.len);
        out[(base_point_count + at) * 2] = sum_x / count;
        out[(base_point_count + at) * 2 + 1] = sum_y / count;
    }
}

/// Maps a fill()-normalized point from sensor space into the space of
/// a frame drawn with the preview blit's mirror and quarter turns -
/// mirror first, then rotation, the blit's own transform order.
pub fn transformPoint(u: f32, v: f32, rotation_quarter_turns: u32, mirror: bool) [2]f32 {
    var x = u * 2.0 - 1.0;
    const y = 1.0 - v * 2.0;
    if (mirror) x = -x;
    const rotated: [2]f32 = switch (rotation_quarter_turns % 4) {
        0 => .{ x, y },
        1 => .{ -y, x },
        2 => .{ -x, -y },
        3 => .{ y, -x },
        else => unreachable,
    };
    return .{ (rotated[0] + 1.0) * 0.5, (1.0 - rotated[1]) * 0.5 };
}

const t = std.testing;

test "every entry addresses a mesh vertex" {
    for (mesh_index) |vertex| {
        try t.expect(vertex < face.landmark_count);
    }
}

test "the center line anchors are exact" {
    try t.expectEqual(@as(u16, 1), mesh_index[46]); // nose tip
    try t.expectEqual(@as(u16, 168), mesh_index[43]); // between the brows
    try t.expectEqual(@as(u16, 152), mesh_index[16]); // chin
}

test "the eye warp points sit on opposite sides" {
    // The big eye warp reads 74/72 on one side and 77/75 on the other;
    // opposite sides of the face must land on distinct vertices.
    try t.expect(mesh_index[74] != mesh_index[77]);
    try t.expect(mesh_index[72] != mesh_index[75]);
}

test "normalized fill lands inside the unit square for in frame points" {
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = @floatFromInt(at % 640), .y = @floatFromInt(at % 480), .z = 0 };
    }
    var out: [point_count * 2]f32 = undefined;
    fill(&landmarks, 640, 480, &out);
    for (out) |value| {
        try t.expect(value >= 0.0 and value <= 1.0);
    }
}

test "each hub point is exactly its neighbors' centroid" {
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = @floatFromInt((at * 7) % 640), .y = @floatFromInt((at * 11) % 480), .z = 0 };
    }
    var out: [point_count * 2]f32 = undefined;
    fill(&landmarks, 640, 480, &out);
    for (hub_neighbors, 0..) |neighbors, at| {
        var sum_x: f32 = 0;
        var sum_y: f32 = 0;
        for (neighbors) |n| {
            sum_x += out[n * 2];
            sum_y += out[n * 2 + 1];
        }
        const count: f32 = @floatFromInt(neighbors.len);
        const hub = base_point_count + at;
        try t.expectApproxEqAbs(sum_x / count, out[hub * 2], 1e-6);
        try t.expectApproxEqAbs(sum_y / count, out[hub * 2 + 1], 1e-6);
    }
}

test "transformPoint matches the preview blit for every camera pose" {
    const eps = 1e-6;
    // No rotation, no mirror: identity.
    const id = transformPoint(0.25, 0.75, 0, false);
    try t.expectApproxEqAbs(@as(f32, 0.25), id[0], eps);
    try t.expectApproxEqAbs(@as(f32, 0.75), id[1], eps);
    // Rear camera (3 quarter turns, unmirrored): (u, v) -> (1 - v, u).
    const rear = transformPoint(0.25, 0.75, 3, false);
    try t.expectApproxEqAbs(@as(f32, 0.25), rear[0], eps);
    try t.expectApproxEqAbs(@as(f32, 0.25), rear[1], eps);
    // Front camera (1 quarter turn, mirrored): (u, v) -> (v, u).
    const front = transformPoint(0.25, 0.75, 1, true);
    try t.expectApproxEqAbs(@as(f32, 0.75), front[0], eps);
    try t.expectApproxEqAbs(@as(f32, 0.25), front[1], eps);
    // Mirror alone flips only the horizontal axis.
    const mirrored = transformPoint(0.25, 0.75, 0, true);
    try t.expectApproxEqAbs(@as(f32, 0.75), mirrored[0], eps);
    try t.expectApproxEqAbs(@as(f32, 0.75), mirrored[1], eps);
    // A half turn flips both axes.
    const half = transformPoint(0.25, 0.75, 2, false);
    try t.expectApproxEqAbs(@as(f32, 0.75), half[0], eps);
    try t.expectApproxEqAbs(@as(f32, 0.25), half[1], eps);
}

test "transformPoint stays inside the unit square" {
    var rotation: u32 = 0;
    while (rotation < 4) : (rotation += 1) {
        for ([_]bool{ false, true }) |mirror| {
            for ([_][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 }, .{ 0.5, 0.5 } }) |p| {
                const out = transformPoint(p[0], p[1], rotation, mirror);
                try t.expect(out[0] >= 0.0 and out[0] <= 1.0);
                try t.expect(out[1] >= 0.0 and out[1] <= 1.0);
            }
        }
    }
}
