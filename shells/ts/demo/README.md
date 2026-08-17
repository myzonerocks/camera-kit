# Web demo

A browser page with a live camera preview, real-time face tracking, and
sliders for all six beauty effects, running the wasm core through a
real bgfx renderer (WebGPU when the browser has a working adapter,
WebGL2 otherwise). No framework, no bundler beyond a single `bun build`.

## One-time setup

From the repo root:

    zig build wasm-emscripten
    zig build wasm-emscripten-webgpu
    zig build tracking-wasm
    zig build fetch-models
    cp zig-out/wasm-emscripten/camerakit_web.js zig-out/wasm-emscripten/camerakit_web.wasm shells/ts/demo/
    mkdir -p shells/ts/demo/webgpu
    cp zig-out/wasm-emscripten-webgpu/camerakit_web.js zig-out/wasm-emscripten-webgpu/camerakit_web.wasm shells/ts/demo/webgpu/
    cp zig-out/wasm/camerakit_tracking.wasm shells/ts/demo/
    cp .models/face_landmarker.task .models/corpus/face_frontal_b.jpg .models/corpus/no_face_control.jpg shells/ts/demo/
    cd shells/ts/demo
    bun build ./tracking-worker.ts --outfile=./tracking-worker.js --format=esm

Everything this copies in is a gitignored build/fetch output, not
source - re-run its step whenever the core, the tracking module, or
the pinned models change. The webgpu/ subdirectory keeps its own
camerakit_web.js/.wasm pair separate from the WebGL2 one at the top
level - main.ts picks between them at load time based on whether the
browser has a working WebGPU adapter.

## Run it

    bun build ./main.ts --outfile=./dist.js --format=esm
    python3 -m http.server 8932

Then open http://localhost:8932/. Grant camera access when the browser
asks. Use `bun build`, not `bun index.html --port=N` - the latter is a
bundler dev server that serves the same HTML for every path, not a
static file server.

If your camera hands the browser frames pre-rotated, check "camera
upside down" in the controls bar; it's remembered across reloads.

## Proving it

    bun run prove.ts

Drives the real page in headless Chrome (fake capture device) and
asserts real deltas for whiten/smooth/reshape/makeup plus live face
tracking - the same technique the demo's own browser testing uses
throughout this repo.
