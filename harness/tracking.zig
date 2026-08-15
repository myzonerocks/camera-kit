//! Tracking harness: opens the pinned face model bundle, stands up the
//! inference engines, and runs the face pipeline over synthetic frames.
//! This is where the pipeline's plumbing proves itself on a host before
//! any shell touches it: tensor shapes are interrogated from the models
//! rather than assumed, and a synthetic face-less frame must produce no
//! detections while the smoke render of a high-contrast blob exercises
//! every pre and post processing stage without crashing or leaking.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const face = @import("face");
const tracker = @import("tracker");

const stb = @cImport(@cInclude("stb_image.h"));

var harness_io: std.Io = undefined;

const CorpusFrame = struct {
    frame: sampler.Frame,
    fn deinit(corpus: CorpusFrame) void {
        stb.stbi_image_free(@constCast(corpus.frame.pixels.rgba8.ptr));
    }
};

fn loadCorpusFrame(gpa: std.mem.Allocator, path: []const u8) !CorpusFrame {
    const encoded = try std.Io.Dir.cwd().readFileAlloc(harness_io, path, gpa, .limited(32 << 20));
    defer gpa.free(encoded);
    var width: c_int = 0;
    var height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &width, &height, &channels, 4) orelse
        return error.UndecodableCorpusFrame;
    const len = @as(usize, @intCast(width)) * @as(usize, @intCast(height)) * 4;
    return .{ .frame = .{
        .pixels = .{ .rgba8 = pixels[0..len] },
        .width = @intCast(width),
        .height = @intCast(height),
    } };
}

fn reportEngine(name: []const u8, engine: *const runtime.Engine) !void {
    var buffer: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(harness_io, &buffer);
    const out = &stdout.interface;
    try out.print("{s}: {d} inputs, {d} outputs\n", .{ name, engine.inputCount(), engine.outputCount() });
    for (0..engine.outputCount()) |at| {
        var dims_buffer: [8]i32 = undefined;
        const dims = try engine.outputDims(at, &dims_buffer);
        try out.print("  output {d}: dims", .{at});
        for (dims) |dim| try out.print(" {d}", .{dim});
        try out.print("\n", .{});
    }
    try out.flush();
}

