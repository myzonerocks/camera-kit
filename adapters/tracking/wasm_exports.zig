//! The web tracking module's export surface. The browser has its own
//! threading story: the SDK runs this whole module inside a Worker, so
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
const pose = @import("pose");
const hand = @import("hand");
const segmentation_core = @import("segmentation_core");

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

/// Allocation the embedder pairs with goss_tracking_free; how bundle and
/// frame bytes reach this module's memory.
pub export fn goss_tracking_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = gpa.alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn goss_tracking_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    gpa.free(p[0..size]);
}

pub export fn goss_tracking_result_size() usize {
    return @sizeOf(face.Result);
}

pub export fn goss_tracking_create(task_ptr: ?[*]const u8, task_len: usize) ?*Instance {
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

pub export fn goss_tracking_destroy(instance: ?*Instance) void {
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
/// result for goss_tracking_result. Synchronous by design: the Worker this
/// runs in is the off-main-thread guarantee.
pub export fn goss_tracking_process(instance: ?*Instance, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const tracking = instance orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or height == 0) return status_invalid;

    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };

    const crop = tracking.lock.cropForFrame() orelse detect: {
        sampler.sampleRegion(image, sampler.frameSquare(width, height), .symmetric, tracking.detector_side, tracking.detector_tensor);
        tracking.detector_engine.writeInput(0, std.mem.sliceAsBytes(tracking.detector_tensor)) catch return status_invalid;
        tracking.detector_engine.invoke() catch return status_invalid;
        const raw_boxes = tracking.detector_engine.outputFloats(0) catch return status_invalid;
        const raw_scores = tracking.detector_engine.outputFloats(1) catch return status_invalid;
        var candidates: [16]detector.face.Detection = undefined;
        const found = detector.face.decode(raw_boxes, raw_scores, tracking.anchors, @floatFromInt(tracking.detector_side), 0.5, &candidates);
        if (found.len == 0) {
            publishEmpty(tracking, timestamp_us);
            return status_ok;
        }
        const region = face.regionFromDetection(found[0], sampler.frameSquare(width, height));
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

pub export fn goss_tracking_result(instance: ?*Instance, out: ?[*]u8) i32 {
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

// The selfie/hair segmenter, same shape: one Core per create, RGBA frames
// in, a 256x256 mask out. The embedder allocates the model and the mask
// buffer with goss_tracking_alloc/free.

pub export fn goss_segmentation_mask_side() u32 {
    return segmentation_core.mask_side;
}

pub export fn goss_segmentation_create(model_ptr: ?[*]const u8, model_len: usize, threads: i32) ?*segmentation_core.Core {
    const model = model_ptr orelse return null;
    if (model_len == 0) return null;
    return segmentation_core.Core.init(gpa, model[0..model_len], threads) catch null;
}

pub export fn goss_segmentation_destroy(core: ?*segmentation_core.Core) void {
    if (core) |c| c.deinit();
}

pub export fn goss_segmentation_class_count(core: ?*segmentation_core.Core) u32 {
    const c = core orelse return 0;
    return c.class_count;
}

pub export fn goss_segmentation_process(core: ?*segmentation_core.Core, rgba: ?[*]const u8, width: u32, height: u32) i32 {
    const c = core orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or height == 0) return status_invalid;
    const frame: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };
    if (!c.compute(frame)) return status_invalid;
    c.publish();
    return status_ok;
}

pub export fn goss_segmentation_read_mask(core: ?*segmentation_core.Core, out: ?[*]f32) i32 {
    const c = core orelse return status_invalid;
    const dst = out orelse return status_invalid;
    if (!c.subjectMask(@ptrCast(dst))) return status_again;
    return status_ok;
}

pub export fn goss_segmentation_read_class_mask(core: ?*segmentation_core.Core, class_index: u32, out: ?[*]f32) i32 {
    const c = core orelse return status_invalid;
    const dst = out orelse return status_invalid;
    if (!c.classMask(class_index, @ptrCast(dst))) return status_again;
    return status_ok;
}

// --- Pose ---
// The pose pipeline, the face module's twin for a different bundle: a
// pose detector then the landmark model, decoded to pose.Result. Stands
// on its own instance; RGBA frames in, the pose result out.

const pose_max_candidates = 8;
const pose_presence_floor = 0.5;

const PoseInstance = struct {
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
    lock: ?sampler.Region = null,
    result: pose.Result = std.mem.zeroes(pose.Result),
    has_result: bool = false,
    serial: u64 = 0,
};

pub export fn goss_pose_result_size() usize {
    return @sizeOf(pose.Result);
}

pub export fn goss_pose_create(task_ptr: ?[*]const u8, task_len: usize) ?*PoseInstance {
    const task_source = task_ptr orelse return null;
    if (task_len == 0) return null;

    const instance = gpa.create(PoseInstance) catch return null;
    errdefer gpa.destroy(instance);
    const owned = gpa.dupe(u8, task_source[0..task_len]) catch return null;
    errdefer gpa.free(owned);

    const task = bundle.Bundle.open(owned) catch return null;
    const detector_entry = task.find("pose_detector.tflite") catch return null;
    const landmarks_entry = task.find("pose_landmarks_detector.tflite") catch return null;
    const detector_payload = task.payload(gpa, detector_entry) catch return null;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = task.payload(gpa, landmarks_entry) catch return null;
    errdefer landmarks_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, 1) catch return null;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, 1) catch return null;
    errdefer landmarks_engine.deinit();

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
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .detector_side = detector_side,
        .landmark_side = landmark_side,
        .anchors = anchors,
        .detector_tensor = detector_tensor,
        .landmark_tensor = landmark_tensor,
    };
    return instance;
}

