# Gosslens — Kotlin SDK

Kotlin SDK for [Gosslens](../../include/gosslens.h), a camera engine with a
Zig core behind one C ABI. Wraps it as `Engine`, `Session`, and
`Gosslens` — the same names the [Swift](../swift/README.md) and
[TypeScript](../ts/README.md) SDKs use.

This SDK owns capture ingress, GPU surface handoff, and platform
tracking. The frame graph, lens runtime, and effect pipeline live in the
core.

## Install

```kotlin
repositories {
    maven { url = uri("https://jitpack.io") }
}
dependencies {
    implementation("com.myzonerocks:gosslens:0.1.0")
}
```

Built from a tagged commit by [JitPack](https://jitpack.io) — see
[`jitpack.yml`](../../jitpack.yml). Building against a checkout of this
repository takes it as an included build instead:

```kotlin
dependencies {
    implementation(project(":"))
}
```

## Use

```kotlin
val engine = Engine.create()
engine.initRenderer(surface, width, height)

val session = Session.create(engine)
session.enableBeauty(resourceDir)

session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height, rotationDegrees = 90, mirrored = false, timestampUs)
engine.renderFrame(session)

session.setWhiten(0.6f)
session.activateLens(manifestJson)
```

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`;
any non-OK status falls back to `submitFrameCopy`.

## Demo app

[`demo/`](demo/), a real Android app — see [`demo/README.md`](demo/README.md).

## TODO

- Tag a `0.1.0` release; JitPack needs a real tag to resolve.
- Add a `src/test/` suite. Conformance runs through the demo app's
  `ConformanceRunner` and [`harness/`](../../harness/) for now.
