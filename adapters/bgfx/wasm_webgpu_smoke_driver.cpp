// Minimal proof that bgfx's real WebGPU backend runs on web: same canvas
// selector convention the HTML5 GL backend uses (init.platformData.nwh
// as a CSS selector string, per renderer_webgpu.cpp's own Emscripten
// surface-creation branch), initializes, reports which renderer
// actually came up, shuts down. Node
// has no real WebGPU adapter, so bgfx_init there is expected to fall
// back to the Noop renderer rather than WebGPU - the real proof this
// driver exists for needs a real browser.
//
// Also times a bgfx_touch+bgfx_frame loop, the same shape
// wasm_bgfx_smoke_driver.cpp times without Asyncify - measures
// Asyncify's per-frame cost on the real bgfx submission path.
#include <bgfx/c99/bgfx.h>
#include <emscripten.h>
#include <stdio.h>

int main() {
  bgfx_init_t init;
  bgfx_init_ctor(&init);
  init.type = BGFX_RENDERER_TYPE_WEBGPU;
  init.resolution.width = 640;
  init.resolution.height = 480;
  init.platformData.nwh = (void*)"#canvas";
  bool ok = bgfx_init(&init);
  printf("wasm-webgpu-smoke: bgfx_init %s\n", ok ? "ok" : "failed");
  if (ok) {
    printf("wasm-webgpu-smoke: renderer %s\n", bgfx_get_renderer_name(bgfx_get_renderer_type()));

    bgfx_set_view_clear(0, BGFX_CLEAR_COLOR | BGFX_CLEAR_DEPTH, 0x303030ff, 1.0f, 0);
    bgfx_set_view_rect(0, 0, 0, 640, 480);

    const int kFrames = 600;
    for (int i = 0; i < 30; ++i) {
      bgfx_touch(0);
      bgfx_frame(false);
    }
    // Cross-checked against a JS-side clock, not just emscripten_get_now()
    // alone - Asyncify-instrumented calls resume through JS promise/
    // microtask machinery, which a C++-only reading might not capture.
    EM_ASM({ window.__benchStart = performance.now(); });
    double start = emscripten_get_now();
    for (int i = 0; i < kFrames; ++i) {
      bgfx_touch(0);
      bgfx_frame(false);
    }
    double elapsed = emscripten_get_now() - start;
    EM_ASM({
      const jsElapsed = performance.now() - window.__benchStart;
      console.log('wasm-webgpu-smoke: JS-side bracket ' + jsElapsed.toFixed(3) + 'ms for ' + $0 + ' frames, ' + (jsElapsed / $0).toFixed(4) + 'ms/frame');
    }, kFrames);
    printf("wasm-webgpu-smoke: %d frames in %.3fms, %.4fms/frame\n", kFrames, elapsed, elapsed / kFrames);

    bgfx_shutdown();
  }
  EM_ASM({ document.title = 'BENCH_DONE'; });
  return ok ? 0 : 1;
}
