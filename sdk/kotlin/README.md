# Gosslens — Kotlin SDK

The Kotlin SDK for **Gosslens**, a brand-neutral camera engine. A Zig core
owns the frame graph, the lens runtime, and the effect pipeline behind one
frozen C ABI (`include/gosslens.h`); this module is the idiomatic layer an
Android app embeds over it — `Engine`, `Session`, `Gosslens` — matching the
Swift and TypeScript SDKs method for method.

This SDK owns capture ingress, GPU surface handoff, and the platform's own
tracking/world backends. It does **not** own the frame graph, the lens
runtime, or the effect pipeline — those live in the core and are identical
across every platform.

## Install

The library is this Gradle project's own root module. Depend on it from a
build that includes this repository:

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

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`-backed
frame; any non-OK status means that stream should fall back to
`submitFrameCopy`.

## Beauty and lenses

```kotlin
session.setWhiten(0.6f)
session.setSmooth(0.4f)
session.activateLens(manifestJson)
session.tickLens(dtUs, signals)
```

## Design commitments

- **Zero-copy on the frame path where the platform allows it.** A hardware
  buffer is wrapped, not re-encoded, until the lens graph itself needs to
  touch it.
- **One canonical method name per ABI operation.** `Session.setBeauty(effect, amount)`
  is the same name and parameter shape as Swift's `Session.setBeauty` and
  TypeScript's `Session.setBeauty` — decided once in `API-CONFORMANCE.md`,
  not reinvented per platform.
- **Every handle has one owner.** `Engine`/`Session` are `AutoCloseable`;
  `close()` is the sanctioned platform-idiom exception to `destroy()`.

## Demo app

`demo/` is a real Android app driving a live camera through this SDK — see
`demo/README.md`.

## TODO

- Publish to Maven Central / a coordinate consumers can depend on without
  including this repository; the install instructions above assume an
  included build until then.
- `src/test/` — this module has no unit test suite yet; conformance today
  runs through the demo app's `ConformanceRunner` and the headless harness
  in `harness/`, not a Gradle test task.
