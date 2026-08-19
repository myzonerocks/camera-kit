//! The hand tracking worker: palm detection plus the hand landmark model
//! out of one bundle, run detect-then-track per hand slot off the camera
//! thread. Same mailbox/seqlock shape as the face worker; up to two hands
//! hold their slots so a hand keeps its identity across frames.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const hand = @import("hand");
const graph = @import("graph");
const math = @import("math");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidBundle, OutOfMemory };

const max_candidates = 8;
const presence_floor = 0.5;
/// A fresh detection overlapping a tracked hand this much is that hand,
/// not a new one - the shipped graphs associate on the same bar.
const association_overlap = 0.5;

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

pub const HandTracking = struct {
    gpa: std.mem.Allocator,
    task_bytes: []u8,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,

    detector_side: u32,
    landmark_side: u32,
    anchors: []detector.Anchor,
    detector_tensor: []f32,
    landmark_tensor: []f32,

    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,

    locks: [hand.max_hands]?sampler.Region = @splat(null),
    slot: graph.ResultSlot(hand.Result) = .{},
    published: std.atomic.Value(u64) = .init(0),
    serial: u64 = 0,

    thread: ?std.Thread = null,
};

fn engineInputSide(engine: *const runtime.Engine) ?u32 {
    const tensor = runtime.c.TfLiteInterpreterGetInputTensor(engine.interpreter, 0) orelse return null;
    if (runtime.c.TfLiteTensorNumDims(tensor) != 4) return null;
    return @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
}

fn anchorTotal(engine: *const runtime.Engine) ?usize {
    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, 0) orelse return null;
    if (runtime.c.TfLiteTensorNumDims(tensor) < 2) return null;
    return @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
}

fn outputFloatCount(engine: *const runtime.Engine, index: i32) usize {
    const tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, index) orelse return 0;
    return runtime.c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
}

/// Copies the bundle, stands both engines up, verifies the landmark
/// model's output contract, and starts the worker.
pub fn create(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*HandTracking {
    const tracking = gpa.create(HandTracking) catch return error.OutOfMemory;
    errdefer gpa.destroy(tracking);

    const owned_bytes = gpa.dupe(u8, task_bytes) catch return error.OutOfMemory;
    errdefer gpa.free(owned_bytes);

    const task = bundle.Bundle.open(owned_bytes) catch return error.InvalidBundle;
    const detector_entry = task.find("hand_detector.tflite") catch return error.InvalidBundle;
    const landmarks_entry = task.find("hand_landmarks_detector.tflite") catch return error.InvalidBundle;

    const detector_payload = task.payload(gpa, detector_entry) catch return error.InvalidBundle;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = task.payload(gpa, landmarks_entry) catch return error.InvalidBundle;
    errdefer landmarks_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer landmarks_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return error.InvalidBundle;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return error.InvalidBundle;
    const total = anchorTotal(&detector_engine) orelse return error.InvalidBundle;
    const plan = detector.planForModel(detector_side, total) orelse return error.InvalidBundle;

    // The landmark model's output contract: landmarks, presence,
    // handedness, in that order. A bundle whose sizes disagree is a
    // wiring defect to refuse, not to run with.
    if (outputFloatCount(&landmarks_engine, 0) != hand.landmark_count * 3) return error.InvalidBundle;
    if (outputFloatCount(&landmarks_engine, 1) != 1) return error.InvalidBundle;
    if (outputFloatCount(&landmarks_engine, 2) != 1) return error.InvalidBundle;

    const anchors = gpa.alloc(detector.Anchor, total) catch return error.OutOfMemory;
    errdefer gpa.free(anchors);
    detector.generateAnchors(detector_side, plan, anchors);

    const detector_tensor = gpa.alloc(f32, @as(usize, detector_side) * detector_side * 3) catch return error.OutOfMemory;
    errdefer gpa.free(detector_tensor);
    const landmark_tensor = gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3) catch return error.OutOfMemory;
    errdefer gpa.free(landmark_tensor);

    tracking.* = .{
        .gpa = gpa,
        .io_state = std.Io.Threaded.init(gpa, .{}),
        .task_bytes = owned_bytes,
        .detector_payload = detector_payload,
        .landmarks_payload = landmarks_payload,
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .detector_side = detector_side,
        .landmark_side = landmark_side,
        .anchors = anchors,
        .detector_tensor = detector_tensor,
        .landmark_tensor = landmark_tensor,
    };

    tracking.thread = std.Thread.spawn(.{}, workerMain, .{tracking}) catch return error.OutOfMemory;
    return tracking;
}

