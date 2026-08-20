//! Conformance harness: drives a real packaged reference lens through the
//! production ABI end to end - real engine, real session, real face
//! tracking and segmentation against a real corpus portrait, real
//! goss_session_activate_lens_from_directory, real goss_engine_render_frame -
//! and proves the result is bit-stable: the same fixed input rendered
//! twice produces byte-identical output. Each lens's hash also checks
//! against lenses/conformance-baseline.txt (--print regenerates it), so
//! a change that shifts a lens's real output shows up as a tracked diff
//! in review, not just same-run determinism. This is still one platform
//! (host/macOS); cross-platform value-stability is real remaining work.

const std = @import("std");
const abi = @import("abi");
const sampler = @import("sampler");
const image_adapter = @import("image");
const png = @import("png");
const world_replay = @import("world_replay");
const math = @import("math");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
});
const stb = @cImport(@cInclude("stb_image.h"));

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

const width: u32 = 400;
const height: u32 = 300;
/// Each lens runs with the segmentation model a real host would pick
/// for it: the single-class segmenter's person confidence is crisper
/// for subject compositing, the multiclass model carries the class
/// channels (hair) the channel lenses need.
const reference_lenses = [_]struct { name: []const u8, segmentation_model: []const u8 }{
    .{ .name = "shader-tint", .segmentation_model = single_class_model_path },
    .{ .name = "beauty-baseline", .segmentation_model = single_class_model_path },
    .{ .name = "background-swap", .segmentation_model = single_class_model_path },
    .{ .name = "trigger-anim", .segmentation_model = single_class_model_path },
    .{ .name = "hair-recolor", .segmentation_model = multiclass_model_path },
    .{ .name = "face-paint", .segmentation_model = single_class_model_path },
    .{ .name = "face-mask", .segmentation_model = single_class_model_path },
};
const baseline_path = "lenses/conformance-baseline.txt";
const corpus_path = ".models/corpus/face_frontal_b.jpg";
const face_bundle_path = ".models/face_landmarker.task";
const multiclass_model_path = ".models/selfie_multiclass.tflite";
const single_class_model_path = ".models/selfie_segmenter.tflite";
const beauty_resource_path = ".vendor/gpupixel/src";

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
    var img_width: c_int = 0;
    var img_height: c_int = 0;
    var channels: c_int = 0;
    const pixels = stb.stbi_load_from_memory(encoded.ptr, @intCast(encoded.len), &img_width, &img_height, &channels, 4) orelse
        return error.UndecodableCorpusFrame;
    const len = @as(usize, @intCast(img_width)) * @as(usize, @intCast(img_height)) * 4;
    return .{ .frame = .{
        .pixels = .{ .rgba8 = pixels[0..len] },
        .width = @intCast(img_width),
        .height = @intCast(img_height),
    } };
}

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
/// deliver it: full range, the classic standard, chroma averaged 2x2 -
/// through the image adapter, the kit's one CPU conversion authority.
fn rgbaToNv12(gpa: std.mem.Allocator, frame: sampler.Frame) !Nv12Copy {
    const w = frame.width;
    const h = frame.height;
    const half_width = (w + 1) / 2;
    const half_height = (h + 1) / 2;
    const y_plane = try gpa.alloc(u8, @as(usize, w) * h);
    errdefer gpa.free(y_plane);
    const uv_plane = try gpa.alloc(u8, @as(usize, half_width) * half_height * 2);
    errdefer gpa.free(uv_plane);
    try image_adapter.rgbaToNv12(gpa, frame.pixels.rgba8, w, h, y_plane, uv_plane);
    return .{ .y = y_plane, .uv = uv_plane, .width = w, .height = h };
}

