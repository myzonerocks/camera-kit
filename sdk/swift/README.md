# Gosslens — Swift SDK

Swift SDK for [Gosslens](../../include/gosslens.h), a camera engine with a
Zig core behind one C ABI. Wraps it as `GossEngine`, `GossSession`, and
`Gosslens`, the same names the [Kotlin](../kotlin/README.md) and
[TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

[docs/INTEGRATION-iOS.md](../../docs/INTEGRATION-iOS.md) is the start-to-finish
guide: build the slices, add the package, set the two search paths, and the
minimal render loop.

## Install

```swift
.package(url: "https://github.com/myzonerocks/gosslens", branch: "main"),
```

```swift
.product(name: "Gosslens", package: "gosslens"),
```

Resolved from the [root manifest](../../Package.swift); `cd sdk/swift &&
swift build` uses this directory's own for development.

The package alone doesn't link the engine - `zig build ios`/`ios-simulator`
produces the native `.a` archives, and your app target needs its own
`LIBRARY_SEARCH_PATHS`/`OTHER_LDFLAGS` pointing at `zig-out/`. See
[`demo/project.yml`](demo/project.yml) for the exact list.

## Use

```swift
let engine = try GossEngine.create()
try engine.initRenderer(surface: metalLayer, width: width, height: height)

let session = try GossSession.create(engine: engine)
try session.enableBeauty(resourceDir: Bundle.main.bundlePath)

let desc = GossFrameDesc(
    width: width, height: height, pixelFormat: .nv12,
    rotationDegrees: 90, timestampUs: timestampUs
)
try session.submitFrame(desc: desc, planes: [yPlaneHandle, uvPlaneHandle])
try engine.renderFrame(session: session)

try session.setWhiten(0.6)
try session.activateLens(manifestJson: manifestData)
```

`submitFrame` wraps platform texture handles; `submitFrameCopy` is the
CPU fallback.

Capture, recording, and world tracking hang off the same engine and
session:

```swift
let photo = try engine.capturePhoto(session: session)             // preview-res PNG
let still = try engine.captureStill(session: session,             // full-res, supersampled
    config: GossEngine.StillConfig(width: 8064, height: 6048, supersample: 2))
let wide = try engine.captureStill(session: session,             // Display-P3, 16-bit PNG
    config: GossEngine.StillConfig(colorSpace: .displayP3, bitDepth: 16))
let jpeg = try engine.capturePhoto(session: session, as: .jpeg, quality: 92)

try engine.startRecording(session: session, path: outPath, hevc: true)
try engine.submitAudio(session: session, samples: pcm, frameCount: n,
                       sampleRate: 48000, channels: 1, timestampUs: ts)
try engine.stopRecording()

let world = GossWorldSource(session: session)   // ARKit, an ARSessionDelegate
arSession.delegate = world
world.start()
```

The full cross-platform capability tour is in the
[root README](../../README.md#using-gosslens).

## Demo app

[`demo/`](demo/) is a real iOS app; see [`demo/README.md`](demo/README.md).

## TODO

- Tag a release; the manifest above pins to `main`, which drifts.
- Add a `Tests/` target. Conformance runs through the demo app's
  `-GossConformance` launch argument and [`harness/`](../../harness/) for now.
