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
    return 0;
}
