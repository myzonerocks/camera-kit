# Gosslens — Kotlin SDK

Kotlin SDK for [Gosslens](../../include/gosslens.h), a camera engine with a
Zig core behind one C ABI. Wraps it as `GossEngine`, `GossSession`, and
`Gosslens` — the same names the [Swift](../swift/README.md) and
[TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

## Install

Building against a checkout of this repository:

```kotlin
dependencies {
    implementation(project(":"))
}
```

Over [JitPack](https://jitpack.io) once a tag exists (see the native-`.so`
caveat in TODO below):

```kotlin
repositories {
    maven { url = uri("https://jitpack.io") }
}
dependencies {
    implementation("com.myzonerocks:gosslens:0.1.0")
}
```

## Use

```kotlin
val engine = GossEngine.create()
engine.initRenderer(surface, width, height)

val session = GossSession.create(engine)
session.enableBeauty(resourceDir)

session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height, rotationDegrees = 90, mirrored = false, timestampUs)
engine.renderFrame(session)

session.setWhiten(0.6f)
session.activateLens(manifestJson)
```

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`;
any non-OK status falls back to `submitFrameCopy`.

Photo capture, recording, and audio hang off the same engine and session:

```kotlin
val png: ByteArray? = engine.capturePhoto(session)

engine.startRecording(session, outPath, hevc = true)
engine.submitAudio(session, pcm, frameCount, sampleRate = 48000, channels = 1, timestampUs)
engine.stopRecording()
```

World tracking feeds ARCore frames in through the demo's
[`WorldFeeder`](demo/src/main/kotlin/com/gosslens/demo/WorldFeeder.kt).
Full-resolution stills and platform photo formats are iOS-first for now;
see [docs/PARITY.md](../../docs/PARITY.md). The full cross-platform
capability tour is in the [root README](../../README.md#using-gosslens).

## Demo app

[`demo/`](demo/), a real Android app — see [`demo/README.md`](demo/README.md).

## TODO

- Tag a `0.1.0` release; JitPack needs a real tag to resolve.
- JitPack's build doesn't run `zig build android` first, so today's
  JitPack artifact would carry no native `.so` and crash on
  `System.loadLibrary`. Needs a real CI step that cross-compiles the
  native library (NDK-dependent, not something JitPack's own
  environment can do) before publishing - the included-build path
  above is the only one that works right now.
- Add a `src/test/` suite. Conformance runs through the demo app's
  `ConformanceRunner` and [`harness/`](../../harness/) for now.