pub export fn goss_pose_destroy(instance: ?*PoseInstance) void {
    const p = instance orelse return;
    p.detector_engine.deinit();
    p.landmarks_engine.deinit();
    gpa.free(p.landmark_tensor);
    gpa.free(p.detector_tensor);
    gpa.free(p.anchors);
    p.landmarks_payload.deinit(gpa);
    p.detector_payload.deinit(gpa);
    gpa.free(p.task_bytes);
    gpa.destroy(p);
}

fn poseEmpty(p: *PoseInstance, timestamp_us: i64) void {
    p.serial += 1;
    p.result = std.mem.zeroes(pose.Result);
    p.result.frame_serial = p.serial;
    p.result.timestamp_us = timestamp_us;
    p.has_result = true;
}

pub export fn goss_pose_process(instance: ?*PoseInstance, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const p = instance orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or height == 0) return status_invalid;
    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };

    const crop = p.lock orelse detect: {
        const square = sampler.frameSquare(width, height);
        sampler.sampleRegion(image, square, .symmetric, p.detector_side, p.detector_tensor);
        p.detector_engine.writeInput(0, std.mem.sliceAsBytes(p.detector_tensor)) catch return status_invalid;
        p.detector_engine.invoke() catch return status_invalid;
        const raw_boxes = p.detector_engine.outputFloats(0) catch return status_invalid;
        const raw_scores = p.detector_engine.outputFloats(1) catch return status_invalid;
        var candidates: [pose_max_candidates]detector.pose.Detection = undefined;
        const found = detector.pose.decode(raw_boxes, raw_scores, p.anchors, @floatFromInt(p.detector_side), 0.5, &candidates);
        if (found.len == 0) {
            poseEmpty(p, timestamp_us);
            return status_ok;
        }
        const region = pose.regionFromDetection(found[0], square);
        p.lock = region;
        break :detect region;
    };

    sampler.sampleRegion(image, crop, .unit, p.landmark_side, p.landmark_tensor);
    p.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(p.landmark_tensor)) catch return status_invalid;
    p.landmarks_engine.invoke() catch return status_invalid;
    const raw_landmarks = p.landmarks_engine.outputFloats(0) catch return status_invalid;
    const presence = presenceScore((p.landmarks_engine.outputFloats(1) catch return status_invalid)[0]);
    if (presence < pose_presence_floor) {
        p.lock = null;
        poseEmpty(p, timestamp_us);
        return status_ok;
    }

    var landmarks: [pose.raw_landmark_count]pose.Landmark = undefined;
    var visibilities: [pose.raw_landmark_count]f32 = undefined;
    var presences: [pose.raw_landmark_count]f32 = undefined;
    pose.decodeLandmarks(raw_landmarks, crop, @floatFromInt(p.landmark_side), &landmarks, &visibilities, &presences);
    p.lock = pose.regionFromLandmarks(&landmarks);

    p.serial += 1;
    p.result.frame_serial = p.serial;
    p.result.timestamp_us = timestamp_us;
    p.result.presence = presence;
    p.result.landmark_count_out = pose.landmark_count;
    for (0..pose.landmark_count) |at| {
        p.result.landmarks[at * 3] = landmarks[at].x;
        p.result.landmarks[at * 3 + 1] = landmarks[at].y;
        p.result.landmarks[at * 3 + 2] = landmarks[at].z;
        p.result.visibilities[at] = visibilities[at];
        p.result.presences[at] = presences[at];
    }
    p.has_result = true;
    return status_ok;
}

