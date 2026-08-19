//! Hand pipeline geometry: how a palm detection or a previous frame's
//! landmarks become the aligned crop the hand landmark model reads. The
//! constants mirror the pinned models' task graphs; the wrist-to-middle
//! direction steers rotation so the hand points up in the crop.

const std = @import("std");
const sampler = @import("sampler");
const detector = @import("detector");

pub const landmark_count = 21;
pub const max_hands = 2;

pub const Landmark = sampler.Landmark;

/// The crop points the hand up: the steering segment's target angle is a
/// quarter turn, where the face pipeline levels its segment to zero.
const target_angle = std.math.pi * 0.5;

/// Palm-detection crop: rotation from the wrist center to the middle
/// finger keypoint, then the detection box shifted half its height up
/// along the rotated hand axis, squared to its long side, scaled 2.6.
const palm_rotation_start_keypoint = 0;
const palm_rotation_end_keypoint = 2;
const palm_shift_y = -0.5;
const palm_scale = 2.6;

/// Tracking crop from landmarks: shifted a tenth of the box up along the
/// rotated hand axis, squared to its long side, scaled 2.0.
const landmarks_shift_y = -0.1;
const landmarks_scale = 2.0;

/// One tracked hand as published. handedness is the model's score that
/// this is a right hand; landmarks are x, y in frame pixels and z in the
/// same scale. The layout is frozen.
pub const Hand = extern struct {
    presence: f32,
    handedness: f32,
    landmarks: [landmark_count * 3]f32,
};

/// One published hand tracking result, the shape that crosses the C
/// boundary. A zero hand count means the frame held no hands. The layout
/// is frozen.
pub const Result = extern struct {
    frame_serial: u64,
    timestamp_us: i64,
    hand_count: u32,
    reserved: u32,
    hands: [max_hands]Hand,
};

comptime {
    std.debug.assert(@sizeOf(Hand) == 8 + landmark_count * 3 * 4);
    std.debug.assert(@offsetOf(Result, "hand_count") == 16);
    std.debug.assert(@offsetOf(Result, "hands") == 24);
    std.debug.assert(@sizeOf(Result) == 24 + max_hands * @sizeOf(Hand));
}

fn mapToFrame(square: sampler.Region, u: f32, v: f32) [2]f32 {
    return .{
        square.center_x + (u - 0.5) * square.side,
        square.center_y + (v - 0.5) * square.side,
    };
}

fn handUpRotation(dx: f32, dy: f32) f32 {
    return normalizeRadians(target_angle - std.math.atan2(-dy, dx));
}

fn normalizeRadians(angle: f32) f32 {
    return angle - 2.0 * std.math.pi * @floor((angle + std.math.pi) / (2.0 * std.math.pi));
}

/// Shifts a rect's center along its own rotated axes, squares it to the
/// long side, and scales it - one transformation contract shared by the
/// detection and tracking crops, differing only in constants.
fn transformRect(center_x: f32, center_y: f32, width: f32, height: f32, rotation: f32, shift_y: f32, scale: f32) sampler.Region {
    const cos = @cos(rotation);
    const sin = @sin(rotation);
    return .{
        .center_x = center_x - height * shift_y * sin,
        .center_y = center_y + height * shift_y * cos,
        .side = @max(width, height) * scale,
        .rotation = rotation,
    };
}

/// The aligned landmark crop for a fresh palm detection, in frame pixels.
/// Detection coordinates are normalized to the detector's input square.
pub fn regionFromDetection(detection: detector.palm.Detection, square: sampler.Region) sampler.Region {
    const wrist = mapToFrame(square, detection.keypoints[palm_rotation_start_keypoint][0], detection.keypoints[palm_rotation_start_keypoint][1]);
    const middle = mapToFrame(square, detection.keypoints[palm_rotation_end_keypoint][0], detection.keypoints[palm_rotation_end_keypoint][1]);
    const center = mapToFrame(square, detection.x, detection.y);
    const rotation = handUpRotation(middle[0] - wrist[0], middle[1] - wrist[1]);
    return transformRect(
        center[0],
        center[1],
        detection.width * square.side,
        detection.height * square.side,
        rotation,
        palm_shift_y,
        palm_scale,
    );
}

/// The next frame's crop from this frame's landmarks. Rotation steers
/// from the wrist toward the midpoint of the midpoint of two finger
/// joints with the third - the exact blend the shipped graph computes -
/// and the box is the landmark bounds in the rotated frame, reprojected.
pub fn regionFromLandmarks(landmarks: *const [landmark_count]Landmark) sampler.Region {
    const wrist = landmarks[0];
    var toward_x = (landmarks[4].x + landmarks[8].x) * 0.5;
    var toward_y = (landmarks[4].y + landmarks[8].y) * 0.5;
    toward_x = (toward_x + landmarks[6].x) * 0.5;
    toward_y = (toward_y + landmarks[6].y) * 0.5;
    const rotation = handUpRotation(toward_x - wrist.x, toward_y - wrist.y);

    // Bounds in the rotated frame, so the box hugs the leveled hand.
    const cos = @cos(-rotation);
    const sin = @sin(-rotation);
    var min_x = std.math.floatMax(f32);
    var max_x = -std.math.floatMax(f32);
    var min_y = std.math.floatMax(f32);
    var max_y = -std.math.floatMax(f32);
    for (landmarks) |landmark| {
        const x = landmark.x * cos - landmark.y * sin;
        const y = landmark.x * sin + landmark.y * cos;
        min_x = @min(min_x, x);
        max_x = @max(max_x, x);
        min_y = @min(min_y, y);
        max_y = @max(max_y, y);
    }
    const projected_x = (min_x + max_x) * 0.5;
    const projected_y = (min_y + max_y) * 0.5;
    const center_x = projected_x * @cos(rotation) - projected_y * @sin(rotation);
    const center_y = projected_x * @sin(rotation) + projected_y * @cos(rotation);
    return transformRect(
        center_x,
        center_y,
        max_x - min_x,
        max_y - min_y,
        rotation,
        landmarks_shift_y,
        landmarks_scale,
    );
}

