# Gosslens — TypeScript SDK

The TypeScript SDK for **Gosslens**, a brand-neutral camera engine. A Zig
core owns the frame graph, the lens runtime, and the effect pipeline behind
one frozen C ABI (`include/gosslens.h`), compiled to `wasm32`; this package
is the idiomatic layer a web app embeds over it — `Engine`, `Session`,
`Gosslens` — matching the Swift and Kotlin SDKs method for method.

This SDK owns camera capture through `getUserMedia`, the render loop, and
decoding the PNGs the core has no decoder for. It does **not** own the frame
graph, the lens runtime, or the effect pipeline — those live in the core and
are identical across every platform.

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
once and also owns the capture loop (camera, `requestAnimationFrame`, FPS
accounting) — the class most demo/app code actually wants.

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

- **One canonical method name per ABI operation.** `Session.setBeauty(effect, amount)`
  is the same name and parameter shape as Swift's `Session.setBeauty` and
  Kotlin's `Session.setBeauty` — decided once in `API-CONFORMANCE.md`, not
  reinvented per platform.
- **Two build artifacts, not a runtime toggle.** WebGPU and WebGL2 are
  separate `gosslens_web.js`/`.wasm` outputs, since Asyncify (WebGPU) taxes
  the whole per-frame path; `pickEngineUrl` picks the right one after
  confirming a real adapter, never navigator.gpu's bare presence.

## Demo app

`demo/` is a real web page driving a live camera through this SDK — see
`demo/README.md`.

## TODO

- Publish to npm; the install instructions above assume a monorepo
  workspace dependency until then.
- `test/` — this package has no unit test suite yet; conformance today runs
  through `demo/prove.ts` and the headless harness in `harness/`, not a
  `bun test` task.
