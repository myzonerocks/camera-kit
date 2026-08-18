# Gosslens — Kotlin SDK

Kotlin SDK for Gosslens, a camera engine with a Zig core behind one C ABI
([`include/gosslens.h`](../../include/gosslens.h)). This module wraps that
ABI as `Engine`, `Session`, and `Gosslens`, the same names and method
shapes the [Swift](../swift/README.md) and [TypeScript](../ts/README.md)
SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform tracking.
The frame graph, the lens runtime, and the effect pipeline live in the core
and stay identical across every platform.

## Install

```kotlin
dependencies {
    implementation("com.myzonerocks:gosslens:0.1.0")
}
```

Resolved via [JitPack](https://jitpack.io), the same as depending straight
on a git repository rather than a formal registry. A consuming app
building against a checkout of this repository takes it as an included
build instead:

```kotlin
dependencies {
    implementation(project(":"))
}
```

```kotlin
import com.gosslens.Engine
import com.gosslens.Session
```

## Bring up an engine and a session

```kotlin
val engine = Engine.create()
engine.initRenderer(surface, width, height)

val session = Session.create(engine)
session.enableBeauty(resourceDir)
```

## Submit a frame and render

```kotlin
session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height, rotationDegrees = 90, mirrored = false, timestampUs)
engine.renderFrame(session)
```

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`. Any
non-OK status means that stream should fall back to `submitFrameCopy`.

## Beauty and lenses

```kotlin
session.setWhiten(0.6f)
session.setSmooth(0.4f)
session.activateLens(manifestJson)
session.tickLens(dtUs, signals)
```

## Design commitments

- Zero-copy on the frame path where the platform allows it: a hardware
  buffer is wrapped, not re-encoded, until the lens graph needs to touch it.
- One method name per ABI operation, held across all three SDKs, decided
  once per operation rather than guessed independently per platform.
- `Engine`/`Session` are `AutoCloseable`. `close()` is the one sanctioned
  platform-idiom exception to `destroy()`.

## Demo app

[`demo/`](demo/) is a real Android app driving a live camera through this
SDK. See [`demo/README.md`](demo/README.md).

## TODO

- Tag a real `0.1.0` release. The build script publishes this module and
  JitPack resolves any tagged commit, but no tag exists yet and this repo
  is private, which JitPack's free tier doesn't build from.
- Add a `src/test/` suite. Conformance today runs through the demo app's
  `ConformanceRunner` and the headless harness in
  [`harness/`](../../harness/), not a Gradle test task.
