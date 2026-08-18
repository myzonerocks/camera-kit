# Gosslens — Swift SDK

The Swift SDK for **Gosslens**, a brand-neutral camera engine. A Zig core owns
the frame graph, the lens runtime, and the effect pipeline behind one frozen C
ABI (`include/gosslens.h`); this package is the idiomatic layer an iOS app
embeds over it — `Engine`, `Session`, `Gosslens` — matching the Kotlin and
TypeScript SDKs method for method.

This SDK owns capture ingress, GPU surface handoff, and the platform's own
tracking/world backends. It does **not** own the frame graph, the lens
runtime, or the effect pipeline — those live in the core and are identical
across every platform.

## Install

Add the package locally (this repository has not published a tagged release
yet):

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

`submitFrame` is zero-copy: the platform texture handles are wrapped, not
copied. `submitFrameCopy` is the CPU-copy fallback for a stream whose planes
aren't already GPU textures.

## Beauty and lenses

```swift
try session.setWhiten(0.6)
try session.setSmooth(0.4)
try session.activateLens(manifestJson: manifestData)
try session.tickLens(dtUs: frameTimeUs, signals: LensSignals(hasFace: true))
```

## Design commitments

- **Zero-copy on the frame path.** A submitted frame's platform texture is
  wrapped, never re-encoded, until the lens graph itself needs to touch it.
- **One canonical method name per ABI operation.** `Session.setBeauty(effect:amount:)`
  is the same name and parameter shape as Kotlin's `Session.setBeauty` and
  TypeScript's `Session.setBeauty` — decided once in `API-CONFORMANCE.md`,
  not reinvented per platform.
- **Every handle has one owner.** `destroy()` is idempotent and `deinit`
  falls back to it, so a double-free through the wrapper is not possible.

## Demo app

`demo/` is a real iOS app driving a live camera through this SDK — see
`demo/README.md`.

## TODO

- Publish a tagged release; the install instructions above assume a local
  path dependency until then.
- `Tests/` — this package has no test target yet; conformance today runs
  through the demo app's `-GossConformance` launch argument and the
  headless harness in `harness/`, not a SwiftPM test suite.
