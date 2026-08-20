//! Tracking harness: opens the pinned face model bundle, stands up the
//! inference engines, and runs the face pipeline over synthetic frames.
//! This is where the pipeline's plumbing proves itself on a host before
//! any SDK touches it: tensor shapes are interrogated from the models
//! rather than assumed, and a synthetic face-less frame must produce no
//! detections while the smoke render of a high-contrast blob exercises
//! every pre and post processing stage without crashing or leaking.

const std = @import("std");
const bundle = @import("bundle");
const runtime = @import("runtime");
const detector = @import("detector");
const sampler = @import("sampler");
const face = @import("face");
const hand = @import("hand");
const pose = @import("pose");
const face_geometry = @import("face_geometry");
const tracker = @import("tracker");

const abi = @import("abi");
const math = @import("math");

const face106 = @import("face106");
const segmentation = @import("segmentation");
const builtin = @import("builtin");

/// The beauty chain needs a windowing gl context; the harness proves it
/// where one exists and the tracking pipeline everywhere.
const beauty_available = builtin.os.tag == .macos;

const stb = @cImport(@cInclude("stb_image.h"));

extern fn goss_beauty_create(resource_path: ?[*:0]const u8) ?*anyopaque;
extern fn goss_beauty_destroy(handle: ?*anyopaque) void;
extern fn goss_beauty_set(handle: ?*anyopaque, effect: i32, value: f32) void;
extern fn goss_beauty_process(handle: ?*anyopaque, rgba_in: [*]const u8, width: i32, height: i32, landmarks106: ?[*]const f32, rgba_out: [*]u8) i32;
extern fn goss_beauty_output_texture(handle: ?*anyopaque) u32;
extern fn goss_beauty_interop_create() ?*anyopaque;
extern fn goss_beauty_interop_destroy(handle: ?*anyopaque) void;
extern fn goss_beauty_interop_composite(handle: ?*anyopaque, source_texture: u32, width: i32, height: i32) ?*anyopaque;

// CoreVideo's C ABI, called directly rather than through an objc++ shim:
// the harness only needs to read back what the GPU compositing path wrote,
// the same read a real Metal consumer would do through CVMetalTextureCache
// instead.
extern fn CVPixelBufferLockBaseAddress(buffer: ?*anyopaque, flags: u64) i32;
extern fn CVPixelBufferUnlockBaseAddress(buffer: ?*anyopaque, flags: u64) i32;
extern fn CVPixelBufferGetBaseAddress(buffer: ?*anyopaque) ?[*]u8;
extern fn CVPixelBufferGetBytesPerRow(buffer: ?*anyopaque) usize;

var harness_io: std.Io = undefined;

const Nv12Copy = struct {
    y: []u8,
    uv: []u8,
    width: u32,
    height: u32,

    fn deinit(copy: Nv12Copy, gpa: std.mem.Allocator) void {
        gpa.free(copy.y);
        gpa.free(copy.uv);
    }
};

