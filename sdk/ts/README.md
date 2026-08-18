# Gosslens — TypeScript SDK

TypeScript SDK for Gosslens, a camera engine with a Zig core behind one C
ABI ([`include/gosslens.h`](../../include/gosslens.h)), compiled to
`wasm32`. This package wraps that ABI as `Engine`, `Session`, and
`Gosslens`, the same names and method shapes the
[Swift](../swift/README.md) and [Kotlin](../kotlin/README.md) SDKs use.

This SDK owns camera capture through `getUserMedia`, the render loop, and
decoding the PNGs the core has no decoder for. The frame graph, the lens
runtime, and the effect pipeline live in the core and stay identical across
every platform.

## Install

```json
{
  "dependencies": {
    "@gosslens/core": "workspace:*"
  }
}
```

```ts
import { Gosslens, Engine, Session, PreviewSession } from "@gosslens/core";
```

## Bring up an engine and a session

```ts
const gosslens = await Gosslens.load(canvas, wasmJsUrl);
const engine = await Engine.create(gosslens, canvas);
const session = Session.create(engine, gosslens);
```

`PreviewSession.create(canvas, wasmJsUrl, events)` does all three steps at
once and also owns the capture loop: camera, `requestAnimationFrame`, FPS
accounting. Most app code wants this one, not the three pieces directly.

## Submit a frame and render

```ts
session.submitFrameRgbaCopy(rgba, width, height, mirror);
engine.renderFrame(session);
```

## Beauty and lenses

```ts
session.setWhiten(0.6);
session.setSmooth(0.4);
session.activateLens(manifestJson);
session.tickLens(dtUs);
```

## Design commitments

- One method name per ABI operation, held across all three SDKs, decided
  once per operation rather than guessed independently per platform.
- WebGPU and WebGL2 are two separate build artifacts, not a runtime
  toggle: Asyncify (required for WebGPU) taxes the whole per-frame path.
  `pickEngineUrl` picks the right one after confirming a real adapter,
  not just `navigator.gpu`'s presence.

## Demo app

[`demo/`](demo/) is a real web page driving a live camera through this
SDK. See [`demo/README.md`](demo/README.md).

## TODO

- Publish to npm. The install instructions above assume a monorepo
  workspace dependency until then.
- Add a `test/` suite. Conformance today runs through
  [`demo/prove.ts`](demo/prove.ts) and the headless harness in
  [`harness/`](../../harness/), not a `bun test` task.