/// Maps the landmark model's raw output, in crop input pixels, back into
/// frame pixels through the crop's rotation and scale.
pub fn decodeLandmarks(raw: []const f32, region: sampler.Region, input_side: f32, out: *[landmark_count]Landmark) void {
    sampler.decodeLandmarks(landmark_count, raw, region, input_side, out);
}

const t = std.testing;

fn upwardHandLandmarks() [landmark_count]Landmark {
    // A synthetic upright hand: wrist at the bottom, fingers above, the
    // steering joints straight up from the wrist.
    var landmarks: [landmark_count]Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        const column = @as(f32, @floatFromInt(at % 5)) * 10.0;
        const row = @as(f32, @floatFromInt(at / 5)) * 20.0;
        landmark.* = .{ .x = 300 + column - 20, .y = 400 - row, .z = 0 };
    }
    landmarks[0] = .{ .x = 320, .y = 400, .z = 0 };
    landmarks[4] = .{ .x = 320, .y = 330, .z = 0 };
    landmarks[6] = .{ .x = 320, .y = 320, .z = 0 };
    landmarks[8] = .{ .x = 320, .y = 330, .z = 0 };
    return landmarks;
}

test "an upright palm detection produces an unrotated crop above the wrist" {
    var detection = std.mem.zeroes(detector.palm.Detection);
    detection.x = 0.5;
    detection.y = 0.5;
    detection.width = 0.2;
    detection.height = 0.2;
    detection.keypoints[palm_rotation_start_keypoint] = .{ 0.5, 0.6 };
    detection.keypoints[palm_rotation_end_keypoint] = .{ 0.5, 0.4 }; // middle finger above the wrist
    const square = sampler.frameSquare(640, 480);
    const region = regionFromDetection(detection, square);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-5);
    try t.expectApproxEqAbs(@as(f32, 320.0), region.center_x, 1e-3);
    // Shifted half the box height up, toward the fingers.
    try t.expectApproxEqAbs(@as(f32, 240.0 + palm_shift_y * 0.2 * 640.0), region.center_y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 0.2 * 640.0 * palm_scale), region.side, 1e-3);
}

test "a sideways hand rotates the crop upright" {
    var detection = std.mem.zeroes(detector.palm.Detection);
    detection.x = 0.5;
    detection.y = 0.5;
    detection.width = 0.2;
    detection.height = 0.2;
    detection.keypoints[palm_rotation_start_keypoint] = .{ 0.4, 0.5 };
    detection.keypoints[palm_rotation_end_keypoint] = .{ 0.6, 0.5 }; // fingers point right
    const region = regionFromDetection(detection, sampler.frameSquare(100, 100));
    try t.expectApproxEqAbs(@as(f32, std.math.pi / 2.0), region.rotation, 1e-5);
}

test "the tracking crop covers upright landmarks with headroom" {
    const landmarks = upwardHandLandmarks();
    const region = regionFromLandmarks(&landmarks);
    try t.expectApproxEqAbs(@as(f32, 0.0), region.rotation, 1e-4);
    var min_x = landmarks[0].x;
    var max_x = landmarks[0].x;
    var min_y = landmarks[0].y;
    var max_y = landmarks[0].y;
    for (landmarks) |landmark| {
        min_x = @min(min_x, landmark.x);
        max_x = @max(max_x, landmark.x);
        min_y = @min(min_y, landmark.y);
        max_y = @max(max_y, landmark.y);
    }
    try t.expect(region.side >= @max(max_x - min_x, max_y - min_y) * (landmarks_scale - 0.01));
    try t.expect(region.center_x > min_x and region.center_x < max_x);
    // Shifted up along the hand, so the center sits above the box middle.
    try t.expect(region.center_y < (min_y + max_y) * 0.5);
}

test "landmark decode through an identity region is a rescale" {
    var raw: [landmark_count * 3]f32 = undefined;
    for (0..landmark_count) |at| {
        raw[at * 3] = 112;
        raw[at * 3 + 1] = 56;
        raw[at * 3 + 2] = 4;
    }
    const region: sampler.Region = .{ .center_x = 100, .center_y = 100, .side = 224, .rotation = 0 };
    var out: [landmark_count]Landmark = undefined;
    decodeLandmarks(&raw, region, 224, &out);
    try t.expectApproxEqAbs(@as(f32, 100.0), out[0].x, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 100.0 - 56.0), out[0].y, 1e-3);
    try t.expectApproxEqAbs(@as(f32, 4.0), out[0].z, 1e-3);
}

test "the frozen result layout holds" {
    var result = std.mem.zeroes(Result);
    result.hand_count = 1;
    result.hands[0].presence = 0.9;
    try t.expectEqual(@as(usize, 24 + 2 * (8 + 21 * 3 * 4)), @sizeOf(Result));
    try t.expectApproxEqAbs(@as(f32, 0.9), result.hands[0].presence, 1e-6);
}
