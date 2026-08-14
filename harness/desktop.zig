//! Desktop harness: drives the real render stack on screen and proves what
//! it drew by reading the pixels back. This is the acceptance surface for
//! the render adapter; nothing merges on a promise here.

const std = @import("std");
const graph = @import("graph");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("bgfx/c99/bgfx.h");
});

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

const width: u32 = 800;
const height: u32 = 600;
const screenshot_path = "zig-out/harness-frame.ppm";

var screenshot_written: bool = false;

// bgfx callback vtable. Screenshots arrive here as BGRA rows; everything
// else is inert. The vtable layout mirrors bgfx_callback_vtbl_t exactly.
const Callbacks = struct {
    var vtbl: c.bgfx_callback_vtbl_t = .{
        .fatal = fatal,
        .trace_vargs = traceVargs,
        .profiler_begin = profilerBegin,
        .profiler_begin_literal = profilerBeginLiteral,
        .profiler_end = profilerEnd,
        .cache_read_size = cacheReadSize,
        .cache_read = cacheRead,
        .cache_write = cacheWrite,
        .screen_shot = screenShot,
        .capture_begin = captureBegin,
        .capture_end = captureEnd,
        .capture_frame = captureFrame,
    };
    var iface: c.bgfx_callback_interface_t = .{ .vtbl = &vtbl };

    fn fatal(_: [*c]c.bgfx_callback_interface_t, file: [*c]const u8, line: u16, code: c.bgfx_fatal_t, message: [*c]const u8) callconv(.c) void {
        std.debug.print("harness: bgfx fatal {d} at {s}:{d}: {s}\n", .{ code, file, line, message });
        std.process.abort();
    }
    fn traceVargs(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u16, _: [*c]const u8, _: [*c]u8) callconv(.c) void {}
    fn profilerBegin(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u32, _: [*c]const u8, _: u16) callconv(.c) void {}
    fn profilerBeginLiteral(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u32, _: [*c]const u8, _: u16) callconv(.c) void {}
    fn profilerEnd(_: [*c]c.bgfx_callback_interface_t) callconv(.c) void {}
    fn cacheReadSize(_: [*c]c.bgfx_callback_interface_t, _: u64) callconv(.c) u32 {
        return 0;
    }
    fn cacheRead(_: [*c]c.bgfx_callback_interface_t, _: u64, _: ?*anyopaque, _: u32) callconv(.c) bool {
        return false;
    }
    fn cacheWrite(_: [*c]c.bgfx_callback_interface_t, _: u64, _: ?*const anyopaque, _: u32) callconv(.c) void {}
    fn captureBegin(_: [*c]c.bgfx_callback_interface_t, _: u32, _: u32, _: u32, _: c.bgfx_texture_format_t, _: bool) callconv(.c) void {}
    fn captureEnd(_: [*c]c.bgfx_callback_interface_t) callconv(.c) void {}
    fn captureFrame(_: [*c]c.bgfx_callback_interface_t, _: ?*const anyopaque, _: u32) callconv(.c) void {}

    fn screenShot(
        _: [*c]c.bgfx_callback_interface_t,
        path: [*c]const u8,
        shot_width: u32,
        shot_height: u32,
        pitch: u32,
        _: c_uint,
        data: ?*const anyopaque,
        _: u32,
        yflip: bool,
    ) callconv(.c) void {
        writePpm(std.mem.span(@as([*:0]const u8, @ptrCast(path))), shot_width, shot_height, pitch, @ptrCast(data.?), yflip) catch |err| {
            std.debug.print("harness: screenshot write failed: {t}\n", .{err});
            return;
        };
        screenshot_written = true;
    }
};

var harness_io: std.Io = undefined;

fn writePpm(path: []const u8, w: u32, h: u32, pitch: u32, bgra: [*]const u8, yflip: bool) !void {
    const gpa = std.heap.page_allocator;
    const body = try gpa.alloc(u8, 64 + w * h * 3);
    defer gpa.free(body);
    const header = try std.fmt.bufPrint(body[0..64], "P6\n{d} {d}\n255\n", .{ w, h });
    var len: usize = header.len;
    for (0..h) |row_index| {
        const source_row = if (yflip) h - 1 - row_index else row_index;
        const row = bgra[source_row * pitch ..][0 .. w * 4];
        for (0..w) |x| {
            body[len] = row[x * 4 + 2];
            body[len + 1] = row[x * 4 + 1];
            body[len + 2] = row[x * 4];
            len += 3;
        }
    }
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = path, .data = body[0..len] });
}

pub fn main(init_args: std.process.Init) !void {
    harness_io = init_args.io;
    if (c.glfwInit() == c.GLFW_FALSE) {
        std.debug.print("harness: glfw init failed\n", .{});
        return error.GlfwInit;
    }
    defer c.glfwTerminate();

    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "camera-kit harness", null, null) orelse {
        std.debug.print("harness: window creation failed\n", .{});
        return error.WindowCreate;
    };
    defer c.glfwDestroyWindow(window);

    var init: c.bgfx_init_t = undefined;
    c.bgfx_init_ctor(&init);
    init.type = c.BGFX_RENDERER_TYPE_METAL;
    init.resolution.width = width;
    init.resolution.height = height;
    init.resolution.reset = c.BGFX_RESET_VSYNC;
    init.platformData.nwh = glfwGetCocoaWindow(window);
    init.callback = &Callbacks.iface;
    if (!c.bgfx_init(&init)) {
        std.debug.print("harness: bgfx init failed\n", .{});
        return error.BgfxInit;
    }
    defer c.bgfx_shutdown();

    const renderer = c.bgfx_get_renderer_type();
    std.debug.print("harness: renderer {s}\n", .{c.bgfx_get_renderer_name(renderer)});

    c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0xff00ffff, 1.0, 0);
    c.bgfx_set_view_rect(0, 0, 0, @intCast(width), @intCast(height));

    var frame: u32 = 0;
    while (frame < 90 and c.glfwWindowShouldClose(window) == c.GLFW_FALSE) : (frame += 1) {
        c.glfwPollEvents();
        c.bgfx_touch(0);
        if (frame == 60) {
            c.bgfx_request_screen_shot(.{ .idx = std.math.maxInt(u16) }, screenshot_path);
        }
        _ = c.bgfx_frame(0);
    }

    if (!screenshot_written) {
        std.debug.print("harness: FAIL no screenshot was produced\n", .{});
        return error.NoScreenshot;
    }

    const shot = try std.Io.Dir.cwd().readFileAlloc(harness_io, screenshot_path, std.heap.page_allocator, .limited(32 << 20));
    defer std.heap.page_allocator.free(shot);
    const pixels = std.mem.indexOf(u8, shot, "255\n").? + 4;
    const center = pixels + ((height / 2) * width + width / 2) * 3;
    const r = shot[center];
    const g = shot[center + 1];
    const b = shot[center + 2];
    std.debug.print("harness: center pixel r={d} g={d} b={d}\n", .{ r, g, b });
    if (r > 200 and g < 50 and b > 200) {
        std.debug.print("harness: PROOF clear color reached the backbuffer\n", .{});
    } else {
        std.debug.print("harness: FAIL backbuffer does not show the clear color\n", .{});
        return error.WrongPixels;
    }
}
