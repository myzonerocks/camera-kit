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
    cp zig-out/wasm/gosslens_tracking.wasm sdk/ts/demo/
    cp .models/face_landmarker.task .models/corpus/face_frontal_b.jpg .models/corpus/no_face_control.jpg sdk/ts/demo/
    cd sdk/ts/demo
    bun build ./tracking-worker.ts --outfile=./tracking-worker.js --format=esm

wasm-emscripten and wasm-emscripten-webgpu each copy their own
gosslens_web.js/.wasm output straight into sdk/ts/demo/ (WebGL2)
and sdk/ts/demo/webgpu/ (WebGPU) as part of the build itself, so
there's no separate cp step for those two and no way to silently keep
testing a stale binary after a source change - main.ts picks between
the two directories at load time based on whether the browser has a
working WebGPU adapter. Everything else this copies in is still a
gitignored fetch/build output with no auto-copy of its own yet -
re-run its own step whenever the tracking module or the pinned models
change.

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

## Proving the tracking modules

Face, pose, hand and segmentation each run in a real browser over a
corpus still, not the live camera. From the repo root, copy the extra
bundles the proof reads:

    cp .models/pose_landmarker_full.task .models/gesture_recognizer.task .models/selfie_multiclass.tflite sdk/ts/demo/
    cp .models/corpus/body_standing.jpg .models/corpus/hand_raised.jpg sdk/ts/demo/

Then build the worker and page and run the proof:

    cd sdk/ts/demo
    bun build ./track-worker.ts --outfile=./track-worker.js --format=esm
    bun build ./track-page.ts --outfile=./track.js --format=esm
    bun run track-prove.ts

It stands each pipeline up in turn, runs inference over its still, and
prints a PASS line with the landmark counts, the detected hand and
gesture, and the segmentation class count and mask coverage. track-prove
materializes the corpus and bundles itself, so a fresh checkout proves
once the models are fetched.