pub export fn goss_pose_result(instance: ?*PoseInstance, out: ?[*]u8) i32 {
    const p = instance orelse return status_invalid;
    const destination = out orelse return status_invalid;
    if (!p.has_result) return status_again;
    @memcpy(destination[0..@sizeOf(pose.Result)], std.mem.asBytes(&p.result));
    return status_ok;
}

// A palm detector then the landmark model over up to two tracked hands,
// with handedness, and gestures when the bundle nests the recognizer's
// embedder/classifier pair. RGBA frames in, hand.Result out. The
// synchronous twin of the hand worker.

const hand_max_candidates = 8;
const hand_presence_floor = 0.5;
const hand_association_overlap = 0.5;

fn floatCount(engine: *const runtime.Engine, index: i32, input: bool) usize {
    const tensor = if (input)
        runtime.c.TfLiteInterpreterGetInputTensor(engine.interpreter, index)
    else
        runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, index);
    const t = tensor orelse return 0;
    return runtime.c.TfLiteTensorByteSize(t) / @sizeOf(f32);
}

const HandInstance = struct {
    task_bytes: []u8,
    landmarker_container: ?bundle.Payload,
    gesture_container: ?bundle.Payload,
    detector_payload: bundle.Payload,
    landmarks_payload: bundle.Payload,
    embedder_payload: ?bundle.Payload,
    classifier_payload: ?bundle.Payload,
    detector_engine: runtime.Engine,
    landmarks_engine: runtime.Engine,
    embedder_engine: ?runtime.Engine,
    classifier_engine: ?runtime.Engine,
    detector_side: u32,
    landmark_side: u32,
    anchors: []detector.Anchor,
    detector_tensor: []f32,
    landmark_tensor: []f32,
    locks: [hand.max_hands]?sampler.Region = @splat(null),
    result: hand.Result = std.mem.zeroes(hand.Result),
    has_result: bool = false,
    serial: u64 = 0,
};

pub export fn goss_hand_result_size() usize {
    return @sizeOf(hand.Result);
}