/// Activates bundle_path on a fresh session with real face tracking and
/// segmentation enabled, feeds a real corpus portrait (not a synthetic
/// frame) to both the analysis path and the render preview, and
/// requests a screenshot at out_path once real results have landed -
/// bgfx's own default callback (no custom one is wired here, since
/// RendererDesc has no callback field to carry one through the frozen
/// ABI) writes it as out_path ++ ".tga".
fn renderOnce(gpa: std.mem.Allocator, engine: *abi.Engine, bundle_path: []const u8, out_path: [:0]const u8, segmentation_model: ?[]const u8) !void {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const face_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, face_bundle_path, gpa, .limited(16 << 20));
    defer gpa.free(face_bytes);
    if (abi.goss_session_enable_face_tracking(session, face_bytes.ptr, face_bytes.len, 2) != .ok) {
        return error.EnableFaceTrackingFailed;
    }
    if (segmentation_model) |model_path| {
        const segmentation_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, model_path, gpa, .limited(16 << 20));
        defer gpa.free(segmentation_bytes);
        if (abi.goss_session_enable_segmentation(session, segmentation_bytes.ptr, segmentation_bytes.len, 2) != .ok) {
            return error.EnableSegmentationFailed;
        }
    }
    // Enabled unconditionally, same as face tracking and segmentation
    // above: only beauty-baseline actually splices a beauty node, so
    // this is a real no-op for the other reference lenses (beautyActive
    // gates on the active lens, not just the session) rather than a
    // per-lens special case here. Enabling before activation matters -
    // activation applies the lens's own default effect values to
    // whatever chain is already live, and a chain enabled afterward
    // would silently miss them.
    if (abi.goss_session_enable_beauty(session, beauty_resource_path) != .ok) {
        return error.EnableBeautyFailed;
    }

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: activate {s}: {s}\n", .{ bundle_path, @tagName(activated) });
        return error.ActivationFailed;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_track_frame(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.TrackFrameFailed;
    }

    // Face tracking runs off-thread; wait for a real result before
    // proceeding so the render below reflects real landmarks, not
    // whatever the worker's first frame or two happens to still be
    // computing.
    var result: abi.FaceResult = undefined;
    var polls: usize = 0;
    while (abi.goss_session_face_result(session, &result) == .again) {
        std.Thread.yield() catch {};
        polls += 1;
        if (polls > 100_000_000) return error.FaceResultTimedOut;
    }

    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Like the face wait above: heavier segmentation models publish
    // later than the face result, so render until the mask texture
    // exists - render_frame itself polls the worker, the same way a
    // real app's frame loop picks the mask up.
    if (segmentation_model != null) {
        var mask_polls: usize = 0;
        while (session.segmentation_texture == null) {
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            mask_polls += 1;
            if (mask_polls > 100_000) return error.SegmentationTimedOut;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot(out_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
}

/// Proves video recording end to end through the public surface: a
/// real lens composites the corpus frame while recording, the finished
/// file decodes back with the recorded shape, and a decoded frame is
/// exported as the by-eye artifact.
fn proveVideoRecording(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    if (!abi.recording_supported) {
        std.debug.print("conformance: FAIL recording backend missing on this host\n", .{});
        return false;
    }
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL recording lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const path = "zig-out/conformance-recording.mp4";
    if (abi.goss_engine_recording_start(engine, session, path.ptr, path.len, null) != .ok) {
        std.debug.print("conformance: FAIL recording start\n", .{});
        return false;
    }
    const total_frames = 40;
    // Per-frame synthetic PCM: near-silence for the first half, a loud
    // burst after - the level must rise and the beat must fire, and the
    // muxed audio track must line up with the video track.
    const audio_frames_per_video_frame = 1600;
    var pcm: [audio_frames_per_video_frame * 2]f32 = undefined;
    var beat_fired = false;
    for (0..total_frames) |i| {
        const desc: abi.FrameDesc = .{
            .width = planes.width,
            .height = planes.height,
            .pixel_format = 0,
            .color_standard = 0,
            .color_range = 1,
            .flags = 0,
            .timestamp_us = @intCast((i + 1) * 33_333),
        };
        if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
            return error.SubmitFailed;
        }
        const amplitude: f32 = if (i < 30) 0.03 else 0.8;
        for (0..audio_frames_per_video_frame) |at| {
            const value = amplitude * @sin(@as(f32, @floatFromInt(i * audio_frames_per_video_frame + at)) * 0.2);
            pcm[at * 2] = value;
            pcm[at * 2 + 1] = value;
        }
        if (abi.goss_session_submit_audio(session, &pcm, audio_frames_per_video_frame, 48_000, 2, @intCast((i + 1) * 33_333)) != .ok) {
            std.debug.print("conformance: FAIL audio submit\n", .{});
            return false;
        }
        if (session.audio.beat) beat_fired = true;
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    if (!beat_fired or session.audio.level < 0.1) {
        std.debug.print("conformance: FAIL audio analysis (beat {any}, level {d:.3})\n", .{ beat_fired, session.audio.level });
        return false;
    }
    if (abi.goss_engine_recording_stop(engine) != .ok) {
        std.debug.print("conformance: FAIL recording stop\n", .{});
        return false;
    }

    const shape = abi.recordingProbe(path) catch {
        std.debug.print("conformance: FAIL the recorded file does not decode\n", .{});
        return false;
    };
    // Every encoder pool slot skips exactly its first frame while the
    // render-target wrap lands, and the engine counts those plus any
    // timestamp drops. The decoded count must match that accounting
    // (one extra sample of container-timing slack allowed - the video
    // track starts after time zero once audio sets the clock base),
    // and warmups must stay a minority of the recording.
    const accounted = total_frames - engine.recording_warmups - engine.recording_dropped;
    if (shape.frames < accounted or shape.frames > accounted + 1 or shape.frames < total_frames / 2 or shape.width != 400 or shape.height != 300) {
        std.debug.print("conformance: FAIL recorded shape {d} frames ({d} warmups, {d} dropped) {d}x{d} video {d}us\n", .{ shape.frames, engine.recording_warmups, engine.recording_dropped, shape.width, shape.height, shape.duration_us });
        return false;
    }

    const bgra = try gpa.alloc(u8, @as(usize, shape.width) * shape.height * 4);
    defer gpa.free(bgra);
    const exported = abi.recordingExportFrame(path, shape.frames / 2, bgra) catch {
        std.debug.print("conformance: FAIL recorded frame export\n", .{});
        return false;
    };
    for (0..@as(usize, exported.width) * exported.height) |at| {
        std.mem.swap(u8, &bgra[at * 4], &bgra[at * 4 + 2]);
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, bgra, exported.width, exported.height);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-recording-frame.png", .data = png_bytes.items });

    // Both tracks ride one clock, so they must END together even
    // though video starts late by the warmup frames: the probes report
    // track start + duration, and the ends stay within two frames.
    const audio_end_us = abi.recordingProbeAudio(path) catch {
        std.debug.print("conformance: FAIL the recording has no decodable audio track\n", .{});
        return false;
    };
    const drift = @abs(shape.duration_us - audio_end_us);
    if (drift > 66_666) {
        std.debug.print("conformance: FAIL a/v end drift {d}us (video end {d}, audio end {d})\n", .{ drift, shape.duration_us, audio_end_us });
        return false;
    }
    std.debug.print("conformance: PROOF recording is a decodable video with an aligned audio track ({d}/{d} frames, {d} pool warmups, {d}x{d}, video {d}us, a/v drift {d}us)\n", .{ shape.frames, total_frames, engine.recording_warmups, shape.width, shape.height, shape.duration_us, drift });
    return true;
}

/// Proves the platform photo formats end to end: JPEG and HEIC
/// captures decode back at the right shape within a small error of
/// the deterministic PNG capture's pixels. Lossy encoders are not
/// bit-stable across hosts, so nothing here pins a hash.
fn provePlatformPhotos(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    if (!abi.photo_supported) {
        std.debug.print("conformance: FAIL platform photo backend missing on this host\n", .{});
        return false;
    }
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL photo formats lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // The deterministic PNG capture is the pixel reference.
    var ref_needed: usize = 0;
    var photo_width: u32 = 0;
    var photo_height: u32 = 0;
    var probe_byte: [1]u8 = undefined;
    if (abi.goss_engine_capture_photo(engine, session, &probe_byte, 0, &ref_needed, &photo_width, &photo_height) != .invalid_argument or ref_needed == 0) {
        std.debug.print("conformance: FAIL reference png probe\n", .{});
        return false;
    }
    const ref_png = try gpa.alloc(u8, ref_needed);
    defer gpa.free(ref_png);
    var ref_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, ref_png.ptr, ref_png.len, &ref_len, &photo_width, &photo_height) != .ok) {
        std.debug.print("conformance: FAIL reference png capture\n", .{});
        return false;
    }
    const reference_image = image_adapter.decode(gpa, ref_png[0..ref_len]) catch {
        std.debug.print("conformance: FAIL reference png does not decode\n", .{});
        return false;
    };
    defer gpa.free(reference_image.rgba);
    const reference = reference_image.rgba;
    if (reference_image.width != photo_width or reference_image.height != photo_height) {
        std.debug.print("conformance: FAIL reference png shape\n", .{});
        return false;
    }

    for ([_]struct { format: u32, name: []const u8 }{
        .{ .format = 1, .name = "jpeg" },
        .{ .format = 2, .name = "heic" },
    }) |case| {
        var needed: usize = 0;
        if (abi.goss_engine_capture_photo_as(engine, session, case.format, 85, &probe_byte, 0, &needed, &photo_width, &photo_height) != .invalid_argument or needed == 0) {
            std.debug.print("conformance: FAIL {s} size probe\n", .{case.name});
            return false;
        }
        const encoded = try gpa.alloc(u8, needed);
        defer gpa.free(encoded);
        var encoded_len: usize = 0;
        if (abi.goss_engine_capture_photo_as(engine, session, case.format, 85, encoded.ptr, encoded.len, &encoded_len, &photo_width, &photo_height) != .ok) {
            std.debug.print("conformance: FAIL {s} capture\n", .{case.name});
            return false;
        }
        const decoded = try gpa.alloc(u8, @as(usize, photo_width) * photo_height * 4);
        defer gpa.free(decoded);
        var decoded_width: u32 = 0;
        var decoded_height: u32 = 0;
        abi.photoDecode(encoded[0..encoded_len], decoded, &decoded_width, &decoded_height) catch {
            std.debug.print("conformance: FAIL {s} does not decode\n", .{case.name});
            return false;
        };
        if (decoded_width != photo_width or decoded_height != photo_height) {
            std.debug.print("conformance: FAIL {s} decoded shape {d}x{d}\n", .{ case.name, decoded_width, decoded_height });
            return false;
        }
        var total_error: u64 = 0;
        for (0..@as(usize, photo_width) * photo_height) |at| {
            for (0..3) |ch| {
                const a: i32 = reference[at * 4 + ch];
                const b: i32 = decoded[at * 4 + ch];
                total_error += @abs(a - b);
            }
        }
        const mean_error = @as(f64, @floatFromInt(total_error)) / @as(f64, @floatFromInt(@as(usize, photo_width) * photo_height * 3));
        if (mean_error > 6.0) {
            std.debug.print("conformance: FAIL {s} mean channel error {d:.2} vs the png capture\n", .{ case.name, mean_error });
            return false;
        }
        const metadata = abi.photoProbeMetadata(encoded[0..encoded_len]) catch {
            std.debug.print("conformance: FAIL {s} metadata probe\n", .{case.name});
            return false;
        };
        if (metadata.orientation != 1 or !std.mem.eql(u8, metadata.software[0..metadata.software_len], "gosslens")) {
            std.debug.print("conformance: FAIL {s} metadata (orientation {d})\n", .{ case.name, metadata.orientation });
            return false;
        }
        std.debug.print("conformance: PROOF {s} photo capture decodes back within {d:.2} mean channel error, exif intact ({d} bytes)\n", .{ case.name, mean_error, encoded_len });
    }
    return true;
}

