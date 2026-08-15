//! The web tracking module's export surface. The browser has its own
//! threading story: the shell runs this whole module inside a Worker, so
//! every call here executes the pipeline synchronously and returns. One
//! instance per create call, frames in as RGBA straight from the camera
//! canvas, the frozen result struct out.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const face = @import("face");
const tracker = @import("tracker");

const gpa = std.heap.wasm_allocator;

/// The delegate's cache mapper names this libc call; the web target has no
/// page locking, and the mapper treats refusal as advisory.
export fn mlock(address: ?*const anyopaque, length: usize) c_int {
    _ = address;
    _ = length;
    return -1;
}

const status_ok: i32 = 0;
const status_invalid: i32 = 1;
const status_out_of_memory: i32 = 2;
const status_again: i32 = 7;

const Instance = struct {
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

    lock: tracker.Tracker = .{},
    result: face.Result = std.mem.zeroes(face.Result),
    has_result: bool = false,
    serial: u64 = 0,
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

/// Allocation the embedder pairs with ck_tracking_free; how bundle and
/// frame bytes reach this module's memory.
pub export fn ck_tracking_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = gpa.alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn ck_tracking_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    gpa.free(p[0..size]);
}

pub export fn ck_tracking_result_size() usize {
    return @sizeOf(face.Result);
}

pub export fn ck_tracking_create(task_ptr: ?[*]const u8, task_len: usize) ?*Instance {
    const task_source = task_ptr orelse return null;
    if (task_len == 0) return null;

    const instance = gpa.create(Instance) catch return null;
    errdefer gpa.destroy(instance);

    const owned = gpa.dupe(u8, task_source[0..task_len]) catch return null;
    errdefer gpa.free(owned);

    const task = bundle.Bundle.open(owned) catch return null;
    const detector_entry = task.find("face_detector.tflite") catch return null;
    const landmarks_entry = task.find("face_landmarks_detector.tflite") catch return null;
    const blendshapes_entry = task.find("face_blendshapes.tflite") catch return null;

    const detector_payload = task.payload(gpa, detector_entry) catch return null;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = task.payload(gpa, landmarks_entry) catch return null;
    errdefer landmarks_payload.deinit(gpa);
    const blendshapes_payload = task.payload(gpa, blendshapes_entry) catch return null;
    errdefer blendshapes_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, 1) catch return null;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, 1) catch return null;
    errdefer landmarks_engine.deinit();
    var blendshapes_engine = runtime.Engine.init(blendshapes_payload.bytes, 1) catch return null;
    errdefer blendshapes_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return null;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return null;
    const total = anchorTotal(&detector_engine) orelse return null;
    const plan = detector.planForModel(detector_side, total) orelse return null;

    const anchors = gpa.alloc(detector.Anchor, total) catch return null;
    errdefer gpa.free(anchors);
    detector.generateAnchors(detector_side, plan, anchors);

    const detector_tensor = gpa.alloc(f32, @as(usize, detector_side) * detector_side * 3) catch return null;
    errdefer gpa.free(detector_tensor);
    const landmark_tensor = gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3) catch return null;
    errdefer gpa.free(landmark_tensor);

    instance.* = .{
        .task_bytes = owned,
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
    return instance;
}

pub export fn ck_tracking_destroy(instance: ?*Instance) void {
    const tracking = instance orelse return;
    tracking.blendshapes_engine.deinit();
    tracking.landmarks_engine.deinit();
    tracking.detector_engine.deinit();
    gpa.free(tracking.landmark_tensor);
    gpa.free(tracking.detector_tensor);
    gpa.free(tracking.anchors);
    tracking.blendshapes_payload.deinit(gpa);
    tracking.landmarks_payload.deinit(gpa);
    tracking.detector_payload.deinit(gpa);
    gpa.free(tracking.task_bytes);
    gpa.destroy(tracking);
}

fn presenceScore(raw: f32) f32 {
    return if (raw < 0.0 or raw > 1.0) 1.0 / (1.0 + @exp(-raw)) else raw;
}

