//! Face pipeline geometry: how a detection or a previous frame's landmarks
//! become the aligned crop the landmark model reads, and how its output
//! maps back into frame pixels. The constants mirror the task graphs the
//! pinned models ship with: eye keypoints steer rotation to a level face,
//! crops are squares on the long side scaled by one and a half, and the
//! blendshape model reads a fixed 146 landmark subset as pixel pairs.

const std = @import("std");
const sampler = @import("sampler");
const detector = @import("detector");

pub const landmark_count = 478;
pub const blendshape_count = 52;
pub const region_scale = 1.5;

pub const Landmark = struct { x: f32, y: f32, z: f32 };

/// One published tracking result, the shape that crosses the C boundary.
/// Landmarks are x, y in frame pixels and z in the same scale; a zero
/// landmark count means the frame held no face. The layout is frozen.
pub const Result = extern struct {
    frame_serial: u64,
    timestamp_us: i64,
    presence: f32,
    landmark_count_out: u32,
    landmarks: [landmark_count * 3]f32,
    blendshapes: [blendshape_count]f32,
};

comptime {
    std.debug.assert(@sizeOf(Result) == 5968);
    std.debug.assert(@offsetOf(Result, "presence") == 16);
    std.debug.assert(@offsetOf(Result, "landmarks") == 24);
    std.debug.assert(@offsetOf(Result, "blendshapes") == 24 + landmark_count * 3 * 4);
}

/// Indices of the landmarks the blendshape model consumes, in its input
/// order. The subset is part of the model's contract, fixed at training.
pub const blendshape_subset = [146]u16{
    0,   1,   4,   5,   6,   7,   8,   10,  13,  14,  17,  21,  33,
    37,  39,  40,  46,  52,  53,  54,  55,  58,  61,  63,  65,  66,
    67,  70,  78,  80,  81,  82,  84,  87,  88,  91,  93,  95,  103,
    105, 107, 109, 127, 132, 133, 136, 144, 145, 146, 148, 149, 150,
    152, 153, 154, 155, 157, 158, 159, 160, 161, 162, 163, 168, 172,
    173, 176, 178, 181, 185, 191, 195, 197, 234, 246, 249, 251, 263,
    267, 269, 270, 276, 282, 283, 284, 285, 288, 291, 293, 295, 296,
    297, 300, 308, 310, 311, 312, 314, 317, 318, 321, 323, 324, 332,
    334, 336, 338, 356, 361, 362, 365, 373, 374, 375, 377, 378, 379,
    380, 381, 382, 384, 385, 386, 387, 388, 389, 390, 397, 398, 400,
    402, 405, 409, 415, 454, 466, 468, 469, 470, 471, 472, 473, 474,
    475, 476, 477,
};

/// Landmark pair steering the tracking crop's rotation: the eye outer
/// corners, leveled to zero degrees.
pub const rotation_start_landmark = 33;
pub const rotation_end_landmark = 263;

/// The square the detector samples: the whole frame, centered, padded to
/// square on the long side.
pub fn frameSquare(width: u32, height: u32) sampler.Region {
    return .{
        .center_x = @as(f32, @floatFromInt(width)) * 0.5,
        .center_y = @as(f32, @floatFromInt(height)) * 0.5,
        .side = @floatFromInt(@max(width, height)),
        .rotation = 0,
    };
}

fn mapToFrame(square: sampler.Region, u: f32, v: f32) [2]f32 {
    return .{
        square.center_x + (u - 0.5) * square.side,
        square.center_y + (v - 0.5) * square.side,
    };
}

fn levelRotation(dx: f32, dy: f32) f32 {
    // Zero when the steering segment lies level in the image; the sign
    // convention matches the task graph's target angle of zero degrees.
    return -std.math.atan2(-dy, dx);
}

/// The aligned landmark crop for a fresh detection, in frame pixels.
/// Detection coordinates are normalized to the detector's input square.
pub fn regionFromDetection(detection: detector.Detection, square: sampler.Region) sampler.Region {
    const eye_right = mapToFrame(square, detection.keypoints[0][0], detection.keypoints[0][1]);
    const eye_left = mapToFrame(square, detection.keypoints[1][0], detection.keypoints[1][1]);
    const center = mapToFrame(square, detection.x, detection.y);
    const long_side = @max(detection.width, detection.height) * square.side;
    return .{
        .center_x = center[0],
        .center_y = center[1],
        .side = long_side * region_scale,
        .rotation = levelRotation(eye_left[0] - eye_right[0], eye_left[1] - eye_right[1]),
    };
}