/// Proves the world seam end to end on the replay source: an orbiting
/// camera track drives world-anchored content through the public
/// surface, initializing frames draw nothing, tracking frames draw the
/// marker, and the whole sequence is bit-stable across two runs.
fn proveWorldAnchor(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/world-anchor", ".lens-packages/world-anchor".len) != .ok) {
            std.debug.print("conformance: FAIL world lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initializing_shot: []u8 = &.{};
        defer if (initializing_shot.len > 0) gpa.free(initializing_shot);
        var tracking_shot: []u8 = &.{};
        defer if (tracking_shot.len > 0) gpa.free(tracking_shot);

        const anchor = abi.WorldAnchor{ .id = 7, .pose = .{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 } };
        for (0..24) |i| {
            const replay = world_replay.stateAt(@intCast(i), 33_333, 4.0 / 3.0);
            const state = abi.WorldState{
                .tracking_state = replay.tracking_state,
                .world_from_camera = @bitCast(replay.world_from_camera.cols),
                .projection = @bitCast(replay.projection.cols),
                .timestamp_us = replay.timestamp_us,
            };
            if (abi.goss_session_submit_world(session, &state, null, 0, @ptrCast(&anchor), 1, null) != .ok) {
                std.debug.print("conformance: FAIL world submit\n", .{});
                return false;
            }
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = replay.timestamp_us,
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();

            if (i == 1 or i == 12) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const capacity = @as(usize, 400) * 300 * 4;
                const shot = try gpa.alloc(u8, capacity);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    std.debug.print("conformance: FAIL world capture at frame {d}\n", .{i});
                    gpa.free(shot);
                    return false;
                }
                if (i == 1) initializing_shot = shot else tracking_shot = shot;
            }
        }

        if (std.mem.eql(u8, initializing_shot, tracking_shot)) {
            std.debug.print("conformance: FAIL the tracked frame must differ from the initializing frame\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initializing_shot);
        hasher.update(tracking_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, tracking_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-world-anchor.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL world replay is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF world-anchored content tracks the replayed camera, degrades while initializing, bit-stable across runs\n", .{});
    return true;
}

/// Proves lens physics end to end: a dropped marker settles onto the
/// slab across advancing frame timestamps, the settled frame differs
/// from the falling frame, and two runs land bit-identical.
fn provePhysicsDrop(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/physics-drop", ".lens-packages/physics-drop".len) != .ok) {
            std.debug.print("conformance: FAIL physics lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var falling_shot: []u8 = &.{};
        defer if (falling_shot.len > 0) gpa.free(falling_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();

            if (i == 4 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    std.debug.print("conformance: FAIL physics capture at frame {d}\n", .{i});
                    gpa.free(shot);
                    return false;
                }
                if (i == 4) falling_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, falling_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the settled frame must differ from the falling frame\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(falling_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-physics-drop.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL physics is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF lens physics settles deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves high-resolution capture: a still captured at a resolution
/// larger than the 400x300 preview swap chain comes back at that
/// resolution, not clamped to preview, and decodes; a still at the
/// submitted frame's own resolution comes back at the frame size.
fn proveHighResCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL still capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    // An explicit capture resolution well past the 400x300 preview.
    const cases = [_]struct { config: abi.CaptureConfig, want_w: u32, want_h: u32 }{
        .{ .config = .{ .width = 1200, .height = 900, .supersample = 0, .format = 0, .quality = 0 }, .want_w = 1200, .want_h = 900 },
        // Zero width and height captures at the submitted frame's size.
        .{ .config = .{ .width = 0, .height = 0, .supersample = 0, .format = 0, .quality = 0 }, .want_w = planes.width, .want_h = planes.height },
    };
    for (cases) |case| {
        var needed: usize = 0;
        var still_w: u32 = 0;
        var still_h: u32 = 0;
        var probe_byte: [1]u8 = undefined;
        if (abi.goss_engine_capture_still(engine, session, &case.config, &probe_byte, 0, &needed, &still_w, &still_h) != .invalid_argument or needed == 0) {
            std.debug.print("conformance: FAIL still size probe ({d}x{d})\n", .{ case.want_w, case.want_h });
            return false;
        }
        if (still_w != case.want_w or still_h != case.want_h) {
            std.debug.print("conformance: FAIL still captured at {d}x{d}, wanted {d}x{d} (preview is 400x300)\n", .{ still_w, still_h, case.want_w, case.want_h });
            return false;
        }
        const encoded = try gpa.alloc(u8, needed);
        defer gpa.free(encoded);
        var encoded_len: usize = 0;
        if (abi.goss_engine_capture_still(engine, session, &case.config, encoded.ptr, encoded.len, &encoded_len, &still_w, &still_h) != .ok) {
            std.debug.print("conformance: FAIL still capture ({d}x{d})\n", .{ case.want_w, case.want_h });
            return false;
        }
        const decoded = image_adapter.decode(gpa, encoded[0..encoded_len]) catch {
            std.debug.print("conformance: FAIL still does not decode\n", .{});
            return false;
        };
        defer gpa.free(decoded.rgba);
        if (decoded.width != case.want_w or decoded.height != case.want_h) {
            std.debug.print("conformance: FAIL still decoded at {d}x{d}\n", .{ decoded.width, decoded.height });
            return false;
        }
    }
    // Supersampling: the same output size, but the effect chain rendered
    // larger and box-downsampled, so the pixels differ from 1x (real
    // anti-aliasing) and two supersampled captures are byte-identical.
    const base_cfg = abi.CaptureConfig{ .width = 300, .height = 200, .supersample = 1, .format = 0, .quality = 0 };
    const ss_cfg = abi.CaptureConfig{ .width = 300, .height = 200, .supersample = 2, .format = 0, .quality = 0 };
    var ss_out_w: u32 = 0;
    var ss_out_h: u32 = 0;
    var base_len: usize = 0;
    var ss_len_a: usize = 0;
    var ss_len_b: usize = 0;
    const base_buf = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(base_buf);
    const ss_a = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(ss_a);
    const ss_b = try gpa.alloc(u8, 300 * 200 * 4 + 4096);
    defer gpa.free(ss_b);
    if (abi.goss_engine_capture_still(engine, session, &base_cfg, base_buf.ptr, base_buf.len, &base_len, &ss_out_w, &ss_out_h) != .ok) {
        std.debug.print("conformance: FAIL base capture for supersample compare\n", .{});
        return false;
    }
    if (abi.goss_engine_capture_still(engine, session, &ss_cfg, ss_a.ptr, ss_a.len, &ss_len_a, &ss_out_w, &ss_out_h) != .ok or ss_out_w != 300 or ss_out_h != 200) {
        std.debug.print("conformance: FAIL supersampled capture ({d}x{d})\n", .{ ss_out_w, ss_out_h });
        return false;
    }
    if (abi.goss_engine_capture_still(engine, session, &ss_cfg, ss_b.ptr, ss_b.len, &ss_len_b, &ss_out_w, &ss_out_h) != .ok) {
        std.debug.print("conformance: FAIL second supersampled capture\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, ss_a[0..ss_len_a], ss_b[0..ss_len_b])) {
        std.debug.print("conformance: FAIL supersampled capture is not deterministic\n", .{});
        return false;
    }
    if (std.mem.eql(u8, base_buf[0..base_len], ss_a[0..ss_len_a])) {
        std.debug.print("conformance: FAIL supersampling did not change the pixels\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF supersampled capture is the same size, anti-aliased (differs from 1x), and deterministic\n", .{});

    std.debug.print("conformance: PROOF stills capture at their own resolution ({d}x{d} source and 1200x900 explicit), decoupled from the 400x300 preview\n", .{ planes.width, planes.height });
    return true;
}

/// Proves tiled composition: a capture split across a lowered tile cap is
/// composited tile by tile and stitched, and the result is byte-identical
/// to the same capture as a single target. Tiling breaks the texture-size
/// ceiling on a full-sensor still without ever changing a pixel.
fn proveTiledCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len) != .ok) {
        std.debug.print("conformance: FAIL tiled capture lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const cfg = abi.CaptureConfig{ .width = 400, .height = 300, .supersample = 0, .format = 0, .quality = 0 };
    const buf_cap = 400 * 300 * 4 + 4096;

    // The reference: the whole 400x300 output composited in one target.
    const whole = try gpa.alloc(u8, buf_cap);
    defer gpa.free(whole);
    var whole_len: usize = 0;
    var ow: u32 = 0;
    var oh: u32 = 0;
    session.capture_tile_cap = 0;
    if (abi.goss_engine_capture_still(engine, session, &cfg, whole.ptr, whole.len, &whole_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
        std.debug.print("conformance: FAIL single-target capture for the tiling compare\n", .{});
        return false;
    }

    // Two lowered caps forcing different grids: 200 -> 2x2, 150 -> 3x2.
    // Each stitched result must match the single-target bytes exactly.
    const caps = [_]u32{ 200, 150 };
    for (caps) |tcap| {
        const tiled = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled);
        var tiled_len: usize = 0;
        session.capture_tile_cap = tcap;
        const status = abi.goss_engine_capture_still(engine, session, &cfg, tiled.ptr, tiled.len, &tiled_len, &ow, &oh);
        session.capture_tile_cap = 0;
        if (status != .ok or ow != 400 or oh != 300) {
            std.debug.print("conformance: FAIL tiled capture at cap {d}\n", .{tcap});
            return false;
        }
        if (!std.mem.eql(u8, whole[0..whole_len], tiled[0..tiled_len])) {
            std.debug.print("conformance: FAIL tiled capture at cap {d} is not byte-identical to the single target\n", .{tcap});
            return false;
        }
    }

    std.debug.print("conformance: PROOF tiled composition stitches byte-identical to a single-target render (2x2 and 3x2 grids)\n", .{});
    return true;
}

/// Proves a script node: the sandboxed script reads a signal and writes a
/// lens parameter each tick, deterministically, and the host reads it back
/// through the ABI. The scripting section's end-to-end proof.
fn proveScript(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/script-param", ".lens-packages/script-param".len) != .ok) {
        std.debug.print("conformance: FAIL script lens activation\n", .{});
        return false;
    }

    const name = "intensity";
    var present = std.mem.zeroes(abi.LensSignals);
    present.has_face = true;
    const absent = std.mem.zeroes(abi.LensSignals);

    var v_present: f32 = -1;
    var v_absent: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v_present) != .ok) {
        std.debug.print("conformance: FAIL reading the script-driven parameter\n", .{});
        return false;
    }
    _ = abi.goss_session_tick_lens(session, 16000, &absent);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_absent);

    if (@abs(v_present - 0.8) > 1e-6 or @abs(v_absent - 0.2) > 1e-6) {
        std.debug.print("conformance: FAIL script drove intensity to {d}/{d}, wanted 0.8/0.2\n", .{ v_present, v_absent });
        return false;
    }

    // Deterministic: the same signal produces the same value, bit for bit.
    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &present);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v_present) {
        std.debug.print("conformance: FAIL script is not deterministic ({d} vs {d})\n", .{ v_again, v_present });
        return false;
    }

    std.debug.print("conformance: PROOF a script node drives a lens parameter from a signal deterministically (0.8 present, 0.2 absent)\n", .{});
    return true;
}

