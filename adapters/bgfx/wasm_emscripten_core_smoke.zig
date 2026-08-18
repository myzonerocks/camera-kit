const std = @import("std");
const render = @import("render");
const c = render.c;

// Proves render.zig's own bgfx_init/bgfx_shutdown calls, not just its
// declarations, actually link and run against wasm32-emscripten - the
// "#canvas" selector convention bgfx's own HTML5 GL context expects for
// platformData.nwh (glcontext_html5.cpp, undocumented in the C99
// header) only resolves against a real DOM canvas, so this reports
// bgfx_init's result rather than asserting it - false here just means
// no browser canvas was present, not a build failure.
export fn goss_core_smoke_probe() i32 {
    // std.heap.c_allocator, not wasm_allocator: wasm_allocator grows
    // memory through a raw wasm instruction Emscripten's own JS-side
    // heap-view tracking never sees, leaving a caller's cached HEAP32/
    // HEAPU8 view stale (found while diagnosing exactly this in
    // core/abi/abi.zig's own allocator selection).
    var renderer = render.Renderer.init(std.heap.c_allocator, .{
        .native_window_handle = @ptrCast(@constCast("#canvas")),
        .width = 640,
        .height = 480,
    }) catch return -1;
    defer renderer.deinit();
    return 0;
}

/// Renders one composited frame through Renderer's own production
/// submitPreview path - the same program-loading/full-screen-quad/
/// submit sequence a real session runs. Writes the active renderer's
/// name into out_name/out_name_cap so the caller can assert on it.
export fn goss_core_smoke_render_frame(out_name: [*]u8, out_name_cap: i32) i32 {
    var renderer = render.Renderer.init(std.heap.c_allocator, .{
        .native_window_handle = @ptrCast(@constCast("#canvas")),
        .width = 640,
        .height = 480,
    }) catch return -1;
    defer renderer.deinit();

    const renderer_type = c.bgfx_get_renderer_type();
    const name = std.mem.span(c.bgfx_get_renderer_name(renderer_type));
    const copy_len = @min(name.len, @as(usize, @intCast(out_name_cap)));
    @memcpy(out_name[0..copy_len], name[0..copy_len]);

    c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x303030ff, 1.0, 0);
    c.bgfx_set_view_rect(0, 0, 0, 640, 480);

    // 2x2 solid red - trivial content; the point is that the real
    // shader program creates and submits without a validation error.
    const red_pixels = [_]u8{ 255, 0, 0, 255 } ** 4;
    const texture = render.Renderer.createStaticTexture(2, 2, &red_pixels);
    renderer.submitPreview(0, .{ .bgra = .{ .texture = texture } }, 0, false);
    _ = c.bgfx_frame(0);

    return @intCast(copy_len);
}

/// bgfx_read_texture() enqueues a CommandBuffer::ReadTexture entry
/// (bgfx_p.h's Context::readTexture) instead of running synchronously,
/// and its return value is the frame number bgfx_frame() must reach
/// before the buffer is safe to read - per bgfx's own documented
/// contract, not a fixed number of extra calls. Packs the first
/// read-back pixel's RGBA into the return value (8 bits each) so a
/// caller can inspect the real bytes.
export fn goss_core_smoke_read_texture() i32 {
    var renderer = render.Renderer.init(std.heap.c_allocator, .{
        .native_window_handle = @ptrCast(@constCast("#canvas")),
        .width = 640,
        .height = 480,
    }) catch return -1;
    defer renderer.deinit();

    const red_pixels = [_]u8{ 255, 0, 0, 255 } ** 4;
    const texture = render.Renderer.createStaticTexture(2, 2, &red_pixels);
    _ = c.bgfx_frame(0);

    var pixels: [2 * 2 * 4]u8 = undefined;
    const ready_frame = render.Renderer.readTexture(texture, &pixels);
    while (c.bgfx_frame(0) < ready_frame) {}

    return (@as(i32, pixels[0]) << 24) | (@as(i32, pixels[1]) << 16) | (@as(i32, pixels[2]) << 8) | @as(i32, pixels[3]);
}
