//! Conformance harness: drives a real packaged reference lens through the
//! production ABI end to end - real engine, real session, real
//! ck_session_activate_lens_from_directory, real ck_engine_render_frame -
//! and proves the result is bit-stable: the same fixed input rendered
//! twice produces byte-identical output. This is the first slice of
//! SPEC section 9's conformance requirement (one reference lens, one
//! platform, determinism only); the full reference set, cross-platform
//! value-stability, and pinned cross-run baselines are real remaining
//! work.

const std = @import("std");
const abi = @import("abi");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
});

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

const width: u32 = 400;
const height: u32 = 300;

const SynthFrame = struct {
    y: []u8,
    uv: []u8,

    fn deinit(frame: SynthFrame, gpa: std.mem.Allocator) void {
        gpa.free(frame.y);
        gpa.free(frame.uv);
    }
};

/// A fixed diagonal gradient, not a flat frame - a flat input can't tell
/// "rendered something" apart from "rendered nothing", the same
/// reasoning the segmentation proof elsewhere in this repo already
/// applies to its own synthetic input.
fn synthFrame(gpa: std.mem.Allocator, w: u32, h: u32) !SynthFrame {
    const y = try gpa.alloc(u8, w * h);
    errdefer gpa.free(y);
    for (0..h) |row| {
        for (0..w) |col| {
            y[row * w + col] = @intCast((row + col) % 256);
        }
    }
    const half_w = (w + 1) / 2;
    const half_h = (h + 1) / 2;
    const uv = try gpa.alloc(u8, half_w * half_h * 2);
    @memset(uv, 128);
    return .{ .y = y, .uv = uv };
}

/// Activates bundle_path on a fresh session, submits the same fixed
/// frame, renders it a few times to let the request settle, and
/// requests a screenshot at out_path - bgfx's own default callback (no
/// custom one is wired here, since RendererDesc has no callback field
/// to carry one through the frozen ABI) writes it as out_path ++ ".tga".
fn renderOnce(gpa: std.mem.Allocator, engine: *abi.Engine, bundle_path: []const u8, out_path: [:0]const u8) !void {
    const session = try abi.createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer abi.destroySession(session);

    const activated = abi.ck_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len);
    if (activated != .ok) {
        std.debug.print("conformance: activate {s}: {s}\n", .{ bundle_path, @tagName(activated) });
        return error.ActivationFailed;
    }

    const frame = try synthFrame(gpa, width, height);
    defer frame.deinit(gpa);

    const desc: abi.FrameDesc = .{
        .width = width,
        .height = height,
        .pixel_format = 0,
        .color_standard = 0,
        .color_range = 1,
        .flags = 0,
        .timestamp_us = 1000,
    };
    const half_w = (width + 1) / 2;
    if (abi.ck_session_submit_frame_copy(session, &desc, frame.y.ptr, width, frame.uv.ptr, half_w * 2) != .ok) {
        return error.SubmitFailed;
    }

    for (0..5) |_| {
        _ = abi.ck_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
    engine.renderer.?.requestScreenshot(out_path.ptr);
    for (0..5) |_| {
        _ = abi.ck_engine_render_frame(engine, session);
        c.glfwPollEvents();
    }
}

/// Pumps a few frames with no active session, purely so bgfx has enough
/// frame boundaries to actually retire whatever the session just
/// destroyed - destroySession's own bgfx_destroy_* calls only queue
/// destruction until the GPU is done with a resource, they do not force
/// it, so creating (or shutting down) immediately after leaves handles
/// bgfx itself still considers in flight.
fn settle(engine: *abi.Engine) void {
    for (0..10) |_| {
        _ = abi.ck_engine_render_frame(engine, null);
        c.glfwPollEvents();
    }
}

pub fn main(init_args: std.process.Init) !u8 {
    const gpa = init_args.gpa;

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "camera-kit conformance", null, null) orelse return error.WindowCreate;
    defer c.glfwDestroyWindow(window);

    const engine = try abi.createEngine(gpa, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
    defer abi.destroyEngine(engine);

    const renderer_desc: abi.RendererDesc = .{
        .native_window_handle = glfwGetCocoaWindow(window),
        .width = width,
        .height = height,
    };
    if (abi.ck_engine_init_renderer(engine, &renderer_desc) != .ok) return error.RendererInit;

    try renderOnce(gpa, engine, ".lens-packages/shader-tint", "zig-out/conformance-shader-tint-a");
    settle(engine);
    try renderOnce(gpa, engine, ".lens-packages/shader-tint", "zig-out/conformance-shader-tint-b");
    settle(engine);

    const shot_a = try std.Io.Dir.cwd().readFileAlloc(init_args.io, "zig-out/conformance-shader-tint-a.tga", gpa, .limited(8 << 20));
    defer gpa.free(shot_a);
    const shot_b = try std.Io.Dir.cwd().readFileAlloc(init_args.io, "zig-out/conformance-shader-tint-b.tga", gpa, .limited(8 << 20));
    defer gpa.free(shot_b);

    if (!std.mem.eql(u8, shot_a, shot_b)) {
        std.debug.print("conformance: FAIL shader-tint produced different output across two runs of the same fixed input\n", .{});
        return 1;
    }
    std.debug.print("conformance: PROOF shader-tint is bit-stable across two runs of the same fixed input through the real ABI ({d} bytes)\n", .{shot_a.len});
    return 0;
}
