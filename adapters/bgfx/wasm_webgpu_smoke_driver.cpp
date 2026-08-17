// Minimal proof that bgfx's real WebGPU backend runs on web: same canvas
// selector convention the HTML5 GL backend uses (init.platformData.nwh
// as a CSS selector string - confirmed against renderer_webgpu.cpp's own
// Emscripten surface-creation branch, not assumed to match the GL one),
// initializes, reports which renderer actually came up, shuts down. Node
// has no real WebGPU adapter, so bgfx_init there is expected to fall
// back to the Noop renderer rather than WebGPU - the real proof this
// driver exists for needs a real browser.
#include <bgfx/c99/bgfx.h>
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
    bgfx_shutdown();
  }
  return ok ? 0 : 1;
}