/// Proves lens audio: a play_sound trigger starts a voice that the mixer
/// pulls out as PCM, silent before the trigger, non-silent after, and
/// bit-identical across two runs of the same sequence.
fn proveAudio(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const block: u32 = 512;

    var captured: [2][block]i16 = undefined;
    for (0..2) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/sound-beat", ".lens-packages/sound-beat".len) != .ok) {
            std.debug.print("conformance: FAIL sound lens activation\n", .{});
            return false;
        }

        // Before any trigger the mixer has no voice, so the pull is silent.
        var pre: [block]i16 = undefined;
        _ = abi.goss_session_pull_audio(session, &pre, block);
        var pre_energy: u64 = 0;
        for (pre) |s| pre_energy += @abs(@as(i32, s));
        if (pre_energy != 0) {
            std.debug.print("conformance: FAIL audio before the trigger is not silent\n", .{});
            return false;
        }

        // Face present fires the play_sound trigger; the next pull carries it.
        var present = std.mem.zeroes(abi.LensSignals);
        present.has_face = true;
        _ = abi.goss_session_tick_lens(session, 16000, &present);
        _ = abi.goss_session_pull_audio(session, &captured[run], block);
    }
    _ = gpa;

    var energy: u64 = 0;
    for (captured[0]) |s| energy += @abs(@as(i32, s));
    if (energy == 0) {
        std.debug.print("conformance: FAIL the sound did not play after the trigger\n", .{});
        return false;
    }
    if (!std.mem.eql(i16, &captured[0], &captured[1])) {
        std.debug.print("conformance: FAIL lens audio is not deterministic across runs\n", .{});
        return false;
    }

    std.debug.print("conformance: PROOF a play_sound trigger mixes a voice the SDK pulls, silent before and bit-stable after\n", .{});
    return true;
}