pub fn destroy(tracking: *HandTracking) void {
    const io = tracking.io_state.io();
    {
        tracking.mutex.lockUncancelable(io);
        defer tracking.mutex.unlock(io);
        tracking.stop = true;
        tracking.frame_ready.signal(io);
    }
    if (tracking.thread) |thread| thread.join();

    const gpa = tracking.gpa;
    tracking.pending.y.deinit(gpa);
    tracking.pending.uv.deinit(gpa);
    tracking.detector_engine.deinit();
    tracking.landmarks_engine.deinit();
    gpa.free(tracking.landmark_tensor);
    gpa.free(tracking.detector_tensor);
    gpa.free(tracking.anchors);
    tracking.landmarks_payload.deinit(gpa);
    tracking.detector_payload.deinit(gpa);
    gpa.free(tracking.task_bytes);
    tracking.io_state.deinit();
    gpa.destroy(tracking);
}

/// Copies one NV12 frame into the mailbox, replacing any frame the worker
/// has not picked up yet - tracking always wants the newest frame.
pub fn submitNv12(
    tracking: *HandTracking,
    width: u32,
    height: u32,
    timestamp_us: i64,
    conversion: math.color.Conversion,
    y: [*]const u8,
    y_stride: u32,
    uv: [*]const u8,
    uv_stride: u32,
) void {
    const y_size = @as(usize, width) * height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const uv_size = @as(usize, half_width) * half_height * 2;

    const io = tracking.io_state.io();
    tracking.mutex.lockUncancelable(io);
    defer tracking.mutex.unlock(io);
    if (tracking.stop) return;

    tracking.pending.y.resize(tracking.gpa, y_size) catch return;
    tracking.pending.uv.resize(tracking.gpa, uv_size) catch return;
    for (0..height) |row| {
        const src = y[row * y_stride ..][0..width];
        @memcpy(tracking.pending.y.items[row * width ..][0..width], src);
    }
    for (0..half_height) |row| {
        const src = uv[row * uv_stride ..][0 .. half_width * 2];
        @memcpy(tracking.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], src);
    }
    tracking.pending.width = width;
    tracking.pending.height = height;
    tracking.pending.timestamp_us = timestamp_us;
    tracking.pending.conversion = conversion;
    tracking.pending.fresh = true;
    tracking.frame_ready.signal(io);
}

/// Reads the latest published result. False until the worker has produced
/// its first one.
pub fn readResult(tracking: *HandTracking, out: *hand.Result) bool {
    if (tracking.published.load(.acquire) == 0) return false;
    const published = tracking.slot.latest() orelse return false;
    out.* = published.value;
    return true;
}

fn workerMain(tracking: *HandTracking) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(tracking.gpa);
        frame.uv.deinit(tracking.gpa);
    }

    while (true) {
        {
            const io = tracking.io_state.io();
            tracking.mutex.lockUncancelable(io);
            defer tracking.mutex.unlock(io);
            while (!tracking.pending.fresh and !tracking.stop) {
                tracking.frame_ready.waitUncancelable(io, &tracking.mutex);
            }
            if (tracking.stop) return;
            std.mem.swap(PendingFrame, &frame, &tracking.pending);
            tracking.pending.fresh = false;
        }
        processFrame(tracking, &frame);
    }
}

