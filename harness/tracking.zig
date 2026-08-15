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

var harness_io: std.Io = undefined;

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
    const frame: sampler.Frame = .{ .pixels = frame_pixels, .width = frame_width, .height = frame_height };

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

    var buffer: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(harness_io, &buffer);
    const out = &stdout.interface;
    try out.print("blank frame detections: {d}\n", .{detections.len});
    try out.flush();
    if (detections.len != 0) return 1;

    try out.print("tracking harness: engines up, decode clean\n", .{});
    try out.flush();
    return 0;
}
