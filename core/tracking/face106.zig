//! The face contour convention the beauty effects consume: one hundred
//! and six points in a fixed order, jaw and brows and eyes and nose and
//! mouth, each expressed here as the mesh vertex closest to it on the
//! canonical face. The table was solved by similarity-aligning the effect
//! engine's own canonical coordinates to the mesh's canonical geometry
//! from the model bundle, nearest vertices taken, the three center line
//! anchors pinned exactly, and every symmetric pair verified to land on
//! mirrored mesh vertices.

const std = @import("std");
const face = @import("face");

pub const point_count = 106;

pub const mesh_index = [point_count]u16{
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

/// Fills the effect engine's landmark layout from tracked mesh landmarks:
/// x then y per point, normalized by the frame size.
pub fn fill(landmarks: *const [face.landmark_count]face.Landmark, width: f32, height: f32, out: *[point_count * 2]f32) void {
    for (mesh_index, 0..) |vertex, at| {
        out[at * 2] = landmarks[vertex].x / width;
        out[at * 2 + 1] = landmarks[vertex].y / height;
    }
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
