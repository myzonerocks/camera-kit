# Integrating gosslens on Android

The path from a checkout to a camera preview with a lens on it in your own
app. The [Kotlin SDK](../sdk/kotlin/README.md) is the surface; the
[demo](../sdk/kotlin/demo) is a full working reference for the frame loop.

Unlike the static-archive story on iOS, the engine ships here as one shared
library. `libgosslens.so` links the whole engine - the inference stack,
QuickJS, Jolt, everything - into itself, so there is nothing for a consumer to
resolve by hand. The one thing to get right is that the `.so` is present when
gradle packages your app.

## Build the native library

    zig build android

This writes `zig-out/android/arm64-v8a/libgosslens.so` and
`zig-out/android/x86_64/libgosslens.so`. arm64-v8a covers every current device
and the arm64 emulator an Apple-silicon machine runs by default; x86_64 covers
an Intel-host emulator. gradle picks the right one per ABI, so a device and
either emulator all link and run the engine.

## Add the SDK

The Kotlin SDK is an Android library module that packages the `.so` for you -
its gradle reads `jniLibs.srcDir("../../zig-out/android")`, so once you have run
`zig build android`, the archive it produces carries the native library.

The SDK is not published to Maven Central (or anywhere) yet, so add this
project as an included build and depend on it - gradle substitutes the module
for the coordinate, no registry involved:

    // settings.gradle.kts
    includeBuild("../gosslens/sdk/kotlin")

    // build.gradle.kts
    dependencies {
        implementation("com.myzonerocks:gosslens")
    }

Publishing an AAR to a coordinate later works the same way, as long as the
`.so` exists at publish time - so a publish step runs `zig build android`
first. A source-only service like JitPack does not run that step and would ship
an AAR with no native library, which crashes on `System.loadLibrary`; the
included build above is the only path that works today.

## The render loop

Create the engine and a session once, then submit and render per frame. Submit
and render run on the same thread.

    val engine = GossEngine.create()
    engine.initRenderer(surface, width, height)
    val session = GossSession.create(engine)

    // per camera frame
    session.submitFrameCopy(yBuffer, yStride, uvBuffer, uvStride, width, height,
                            rotationDegrees = 90, mirrored = false, timestampUs)
    engine.renderFrame(session)

`submitHardwareBuffer` is the zero-copy path for an `AHardwareBuffer`; any
non-OK status falls back to `submitFrameCopy`.
[`MainActivity`](../sdk/kotlin/demo/src/main/kotlin/com/gosslens/demo/MainActivity.kt)
is the copy-pasteable version of this, including the surface and camera wiring.

## Lenses

A lens is a manifest plus its assets. Activate one on the session:

    session.activateLens(manifestJson)

A lens that reads face, hand, or pose landmarks needs the matching ML model
enabled first, or it loads and renders nothing with no error:

    session.enableFaceTracking(taskBundle, threads = 2)

The `.task` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`) are separate resources you ship with your app;
they are not part of the `.so`. Bundle the ones your lenses use.

## Lives and calls

Publishing the lens-baked frames into a LiveKit or WebRTC call is a custom
video source fed one frame per tick. `captureLiveFrame` renders the composited
frame and returns it in a WebRTC format (BGRA by default), so you build a
`VideoFrame` for the source with no channel swizzle of your own:

    val frame = engine.captureLiveFrame(session, width, height) ?: return
    // wrap frame (BGRA, width x height) in a VideoFrame and hand it to the
    // custom VideoSource you publish; show the same frame locally too

It renders once per call, so a broadcast source needs no separate preview
render. For audio, `submitAudio` feeds the mic in so audio-reactive lenses
respond. For the outgoing track, `mixOutputAudio` folds the lens's own sound
into the mic block you are about to publish and hands back the mixed interleaved
s16 - the engine resamples the lens sound to your track's rate and sums it in,
so there is nothing to hand-mix (pass a null mic buffer for lens sound over
silence). `pullAudio` still pulls the lens sound alone for local playback with
no call; in a call, `mixOutputAudio` replaces it.

## Method names

The operation names match the other SDKs: `GossEngine.create(config)`,
`GossSession.create(engine)`, `submitFrameCopy`, `renderFrame`. The full table
is in [API.md](API.md).
