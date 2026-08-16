//! Conformance harness: drives a real packaged reference lens through the
//! production ABI end to end - real engine, real session, real
//! ck_session_activate_lens_from_directory, real ck_engine_render_frame -
//! and proves the result is bit-stable: the same fixed input rendered
//! twice produces byte-identical output. Each lens's hash also checks
//! against lenses/conformance-baseline.txt (--print regenerates it), so
//! a change that shifts a lens's real output shows up as a tracked diff
//! in review, not just same-run determinism. This is still one platform
//! (host/macOS); cross-platform value-stability is real remaining work.

const std = @import("std");
const abi = @import("abi");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
});

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

const width: u32 = 400;
const height: u32 = 300;
const reference_lenses = [_][]const u8{ "shader-tint", "beauty-baseline", "background-swap" };
const baseline_path = "lenses/conformance-baseline.txt";

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

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

/// Activates lens_name's packaged bundle twice, rendering the same fixed
/// input through each, and asserts the two screenshots are byte-
/// identical - proving the lens is bit-stable, not just that it
/// happened to render something. Returns the hex hash of that output on
/// success, null (with a printed reason) on failure.
fn checkDeterminism(gpa: std.mem.Allocator, io: std.Io, engine: *abi.Engine, lens_name: []const u8) !?[64]u8 {
    var bundle_buf: [256]u8 = undefined;
    const bundle_path = try std.fmt.bufPrint(&bundle_buf, ".lens-packages/{s}", .{lens_name});
    var out_a_buf: [256:0]u8 = undefined;
    const out_a = try std.fmt.bufPrintZ(&out_a_buf, "zig-out/conformance-{s}-a", .{lens_name});
    var out_b_buf: [256:0]u8 = undefined;
    const out_b = try std.fmt.bufPrintZ(&out_b_buf, "zig-out/conformance-{s}-b", .{lens_name});

    try renderOnce(gpa, engine, bundle_path, out_a);
    settle(engine);
    try renderOnce(gpa, engine, bundle_path, out_b);
    settle(engine);

    var path_a_buf: [256]u8 = undefined;
    const path_a = try std.fmt.bufPrint(&path_a_buf, "{s}.tga", .{out_a});
    var path_b_buf: [256]u8 = undefined;
    const path_b = try std.fmt.bufPrint(&path_b_buf, "{s}.tga", .{out_b});

    const shot_a = try std.Io.Dir.cwd().readFileAlloc(io, path_a, gpa, .limited(8 << 20));
    defer gpa.free(shot_a);
    const shot_b = try std.Io.Dir.cwd().readFileAlloc(io, path_b, gpa, .limited(8 << 20));
    defer gpa.free(shot_b);

    if (!std.mem.eql(u8, shot_a, shot_b)) {
        std.debug.print("conformance: FAIL {s} produced different output across two runs of the same fixed input\n", .{lens_name});
        return null;
    }
    const hash = sha256Hex(shot_a);
    std.debug.print("conformance: PROOF {s} is bit-stable across two runs of the same fixed input through the real ABI ({d} bytes, sha256 {s})\n", .{ lens_name, shot_a.len, hash });
    return hash;
}

pub fn main(init_args: std.process.Init) !u8 {
    const gpa = init_args.gpa;

    var arg_it = std.process.Args.Iterator.init(init_args.minimal.args);
    _ = arg_it.next();
    const print_mode = if (arg_it.next()) |arg| std.mem.eql(u8, arg, "--print") else false;

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

    var current: std.Io.Writer.Allocating = .init(gpa);
    defer current.deinit();
    for (reference_lenses) |name| {
        const hash = try checkDeterminism(gpa, init_args.io, engine, name) orelse return 1;
        try current.writer.print("{s} {s}\n", .{ name, hash });
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
    return 0;
}
