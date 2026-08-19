# Gosslens — Swift SDK

Swift SDK for [Gosslens](../../include/gosslens.h), a camera engine with a
Zig core behind one C ABI. Wraps it as `Engine`, `Session`, and
`Gosslens` — the same names the [Kotlin](../kotlin/README.md) and
[TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

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
let engine = try Engine.create()
try engine.initRenderer(surface: metalLayer, width: width, height: height)

let session = try Session.create(engine: engine)
try session.enableBeauty(resourceDir: Bundle.main.bundlePath)

let desc = FrameDesc(
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

## Demo app

[`demo/`](demo/), a real iOS app — see [`demo/README.md`](demo/README.md).

## TODO

- Tag a release; the manifest above pins to `main`, which drifts.
- Add a `Tests/` target. Conformance runs through the demo app's
  `-GossConformance` launch argument and [`harness/`](../../harness/) for now.
