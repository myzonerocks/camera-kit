// Minimal proof that bgfx's real GL backend runs on web: activates the
// same canvas selector convention bgfx's own HTML5 GL context expects
// (init.platformData.nwh as a CSS selector string, not a native handle),
// initializes, reports which renderer actually came up, shuts down.
#include <bgfx/c99/bgfx.h>
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
    bgfx_shutdown();
  }
  return ok ? 0 : 1;
}
