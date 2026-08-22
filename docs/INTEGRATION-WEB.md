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

`@gosslens/core` is not published to a registry yet. Consume it from this
checkout as a workspace dependency (the demo does), pointing your workspace at
`sdk/ts`:

    { "dependencies": { "@gosslens/core": "workspace:*" } }

or a direct path while you develop:

    { "dependencies": { "@gosslens/core": "file:../gosslens/sdk/ts" } }

Run `bun run build` in `sdk/ts` first so `dist/` exists. The imports below use
the package name either way.

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

## Lives and calls

The web is the easy case: the rendered canvas is already a live video source.
`canvas.captureStream()` hands you a `MediaStreamTrack` of the composited,
lens-baked output with no readback and no copy - publish it straight to
LiveKit or any WebRTC peer:

    const track = canvas.captureStream(30).getVideoTracks()[0];
    // publish `track` through your LiveKit room or RTCPeerConnection

Keep the render loop running (`renderFrame` per frame) and the track carries
every composited frame. Reach for `captureLiveFrame` only when you need the
raw pixels (BGRA by default) rather than a track. For audio, `submitAudio`
feeds mic samples in for audio-reactive lenses, and `mixOutputAudio` folds the
lens's own sound into the mic block you are about to publish and returns the
mixed interleaved s16 for your outgoing WebRTC audio track (pass `null` for the
mic to send the lens sound over silence). `pullAudio` still pulls the lens sound
alone for local WebAudio playback with no call in progress.

## Method names

The operation names match the other SDKs: `GossEngine.create(gosslens)`,
`GossSession.create(engine)`, `submitFrameRgbaCopy`, `renderFrame`. The full
table is in [API.md](API.md).
