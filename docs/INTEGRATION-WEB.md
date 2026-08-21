# Integrating gosslens on the web

The path from a checkout to a camera preview with a lens on it in a web app.
The [TypeScript SDK](../sdk/ts/README.md) is the surface; the
[demo](../sdk/ts/demo) is a full working page.

The web build is different from the native ones in one way worth stating up
front: the engine is WebAssembly, and the browser will not let a package fetch
a `.wasm` from inside `node_modules` the way a native app links an archive. So
`@gosslens/core` ships the JavaScript wrapper only, and you host the wasm and
model assets yourself and hand the SDK their URLs. The SDK never guesses a
path.

## Build the assets

    zig build wasm-emscripten           # gosslens_web.js/.wasm, WebGL2
    zig build wasm-emscripten-webgpu     # gosslens_web.js/.wasm, WebGPU
    zig build tracking-wasm              # gosslens_tracking.wasm
    zig build fetch-models               # the ML .task/.tflite bundles

WebGPU and WebGL2 are two separate engine artifacts, not a runtime switch.
Serve both, plus the tracking module and whichever model bundles your lenses
use, from your own static host.

## Install

    npm i @gosslens/core

## The render loop

`GossPreviewSession` does the engine, renderer, session, and capture loop in
one call - most apps want this:

    import { GossPreviewSession, pickEngineUrl } from "@gosslens/core";

    const wasmJsUrl = await pickEngineUrl(webgpuUrl, webgl2Url);
    const preview = await GossPreviewSession.create(canvas, wasmJsUrl);
    preview.activateLens(manifestJson);

`pickEngineUrl` confirms a real WebGPU adapter before choosing, and falls back
to the WebGL2 URL. If you drive the loop yourself, the pieces are public too:

    import { Gosslens, GossEngine, GossSession } from "@gosslens/core";

    const gosslens = await Gosslens.load(canvas, wasmJsUrl);
    const engine = GossEngine.create(gosslens);
    await engine.initRenderer(canvas);
    const session = GossSession.create(engine);

    session.submitFrameRgbaCopy(rgba, width * 4, width, height);
    engine.renderFrame(session);

## Tracking

Face, hand, pose, and segmentation run in the `gosslens_tracking.wasm` module,
off the main thread in a Worker. Each tracker takes the module bytes and a
model bundle and returns its result synchronously inside the worker:

    // tracking-worker.ts
    import { GossFaceTracker } from "@gosslens/core";

    const moduleBytes = await (await fetch(trackingWasmUrl)).arrayBuffer();
    const tracker = await GossFaceTracker.create(moduleBytes, faceTaskBytes);
    // per frame, on RGBA pixels from the camera canvas:
    const result = tracker.process(rgba, width, height, timestampUs);

[`demo/tracking-worker.ts`](../sdk/ts/demo/tracking-worker.ts) is the reference
worker, and [`demo/track-worker.ts`](../sdk/ts/demo/track-worker.ts) stands all
four pipelines up over still images. Feed a segmentation mask back to the
session with `setSegmentationMask` so a lens can composite against it.

The `.task`/`.tflite` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`, `selfie_multiclass.tflite`) are the ones
`fetch-models` writes; host and fetch the ones your lenses use.

## Method names

The operation names match the other SDKs: `GossEngine.create(gosslens)`,
`GossSession.create(engine)`, `submitFrameRgbaCopy`, `renderFrame`. The full
table is in [API.md](API.md).
