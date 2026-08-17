const std = @import("std");
const render = @import("render");

// Proves render.zig's own bgfx_init/bgfx_shutdown calls, not just its
// declarations, actually link and run against wasm32-emscripten - the
// "#canvas" selector convention bgfx's own HTML5 GL context expects for
// platformData.nwh (glcontext_html5.cpp, undocumented in the C99
// header) only resolves against a real DOM canvas, so this reports
// bgfx_init's result rather than asserting it - false here just means
// no browser canvas was present, not a build failure.
export fn ck_core_smoke_probe() i32 {
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
    renderer.deinit();
    return 0;
}