/// Proves physics chains: a dynamic pendant chained to a static anchor
/// swings out under gravity to hang at the chain length, the settled
/// frame differs from the initial frame, and two runs are identical.
fn provePhysicsChain(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/physics-chain", ".lens-packages/physics-chain".len) != .ok) {
            std.debug.print("conformance: FAIL chain lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the chained pendant did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-physics-chain.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL physics chain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a chained pendant swings and hangs deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves lens cloth: a simulated flag drapes under gravity across
/// advancing frames, the settled frame differs from the initial, and
/// two runs land bit-identical.
fn proveClothFlag(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/cloth-flag", ".lens-packages/cloth-flag".len) != .ok) {
            std.debug.print("conformance: FAIL cloth lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the cloth did not drape\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-cloth-flag.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL cloth is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a simulated cloth flag drapes deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves lens particles: the fountain emits and falls deterministically over
/// frames, the settled frame differing from the initial and bit-stable across
/// two runs.
fn proveParticles(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/sparkles", ".lens-packages/sparkles".len) != .ok) {
            std.debug.print("conformance: FAIL particle lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the particles did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-sparkles.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL particles are not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a particle fountain emits and falls deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves the fading-particle path: the ember-fountain lens sets fade, so each
/// point is alpha-blended by its remaining life through the particle program
/// rather than drawn opaque. The fountain still develops (settled differs from
/// initial) and the whole thing is bit-stable across runs.
fn proveEmber(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/ember-fountain", ".lens-packages/ember-fountain".len) != .ok) {
            std.debug.print("conformance: FAIL ember lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the ember fountain did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-ember-fountain.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL the ember fountain is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF a fading particle fountain alpha-blends each point by its life deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves a post-effect lens activates from raw json, no bundle directory:
/// goss_session_activate_lens on a blur.pass manifest builds the composite
/// chain (the asset-free path the web uses), so the capture differs from the
/// plain frame and is bit-stable - post-effects reach the browser too.
fn proveJsonPostEffect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const blur_manifest =
        \\{"glf":"1.0","id":"goss.test.json-blur","version":"1.0.0","display_name":"JSON Blur","engine_compat":">=0.5","capabilities":[],"parameters":[],"nodes":[{"id":"b","type":"blur.pass","inputs":{"frame":"camera"},"params":{}}],"triggers":[]}
    ;
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (0..3) |run| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (run > 0) {
            if (abi.goss_session_activate_lens(session, blur_manifest.ptr, blur_manifest.len) != .ok) {
                std.debug.print("conformance: FAIL json blur activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL json post-effect is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL a json-activated blur.pass did not change the frame\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a post-effect lens activates from raw json and renders deterministically, no bundle directory needed\n", .{});
    return true;
}

/// Proves the whole node graph composes in one lens: studio-full runs a
/// beauty.face smooth, then grade.pass, bloom.pass and a fading ember fountain
/// over the same frame; its settled capture differs from the plain frame and
/// is bit-stable - beauty, post-effects and particles coexisting in one pass.
fn proveFullStack(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/studio-full", ".lens-packages/studio-full" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL studio-full lens activation\n", .{});
                return false;
            }
        }
        var shot: []u8 = &.{};
        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
            }
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL the full stack is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL the full stack did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-studio-full.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF beauty, grade, bloom and a fading particle fountain compose in one lens deterministically, differing from the plain frame\n", .{});
    return true;
}

/// Proves a blur.pass post-effect: the built-in separable blur softens the
/// frame, so a blurred capture differs from the un-blurred one and is
/// bit-stable across runs (no asset, always ready).
fn proveBlur(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/soft-blur", ".lens-packages/soft-blur" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL blur lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL blur is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL blur.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-soft-blur.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a blur.pass softens the frame deterministically, differing from the un-blurred capture\n", .{});
    return true;
}

/// Proves a grade.pass post-effect: the parametric color grade shifts the
/// frame (warm, brighter, more contrast), so a graded capture differs from
/// the un-graded one and is bit-stable across runs (no asset, ready at
/// activation).
fn proveGrade(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/warm-grade", ".lens-packages/warm-grade" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL grade lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL grade is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL grade.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-warm-grade.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a grade.pass shifts the frame's color deterministically, differing from the un-graded capture\n", .{});
    return true;
}

/// Proves a bloom.pass post-effect: the bright pass, separable blur and
/// additive composite bleed a glow from the highlights, so a bloomed
/// capture differs from the plain one and is bit-stable across runs (no
/// asset, ready at activation).
fn proveBloom(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/glow-bloom", ".lens-packages/glow-bloom" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL bloom lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL bloom is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL bloom.pass did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-glow-bloom.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF a bloom.pass glows the frame's highlights deterministically, differing from the plain capture\n", .{});
    return true;
}

/// Proves the post-effect nodes compose: a lens chaining blur.pass into
/// grade.pass into bloom.pass runs all three in one composite chain, its
/// capture bit-stable and differing from the plain frame - the multi-stage
/// path (ping-pong, bloom scratch) the single-node proofs never exercise.
fn proveStackedPostEffects(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const corpus = try loadCorpusFrame(gpa, corpus_path);
    defer corpus.deinit();
    const planes = try rgbaToNv12(gpa, corpus.frame);
    defer planes.deinit(gpa);
    const half_w = (planes.width + 1) / 2;

    const lenses = [_]?[]const u8{ null, ".lens-packages/studio-stack", ".lens-packages/studio-stack" };
    var shots: [3][]u8 = undefined;
    var taken: usize = 0;
    defer for (shots[0..taken]) |shot| gpa.free(shot);

    for (lenses) |lens_pkg| {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (lens_pkg) |pkg| {
            if (abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len) != .ok) {
                std.debug.print("conformance: FAIL stacked post-effect lens activation\n", .{});
                return false;
            }
        }
        for (0..3) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
                return error.SubmitFailed;
            }
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
        }
        var shot_width: u32 = 0;
        var shot_height: u32 = 0;
        const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
        errdefer gpa.free(shot);
        if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
            gpa.free(shot);
            return false;
        }
        shots[taken] = shot;
        taken += 1;
    }
    if (!std.mem.eql(u8, shots[1], shots[2])) {
        std.debug.print("conformance: FAIL the stacked post-effect chain is not bit-stable across runs\n", .{});
        return false;
    }
    if (std.mem.eql(u8, shots[0], shots[1])) {
        std.debug.print("conformance: FAIL the stacked post-effect chain did not change the frame\n", .{});
        return false;
    }
    var png_bytes: std.ArrayList(u8) = .empty;
    defer png_bytes.deinit(gpa);
    try png.encodeRgba(gpa, &png_bytes, shots[1], 400, 300);
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-studio-stack.png", .data = png_bytes.items });
    std.debug.print("conformance: PROOF blur, grade and bloom compose in one chain deterministically, differing from the plain capture\n", .{});
    return true;
}