pub export fn goss_hand_create(task_ptr: ?[*]const u8, task_len: usize) ?*HandInstance {
    const task_source = task_ptr orelse return null;
    if (task_len == 0) return null;

    const p = gpa.create(HandInstance) catch return null;
    errdefer gpa.destroy(p);
    const owned = gpa.dupe(u8, task_source[0..task_len]) catch return null;
    errdefer gpa.free(owned);

    const task = bundle.Bundle.open(owned) catch return null;
    var landmarker_container: ?bundle.Payload = null;
    errdefer if (landmarker_container) |payload| payload.deinit(gpa);
    var gesture_container: ?bundle.Payload = null;
    errdefer if (gesture_container) |payload| payload.deinit(gpa);

    const landmarker = blk: {
        if (task.find("hand_detector.tflite")) |_| break :blk task else |_| {}
        const nested = task.find("hand_landmarker.task") catch return null;
        landmarker_container = task.payload(gpa, nested) catch return null;
        break :blk bundle.Bundle.open(landmarker_container.?.bytes) catch return null;
    };

    const detector_entry = landmarker.find("hand_detector.tflite") catch return null;
    const landmarks_entry = landmarker.find("hand_landmarks_detector.tflite") catch return null;
    const detector_payload = landmarker.payload(gpa, detector_entry) catch return null;
    errdefer detector_payload.deinit(gpa);
    const landmarks_payload = landmarker.payload(gpa, landmarks_entry) catch return null;
    errdefer landmarks_payload.deinit(gpa);

    var detector_engine = runtime.Engine.init(detector_payload.bytes, 1) catch return null;
    errdefer detector_engine.deinit();
    var landmarks_engine = runtime.Engine.init(landmarks_payload.bytes, 1) catch return null;
    errdefer landmarks_engine.deinit();

    const detector_side = engineInputSide(&detector_engine) orelse return null;
    const landmark_side = engineInputSide(&landmarks_engine) orelse return null;
    const total = anchorTotal(&detector_engine) orelse return null;
    const plan = detector.planForModel(detector_side, total) orelse return null;
    if (floatCount(&landmarks_engine, 0, false) != hand.landmark_count * 3) return null;

    var embedder_payload: ?bundle.Payload = null;
    errdefer if (embedder_payload) |payload| payload.deinit(gpa);
    var classifier_payload: ?bundle.Payload = null;
    errdefer if (classifier_payload) |payload| payload.deinit(gpa);
    var embedder_engine: ?runtime.Engine = null;
    errdefer if (embedder_engine) |*engine| engine.deinit();
    var classifier_engine: ?runtime.Engine = null;
    errdefer if (classifier_engine) |*engine| engine.deinit();

    if (task.find("hand_gesture_recognizer.task")) |gesture_entry| {
        gesture_container = task.payload(gpa, gesture_entry) catch return null;
        const gesture = bundle.Bundle.open(gesture_container.?.bytes) catch return null;
        const embedder_entry = gesture.find("gesture_embedder.tflite") catch return null;
        const classifier_entry = gesture.find("canned_gesture_classifier.tflite") catch return null;
        embedder_payload = gesture.payload(gpa, embedder_entry) catch return null;
        classifier_payload = gesture.payload(gpa, classifier_entry) catch return null;
        embedder_engine = runtime.Engine.init(embedder_payload.?.bytes, 1) catch return null;
        classifier_engine = runtime.Engine.init(classifier_payload.?.bytes, 1) catch return null;
    } else |_| {}

    const anchors = gpa.alloc(detector.Anchor, total) catch return null;
    errdefer gpa.free(anchors);
    detector.generateAnchors(detector_side, plan, anchors);
    const detector_tensor = gpa.alloc(f32, @as(usize, detector_side) * detector_side * 3) catch return null;
    errdefer gpa.free(detector_tensor);
    const landmark_tensor = gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3) catch return null;
    errdefer gpa.free(landmark_tensor);

    p.* = .{
        .task_bytes = owned,
        .landmarker_container = landmarker_container,
        .gesture_container = gesture_container,
        .detector_payload = detector_payload,
        .landmarks_payload = landmarks_payload,
        .embedder_payload = embedder_payload,
        .classifier_payload = classifier_payload,
        .detector_engine = detector_engine,
        .landmarks_engine = landmarks_engine,
        .embedder_engine = embedder_engine,
        .classifier_engine = classifier_engine,
        .detector_side = detector_side,
        .landmark_side = landmark_side,
        .anchors = anchors,
        .detector_tensor = detector_tensor,
        .landmark_tensor = landmark_tensor,
    };
    return p;
}

pub export fn goss_hand_destroy(instance: ?*HandInstance) void {
    const p = instance orelse return;
    if (p.classifier_engine) |*e| e.deinit();
    if (p.embedder_engine) |*e| e.deinit();
    p.landmarks_engine.deinit();
    p.detector_engine.deinit();
    gpa.free(p.landmark_tensor);
    gpa.free(p.detector_tensor);
    gpa.free(p.anchors);
    if (p.classifier_payload) |payload| payload.deinit(gpa);
    if (p.embedder_payload) |payload| payload.deinit(gpa);
    p.landmarks_payload.deinit(gpa);
    p.detector_payload.deinit(gpa);
    if (p.gesture_container) |payload| payload.deinit(gpa);
    if (p.landmarker_container) |payload| payload.deinit(gpa);
    gpa.free(p.task_bytes);
    gpa.destroy(p);
}

