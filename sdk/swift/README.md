# Gosslens — Swift SDK

Swift SDK for Gosslens, a camera engine with a Zig core behind one C ABI
([`include/gosslens.h`](../../include/gosslens.h)). This package wraps that
ABI as `Engine`, `Session`, and `Gosslens`, the same names and method
shapes the [Kotlin](../kotlin/README.md) and [TypeScript](../ts/README.md)
SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform tracking.
The frame graph, the lens runtime, and the effect pipeline live in the core
and stay identical across every platform.

## Install

No tagged release yet, so add the package by local path:

```swift
.package(path: "../gosslens/sdk/swift"),
```

```swift
import Gosslens
```

## Bring up an engine and a session

```swift
let engine = try Engine.create()
try engine.initRenderer(surface: metalLayer, width: width, height: height)

let session = try Session.create(engine: engine)
try session.enableBeauty(resourceDir: Bundle.main.bundlePath)
```

## Submit a frame and render

```swift
try session.submitFrame(
    planes: [yPlaneHandle, uvPlaneHandle],
    width: width, height: height,
    pixelFormat: GOSS_PIXEL_NV12.rawValue,
    rotationDegrees: 90, mirrored: false,
    timestampUs: timestampUs
)
try engine.renderFrame(session: session)
```

`submitFrame` wraps the platform texture handles instead of copying them.
`submitFrameCopy` is the CPU-copy fallback for planes that aren't already
GPU textures.

## Beauty and lenses

```swift
try session.setWhiten(0.6)
try session.setSmooth(0.4)
try session.activateLens(manifestJson: manifestData)
try session.tickLens(dtUs: frameTimeUs, signals: LensSignals(hasFace: true))
```

## Design commitments

- Zero-copy on the frame path: a submitted frame's platform texture is
  wrapped, not re-encoded, until the lens graph needs to touch it.
- One method name per ABI operation, held across all three SDKs, decided
  once per operation rather than guessed independently per platform.
- `destroy()` is idempotent and `deinit` falls back to it, so a double-free
  through this wrapper can't happen.

## Demo app

[`demo/`](demo/) is a real iOS app driving a live camera through this SDK.
See [`demo/README.md`](demo/README.md).

## TODO

- Publish a tagged release. The install instructions above assume a local
  path dependency until then.
- Add a `Tests/` target. Conformance today runs through the demo app's
  `-GossConformance` launch argument and the headless harness in
  [`harness/`](../../harness/), not a SwiftPM test suite.