/// Proves the post-effect chain tiles correctly under HD capture: the
/// studio-stack lens (blur, grade, bloom) captured tile-by-tile stitches
/// byte-identical to the single-target render, so the tile-aware post-effect
/// path - bloom's own scratch pair included - holds across grid sizes.
fn proveTiledPostEffect(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/studio-stack", ".lens-packages/studio-stack".len) != .ok) {
        std.debug.print("conformance: FAIL tiled post-effect lens activation\n", .{});
        return false;
    }
    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    const cfg = abi.CaptureConfig{ .width = 400, .height = 300, .supersample = 0, .format = 0, .quality = 0 };
    const buf_cap = 400 * 300 * 4 + 4096;
    const whole = try gpa.alloc(u8, buf_cap);
    defer gpa.free(whole);
    var whole_len: usize = 0;
    var ow: u32 = 0;
    var oh: u32 = 0;
    session.capture_tile_cap = 0;
    if (abi.goss_engine_capture_still(engine, session, &cfg, whole.ptr, whole.len, &whole_len, &ow, &oh) != .ok or ow != 400 or oh != 300) {
        std.debug.print("conformance: FAIL single-target capture for the post-effect tiling compare\n", .{});
        return false;
    }
    const caps = [_]u32{ 200, 150 };
    for (caps) |tcap| {
        const tiled = try gpa.alloc(u8, buf_cap);
        defer gpa.free(tiled);
        var tiled_len: usize = 0;
        session.capture_tile_cap = tcap;
        const status = abi.goss_engine_capture_still(engine, session, &cfg, tiled.ptr, tiled.len, &tiled_len, &ow, &oh);
        session.capture_tile_cap = 0;
        if (status != .ok or ow != 400 or oh != 300) {
            std.debug.print("conformance: FAIL tiled post-effect capture at cap {d}\n", .{tcap});
            return false;
        }
        if (!std.mem.eql(u8, whole[0..whole_len], tiled[0..tiled_len])) {
            std.debug.print("conformance: FAIL tiled post-effect capture at cap {d} is not byte-identical to the single target\n", .{tcap});
            return false;
        }
    }
    std.debug.print("conformance: PROOF the blur/grade/bloom chain tiles byte-identical to a single-target render (2x2 and 3x2 grids)\n", .{});
    return true;
}

/// Proves a script reads a facial blendshape: the script-expression lens maps
/// lens.signals.jawOpen straight to a parameter, so a wide-open jaw drives it
/// near 1 and a nearly-closed jaw near 0, deterministically - the expression
/// surface a trigger already reaches through jawOpen.blendshape.
fn proveExpressionScript(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    _ = gpa;
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/script-expression", ".lens-packages/script-expression".len) != .ok) {
        std.debug.print("conformance: FAIL script-expression lens activation\n", .{});
        return false;
    }

    const name = "open_amount";
    // blendshape_names[25] is jawOpen, pinned by a face module test.
    const jaw_open = 25;
    var open = std.mem.zeroes(abi.LensSignals);
    open.has_face = true;
    open.blendshapes[jaw_open] = 0.9;
    var closed = std.mem.zeroes(abi.LensSignals);
    closed.has_face = true;
    closed.blendshapes[jaw_open] = 0.1;

    var v_open: f32 = -1;
    var v_closed: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &open);
    if (abi.goss_session_parameter_value(session, name.ptr, name.len, &v_open) != .ok) {
        std.debug.print("conformance: FAIL reading the expression-driven parameter\n", .{});
        return false;
    }
    _ = abi.goss_session_tick_lens(session, 16000, &closed);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_closed);
    if (@abs(v_open - 0.9) > 1e-6 or @abs(v_closed - 0.1) > 1e-6) {
        std.debug.print("conformance: FAIL script read jawOpen as {d}/{d}, wanted 0.9/0.1\n", .{ v_open, v_closed });
        return false;
    }

    var v_again: f32 = -1;
    _ = abi.goss_session_tick_lens(session, 16000, &open);
    _ = abi.goss_session_parameter_value(session, name.ptr, name.len, &v_again);
    if (v_again != v_open) {
        std.debug.print("conformance: FAIL expression script is not deterministic ({d} vs {d})\n", .{ v_again, v_open });
        return false;
    }

    std.debug.print("conformance: PROOF a script reads a facial blendshape (jawOpen) and drives a parameter from it deterministically (0.9 open, 0.1 closed)\n", .{});
    return true;
}