pub fn main(init_args: std.process.Init) !u8 {
    harness_io = init_args.io;
    const gpa = init_args.gpa;

    const task_bytes = try std.Io.Dir.cwd().readFileAlloc(
        harness_io,
        ".models/face_landmarker.task",
        gpa,
        .limited(16 << 20),
    );
    defer gpa.free(task_bytes);

    const task = try bundle.Bundle.open(task_bytes);
    const detector_entry = try task.find("face_detector.tflite");
    const landmarks_entry = try task.find("face_landmarks_detector.tflite");
    const blendshapes_entry = try task.find("face_blendshapes.tflite");

    const detector_bytes = try task.payload(gpa, detector_entry);
    defer detector_bytes.deinit(gpa);
    const landmarks_bytes = try task.payload(gpa, landmarks_entry);
    defer landmarks_bytes.deinit(gpa);
    const blendshapes_bytes = try task.payload(gpa, blendshapes_entry);
    defer blendshapes_bytes.deinit(gpa);

    var detector_engine = try runtime.Engine.init(detector_bytes.bytes, 2);
    defer detector_engine.deinit();
    var landmarks_engine = try runtime.Engine.init(landmarks_bytes.bytes, 2);
    defer landmarks_engine.deinit();
    var blendshapes_engine = try runtime.Engine.init(blendshapes_bytes.bytes, 2);
    defer blendshapes_engine.deinit();

    try reportEngine("face_detector", &detector_engine);
    try reportEngine("face_landmarks_detector", &landmarks_engine);
    try reportEngine("face_blendshapes", &blendshapes_engine);

    // The detector's own tensors decide the anchor plan; a mismatch
    // between plan and model must fail here, not on a phone.
    var dims_buffer: [8]i32 = undefined;
    const box_dims = try detector_engine.outputDims(0, &dims_buffer);
    if (box_dims.len < 2) return error.UnexpectedModel;
    const anchor_total: usize = @intCast(box_dims[1]);
    const short_range = [_]detector.Layer{ .{ .stride = 8, .anchors_per_cell = 2 }, .{ .stride = 16, .anchors_per_cell = 6 } };
    const full_range = [_]detector.Layer{.{ .stride = 4, .anchors_per_cell = 1 }};
    var input_dims_buffer: [8]i32 = undefined;
    var input_side: u32 = 128;
    {
        const tensor = runtime.c.TfLiteInterpreterGetInputTensor(detector_engine.interpreter, 0) orelse
            return error.UnexpectedModel;
        const count: usize = @intCast(runtime.c.TfLiteTensorNumDims(tensor));
        for (input_dims_buffer[0..count], 0..) |*dim, at| {
            dim.* = runtime.c.TfLiteTensorDim(tensor, @intCast(at));
        }
        if (count != 4) return error.UnexpectedModel;
        input_side = @intCast(input_dims_buffer[1]);
    }
    const layers: []const detector.Layer = switch (anchor_total) {
        896 => &short_range,
        2304 => &full_range,
        else => return error.UnexpectedModel,
    };
    if (detector.anchorCount(input_side, layers) != anchor_total) return error.UnexpectedModel;

    const anchors = try gpa.alloc(detector.Anchor, anchor_total);
    defer gpa.free(anchors);
    detector.generateAnchors(input_side, layers, anchors);

    // A flat gray frame must produce zero detections through the whole
    // decode; anything else means score handling is broken.
    const frame_width: u32 = 640;
    const frame_height: u32 = 480;
    const frame_pixels = try gpa.alloc(u8, @as(usize, frame_width) * frame_height * 4);
    defer gpa.free(frame_pixels);
    @memset(frame_pixels, 96);
    const frame: sampler.Frame = .{ .pixels = .{ .rgba8 = frame_pixels }, .width = frame_width, .height = frame_height };

    const tensor_len = @as(usize, input_side) * input_side * 3;
    const input_tensor = try gpa.alloc(f32, tensor_len);
    defer gpa.free(input_tensor);
    sampler.sampleRegion(frame, face.frameSquare(frame_width, frame_height), .symmetric, input_side, input_tensor);
    try detector_engine.writeInput(0, std.mem.sliceAsBytes(input_tensor));
    try detector_engine.invoke();

    const raw_boxes = try detector_engine.outputFloats(0);
    const raw_scores = try detector_engine.outputFloats(1);
    const candidates = try gpa.alloc(detector.Detection, 32);
    defer gpa.free(candidates);
    const detections = detector.decode(raw_boxes, raw_scores, anchors, @floatFromInt(input_side), 0.5, candidates);

    var buffer: [512]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(harness_io, &buffer);
    const out = &stdout.interface;
    try out.print("blank frame detections: {d}\n", .{detections.len});
    try out.flush();
    if (detections.len != 0) return 1;

    // The pinned corpus: two frontal portraits that must track end to end,
    // one control frame that must produce nothing.
    const landmark_side: u32 = blk: {
        const tensor = runtime.c.TfLiteInterpreterGetInputTensor(landmarks_engine.interpreter, 0) orelse
            return error.UnexpectedModel;
        break :blk @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
    };
    const landmark_tensor = try gpa.alloc(f32, @as(usize, landmark_side) * landmark_side * 3);
    defer gpa.free(landmark_tensor);

    for ([_]struct { path: []const u8, faces: bool }{
        .{ .path = ".models/corpus/face_frontal_a.jpg", .faces = true },
        .{ .path = ".models/corpus/face_frontal_b.jpg", .faces = true },
        .{ .path = ".models/corpus/no_face_control.jpg", .faces = false },
    }) |case| {
        const corpus = try loadCorpusFrame(gpa, case.path);
        defer corpus.deinit();
        const image = corpus.frame;

        sampler.sampleRegion(image, face.frameSquare(image.width, image.height), .symmetric, input_side, input_tensor);
        try detector_engine.writeInput(0, std.mem.sliceAsBytes(input_tensor));
        try detector_engine.invoke();
        const found = detector.decode(
            try detector_engine.outputFloats(0),
            try detector_engine.outputFloats(1),
            anchors,
            @floatFromInt(input_side),
            0.5,
            candidates,
        );
        try out.print("{s}: {d}x{d}, detections {d}\n", .{ case.path, image.width, image.height, found.len });
        try out.flush();
        if (!case.faces) {
            if (found.len != 0) return 1;

            // A lock pointed at a frame with no face must drop: the
            // landmark model's presence score is the loop's only tether.
            var lock: tracker.Tracker = .{};
            lock.onDetection(.{
                .center_x = @as(f32, @floatFromInt(image.width)) * 0.5,
                .center_y = @as(f32, @floatFromInt(image.height)) * 0.5,
                .side = @as(f32, @floatFromInt(image.width)) * 0.4,
                .rotation = 0,
            });
            sampler.sampleRegion(image, lock.cropForFrame().?, .unit, landmark_side, landmark_tensor);
            try landmarks_engine.writeInput(0, std.mem.sliceAsBytes(landmark_tensor));
            try landmarks_engine.invoke();
            const no_face_raw = (try landmarks_engine.outputFloats(1))[0];
            const no_face_presence = if (no_face_raw < 0.0 or no_face_raw > 1.0)
                1.0 / (1.0 + @exp(-no_face_raw))
            else
                no_face_raw;
            var discard: [face.landmark_count]face.Landmark = undefined;
            face.decodeLandmarks(try landmarks_engine.outputFloats(0), lock.cropForFrame().?, @floatFromInt(landmark_side), &discard);
            const after = lock.onLandmarks(no_face_presence, &discard);
            try out.print("  lock on empty frame: presence {d:.3}, status {s}\n", .{ no_face_presence, @tagName(after) });
            try out.flush();
            if (after != .searching) return 1;
            continue;
        }
        if (found.len == 0) return 1;

        const region = face.regionFromDetection(found[0], face.frameSquare(image.width, image.height));
        sampler.sampleRegion(image, region, .unit, landmark_side, landmark_tensor);
        try landmarks_engine.writeInput(0, std.mem.sliceAsBytes(landmark_tensor));
        try landmarks_engine.invoke();

        const raw_presence = (try landmarks_engine.outputFloats(1))[0];
        const presence = if (raw_presence < 0.0 or raw_presence > 1.0)
            1.0 / (1.0 + @exp(-raw_presence))
        else
            raw_presence;

        var landmarks: [face.landmark_count]face.Landmark = undefined;
        face.decodeLandmarks(try landmarks_engine.outputFloats(0), region, @floatFromInt(landmark_side), &landmarks);
        var inside: usize = 0;
        for (landmarks) |landmark| {
            const slack_x = @as(f32, @floatFromInt(image.width)) * 0.1;
            const slack_y = @as(f32, @floatFromInt(image.height)) * 0.1;
            if (landmark.x > -slack_x and landmark.x < @as(f32, @floatFromInt(image.width)) + slack_x and
                landmark.y > -slack_y and landmark.y < @as(f32, @floatFromInt(image.height)) + slack_y)
            {
                inside += 1;
            }
        }
        const eye_gap = @abs(landmarks[face.rotation_end_landmark].x - landmarks[face.rotation_start_landmark].x);

        var blend_input: [face.blendshape_subset.len * 2]f32 = undefined;
        face.blendshapeInput(&landmarks, &blend_input);
        try blendshapes_engine.writeInput(0, std.mem.sliceAsBytes(&blend_input));
        try blendshapes_engine.invoke();
        const scores = try blendshapes_engine.outputFloats(0);
        var scores_in_range: usize = 0;
        for (scores) |score| {
            if (score >= 0.0 and score <= 1.0) scores_in_range += 1;
        }

        try out.print(
            "  presence {d:.3}, landmarks inside {d}/{d}, eye gap {d:.0}px, blendshapes in range {d}/{d}\n",
            .{ presence, inside, landmarks.len, eye_gap, scores_in_range, scores.len },
        );
        try out.flush();
        if (presence < 0.5) return 1;
        if (inside != landmarks.len) return 1;
        if (eye_gap < region.side * 0.05) return 1;
        if (scores_in_range != scores.len) return 1;

        // Tracking pass: the next frame's crop comes from these landmarks,
        // no detector run. On a still frame the refined crop must keep the
        // lock and land the same geometry.
        var lock: tracker.Tracker = .{};
        lock.onDetection(region);
        if (lock.onLandmarks(presence, &landmarks) != .tracking) return 1;
        const refined = lock.cropForFrame().?;
        sampler.sampleRegion(image, refined, .unit, landmark_side, landmark_tensor);
        try landmarks_engine.writeInput(0, std.mem.sliceAsBytes(landmark_tensor));
        try landmarks_engine.invoke();
        const tracked_raw = (try landmarks_engine.outputFloats(1))[0];
        const tracked_presence = if (tracked_raw < 0.0 or tracked_raw > 1.0)
            1.0 / (1.0 + @exp(-tracked_raw))
        else
            tracked_raw;
        var tracked: [face.landmark_count]face.Landmark = undefined;
        face.decodeLandmarks(try landmarks_engine.outputFloats(0), refined, @floatFromInt(landmark_side), &tracked);
        if (lock.onLandmarks(tracked_presence, &tracked) != .tracking) return 1;
        const tracked_gap = @abs(tracked[face.rotation_end_landmark].x - tracked[face.rotation_start_landmark].x);
        const gap_drift = @abs(tracked_gap - eye_gap) / eye_gap;
        try out.print(
            "  tracking pass: presence {d:.3}, eye gap {d:.0}px, drift {d:.3}\n",
            .{ tracked_presence, tracked_gap, gap_drift },
        );
        try out.flush();
        if (tracked_presence < tracker.presence_floor) return 1;
        if (gap_drift > 0.1) return 1;
    }

    try out.print("tracking harness: corpus clean through detect, landmarks, blendshapes\n", .{});
    try out.flush();
    return 0;
}
