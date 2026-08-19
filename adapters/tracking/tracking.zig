//! The face tracking worker: owns the inference engines and runs the
//! detect-then-track loop off the camera thread. Frames arrive as NV12
//! plane copies into a latest-wins mailbox; results leave through a
//! seqlock slot any thread may read without blocking the worker. One
//! worker per session, created when an SDK enables tracking with a model
//! bundle and torn down with the session.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const face = @import("face");
const tracker = @import("tracker");
const graph = @import("graph");
const math = @import("math");

pub const supported = true;

/// The hand worker lives beside this one and shares its shape; the export
/// layer reaches it through this module the same way it reaches faces.
pub const hand_worker = @import("hand_tracking.zig");

pub const CreateError = error{ Unsupported, InvalidBundle, OutOfMemory };

const max_candidates = 16;

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

pub const Tracking = struct {
    gpa: std.mem.Allocator,
    task_bytes: []u8,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    blendshapes_payload: bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,
    blendshapes_engine: runtime.Engine,

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

    lock: tracker.Tracker = .{},
    slot: graph.ResultSlot(face.Result) = .{},
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

/// Copies the bundle, stands the three engines up, and starts the worker.
/// The thread count stays small on purpose: the render thread owns the
/// frame budget and inference must never starve it.
pub fn create(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*Tracking {
    const tracking = gpa.create(Tracking) catch return error.OutOfMemory;
    errdefer gpa.destroy(tracking);

    const owned_bytes = gpa.dupe(u8, task_bytes) catch return error.OutOfMemory;
    errdefer gpa.free(owned_bytes);

    const task = bundle.Bundle.open(owned_bytes) catch return error.InvalidBundle;
    const detector_entry = task.find("face_detector.tflite") catch return error.InvalidBundle;
    const landmarks_entry = task.find("face_landmarks_detector.tflite") catch return error.InvalidBundle;
    const blendshapes_entry = task.find("face_blendshapes.tflite") catch return error.InvalidBundle;

    const detector_payload = task.payload(gpa, detector_entry) catch return error.InvalidBundle;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = task.payload(gpa, landmarks_entry) catch return error.InvalidBundle;
    errdefer landmarks_payload.deinit(gpa);
    const blendshapes_payload = task.payload(gpa, blendshapes_entry) catch return error.InvalidBundle;
    errdefer blendshapes_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer landmarks_engine.deinit();
    var blendshapes_engine = runtime.Engine.init(blendshapes_payload.bytes, threads) catch return error.InvalidBundle;
    errdefer blendshapes_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return error.InvalidBundle;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return error.InvalidBundle;
    const total = anchorTotal(&detector_engine) orelse return error.InvalidBundle;
    const plan = detector.planForModel(detector_side, total) orelse return error.InvalidBundle;

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
        .blendshapes_payload = blendshapes_payload,
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .blendshapes_engine = blendshapes_engine,
        .detector_side = detector_side,
        .landmark_side = landmark_side,
        .anchors = anchors,
        .detector_tensor = detector_tensor,
        .landmark_tensor = landmark_tensor,
    };

    tracking.thread = std.Thread.spawn(.{}, workerMain, .{tracking}) catch return error.OutOfMemory;
    return tracking;
}

pub fn destroy(tracking: *Tracking) void {
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
    tracking.blendshapes_engine.deinit();
    gpa.free(tracking.landmark_tensor);
    gpa.free(tracking.detector_tensor);
    gpa.free(tracking.anchors);
    tracking.blendshapes_payload.deinit(gpa);
    tracking.landmarks_payload.deinit(gpa);
    tracking.detector_payload.deinit(gpa);
    gpa.free(tracking.task_bytes);
    tracking.io_state.deinit();
    gpa.destroy(tracking);
}

/// Copies one NV12 frame into the mailbox, replacing any frame the worker
/// has not picked up yet: tracking always wants the newest frame, never a
/// backlog. Rows are copied tight so the worker owns plain planes.
pub fn submitNv12(
    tracking: *Tracking,
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
pub fn readResult(tracking: *Tracking, out: *face.Result) bool {
    if (tracking.published.load(.acquire) == 0) return false;
    const published = tracking.slot.latest() orelse return false;
    out.* = published.value;
    return true;
}

fn workerMain(tracking: *Tracking) void {
    // The worker's own copy of the frame, swapped under the lock so the
    // camera thread never waits on inference.
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

fn presenceScore(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

fn processFrame(tracking: *Tracking, frame: *const PendingFrame) void {
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

    const crop = tracking.lock.cropForFrame() orelse detect: {
        sampler.sampleRegion(image, sampler.frameSquare(image.width, image.height), .symmetric, tracking.detector_side, tracking.detector_tensor);
        tracking.detector_engine.writeInput(0, std.mem.sliceAsBytes(tracking.detector_tensor)) catch return;
        tracking.detector_engine.invoke() catch return;
        const raw_boxes = tracking.detector_engine.outputFloats(0) catch return;
        const raw_scores = tracking.detector_engine.outputFloats(1) catch return;
        var candidates: [max_candidates]detector.face.Detection = undefined;
        const found = detector.face.decode(raw_boxes, raw_scores, tracking.anchors, @floatFromInt(tracking.detector_side), 0.5, &candidates);
        if (found.len == 0) {
            publishEmpty(tracking, frame.timestamp_us);
            return;
        }
        const region = face.regionFromDetection(found[0], sampler.frameSquare(image.width, image.height));
        tracking.lock.onDetection(region);
        break :detect region;
    };

    sampler.sampleRegion(image, crop, .unit, tracking.landmark_side, tracking.landmark_tensor);
    tracking.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(tracking.landmark_tensor)) catch return;
    tracking.landmarks_engine.invoke() catch return;
    const raw_landmarks = tracking.landmarks_engine.outputFloats(0) catch return;
    const presence = presenceScore((tracking.landmarks_engine.outputFloats(1) catch return)[0]);

    var landmarks: [face.landmark_count]face.Landmark = undefined;
    face.decodeLandmarks(raw_landmarks, crop, @floatFromInt(tracking.landmark_side), &landmarks);
    if (tracking.lock.onLandmarks(presence, &landmarks) == .searching) {
        publishEmpty(tracking, frame.timestamp_us);
        return;
    }

    var blend_input: [face.blendshape_subset.len * 2]f32 = undefined;
    face.blendshapeInput(&landmarks, &blend_input);
    var result: face.Result = undefined;
    result.frame_serial = tracking.serial + 1;
    result.timestamp_us = frame.timestamp_us;
    result.presence = presence;
    result.landmark_count_out = face.landmark_count;
    for (landmarks, 0..) |landmark, at| {
        result.landmarks[at * 3] = landmark.x;
        result.landmarks[at * 3 + 1] = landmark.y;
        result.landmarks[at * 3 + 2] = landmark.z;
    }
    if (tracking.blendshapes_engine.writeInput(0, std.mem.sliceAsBytes(&blend_input))) |_| {
        if (tracking.blendshapes_engine.invoke()) |_| {
            const scores = tracking.blendshapes_engine.outputFloats(0) catch &[_]f32{};
            const count = @min(scores.len, result.blendshapes.len);
            @memcpy(result.blendshapes[0..count], scores[0..count]);
            if (count < result.blendshapes.len) @memset(result.blendshapes[count..], 0);
        } else |_| {
            @memset(&result.blendshapes, 0);
        }
    } else |_| {
        @memset(&result.blendshapes, 0);
    }

    publish(tracking, result);
}

fn publishEmpty(tracking: *Tracking, timestamp_us: i64) void {
    var result: face.Result = undefined;
    result.frame_serial = tracking.serial + 1;
    result.timestamp_us = timestamp_us;
    result.presence = 0;
    result.landmark_count_out = 0;
    @memset(&result.landmarks, 0);
    @memset(&result.blendshapes, 0);
    publish(tracking, result);
}

fn publish(tracking: *Tracking, result: face.Result) void {
    tracking.serial = result.frame_serial;
    tracking.slot.publish(result, result.timestamp_us);
    tracking.published.store(tracking.serial, .release);
}