/// Runs the whole pipeline over one packed RGBA frame and publishes the
/// result for ck_tracking_result. Synchronous by design: the Worker this
/// runs in is the off-main-thread guarantee.
pub export fn ck_tracking_process(instance: ?*Instance, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const tracking = instance orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or height == 0) return status_invalid;

    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };

    const crop = tracking.lock.cropForFrame() orelse detect: {
        sampler.sampleRegion(image, face.frameSquare(width, height), .symmetric, tracking.detector_side, tracking.detector_tensor);
        tracking.detector_engine.writeInput(0, std.mem.sliceAsBytes(tracking.detector_tensor)) catch return status_invalid;
        tracking.detector_engine.invoke() catch return status_invalid;
        const raw_boxes = tracking.detector_engine.outputFloats(0) catch return status_invalid;
        const raw_scores = tracking.detector_engine.outputFloats(1) catch return status_invalid;
        var candidates: [16]detector.Detection = undefined;
        const found = detector.decode(raw_boxes, raw_scores, tracking.anchors, @floatFromInt(tracking.detector_side), 0.5, &candidates);
        if (found.len == 0) {
            publishEmpty(tracking, timestamp_us);
            return status_ok;
        }
        const region = face.regionFromDetection(found[0], face.frameSquare(width, height));
        tracking.lock.onDetection(region);
        break :detect region;
    };

    sampler.sampleRegion(image, crop, .unit, tracking.landmark_side, tracking.landmark_tensor);
    tracking.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(tracking.landmark_tensor)) catch return status_invalid;
    tracking.landmarks_engine.invoke() catch return status_invalid;
    const raw_landmarks = tracking.landmarks_engine.outputFloats(0) catch return status_invalid;
    const presence = presenceScore((tracking.landmarks_engine.outputFloats(1) catch return status_invalid)[0]);

    var landmarks: [face.landmark_count]face.Landmark = undefined;
    face.decodeLandmarks(raw_landmarks, crop, @floatFromInt(tracking.landmark_side), &landmarks);
    if (tracking.lock.onLandmarks(presence, &landmarks) == .searching) {
        publishEmpty(tracking, timestamp_us);
        return status_ok;
    }

    tracking.serial += 1;
    tracking.result.frame_serial = tracking.serial;
    tracking.result.timestamp_us = timestamp_us;
    tracking.result.presence = presence;
    tracking.result.landmark_count_out = face.landmark_count;
    for (landmarks, 0..) |landmark, at| {
        tracking.result.landmarks[at * 3] = landmark.x;
        tracking.result.landmarks[at * 3 + 1] = landmark.y;
        tracking.result.landmarks[at * 3 + 2] = landmark.z;
    }

    var blend_input: [face.blendshape_subset.len * 2]f32 = undefined;
    face.blendshapeInput(&landmarks, &blend_input);
    @memset(&tracking.result.blendshapes, 0);
    if (tracking.blendshapes_engine.writeInput(0, std.mem.sliceAsBytes(&blend_input))) |_| {
        if (tracking.blendshapes_engine.invoke()) |_| {
            const scores = tracking.blendshapes_engine.outputFloats(0) catch &[_]f32{};
            const count = @min(scores.len, tracking.result.blendshapes.len);
            @memcpy(tracking.result.blendshapes[0..count], scores[0..count]);
        } else |_| {}
    } else |_| {}

    tracking.has_result = true;
    return status_ok;
}

pub export fn ck_tracking_result(instance: ?*Instance, out: ?[*]u8) i32 {
    const tracking = instance orelse return status_invalid;
    const destination = out orelse return status_invalid;
    if (!tracking.has_result) return status_again;
    @memcpy(destination[0..@sizeOf(face.Result)], std.mem.asBytes(&tracking.result));
    return status_ok;
}

fn publishEmpty(tracking: *Instance, timestamp_us: i64) void {
    tracking.serial += 1;
    tracking.result = std.mem.zeroes(face.Result);
    tracking.result.frame_serial = tracking.serial;
    tracking.result.timestamp_us = timestamp_us;
    tracking.has_result = true;
}
