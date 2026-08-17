// Minimal proof that bgfx's real GL backend runs on web: activates the
// same canvas selector convention bgfx's own HTML5 GL context expects
// (init.platformData.nwh as a CSS selector string, not a native handle),
// initializes, reports which renderer actually came up, shuts down.
//
// Also times a bgfx_touch+bgfx_frame loop, the same shape
// wasm_webgpu_smoke_driver.cpp times with Asyncify linked in - this
// build has no Asyncify, so it's the baseline for that comparison.
#include <bgfx/c99/bgfx.h>
#include <emscripten.h>
#include <stdio.h>

int main() {
  bgfx_init_t init;
  bgfx_init_ctor(&init);
  init.type = BGFX_RENDERER_TYPE_OPENGLES;
  init.resolution.width = 640;
  init.resolution.height = 480;
  init.platformData.nwh = (void*)"#canvas";
  bool ok = bgfx_init(&init);
  printf("wasm-bgfx-smoke: bgfx_init %s\n", ok ? "ok" : "failed");
  if (ok) {
    printf("wasm-bgfx-smoke: renderer %s\n", bgfx_get_renderer_name(bgfx_get_renderer_type()));

    bgfx_set_view_clear(0, BGFX_CLEAR_COLOR | BGFX_CLEAR_DEPTH, 0x303030ff, 1.0f, 0);
    bgfx_set_view_rect(0, 0, 0, 640, 480);

    const int kFrames = 600;
    // Warm up: JIT/driver state settles before the timed loop starts.
    for (int i = 0; i < 30; ++i) {
      bgfx_touch(0);
      bgfx_frame(false);
    }
    double start = emscripten_get_now();
    for (int i = 0; i < kFrames; ++i) {
      bgfx_touch(0);
      bgfx_frame(false);
    }
    double elapsed = emscripten_get_now() - start;
    printf("wasm-bgfx-smoke: %d frames in %.3fms, %.4fms/frame\n", kFrames, elapsed, elapsed / kFrames);

    bgfx_shutdown();
  }
  return ok ? 0 : 1;
}