/// Proves the session lifecycle leaks no memory: many activate/tick/destroy
/// cycles of the adapter-heavy lenses (blur, grade, bloom, audio, script) run
/// on a headless engine under a leak-checking allocator, which reports no leak
/// only if every session and the engine free everything - a phone-heat gate.
fn proveNoLeaks(gpa: std.mem.Allocator) !bool {
    _ = gpa;
    const leak_lenses = [_][]const u8{
        ".lens-packages/soft-blur",
        ".lens-packages/warm-grade",
        ".lens-packages/glow-bloom",
        ".lens-packages/sound-beat",
        ".lens-packages/script-param",
    };
    var check: std.heap.DebugAllocator(.{}) = .init;
    const leak_gpa = check.allocator();
    {
        const engine = try abi.createEngine(leak_gpa, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
        defer abi.destroyEngine(engine);
        var cycle: usize = 0;
        while (cycle < 32) : (cycle += 1) {
            for (leak_lenses) |pkg| {
                const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
                defer abi.destroySession(session);
                _ = abi.goss_session_activate_lens_from_directory(session, pkg.ptr, pkg.len);
                var signals = std.mem.zeroes(abi.LensSignals);
                signals.has_face = true;
                var t: u32 = 0;
                while (t < 4) : (t += 1) {
                    _ = abi.goss_session_tick_lens(session, 33_333, &signals);
                }
            }
        }
    }
    if (check.deinit() == .leak) {
        std.debug.print("conformance: FAIL the session lifecycle leaked memory across activate/tick/destroy cycles\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF repeated lens activate/tick/destroy cycles leak no memory (blur, grade, bloom, audio, script)\n", .{});
    return true;
}

/// Proves lens strand hair: the strands hang and settle deterministically
/// across frames (the head pose drives them live on device; here a fixed
/// pose gives a bit-stable host proof), settled differing from initial.
fn proveHairSim(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    var first_hash: [64]u8 = undefined;
    var runs: u32 = 0;
    while (runs < 2) : (runs += 1) {
        const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
        defer abi.destroySession(session);
        defer settle(engine);

        if (abi.goss_session_activate_lens_from_directory(session, ".lens-packages/hair-sim", ".lens-packages/hair-sim".len) != .ok) {
            std.debug.print("conformance: FAIL hair lens activation\n", .{});
            return false;
        }
        const corpus = try loadCorpusFrame(gpa, corpus_path);
        defer corpus.deinit();
        const planes = try rgbaToNv12(gpa, corpus.frame);
        defer planes.deinit(gpa);
        const half_w = (planes.width + 1) / 2;

        var initial_shot: []u8 = &.{};
        defer if (initial_shot.len > 0) gpa.free(initial_shot);
        var settled_shot: []u8 = &.{};
        defer if (settled_shot.len > 0) gpa.free(settled_shot);

        for (0..90) |i| {
            const desc: abi.FrameDesc = .{
                .width = planes.width,
                .height = planes.height,
                .pixel_format = 0,
                .color_standard = 0,
                .color_range = 1,
                .flags = 0,
                .timestamp_us = @intCast((i + 1) * 33_333),
            };
            if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) return error.SubmitFailed;
            _ = abi.goss_engine_render_frame(engine, session);
            c.glfwPollEvents();
            if (i == 2 or i == 85) {
                var shot_width: u32 = 0;
                var shot_height: u32 = 0;
                const shot = try gpa.alloc(u8, @as(usize, 400) * 300 * 4);
                errdefer gpa.free(shot);
                if (abi.goss_engine_capture_frame(engine, session, shot.ptr, shot.len, &shot_width, &shot_height) != .ok) {
                    gpa.free(shot);
                    return false;
                }
                if (i == 2) initial_shot = shot else settled_shot = shot;
            }
        }
        if (std.mem.eql(u8, initial_shot, settled_shot)) {
            std.debug.print("conformance: FAIL the hair did not move\n", .{});
            return false;
        }
        var digest: [32]u8 = undefined;
        var hasher = std.crypto.hash.sha2.Sha256.init(.{});
        hasher.update(initial_shot);
        hasher.update(settled_shot);
        hasher.final(&digest);
        const hash = std.fmt.bytesToHex(digest, .lower);
        if (runs == 0) {
            first_hash = hash;
            var png_bytes: std.ArrayList(u8) = .empty;
            defer png_bytes.deinit(gpa);
            try png.encodeRgba(gpa, &png_bytes, settled_shot, 400, 300);
            try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-hair-sim.png", .data = png_bytes.items });
        } else if (!std.mem.eql(u8, &first_hash, &hash)) {
            std.debug.print("conformance: FAIL hair is not bit-stable across runs\n", .{});
            return false;
        }
    }
    std.debug.print("conformance: PROOF strand hair driven by the head pose settles deterministically, bit-stable across runs\n", .{});
    return true;
}

/// Proves the zero-mask degradation: hair-recolor against a model with
/// no hair class renders exactly the frame it renders with no
/// segmentation at all, and both differ from the real multiclass
/// render - the masked effect draws nothing, never everywhere.
fn proveMaskDegradation(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    try renderOnce(gpa, engine, ".lens-packages/hair-recolor", "zig-out/conformance-hair-degraded", single_class_model_path);
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/hair-recolor", "zig-out/conformance-hair-unsegmented", null);
    settle(engine);

    const degraded = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-degraded.tga", gpa, .limited(8 << 20));
    defer gpa.free(degraded);
    const unsegmented = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-unsegmented.tga", gpa, .limited(8 << 20));
    defer gpa.free(unsegmented);
    if (!std.mem.eql(u8, degraded, unsegmented)) {
        std.debug.print("conformance: FAIL a hair mask without a hair class must render exactly like no segmentation\n", .{});
        return false;
    }
    const real = try std.Io.Dir.cwd().readFileAlloc(harness_io, "zig-out/conformance-hair-recolor-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(real);
    if (std.mem.eql(u8, degraded, real)) {
        std.debug.print("conformance: FAIL the multiclass hair render must differ from the degraded render\n", .{});
        return false;
    }
    std.debug.print("conformance: PROOF a named mask channel without live data degrades to zero, never all-foreground\n", .{});
    return true;
}

/// Proves goss_engine_capture_photo end to end: the size probe
/// reports the exact needed size, a capture into an exactly-sized
/// buffer yields well-formed PNG bytes, and two captures of the same
/// composited frame are byte-identical.
fn provePhotoCapture(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);
    defer settle(engine);

    const activated = abi.goss_session_activate_lens_from_directory(session, ".lens-packages/shader-tint", ".lens-packages/shader-tint".len);
    if (activated != .ok) {
        std.debug.print("conformance: FAIL photo lens activation: {t}\n", .{activated});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var needed: usize = 0;
    var photo_width: u32 = 0;
    var photo_height: u32 = 0;
    const probe = abi.goss_engine_capture_photo(engine, session, @ptrCast(&needed), 0, &needed, &photo_width, &photo_height);
    if (probe != .invalid_argument or needed == 0) {
        std.debug.print("conformance: FAIL photo size probe: {t}, needed {d}\n", .{ probe, needed });
        return false;
    }

    const first = try gpa.alloc(u8, needed);
    defer gpa.free(first);
    var first_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, first.ptr, first.len, &first_len, &photo_width, &photo_height) != .ok or first_len != needed) {
        std.debug.print("conformance: FAIL photo capture into an exactly-sized buffer\n", .{});
        return false;
    }
    const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };
    if (!std.mem.eql(u8, first[0..8], &png_signature) or !std.mem.eql(u8, first[12..16], "IHDR")) {
        std.debug.print("conformance: FAIL photo bytes are not a PNG\n", .{});
        return false;
    }
    if (std.mem.readInt(u32, first[16..20], .big) != photo_width or std.mem.readInt(u32, first[20..24], .big) != photo_height) {
        std.debug.print("conformance: FAIL photo IHDR does not match the reported size\n", .{});
        return false;
    }

    const second = try gpa.alloc(u8, needed);
    defer gpa.free(second);
    var second_len: usize = 0;
    if (abi.goss_engine_capture_photo(engine, session, second.ptr, second.len, &second_len, &photo_width, &photo_height) != .ok) {
        std.debug.print("conformance: FAIL second photo capture\n", .{});
        return false;
    }
    if (!std.mem.eql(u8, first[0..first_len], second[0..second_len])) {
        std.debug.print("conformance: FAIL photo capture produced different bytes across two runs\n", .{});
        return false;
    }
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = "zig-out/conformance-photo.png", .data = first[0..first_len] });
    std.debug.print("conformance: PROOF photo capture is a deterministic PNG of the composited frame ({d}x{d}, {d} bytes, sha256 {s})\n", .{ photo_width, photo_height, first_len, sha256Hex(first[0..first_len]) });
    return true;
}

/// Pumps a few frames with no active session, purely so bgfx has enough
/// frame boundaries to actually retire whatever the session just
/// destroyed - destroySession's own bgfx_destroy_* calls only queue
/// destruction until the GPU is done with a resource, they do not force
/// it, so creating (or shutting down) immediately after leaves handles
/// bgfx itself still considers in flight.
fn settle(engine: *abi.Engine) void {
    for (0..10) |_| {
        _ = abi.goss_engine_render_frame(engine, null);
        c.glfwPollEvents();
    }
}

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Activates lens_name's packaged bundle twice, rendering the same real
/// corpus portrait through each, and asserts the two screenshots are
/// byte-identical - proving the lens is bit-stable, not just that it
/// happened to render something. Returns the hex hash of that output on
/// success, null (with a printed reason) on failure.
fn checkDeterminism(gpa: std.mem.Allocator, engine: *abi.Engine, lens_name: []const u8, segmentation_model: []const u8) !?[64]u8 {
    var bundle_buf: [256]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buf, ".lens-packages/{s}", .{lens_name});
    var out_a_buf: [256:0]u8 = undefined;
    const out_a = try std.fmt.bufPrintZ(&out_a_buf, "zig-out/conformance-{s}-a", .{lens_name});
    var out_b_buf: [256:0]u8 = undefined;
    const out_b = try std.fmt.bufPrintZ(&out_b_buf, "zig-out/conformance-{s}-b", .{lens_name});

    try renderOnce(gpa, engine, bundle_path, out_a, segmentation_model);
    settle(engine);
    try renderOnce(gpa, engine, bundle_path, out_b, segmentation_model);
    settle(engine);

    var path_a_buf: [256]u8 = undefined;
    const path_a = try std.fmt.bufPrint(&path_a_buf, "{s}.tga", .{out_a});
    var path_b_buf: [256]u8 = undefined;
    const path_b = try std.fmt.bufPrint(&path_b_buf, "{s}.tga", .{out_b});

    const shot_a = try std.Io.Dir.cwd().readFileAlloc(harness_io, path_a, gpa, .limited(8 << 20));
    defer gpa.free(shot_a);
    const shot_b = try std.Io.Dir.cwd().readFileAlloc(harness_io, path_b, gpa, .limited(8 << 20));
    defer gpa.free(shot_b);

    if (!std.mem.eql(u8, shot_a, shot_b)) {
        std.debug.print("conformance: FAIL {s} produced different output across two runs of the same fixed input\n", .{lens_name});
        return null;
    }
    const hash = sha256Hex(shot_a);
    std.debug.print("conformance: PROOF {s} is bit-stable across two runs of the same fixed input through the real ABI ({d} bytes, sha256 {s})\n", .{ lens_name, shot_a.len, hash });
    return hash;
}