fn handRegionOverlap(a: sampler.Region, b: sampler.Region) f32 {
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

fn handDetect(p: *HandInstance, image: sampler.Frame) void {
    const square = sampler.frameSquare(image.width, image.height);
    sampler.sampleRegion(image, square, .unit, p.detector_side, p.detector_tensor);
    p.detector_engine.writeInput(0, std.mem.sliceAsBytes(p.detector_tensor)) catch return;
    p.detector_engine.invoke() catch return;
    const raw_boxes = p.detector_engine.outputFloats(0) catch return;
    const raw_scores = p.detector_engine.outputFloats(1) catch return;
    var candidates: [hand_max_candidates]detector.palm.Detection = undefined;
    const found = detector.palm.decode(raw_boxes, raw_scores, p.anchors, @floatFromInt(p.detector_side), 0.5, &candidates);
    for (found) |detection| {
        const region = hand.regionFromDetection(detection, square);
        var duplicate = false;
        for (p.locks) |maybe_lock| {
            const lock = maybe_lock orelse continue;
            if (handRegionOverlap(region, lock) >= hand_association_overlap) {
                duplicate = true;
                break;
            }
        }
        if (duplicate) continue;
        for (&p.locks) |*slot| {
            if (slot.* == null) {
                slot.* = region;
                break;
            }
        }
    }
}

fn handGesture(p: *HandInstance, landmarks: *const [hand.landmark_count]hand.Landmark, handedness: f32, rotation: f32, width: u32, height: u32, slot: *hand.Hand) void {
    if (p.embedder_engine == null or p.classifier_engine == null) return;
    const embedder = &p.embedder_engine.?;
    const classifier = &p.classifier_engine.?;
    const raw_world = p.landmarks_engine.outputFloats(3) catch return;
    var screen_input: [hand.landmark_count * 3]f32 = undefined;
    hand.gestureLandmarkInput(landmarks, @floatFromInt(width), @floatFromInt(height), rotation, &screen_input);
    var world_input: [hand.landmark_count * 3]f32 = undefined;
    hand.gestureWorldInput(raw_world, rotation, &world_input);
    var handedness_input = [1]f32{handedness};
    embedder.writeInput(0, std.mem.sliceAsBytes(&screen_input)) catch return;
    embedder.writeInput(1, std.mem.sliceAsBytes(&handedness_input)) catch return;
    embedder.writeInput(2, std.mem.sliceAsBytes(&world_input)) catch return;
    embedder.invoke() catch return;
    const embedding = embedder.outputFloats(0) catch return;
    classifier.writeInput(0, std.mem.sliceAsBytes(embedding)) catch return;
    classifier.invoke() catch return;
    const scores = classifier.outputFloats(0) catch return;
    var best: usize = 0;
    for (scores, 0..) |score, at| {
        if (score > scores[best]) best = at;
    }
    slot.gesture = @intCast(best);
    slot.gesture_score = presenceScore(scores[best]);
}

pub export fn goss_hand_process(instance: ?*HandInstance, rgba: ?[*]const u8, width: u32, height: u32, timestamp_us: i64) i32 {
    const p = instance orelse return status_invalid;
    const pixels = rgba orelse return status_invalid;
    if (width == 0 or height == 0) return status_invalid;
    const image: sampler.Frame = .{
        .width = width,
        .height = height,
        .pixels = .{ .rgba8 = pixels[0 .. @as(usize, width) * height * 4] },
    };

    var free_slots: usize = 0;
    for (p.locks) |maybe_lock| {
        if (maybe_lock == null) free_slots += 1;
    }
    if (free_slots > 0) handDetect(p, image);

    var result: hand.Result = std.mem.zeroes(hand.Result);
    p.serial += 1;
    result.frame_serial = p.serial;
    result.timestamp_us = timestamp_us;

    for (&p.locks) |*maybe_lock| {
        const crop = maybe_lock.* orelse continue;
        sampler.sampleRegion(image, crop, .unit, p.landmark_side, p.landmark_tensor);
        p.landmarks_engine.writeInput(0, std.mem.sliceAsBytes(p.landmark_tensor)) catch continue;
        p.landmarks_engine.invoke() catch continue;
        const raw_landmarks = p.landmarks_engine.outputFloats(0) catch continue;
        const presence = presenceScore((p.landmarks_engine.outputFloats(1) catch continue)[0]);
        if (presence < hand_presence_floor) {
            maybe_lock.* = null;
            continue;
        }
        const handedness = presenceScore((p.landmarks_engine.outputFloats(2) catch continue)[0]);
        var landmarks: [hand.landmark_count]hand.Landmark = undefined;
        hand.decodeLandmarks(raw_landmarks, crop, @floatFromInt(p.landmark_side), &landmarks);
        maybe_lock.* = hand.regionFromLandmarks(&landmarks);

        const slot = &result.hands[result.hand_count];
        slot.presence = presence;
        slot.handedness = handedness;
        slot.gesture = 0;
        slot.gesture_score = 0;
        handGesture(p, &landmarks, handedness, crop.rotation, width, height, slot);
        for (landmarks, 0..) |landmark, at| {
            slot.landmarks[at * 3] = landmark.x;
            slot.landmarks[at * 3 + 1] = landmark.y;
            slot.landmarks[at * 3 + 2] = landmark.z;
        }
        result.hand_count += 1;
    }

    p.result = result;
    p.has_result = true;
    return status_ok;
}

pub export fn goss_hand_result(instance: ?*HandInstance, out: ?[*]u8) i32 {
    const p = instance orelse return status_invalid;
    const destination = out orelse return status_invalid;
    if (!p.has_result) return status_again;
    @memcpy(destination[0..@sizeOf(hand.Result)], std.mem.asBytes(&p.result));
    return status_ok;
}