/// The next frame's crop from this frame's landmarks, which keeps the
/// model tracking without re-running detection while the face holds.
pub fn regionFromLandmarks(landmarks: *const [landmark_count]Landmark) sampler.Region {
    var min_x = landmarks[0].x;
    var max_x = landmarks[0].x;
    var min_y = landmarks[0].y;
    var max_y = landmarks[0].y;
    for (landmarks[1..]) |landmark| {
        min_x = @min(min_x, landmark.x);
        max_x = @max(max_x, landmark.x);
        min_y = @min(min_y, landmark.y);
        max_y = @max(max_y, landmark.y);
    }
    const start = landmarks[rotation_start_landmark];
    const end = landmarks[rotation_end_landmark];
    return .{
        .center_x = (min_x + max_x) * 0.5,
        .center_y = (min_y + max_y) * 0.5,
        .side = @max(max_x - min_x, max_y - min_y) * region_scale,
        .rotation = levelRotation(end.x - start.x, end.y - start.y),
    };
}

/// Maps the landmark model's raw output, in crop input pixels, back into
/// frame pixels through the crop's rotation and scale.
pub fn decodeLandmarks(raw: []const f32, region: sampler.Region, input_side: f32, out: *[landmark_count]Landmark) void {
    std.debug.assert(raw.len >= landmark_count * 3);
    const cos = @cos(region.rotation);
    const sin = @sin(region.rotation);
    const scale = region.side / input_side;
    for (out, 0..) |*landmark, at| {
        const u = raw[at * 3] / input_side - 0.5;
        const v = raw[at * 3 + 1] / input_side - 0.5;
        landmark.* = .{
            .x = region.center_x + (u * cos - v * sin) * region.side,
            .y = region.center_y + (u * sin + v * cos) * region.side,
            .z = raw[at * 3 + 2] * scale,
        };
    }
}

/// Assembles the blendshape model's input: the subset landmarks as pixel
/// coordinate pairs, in subset order.
pub fn blendshapeInput(landmarks: *const [landmark_count]Landmark, out: *[blendshape_subset.len * 2]f32) void {
    for (blendshape_subset, 0..) |index, at| {
        out[at * 2] = landmarks[index].x;
        out[at * 2 + 1] = landmarks[index].y;
    }
}

const t = std.testing;

test "the blendshape subset is strictly increasing within the mesh" {
    var previous: i32 = -1;
    for (blendshape_subset) |index| {
        try t.expect(index > previous);
        previous = index;
    }
    try t.expect(blendshape_subset[blendshape_subset.len - 1] < landmark_count);
}

test "level eyes produce an unrotated crop" {
    var detection = std.mem.zeroes(detector.Detection);
    detection.x = 0.5;
    detection.y = 0.5;
    detection.width = 0.4;
    detection.height = 0.3;
    detection.keypoints[0] = .{ 0.4, 0.5 };
    detection.keypoints[1] = .{ 0.6, 0.5 };
    const square = frameSquare(640, 480);
    const region = regionFromDetection(detection, square);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 320.0), region.center_x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 240.0), region.center_y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0.4 * 640.0 * region_scale), region.side, 1e-3);
}

test "a tilted eye line rotates the crop level" {
    var detection = std.mem.zeroes(detector.Detection);
    detection.keypoints[0] = .{ 0.5, 0.5 };
    detection.keypoints[1] = .{ 0.5, 0.6 }; // left eye straight below right
    const region = regionFromDetection(detection, frameSquare(100, 100));
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), @abs(region.rotation), 1e-5);
}

test "landmark decode through an identity region is a rescale" {
    var raw: [landmark_count * 3]f32 = undefined;
    for (0..landmark_count) |at| {
        raw[at * 3] = 128;
        raw[at * 3 + 1] = 64;
        raw[at * 3 + 2] = 8;
    }
    const region: sampler.Region = .{ .center_x = 100, .center_y = 100, .side = 256, .rotation = 0 };
    var out: [landmark_count]Landmark = undefined;
    decodeLandmarks(&raw, region, 256, &out);
    try t.expectApproxEqAbs(@as(f32, 100.0), out[0].x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 100.0 - 64.0), out[0].y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 8.0), out[0].z, 1e-3);
}

test "tracking region covers the landmarks with headroom" {
    var landmarks: [landmark_count]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        const angle = @as(f32, @floatFromInt(at)) * 0.013;
        landmark.* = .{ .x = 200 + 50 * @cos(angle), .y = 300 + 40 * @sin(angle), .z = 0 };
    }
    const region = regionFromLandmarks(&landmarks);
    try t.expectApproxEqAbs(@as(f32, 200.0), region.center_x, 1.0);
    try t.expectApproxEqAbs(@as(f32, 300.0), region.center_y, 1.0);
    try t.expect(region.side > 100.0 and region.side < 200.0);
}

test "blendshape input gathers subset pairs in order" {
    var landmarks: [landmark_count]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = @floatFromInt(at), .y = @floatFromInt(at * 2), .z = 0 };
    }
    var out: [blendshape_subset.len * 2]f32 = undefined;
    blendshapeInput(&landmarks, &out);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, @floatFromInt(blendshape_subset[12])), out[24], 1e-6);
    try t.expectApproxEqAbs(@as(f32, @floatFromInt(blendshape_subset[145] * 2)), out[291], 1e-6);
}