/// Proves play_animation actually fires and changes the rendered
/// output, not just that it compiles - the bit-stability loop above
/// only ever exercises the reference lenses' default, never-triggered
/// state, since it never calls goss_session_tick_lens at all. Activates
/// the real packaged trigger-anim bundle, screenshots its rest pose,
/// ticks it in dt_us steps past its own manifest's 2-second timer
/// threshold, screenshots again, and asserts the two differ.
fn proveTriggerAnimFires(gpa: std.mem.Allocator, engine: *abi.Engine) !bool {
    const bundle_path = ".lens-packages/trigger-anim";
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: trigger-anim proof: activate: {s}\n", .{@tagName(activated)});
        return false;
    }

    const corpus = try loadCorpusFrame(gpa, corpus_path);
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
    const half_w = (planes.width + 1) / 2;
    if (abi.goss_session_submit_frame_copy(session, &desc, planes.y.ptr, planes.width, planes.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    // Let the model.gltf node's async .glb load land before either
    // screenshot - both must show a real drawn mesh, only the pose
    // should differ.
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const before_path: [:0]const u8 = "zig-out/conformance-trigger-anim-before";
    engine.renderer.?.requestScreenshot(before_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }

    var signals = std.mem.zeroes(abi.LensSignals);
    var elapsed_us: u64 = 0;
    const dt_us: u32 = 16_666;
    while (elapsed_us < 2_100_000) : (elapsed_us += dt_us) {
        if (abi.goss_session_tick_lens(session, dt_us, &signals) != .ok) {
            std.debug.print("conformance: trigger-anim proof: tick refused\n", .{});
            return false;
        }
    }

    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    const after_path: [:0]const u8 = "zig-out/conformance-trigger-anim-after";
    engine.renderer.?.requestScreenshot(after_path.ptr);
    for (0..5) |_| {
        _ = abi.goss_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    settle(engine);

    const before = try std.Io.Dir.cwd().readFileAlloc(harness_io, before_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(before);
    const after = try std.Io.Dir.cwd().readFileAlloc(harness_io, after_path ++ ".tga", gpa, .limited(8 << 20));
    defer gpa.free(after);

    if (std.mem.eql(u8, before, after)) {
        std.debug.print("conformance: FAIL trigger-anim: play_animation firing after {d}us produced no visible change\n", .{elapsed_us});
        return false;
    }
    std.debug.print("conformance: PROOF trigger-anim's play_animation trigger fires after {d}us and visibly changes the rendered mesh pose\n", .{elapsed_us});
    return true;
}

pub fn main(init_args: std.process.Init) !u8 {
    const gpa = init_args.gpa;
    harness_io = init_args.io;

    // Screenshot comparisons land under zig-out/, which a clean
    // checkout does not have until the first install step runs.
    try std.Io.Dir.cwd().createDirPath(harness_io, "zig-out");

    var arg_it = std.process.Args.Iterator.init(init_args.minimal.args);
    _ = arg_it.next();
    const print_mode = if (arg_it.next()) |arg| std.mem.eql(u8, arg, "--print") else false;

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "gosslens conformance", null, null) orelse return error.WindowCreate;
    defer c.glfwDestroyWindow(window);

    const engine = try abi.createEngine(gpa, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
    defer abi.destroyEngine(engine);

    const renderer_desc: abi.RendererDesc = .{
        .native_window_handle = glfwGetCocoaWindow(window),
        .width = width,
        .height = height,
    };
    if (abi.goss_engine_init_renderer(engine, &renderer_desc) != .ok) return error.RendererInit;

    var current: std.Io.Writer.Allocating = .init(gpa);
    defer current.deinit();
    for (reference_lenses) |lens| {
        const hash = try checkDeterminism(gpa, engine, lens.name, lens.segmentation_model) orelse return 1;
        try current.writer.print("{s} {s}\n", .{ lens.name, hash });
    }

    if (print_mode) {
        var out_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init_args.io, &out_buf);
        try stdout.interface.writeAll(current.writer.buffered());
        try stdout.interface.flush();
        return 0;
    }

    const baseline = std.Io.Dir.cwd().readFileAlloc(init_args.io, baseline_path, gpa, .limited(1 << 16)) catch |err| {
        std.debug.print("conformance: cannot read {s}: {t}\n", .{ baseline_path, err });
        return 1;
    };
    defer gpa.free(baseline);
    if (!std.mem.eql(u8, baseline, current.writer.buffered())) {
        std.debug.print(
            "conformance: output differs from {s}\n---- current ----\n{s}---- baseline ----\n{s}An intended change must update the baseline (zig build conformance -- --print > {s}).\n",
            .{ baseline_path, current.writer.buffered(), baseline, baseline_path },
        );
        return 1;
    }
    std.debug.print("conformance: PROOF all reference lenses match the pinned baseline\n", .{});

    if (!try proveTriggerAnimFires(gpa, engine)) return 1;
    if (!try provePhotoCapture(gpa, engine)) return 1;
    if (!try proveMaskDegradation(gpa, engine)) return 1;
    if (!try proveVideoRecording(gpa, engine)) return 1;
    if (!try provePlatformPhotos(gpa, engine)) return 1;
    if (!try proveWorldAnchor(gpa, engine)) return 1;
    if (!try provePhysicsDrop(gpa, engine)) return 1;
    if (!try provePhysicsChain(gpa, engine)) return 1;
    if (!try proveClothFlag(gpa, engine)) return 1;
    if (!try proveParticles(gpa, engine)) return 1;
    if (!try proveHairSim(gpa, engine)) return 1;
    if (!try proveHighResCapture(gpa, engine)) return 1;
    if (!try proveTiledCapture(gpa, engine)) return 1;
    if (!try proveScript(gpa, engine)) return 1;
    if (!try proveAudio(gpa, engine)) return 1;
    if (!try proveBlur(gpa, engine)) return 1;
    if (!try proveGrade(gpa, engine)) return 1;
    if (!try proveBloom(gpa, engine)) return 1;
    if (!try proveStackedPostEffects(gpa, engine)) return 1;
    if (!try proveExpressionScript(gpa, engine)) return 1;
    if (!try proveEmber(gpa, engine)) return 1;
    if (!try proveJsonPostEffect(gpa, engine)) return 1;
    if (!try proveFullStack(gpa, engine)) return 1;
    if (!try proveTiledPostEffect(gpa, engine)) return 1;
    if (!try proveNoLeaks(gpa)) return 1;
    return 0;
}