fn score01(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

/// Axis-aligned overlap of two square crops as intersection over union;
/// rotation is close between a detection and the lock it duplicates, so
/// the axis-aligned box is a faithful stand-in.
fn regionOverlap(a: sampler.Region, b: sampler.Region) f32 {
    const ax0 = a.center_x - a.side * 0.5;
    const ay0 = a.center_y - a.side * 0.5;
    const bx0 = b.center_x - b.side * 0.5;
    const by0 = b.center_y - b.side * 0.5;
    const x0 = @max(ax0, bx0);
    const y0 = @max(ay0, by0);
    const x1 = @min(ax0 + a.side, bx0 + b.side);
    const y1 = @min(ay0 + a.side, by0 + b.side);
    if (x1 <= x0 or y1 <= y0) return 0;
    const shared = (x1 - x0) * (y1 - y0);
    const total = a.side * a.side + b.side * b.side - shared;
    if (total <= 0) return 0;
    return shared / total;
}

fn detectHands(tracking: *HandTracking, image: sampler.Frame) void {
    const square = sampler.frameSquare(image.width, image.height);
    // The palm detector reads zero-to-one input, unlike the face
    // detector's symmetric range - the shipped graph's own tensor range.
    sampler.sampleRegion(image, square, .unit, tracking.detector_side, tracking.detector_tensor);
    tracking.detector_engine.writeInput(0, std.mem.sliceAsBytes(tracking.detector_tensor)) catch return;
    tracking.detector_engine.invoke() catch return;
    const raw_boxes = tracking.detector_engine.outputFloats(0) catch return;
    const raw_scores = tracking.detector_engine.outputFloats(1) catch return;
    var candidates: [max_candidates]detector.palm.Detection = undefined;
    const found = detector.palm.decode(raw_boxes, raw_scores, tracking.anchors, @floatFromInt(tracking.detector_side), 0.5, &candidates);

    for (found) |detection| {
        const region = hand.regionFromDetection(detection, square);
        var duplicate = false;
        for (tracking.locks) |maybe_lock| {
            const lock = maybe_lock orelse continue;
            if (regionOverlap(region, lock) >= association_overlap) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        for (&tracking.locks) |*slot| {
            if (slot.* == null) {
                slot.* = region;
                break;
            }
        }
    }
}

fn processFrame(tracking: *HandTracking, frame: *const PendingFrame) void {
    const image: sampler.Frame = .{
        .width = frame.width,
        .height = frame.height,
        .pixels = .{ .nv12 = .{
            .y = frame.y.items,
            .y_stride = frame.width,
            .uv = frame.uv.items,
            .uv_stride = ((frame.width + 1) / 2) * 2,
            .conversion = frame.conversion,
        } },
    };

    var free_slots: usize = 0;
    for (tracking.locks) |maybe_lock| {
        if (maybe_lock == null) free_slots += 1;
    }
    if (free_slots > 0) detectHands(tracking, image);

    var result: hand.Result = std.mem.zeroes(hand.Result);
    result.frame_serial = tracking.serial + 1;
    result.timestamp_us = frame.timestamp_us;

    for (&tracking.locks) |*maybe_lock| {
        const crop = maybe_lock.* orelse continue;
        sampler.sampleRegion(image, crop, .unit, tracking.landmark_side, tracking.landmark_tensor);
        tracking.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(tracking.landmark_tensor)) catch continue;
        tracking.landmarks_engine.invoke() catch continue;
        const raw_landmarks = tracking.landmarks_engine.outputFloats(0) catch continue;
        const presence = score01((tracking.landmarks_engine.outputFloats(1) catch continue)[0]);
        if (presence < presence_floor) {
            maybe_lock.* = null;
            continue;
        }
        const handedness = score01((tracking.landmarks_engine.outputFloats(2) catch continue)[0]);

        var landmarks: [hand.landmark_count]hand.Landmark = undefined;
        hand.decodeLandmarks(raw_landmarks, crop, @floatFromInt(tracking.landmark_side), &landmarks);
        maybe_lock.* = hand.regionFromLandmarks(&landmarks);

        const slot = &result.hands[result.hand_count];
        slot.presence = presence;
        slot.handedness = handedness;
        for (landmarks, 0..) |landmark, at| {
            slot.landmarks[at * 3] = landmark.x;
            slot.landmarks[at * 3 + 1] = landmark.y;
            slot.landmarks[at * 3 + 2] = landmark.z;
        }
        result.hand_count += 1;
    }

    tracking.serial = result.frame_serial;
    tracking.slot.publish(result, result.timestamp_us);
    tracking.published.store(tracking.serial, .release);
}