/// Converts a decoded RGBA frame to NV12 exactly the way a camera would
/// deliver it: full range, the classic standard, chroma averaged 2x2.
fn rgbaToNv12(gpa: std.mem.Allocator, frame: sampler.Frame) !Nv12Copy {
    const bytes = frame.pixels.rgba8;
    const conversion = math.color.rgbToYuv(.bt601, .full);
    const width = frame.width;
    const height = frame.height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const y_plane = try gpa.alloc(u8, @as(usize, width) * height);
    errdefer gpa.free(y_plane);
    const uv_plane = try gpa.alloc(u8, @as(usize, half_width) * half_height * 2);
    errdefer gpa.free(uv_plane);

    for (0..height) |row| {
        for (0..width) |column| {
            const at = (row * width + column) * 4;
            const yuv = conversion.apply(.{
                @as(f32, @floatFromInt(bytes[at])) / 255.0,
                @as(f32, @floatFromInt(bytes[at + 1])) / 255.0,
                @as(f32, @floatFromInt(bytes[at + 2])) / 255.0,
            });
            y_plane[row * width + column] = @intFromFloat(std.math.clamp(yuv[0], 0.0, 1.0) * 255.0);
        }
    }
    for (0..half_height) |row| {
        for (0..half_width) |column| {
            var cb: f32 = 0;
            var cr: f32 = 0;
            var samples: f32 = 0;
            for (0..2) |dy| {
                for (0..2) |dx| {
                    const source_y = row * 2 + dy;
                    const source_x = column * 2 + dx;
                    if (source_y >= height or source_x >= width) continue;
                    const at = (source_y * width + source_x) * 4;
                    const yuv = conversion.apply(.{
                        @as(f32, @floatFromInt(bytes[at])) / 255.0,
                        @as(f32, @floatFromInt(bytes[at + 1])) / 255.0,
                        @as(f32, @floatFromInt(bytes[at + 2])) / 255.0,
                    });
                    cb += yuv[1];
                    cr += yuv[2];
                    samples += 1;
                }
            }
            const at = (row * half_width + column) * 2;
            uv_plane[at] = @intFromFloat(std.math.clamp(cb / samples, 0.0, 1.0) * 255.0);
            uv_plane[at + 1] = @intFromFloat(std.math.clamp(cr / samples, 0.0, 1.0) * 255.0);
        }
    }
    return .{ .y = y_plane, .uv = uv_plane, .width = width, .height = height };
}

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
    sampler.sampleRegion(frame, sampler.frameSquare(frame_width, frame_height), .symmetric, input_side, input_tensor);
    try detector_engine.writeInput(0, std.mem.sliceAsBytes(input_tensor));
    try detector_engine.invoke();

    const raw_boxes = try detector_engine.outputFloats(0);
    const raw_scores = try detector_engine.outputFloats(1);
    const candidates = try gpa.alloc(detector.face.Detection, 32);
    defer gpa.free(candidates);
    const detections = detector.face.decode(raw_boxes, raw_scores, anchors, @floatFromInt(input_side), 0.5, candidates);

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

        sampler.sampleRegion(image, sampler.frameSquare(image.width, image.height), .symmetric, input_side, input_tensor);
        try detector_engine.writeInput(0, std.mem.sliceAsBytes(input_tensor));
        try detector_engine.invoke();
        const found = detector.face.decode(
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

        const region = face.regionFromDetection(found[0], sampler.frameSquare(image.width, image.height));
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

    // The hand pipeline over the pinned corpus: the raised-palm frame
    // must detect a palm and land 21 in-bounds landmarks with the lock
    // holding through a tracking pass; the control frame must not.
    {
        const hand_task_bytes = try std.Io.Dir.cwd().readFileAlloc(
            harness_io,
            ".models/hand_landmarker.task",
            gpa,
            .limited(16 << 20),
        );
        defer gpa.free(hand_task_bytes);
        const hand_task = try bundle.Bundle.open(hand_task_bytes);
        const palm_entry = try hand_task.find("hand_detector.tflite");
        const hand_landmarks_entry = try hand_task.find("hand_landmarks_detector.tflite");
        const palm_bytes = try hand_task.payload(gpa, palm_entry);
        defer palm_bytes.deinit(gpa);
        const hand_landmark_bytes = try hand_task.payload(gpa, hand_landmarks_entry);
        defer hand_landmark_bytes.deinit(gpa);

        var palm_engine = try runtime.Engine.init(palm_bytes.bytes, 2);
        defer palm_engine.deinit();
        var hand_landmarks_engine = try runtime.Engine.init(hand_landmark_bytes.bytes, 2);
        defer hand_landmarks_engine.deinit();
        try reportEngine("hand_detector", &palm_engine);
        try reportEngine("hand_landmarks_detector", &hand_landmarks_engine);

        var palm_dims: [8]i32 = undefined;
        const palm_box_dims = try palm_engine.outputDims(0, &palm_dims);
        if (palm_box_dims.len < 2) return error.UnexpectedModel;
        const palm_total: usize = @intCast(palm_box_dims[1]);
        const palm_side: u32 = blk: {
            const tensor = runtime.c.TfLiteInterpreterGetInputTensor(palm_engine.interpreter, 0) orelse
                return error.UnexpectedModel;
            break :blk @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
        };
        const palm_plan = detector.planForModel(palm_side, palm_total) orelse return error.UnexpectedModel;
        const palm_anchors = try gpa.alloc(detector.Anchor, palm_total);
        defer gpa.free(palm_anchors);
        detector.generateAnchors(palm_side, palm_plan, palm_anchors);
        const palm_tensor = try gpa.alloc(f32, @as(usize, palm_side) * palm_side * 3);
        defer gpa.free(palm_tensor);
        const hand_side: u32 = blk: {
            const tensor = runtime.c.TfLiteInterpreterGetInputTensor(hand_landmarks_engine.interpreter, 0) orelse
                return error.UnexpectedModel;
            break :blk @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
        };
        const hand_tensor = try gpa.alloc(f32, @as(usize, hand_side) * hand_side * 3);
        defer gpa.free(hand_tensor);
        const palm_candidates = try gpa.alloc(detector.palm.Detection, 16);
        defer gpa.free(palm_candidates);

        for ([_]struct { path: []const u8, hands: bool }{
            .{ .path = ".models/corpus/hand_raised.jpg", .hands = true },
            .{ .path = ".models/corpus/no_face_control.jpg", .hands = false },
        }) |case| {
            const corpus = try loadCorpusFrame(gpa, case.path);
            defer corpus.deinit();
            const image = corpus.frame;
            const square = sampler.frameSquare(image.width, image.height);

            // Zero-to-one input, the palm detector's own tensor range -
            // not the face detector's symmetric range.
            sampler.sampleRegion(image, square, .unit, palm_side, palm_tensor);
            try palm_engine.writeInput(0, std.mem.sliceAsBytes(palm_tensor));
            try palm_engine.invoke();
            const palms = detector.palm.decode(
                try palm_engine.outputFloats(0),
                try palm_engine.outputFloats(1),
                palm_anchors,
                @floatFromInt(palm_side),
                0.5,
                palm_candidates,
            );
            try out.print("{s}: {d}x{d}, palm detections {d}\n", .{ case.path, image.width, image.height, palms.len });
            try out.flush();
            if (!case.hands) {
                if (palms.len != 0) return 1;
                continue;
            }
            if (palms.len == 0) return 1;

            const crop = hand.regionFromDetection(palms[0], square);
            sampler.sampleRegion(image, crop, .unit, hand_side, hand_tensor);
            try hand_landmarks_engine.writeInput(0, std.mem.sliceAsBytes(hand_tensor));
            try hand_landmarks_engine.invoke();
            const hand_raw = (try hand_landmarks_engine.outputFloats(1))[0];
            const hand_presence = if (hand_raw < 0.0 or hand_raw > 1.0)
                1.0 / (1.0 + @exp(-hand_raw))
            else
                hand_raw;
            const handedness_raw = (try hand_landmarks_engine.outputFloats(2))[0];
            const handedness = if (handedness_raw < 0.0 or handedness_raw > 1.0)
                1.0 / (1.0 + @exp(-handedness_raw))
            else
                handedness_raw;

            var hand_landmarks: [hand.landmark_count]hand.Landmark = undefined;
            hand.decodeLandmarks(try hand_landmarks_engine.outputFloats(0), crop, @floatFromInt(hand_side), &hand_landmarks);
            var inside: usize = 0;
            for (hand_landmarks) |landmark| {
                const slack_x = @as(f32, @floatFromInt(image.width)) * 0.1;
                const slack_y = @as(f32, @floatFromInt(image.height)) * 0.1;
                if (landmark.x > -slack_x and landmark.x < @as(f32, @floatFromInt(image.width)) + slack_x and
                    landmark.y > -slack_y and landmark.y < @as(f32, @floatFromInt(image.height)) + slack_y)
                {
                    inside += 1;
                }
            }
            const finger_span = @abs(hand_landmarks[12].y - hand_landmarks[0].y);
            try out.print(
                "  hand presence {d:.3}, handedness {d:.3}, landmarks inside {d}/{d}, wrist-to-middle-tip {d:.0}px\n",
                .{ hand_presence, handedness, inside, hand_landmarks.len, finger_span },
            );
            try out.flush();
            if (hand_presence < 0.5) return 1;
            if (inside != hand_landmarks.len) return 1;
            if (finger_span < crop.side * 0.05) return 1;

            // Tracking pass: the next crop comes from these landmarks
            // alone, no detector run, and must keep the lock.
            const refined = hand.regionFromLandmarks(&hand_landmarks);
            sampler.sampleRegion(image, refined, .unit, hand_side, hand_tensor);
            try hand_landmarks_engine.writeInput(0, std.mem.sliceAsBytes(hand_tensor));
            try hand_landmarks_engine.invoke();
            const tracked_raw = (try hand_landmarks_engine.outputFloats(1))[0];
            const tracked_presence = if (tracked_raw < 0.0 or tracked_raw > 1.0)
                1.0 / (1.0 + @exp(-tracked_raw))
            else
                tracked_raw;
            try out.print("  hand tracking pass: presence {d:.3}\n", .{tracked_presence});
            try out.flush();
            if (tracked_presence < 0.5) return 1;
        }

        // The same frame through the public surface, fed the gesture
        // recognizer bundle: enable proves the nested-bundle path, the
        // raised palm must come back classified as an open palm.
        const gesture_task_bytes = try std.Io.Dir.cwd().readFileAlloc(
            harness_io,
            ".models/gesture_recognizer.task",
            gpa,
            .limited(16 << 20),
        );
        defer gpa.free(gesture_task_bytes);
        const engine = try abi.createEngine(gpa, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
        defer abi.destroyEngine(engine);
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const enable_hand = abi.goss_session_enable_hand_tracking(session, gesture_task_bytes.ptr, gesture_task_bytes.len, 2);
        if (enable_hand != .ok) {
            try out.print("abi enable hand tracking: {s}\n", .{@tagName(enable_hand)});
            try out.flush();
            return 1;
        }
        const corpus = try loadCorpusFrame(gpa, ".models/corpus/hand_raised.jpg");
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = 2000,
        };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, ((planes.width + 1) / 2) * 2) != .ok) return 1;
        var hand_result: hand.Result = undefined;
        var polls: usize = 0;
        while (abi.goss_session_hand_result(session, &hand_result) == .again) {
            std.Thread.yield() catch {};
            polls += 1;
            if (polls > 100_000_000) {
                try out.print("abi hand result: timed out\n", .{});
                try out.flush();
                return 1;
            }
        }
        var open_palm_seen = false;
        for (hand_result.hands[0..hand_result.hand_count]) |tracked| {
            try out.print(
                "abi hand surface: presence {d:.3}, handedness {d:.3}, gesture {s} ({d:.3})\n",
                .{ tracked.presence, tracked.handedness, hand.gesture_names[tracked.gesture], tracked.gesture_score },
            );
            if (tracked.gesture == 2) open_palm_seen = true;
        }
        try out.flush();
        if (hand_result.hand_count == 0) return 1;
        if (hand_result.hands[0].presence < 0.5) return 1;
        if (hand_result.timestamp_us != 2000) return 1;
        // The corpus frame's raised right palm is the gesture oracle: the
        // classifier must call it an open palm through the whole rail.
        if (!open_palm_seen) return 1;
    }


    // The pose pipeline over the pinned corpus: the standing figure must
    // detect and land 33 in-bounds landmarks with a full-height spread,
    // hold through a tracking pass steered by the auxiliary pair, and
    // publish through the public surface; the control frame stays empty.
    {
        const pose_task_bytes = try std.Io.Dir.cwd().readFileAlloc(
            harness_io,
            ".models/pose_landmarker_full.task",
            gpa,
            .limited(16 << 20),
        );
        defer gpa.free(pose_task_bytes);
        const pose_task = try bundle.Bundle.open(pose_task_bytes);
        const pose_detector_entry = try pose_task.find("pose_detector.tflite");
        const pose_landmarks_entry = try pose_task.find("pose_landmarks_detector.tflite");
        const pose_detector_bytes = try pose_task.payload(gpa, pose_detector_entry);
        defer pose_detector_bytes.deinit(gpa);
        const pose_landmark_bytes = try pose_task.payload(gpa, pose_landmarks_entry);
        defer pose_landmark_bytes.deinit(gpa);

        var pose_detector_engine = try runtime.Engine.init(pose_detector_bytes.bytes, 2);
        defer pose_detector_engine.deinit();
        var pose_landmarks_engine = try runtime.Engine.init(pose_landmark_bytes.bytes, 2);
        defer pose_landmarks_engine.deinit();
        try reportEngine("pose_detector", &pose_detector_engine);
        try reportEngine("pose_landmarks_detector", &pose_landmarks_engine);

        var pose_dims: [8]i32 = undefined;
        const pose_box_dims = try pose_detector_engine.outputDims(0, &pose_dims);
        if (pose_box_dims.len < 2) return error.UnexpectedModel;
        const pose_total: usize = @intCast(pose_box_dims[1]);
        const pose_side: u32 = blk: {
            const tensor = runtime.c.TfLiteInterpreterGetInputTensor(pose_detector_engine.interpreter, 0) orelse
                return error.UnexpectedModel;
            break :blk @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
        };
        const pose_plan = detector.planForModel(pose_side, pose_total) orelse return error.UnexpectedModel;
        const pose_anchors = try gpa.alloc(detector.Anchor, pose_total);
        defer gpa.free(pose_anchors);
        detector.generateAnchors(pose_side, pose_plan, pose_anchors);
        const pose_tensor = try gpa.alloc(f32, @as(usize, pose_side) * pose_side * 3);
        defer gpa.free(pose_tensor);
        const pose_landmark_side: u32 = blk: {
            const tensor = runtime.c.TfLiteInterpreterGetInputTensor(pose_landmarks_engine.interpreter, 0) orelse
                return error.UnexpectedModel;
            break :blk @intCast(runtime.c.TfLiteTensorDim(tensor, 1));
        };
        const pose_landmark_tensor = try gpa.alloc(f32, @as(usize, pose_landmark_side) * pose_landmark_side * 3);
        defer gpa.free(pose_landmark_tensor);
        const pose_candidates = try gpa.alloc(detector.pose.Detection, 8);
        defer gpa.free(pose_candidates);

        for ([_]struct { path: []const u8, body: bool }{
            .{ .path = ".models/corpus/body_standing.jpg", .body = true },
            .{ .path = ".models/corpus/no_face_control.jpg", .body = false },
        }) |case| {
            const corpus = try loadCorpusFrame(gpa, case.path);
            defer corpus.deinit();
            const image = corpus.frame;
            const square = sampler.frameSquare(image.width, image.height);

            // Symmetric input, the pose detector's own range - not the
            // palm detector's zero-to-one.
            sampler.sampleRegion(image, square, .symmetric, pose_side, pose_tensor);
            try pose_detector_engine.writeInput(0, std.mem.sliceAsBytes(pose_tensor));
            try pose_detector_engine.invoke();
            const bodies = detector.pose.decode(
                try pose_detector_engine.outputFloats(0),
                try pose_detector_engine.outputFloats(1),
                pose_anchors,
                @floatFromInt(pose_side),
                0.5,
                pose_candidates,
            );
            try out.print("{s}: {d}x{d}, pose detections {d}\n", .{ case.path, image.width, image.height, bodies.len });
            try out.flush();
            if (!case.body) {
                if (bodies.len != 0) return 1;
                continue;
            }
            if (bodies.len == 0) return 1;

            const crop = pose.regionFromDetection(bodies[0], square);
            sampler.sampleRegion(image, crop, .unit, pose_landmark_side, pose_landmark_tensor);
            try pose_landmarks_engine.writeInput(0, std.mem.sliceAsBytes(pose_landmark_tensor));
            try pose_landmarks_engine.invoke();
            const raw_pose = try pose_landmarks_engine.outputFloats(0);
            const flag_raw = (try pose_landmarks_engine.outputFloats(1))[0];
            const body_presence = if (flag_raw < 0.0 or flag_raw > 1.0)
                1.0 / (1.0 + @exp(-flag_raw))
            else
                flag_raw;

            var body_landmarks: [pose.raw_landmark_count]pose.Landmark = undefined;
            var visibilities: [pose.raw_landmark_count]f32 = undefined;
            var point_presences: [pose.raw_landmark_count]f32 = undefined;
            pose.decodeLandmarks(raw_pose, crop, @floatFromInt(pose_landmark_side), &body_landmarks, &visibilities, &point_presences);
            var inside: usize = 0;
            var min_y = body_landmarks[0].y;
            var max_y = body_landmarks[0].y;
            for (body_landmarks[0..pose.landmark_count]) |landmark| {
                const slack_x = @as(f32, @floatFromInt(image.width)) * 0.1;
                const slack_y = @as(f32, @floatFromInt(image.height)) * 0.1;
                if (landmark.x > -slack_x and landmark.x < @as(f32, @floatFromInt(image.width)) + slack_x and
                    landmark.y > -slack_y and landmark.y < @as(f32, @floatFromInt(image.height)) + slack_y)
                {
                    inside += 1;
                }
                min_y = @min(min_y, landmark.y);
                max_y = @max(max_y, landmark.y);
            }
            const body_height = max_y - min_y;
            try out.print(
                "  pose presence {d:.3}, landmarks inside {d}/{d}, body height {d:.0}px\n",
                .{ body_presence, inside, pose.landmark_count, body_height },
            );
            try out.flush();
            if (body_presence < 0.5) return 1;
            if (inside != pose.landmark_count) return 1;
            // A standing figure must span a real fraction of the frame.
            if (body_height < @as(f32, @floatFromInt(image.height)) * 0.3) return 1;

            // Tracking pass: the next crop comes from the auxiliary
            // alignment pair alone and must keep the lock.
            const refined = pose.regionFromLandmarks(&body_landmarks);
            sampler.sampleRegion(image, refined, .unit, pose_landmark_side, pose_landmark_tensor);
            try pose_landmarks_engine.writeInput(0, std.mem.sliceAsBytes(pose_landmark_tensor));
            try pose_landmarks_engine.invoke();
            const tracked_raw = (try pose_landmarks_engine.outputFloats(1))[0];
            const tracked_presence = if (tracked_raw < 0.0 or tracked_raw > 1.0)
                1.0 / (1.0 + @exp(-tracked_raw))
            else
                tracked_raw;
            try out.print("  pose tracking pass: presence {d:.3}\n", .{tracked_presence});
            try out.flush();
            if (tracked_presence < 0.5) return 1;
        }

        // The same frame through the public surface: enable, one
        // track_frame, polled goss_session_pose_result.
        const engine = try abi.createEngine(gpa, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
        defer abi.destroyEngine(engine);
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        const enable_pose = abi.goss_session_enable_pose_tracking(session, pose_task_bytes.ptr, pose_task_bytes.len, 2);
        if (enable_pose != .ok) {
            try out.print("abi enable pose tracking: {s}\n", .{@tagName(enable_pose)});
            try out.flush();
            return 1;
        }
        const corpus = try loadCorpusFrame(gpa, ".models/corpus/body_standing.jpg");
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = 3000,
        };
        if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, ((planes.width + 1) / 2) * 2) != .ok) return 1;
        var pose_result: pose.Result = undefined;
        var polls: usize = 0;
        while (abi.goss_session_pose_result(session, &pose_result) == .again) {
            std.Thread.yield() catch {};
            polls += 1;
            if (polls > 100_000_000) {
                try out.print("abi pose result: timed out\n", .{});
                try out.flush();
                return 1;
            }
        }
        try out.print(
            "abi pose surface: serial {d}, presence {d:.3}, landmarks {d}, timestamp {d}\n",
            .{ pose_result.frame_serial, pose_result.presence, pose_result.landmark_count_out, pose_result.timestamp_us },
        );
        try out.flush();
        if (pose_result.presence < 0.5) return 1;
        if (pose_result.landmark_count_out != pose.landmark_count) return 1;
        if (pose_result.timestamp_us != 3000) return 1;
    }

    // The same portrait through the public surface: session, worker
    // thread, NV12 planes, polled result. This is the path an SDK runs.
    {
        const engine = try abi.createEngine(gpa, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
        defer abi.destroyEngine(engine);
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);

        const enable = abi.goss_session_enable_face_tracking(session, task_bytes.ptr, task_bytes.len, 2);
        if (enable != .ok) {
            try out.print("abi enable face tracking: {s}\n", .{@tagName(enable)});
            try out.flush();
            return 1;
        }

        const corpus = try loadCorpusFrame(gpa, ".models/corpus/face_frontal_b.jpg");
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);

        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = 1000,
        };
        const feed = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, ((planes.width + 1) / 2) * 2);
        if (feed != .ok) return 1;

        var result: face.Result = undefined;
        var polls: usize = 0;
        while (abi.goss_session_face_result(session, &result) == .again) {
            std.Thread.yield() catch {};
            polls += 1;
            if (polls > 100_000_000) {
                try out.print("abi result: timed out\n", .{});
                try out.flush();
                return 1;
            }
        }
        try out.print(
            "abi surface: serial {d}, presence {d:.3}, landmarks {d}, timestamp {d}\n",
            .{ result.frame_serial, result.presence, result.landmark_count_out, result.timestamp_us },
        );
        try out.flush();
        if (result.presence < 0.5) return 1;
        if (result.landmark_count_out != face.landmark_count) return 1;
        if (result.timestamp_us != 1000) return 1;

        // The head pose through the same public surface: the fit must
        // resolve on the tracked portrait, and reprojecting the basis
        // landmarks through it must land near where tracking put them.
        var head: [16]f32 = undefined;
        if (abi.goss_session_face_pose(session, &head) != .ok) {
            try out.print("abi face pose: refused\n", .{});
            try out.flush();
            return 1;
        }
        var reprojection_sum: f64 = 0;
        for (face_geometry.pose_basis) |entry| {
            const i: usize = entry.landmark;
            const cx = face_geometry.canonical_positions[i * 3];
            const cy = face_geometry.canonical_positions[i * 3 + 1];
            const cz = face_geometry.canonical_positions[i * 3 + 2];
            const px = head[0] * cx + head[4] * cy + head[8] * cz + head[12];
            const py = head[1] * cx + head[5] * cy + head[9] * cz + head[13];
            const dx = px - result.landmarks[i * 3];
            const dy = py - result.landmarks[i * 3 + 1];
            reprojection_sum += @sqrt(@as(f64, dx * dx + dy * dy));
        }
        const reprojection_mean = reprojection_sum / @as(f64, @floatFromInt(face_geometry.pose_basis.len));
        const face_span = @abs(result.landmarks[454 * 3] - result.landmarks[234 * 3]);
        try out.print(
            "abi face pose: basis reprojection mean {d:.1}px, face span {d:.0}px\n",
            .{ reprojection_mean, face_span },
        );
        try out.flush();
        // A weak-perspective fit of a real face lands the stable basis
        // within a small fraction of the face's own width.
        if (face_span <= 0) return 1;
        if (reprojection_mean > @as(f64, face_span) * 0.15) return 1;

        // Segmentation through the same public surface: one session, one
        // enable call, the same NV12 frame goss_session_track_frame already
        // fed to face tracking above now reaches the segmentation worker
        // too - proving the ABI wrapper itself (Status translation,
        // Session lifecycle), not just the worker adapter underneath it
        // (the block below drives that worker directly, mailbox and all).
        {
            const segment_bytes = try std.Io.Dir.cwd().readFileAlloc(
                harness_io,
                ".models/selfie_segmenter.tflite",
                gpa,
                .limited(16 << 20),
            );
            defer gpa.free(segment_bytes);

            const enable_seg = abi.goss_session_enable_segmentation(session, segment_bytes.ptr, segment_bytes.len, 2);
            if (enable_seg != .ok) {
                try out.print("abi enable segmentation: {s}\n", .{@tagName(enable_seg)});
                try out.flush();
                return 1;
            }

            const feed_seg = abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, ((planes.width + 1) / 2) * 2);
            if (feed_seg != .ok) return 1;

            const worker = session.segmentation_worker orelse return 1;
            var mask: [segmentation.mask_len]f32 = undefined;
            var abi_polls: usize = 0;
            while (!segmentation.readMask(worker, &mask)) {
                std.Thread.yield() catch {};
                abi_polls += 1;
                if (abi_polls > 100_000_000) {
                    try out.print("abi segmentation: timed out\n", .{});
                    try out.flush();
                    return 1;
                }
            }
            var abi_mask_min: f32 = 1.0;
            var abi_mask_max: f32 = 0.0;
            for (mask) |value| {
                if (value < 0.0 or value > 1.0) return 1;
                abi_mask_min = @min(abi_mask_min, value);
                abi_mask_max = @max(abi_mask_max, value);
            }
            try out.print("abi segmentation: mask range [{d:.3}, {d:.3}]\n", .{ abi_mask_min, abi_mask_max });
            try out.flush();
            if (abi_mask_max - abi_mask_min < 0.05) return 1;
        }

        // Segmentation, through the real worker adapter rather than a
        // bare engine call: the same latest-wins NV12 mailbox and worker
        // thread an SDK would drive, proving the mutex-guarded mask
        // buffer end to end (not graph.ResultSlot's seqlock - that copies
        // its payload one atomic word at a time, fine for face.Result's
        // few kilobytes but tens of thousands of individual atomic ops
        // per mask at frame rate).
        {
            const segment_bytes = try std.Io.Dir.cwd().readFileAlloc(
                harness_io,
                ".models/selfie_segmenter.tflite",
                gpa,
                .limited(16 << 20),
            );
            defer gpa.free(segment_bytes);

            const seg = try segmentation.create(gpa, segment_bytes, 2);
            defer segmentation.destroy(seg);

            // The same corpus portrait the face pipeline already proved
            // itself against, already converted to NV12 above - real
            // preprocessing through the worker's own crop (the whole
            // frame, letterboxed to square, matching face detection's
            // first pass) rather than a synthetic frame, so a layout bug
            // in the crop or the custom op's upsample would show up as a
            // degenerate (near-uniform) mask rather than passing on
            // arbitrary input.
            segmentation.submitNv12(
                seg,
                planes.width,
                planes.height,
                1000,
                math.color.yuvToRgb(.bt601, .full),
                planes.y.ptr,
                planes.width,
                planes.uv.ptr,
                ((planes.width + 1) / 2) * 2,
            );

            var mask: [segmentation.mask_len]f32 = undefined;
            var mask_polls: usize = 0;
            while (!segmentation.readMask(seg, &mask)) {
                std.Thread.yield() catch {};
                mask_polls += 1;
                if (mask_polls > 100_000_000) {
                    try out.print("segmentation: timed out\n", .{});
                    try out.flush();
                    return 1;
                }
            }

            var mask_min: f32 = 1.0;
            var mask_max: f32 = 0.0;
            for (mask) |value| {
                // The model's last op is a sigmoid (LOGISTIC) - every value
                // in range proves the custom op hasn't silently truncated
                // the upsample or lost the bias, since garbage here is what
                // an offset/layout bug in the transpose-conv would produce.
                if (value < 0.0 or value > 1.0) return 1;
                mask_min = @min(mask_min, value);
                mask_max = @max(mask_max, value);
            }
            try out.print("segmentation: mask {d} values, range [{d:.3}, {d:.3}]\n", .{ mask.len, mask_min, mask_max });
            try out.flush();
            // A portrait must separate subject from background; a mask
            // that reads back near-flat means the crop or the upsample
            // lost the input's real structure somewhere.
            if (mask_max - mask_min < 0.05) return 1;
        }

        // The multiclass segmenter through the same worker: the model's
        // own output size sets the class count, the compat mask stays the
        // person, and the portrait's long hair must actually land in the
        // hair class - per-class means are the oracle.
        {
            const multiclass_bytes = try std.Io.Dir.cwd().readFileAlloc(
                harness_io,
                ".models/selfie_multiclass.tflite",
                gpa,
                .limited(32 << 20),
            );
            defer gpa.free(multiclass_bytes);

            const seg = try segmentation.create(gpa, multiclass_bytes, 2);
            defer segmentation.destroy(seg);
            if (segmentation.classCount(seg) != 6) {
                try out.print("multiclass segmentation: unexpected class count {d}\n", .{segmentation.classCount(seg)});
                try out.flush();
                return 1;
            }

            segmentation.submitNv12(
                seg,
                planes.width,
                planes.height,
                1000,
                math.color.yuvToRgb(.bt601, .full),
                planes.y.ptr,
                planes.width,
                planes.uv.ptr,
                ((planes.width + 1) / 2) * 2,
            );

            var person: [segmentation.mask_len]f32 = undefined;
            var mask_polls: usize = 0;
            while (!segmentation.readMask(seg, &person)) {
                std.Thread.yield() catch {};
                mask_polls += 1;
                if (mask_polls > 100_000_000) {
                    try out.print("multiclass segmentation: timed out\n", .{});
                    try out.flush();
                    return 1;
                }
            }

            var person_sum: f64 = 0;
            var person_min: f32 = 1.0;
            var person_max: f32 = 0.0;
            for (person) |value| {
                person_min = @min(person_min, value);
                person_max = @max(person_max, value);
                person_sum += value;
            }
            const person_mean = person_sum / @as(f64, @floatFromInt(person.len));
            try out.print("multiclass segmentation: person range [{d:.3}, {d:.3}]\n", .{ person_min, person_max });
            try out.flush();
            if (person_min < -0.001 or person_max > 1.001) return 1;

            var hair: [segmentation.mask_len]f32 = undefined;
            if (!segmentation.readClassMask(seg, 1, &hair)) return 1;
            var hair_sum: f64 = 0;
            for (hair) |value| hair_sum += value;
            const hair_mean = hair_sum / @as(f64, @floatFromInt(hair.len));

            var background: [segmentation.mask_len]f32 = undefined;
            if (!segmentation.readClassMask(seg, 0, &background)) return 1;
            var background_sum: f64 = 0;
            for (background) |value| background_sum += value;
            const background_mean = background_sum / @as(f64, @floatFromInt(background.len));

            var out_of_range: [segmentation.mask_len]f32 = undefined;
            if (segmentation.readClassMask(seg, 6, &out_of_range)) return 1;

            try out.print(
                "multiclass segmentation: 6 classes, person mean {d:.3}, hair mean {d:.3}, background mean {d:.3}\n",
                .{ person_mean, hair_mean, background_mean },
            );
            try out.flush();
            // The portrait fills part of the frame with a person whose
            // hair is prominent; the letterboxed square is mostly not
            // person. Means far outside these bands mean class planes
            // are swapped or interleaving is misread.
            if (person_mean < 0.05 or person_mean > 0.8) return 1;
            if (hair_mean < 0.01 or hair_mean > 0.5) return 1;
            if (background_mean < 0.3) return 1;
        }

        // Beauty through the same public surface, fed by the session's own
        // tracking result.
        if (comptime !beauty_available) {
            try out.print("tracking harness: corpus clean through detect, landmarks, blendshapes\n", .{});
            try out.flush();
            return 0;
        }
        if (abi.goss_session_enable_beauty(session, ".vendor/gpupixel/src") != .ok) {
            try out.print("abi beauty enable refused\n", .{});
            try out.flush();
            return 1;
        }
        _ = abi.goss_session_set_beauty(session, 0, 0.9);
        _ = abi.goss_session_set_beauty(session, 1, 0.5);
        const beauty_pixels = @as(usize, corpus.frame.width) * corpus.frame.height * 4;
        const beautified = try gpa.alloc(u8, beauty_pixels);
        defer gpa.free(beautified);
        if (abi.goss_session_beautify_frame(session, corpus.frame.pixels.rgba8.ptr, corpus.frame.width, corpus.frame.height, beautified.ptr) != .ok) {
            try out.print("abi beautify refused\n", .{});
            try out.flush();
            return 1;
        }
        var abi_delta: u64 = 0;
        for (corpus.frame.pixels.rgba8, beautified) |a2, b3| {
            abi_delta += @abs(@as(i32, a2) - @as(i32, b3));
        }
        const abi_mean = @as(f64, @floatFromInt(abi_delta)) / @as(f64, @floatFromInt(beauty_pixels));
        try out.print("abi beauty: mean delta {d:.3}\n", .{abi_mean});
        try out.flush();
        if (abi_mean <= 0.5) return 1;

        // The real beauty-baseline reference lens (lenses/reference/),
        // read from disk exactly as an SDK would ship it - not a
        // hand-rolled copy that could drift from what the validator
        // actually checked. Its trigger is keyed to face.present,
        // sourced from this same session's real tracked result, and
        // ramps over 300ms; ticking it out settles the ramp, proving
        // activate/tick/dispatch land on the same beauty chain
        // goss_session_beautify_frame reads, with real inference data
        // driving a real shipped bundle end to end.
        const lens_manifest = try std.Io.Dir.cwd().readFileAlloc(
            harness_io,
            "lenses/reference/beauty-baseline/manifest.json",
            gpa,
            .limited(256 * 1024),
        );
        defer gpa.free(lens_manifest);
        if (abi.goss_session_activate_lens(session, lens_manifest.ptr, lens_manifest.len) != .ok) {
            try out.print("abi lens: activate refused\n", .{});
            try out.flush();
            return 1;
        }
        var signals = std.mem.zeroes(abi.LensSignals);
        signals.has_face = true;
        signals.blendshapes = result.blendshapes;
        var settle: usize = 0;
        while (settle < 40) : (settle += 1) {
            if (abi.goss_session_tick_lens(session, 8_333, &signals) != .ok) {
                try out.print("abi lens: tick refused\n", .{});
                try out.flush();
                return 1;
            }
        }
        const lens_beautified = try gpa.alloc(u8, beauty_pixels);
        defer gpa.free(lens_beautified);
        if (abi.goss_session_beautify_frame(session, corpus.frame.pixels.rgba8.ptr, corpus.frame.width, corpus.frame.height, lens_beautified.ptr) != .ok) {
            try out.print("abi lens: beautify refused\n", .{});
            try out.flush();
            return 1;
        }
        var lens_delta: u64 = 0;
        for (corpus.frame.pixels.rgba8, lens_beautified) |a4, b4| {
            lens_delta += @abs(@as(i32, a4) - @as(i32, b4));
        }
        const lens_mean = @as(f64, @floatFromInt(lens_delta)) / @as(f64, @floatFromInt(beauty_pixels));
        try out.print("abi lens: mean delta {d:.3}\n", .{lens_mean});
        try out.flush();
        if (lens_mean <= 0.5) return 1;
        abi.goss_session_deactivate_lens(session);
    }


    // The beauty chain over the tracked portrait: all effects at zero must
    // return the frame essentially untouched, and turning the skin smooth
    // up must actually change it, with the tracked contour feeding the
    // landmark driven effects.
    if (comptime beauty_available) {
        const corpus = try loadCorpusFrame(gpa, ".models/corpus/face_frontal_b.jpg");
        defer corpus.deinit();
        const image = corpus.frame;

        sampler.sampleRegion(image, sampler.frameSquare(image.width, image.height), .symmetric, input_side, input_tensor);
        try detector_engine.writeInput(0, std.mem.sliceAsBytes(input_tensor));
        try detector_engine.invoke();
        const found = detector.face.decode(
            try detector_engine.outputFloats(0),
            try detector_engine.outputFloats(1),
            anchors,
            @floatFromInt(input_side),
            0.5,
            candidates,
        );
        if (found.len == 0) return 1;
        const region = face.regionFromDetection(found[0], sampler.frameSquare(image.width, image.height));
        sampler.sampleRegion(image, region, .unit, landmark_side, landmark_tensor);
        try landmarks_engine.writeInput(0, std.mem.sliceAsBytes(landmark_tensor));
        try landmarks_engine.invoke();
        var landmarks: [face.landmark_count]face.Landmark = undefined;
        face.decodeLandmarks(try landmarks_engine.outputFloats(0), region, @floatFromInt(landmark_side), &landmarks);
        var contour: [face106.point_count * 2]f32 = undefined;
        face106.fill(&landmarks, @floatFromInt(image.width), @floatFromInt(image.height), &contour);

        const beauty = goss_beauty_create(".vendor/gpupixel/src") orelse return 1;
        defer goss_beauty_destroy(beauty);
        const pixel_count = @as(usize, image.width) * image.height * 4;
        const out_a = try gpa.alloc(u8, pixel_count);
        defer gpa.free(out_a);
        const source_pixels = image.pixels.rgba8;

        if (goss_beauty_process(beauty, source_pixels.ptr, @intCast(image.width), @intCast(image.height), &contour, out_a.ptr) != 0) {
            try out.print("beauty: identity process refused\n", .{});
            try out.flush();
            return 1;
        }
        var identity_delta: u64 = 0;
        for (source_pixels, out_a) |a, b2| {
            identity_delta += @abs(@as(i32, a) - @as(i32, b2));
        }
        const identity_mean = @as(f64, @floatFromInt(identity_delta)) / @as(f64, @floatFromInt(pixel_count));

        goss_beauty_set(beauty, 0, 0.9);
        goss_beauty_set(beauty, 1, 0.5);
        const out_b = try gpa.alloc(u8, pixel_count);
        defer gpa.free(out_b);
        if (goss_beauty_process(beauty, source_pixels.ptr, @intCast(image.width), @intCast(image.height), &contour, out_b.ptr) != 0) {
            try out.print("beauty: effect process refused\n", .{});
            try out.flush();
            return 1;
        }
        var effect_delta: u64 = 0;
        for (source_pixels, out_b) |a, b2| {
            effect_delta += @abs(@as(i32, a) - @as(i32, b2));
        }
        const effect_mean = @as(f64, @floatFromInt(effect_delta)) / @as(f64, @floatFromInt(pixel_count));
        try out.print("beauty: identity mean delta {d:.3}, smooth+whiten mean delta {d:.3}\n", .{ identity_mean, effect_mean });
        try out.flush();
        if (identity_mean > 2.0) return 1;
        if (effect_mean <= identity_mean + 0.5) return 1;

        // The GPU compositing bridge: out_b above is the same smooth+whiten
        // frame read back through gpupixel's own CPU path; this blits the
        // chain's live output texture into the shared surface and reads
        // that back instead, proving the two paths agree on real pixels
        // rather than just on the fact that a pointer came back non-null.
        const interop = goss_beauty_interop_create() orelse return 1;
        defer goss_beauty_interop_destroy(interop);
        const texture = goss_beauty_output_texture(beauty);
        if (texture == 0) {
            try out.print("beauty interop: no output texture\n", .{});
            try out.flush();
            return 1;
        }
        const surface = goss_beauty_interop_composite(interop, texture, @intCast(image.width), @intCast(image.height)) orelse {
            try out.print("beauty interop: composite refused\n", .{});
            try out.flush();
            return 1;
        };
        if (CVPixelBufferLockBaseAddress(surface, 0) != 0) return 1;
        defer _ = CVPixelBufferUnlockBaseAddress(surface, 0);
        const base = CVPixelBufferGetBaseAddress(surface) orelse return 1;
        const stride = CVPixelBufferGetBytesPerRow(surface);

        var composite_delta: u64 = 0;
        for (0..image.height) |row| {
            const row_bytes = base[row * stride ..][0 .. image.width * 4];
            // The composite blit vertically flips on egress, undoing the
            // live path's flipped GPU ingest. This chain was fed through
            // the CPU path, which ingests upright, so the composite is
            // the CPU readback's vertical mirror - compare accordingly.
            const cpu_row = out_b[(image.height - 1 - row) * image.width * 4 ..][0 .. image.width * 4];
            var col: usize = 0;
            while (col < image.width * 4) : (col += 4) {
                // The shared surface is BGRA; gpupixel's CPU readback is RGBA.
                composite_delta += @abs(@as(i32, row_bytes[col + 0]) - @as(i32, cpu_row[col + 2])); // B
                composite_delta += @abs(@as(i32, row_bytes[col + 1]) - @as(i32, cpu_row[col + 1])); // G
                composite_delta += @abs(@as(i32, row_bytes[col + 2]) - @as(i32, cpu_row[col + 0])); // R
                composite_delta += @abs(@as(i32, row_bytes[col + 3]) - @as(i32, cpu_row[col + 3])); // A
            }
        }
        const composite_mean = @as(f64, @floatFromInt(composite_delta)) / @as(f64, @floatFromInt(pixel_count));
        try out.print("beauty interop: gpu composite vs cpu readback mean delta {d:.3}\n", .{composite_mean});
        try out.flush();
        if (composite_mean > 2.0) return 1;
    }

    try out.print("tracking harness: corpus clean through detect, landmarks, blendshapes\n", .{});
    try out.flush();
    return 0;
}
