# Gosslens — TypeScript SDK

TypeScript SDK for [Gosslens](../../include/gosslens.h), a camera engine
with a Zig core behind one C ABI, compiled to `wasm32`. Wraps it as
`GossEngine`, `GossSession`, and `Gosslens` — the same names the
[Swift](../swift/README.md) and [Kotlin](../kotlin/README.md) SDKs use.

This SDK owns camera capture through `getUserMedia`, the render loop,
and decoding the PNGs the core has no decoder for. The frame graph, lens
runtime, and effect pipeline live in the core.

[docs/INTEGRATION-WEB.md](../../docs/INTEGRATION-WEB.md) is the start-to-finish
guide: build and host the wasm and model assets, the render loop, and the
tracking worker.

## Install

```json
{ "dependencies": { "@gosslens/core": "workspace:*" } }
```

This package is the JS wrapper only. `zig build wasm-emscripten`
produces the `gosslens_web.js`/`.wasm` pair `wasmJsUrl` below needs to
point at - not bundled, since WebGPU and WebGL2 are separate artifacts
(see below).

## Use

```ts
import { Gosslens, GossEngine, GossSession, GossPreviewSession } from "@gosslens/core";

const gosslens = await Gosslens.load(canvas, wasmJsUrl);
const engine = GossEngine.create(gosslens);
await engine.initRenderer(canvas);
const session = GossSession.create(engine);

session.submitFrameRgbaCopy(rgba, width * 4, width, height);
engine.renderFrame(session);

session.setWhiten(0.6);
session.activateLens(manifestJson);
```

`GossPreviewSession.create(canvas, wasmJsUrl, events)` does all three setup
steps and owns the capture loop too — most app code wants this one.

WebGPU and WebGL2 are two separate build artifacts, not a runtime
toggle; `pickEngineUrl` picks the right one after confirming a real
adapter.

Capture reads a PNG back, and world tracking feeds WebXR frames in:

```ts
import { GossWebXRWorldSource } from "@gosslens/core";

const png = await engine.captureFrame(session);   // data URL

const world = new GossWebXRWorldSource(session);
// in the XR animation loop:
world.onFrame(xrFrame, referenceSpace, timestampUs);
```

Video recording and platform photo formats are not wired on web yet; see
[docs/PARITY.md](../../docs/PARITY.md). The full cross-platform capability
tour is in the [root README](../../README.md#using-gosslens).

## Demo app

[`demo/`](demo/), a real web page — see [`demo/README.md`](demo/README.md).

## Tests

`bun test` runs the unit suite in [`test/`](test) - the frozen-layout result
parsers and the WebGPU/WebGL2 pick. The browser end-to-end proofs live in
[`demo/prove.ts`](demo/prove.ts) and [`demo/track-prove.ts`](demo/track-prove.ts),
with the host conformance in [`harness/`](../../harness/).

## TODO

- Publish to npm; the dependency above assumes a monorepo workspace.
