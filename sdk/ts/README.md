# Gosslens — TypeScript SDK

TypeScript SDK for [Gosslens](../../include/gosslens.h), a camera engine
with a Zig core behind one C ABI, compiled to `wasm32`. Wraps it as
`Engine`, `Session`, and `Gosslens` — the same names the
[Swift](../swift/README.md) and [Kotlin](../kotlin/README.md) SDKs use.

This SDK owns camera capture through `getUserMedia`, the render loop,
and decoding the PNGs the core has no decoder for. The frame graph, lens
runtime, and effect pipeline live in the core.

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
import { Gosslens, Engine, Session, PreviewSession } from "@gosslens/core";

const gosslens = await Gosslens.load(canvas, wasmJsUrl);
const engine = Engine.create(gosslens);
await engine.initRenderer(canvas);
const session = Session.create(engine);

session.submitFrameRgbaCopy(rgba, width * 4, width, height);
engine.renderFrame(session);

session.setWhiten(0.6);
session.activateLens(manifestJson);
```

`PreviewSession.create(canvas, wasmJsUrl, events)` does all three setup
steps and owns the capture loop too — most app code wants this one.

WebGPU and WebGL2 are two separate build artifacts, not a runtime
toggle; `pickEngineUrl` picks the right one after confirming a real
adapter.

## Demo app

[`demo/`](demo/), a real web page — see [`demo/README.md`](demo/README.md).

## TODO

- Publish to npm; the dependency above assumes a monorepo workspace.
- Add a `test/` suite. Conformance runs through
  [`demo/prove.ts`](demo/prove.ts) and [`harness/`](../../harness/) for now.
