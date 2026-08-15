//! The tracking loop's state. Detection is expensive and runs only when
//! nothing is being tracked; while a face holds, each frame's crop comes
//! from the previous frame's landmarks and the landmark model alone keeps
//! the lock. A presence score under the floor drops the lock and the next
//! frame goes back through detection.

const std = @import("std");
const sampler = @import("sampler");
const face = @import("face");

/// The landmark model's presence output decides whether the lock holds.
/// One floor for both directions matches the task defaults; hysteresis
/// lives in the score itself, which saturates well above the floor on any
/// actual face.
pub const presence_floor = 0.5;

pub const Status = enum { searching, tracking };

pub const Tracker = struct {
    region: ?sampler.Region = null,

    /// The crop to run the landmark model on this frame, or null when
    /// detection must run first.
    pub fn cropForFrame(tracker: *const Tracker) ?sampler.Region {
        return tracker.region;
    }

    pub fn status(tracker: *const Tracker) Status {
        return if (tracker.region == null) .searching else .tracking;
    }

    /// A fresh detection opens a lock; the crop comes from the detection
    /// geometry until the first landmark pass refines it.
    pub fn onDetection(tracker: *Tracker, detection_region: sampler.Region) void {
        tracker.region = detection_region;
    }

    /// Landmark output either refines the next frame's crop or drops the
    /// lock when the model reports the face gone.
    pub fn onLandmarks(tracker: *Tracker, presence: f32, landmarks: *const [face.landmark_count]face.Landmark) Status {
        if (presence < presence_floor) {
            tracker.region = null;
            return .searching;
        }
        tracker.region = face.regionFromLandmarks(landmarks);
        return .tracking;
    }

    pub fn reset(tracker: *Tracker) void {
        tracker.region = null;
    }
};

const t = std.testing;

fn syntheticLandmarks() [face.landmark_count]face.Landmark {
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        const angle = @as(f32, @floatFromInt(at)) * 0.0132;
        landmark.* = .{ .x = 320 + 80 * @cos(angle), .y = 240 + 60 * @sin(angle), .z = 0 };
    }
    return landmarks;
}

test "a tracker starts searching and locks on detection" {
    var tracker: Tracker = .{};
    try t.expectEqual(Status.searching, tracker.status());
    try t.expectEqual(@as(?sampler.Region, null), tracker.cropForFrame());
    tracker.onDetection(.{ .center_x = 320, .center_y = 240, .side = 200, .rotation = 0 });
    try t.expectEqual(Status.tracking, tracker.status());
    try t.expect(tracker.cropForFrame() != null);
}

test "confident landmarks refine the crop and keep the lock" {
    var tracker: Tracker = .{};
    tracker.onDetection(.{ .center_x = 0, .center_y = 0, .side = 1000, .rotation = 0 });
    const landmarks = syntheticLandmarks();
    try t.expectEqual(Status.tracking, tracker.onLandmarks(0.98, &landmarks));
    const crop = tracker.cropForFrame().?;
    try t.expectApproxEqAbs(@as(f32, 320.0), crop.center_x, 1.0);
    try t.expectApproxEqAbs(@as(f32, 240.0), crop.center_y, 1.0);
    try t.expect(crop.side < 1000);
}

test "a low presence score drops the lock" {
    var tracker: Tracker = .{};
    tracker.onDetection(.{ .center_x = 0, .center_y = 0, .side = 100, .rotation = 0 });
    const landmarks = syntheticLandmarks();
    try t.expectEqual(Status.searching, tracker.onLandmarks(0.2, &landmarks));
    try t.expectEqual(@as(?sampler.Region, null), tracker.cropForFrame());
    try t.expectEqual(Status.searching, tracker.status());
}
