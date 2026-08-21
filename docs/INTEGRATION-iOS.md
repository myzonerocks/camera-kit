# Integrating gosslens on iOS

This is the path from a checkout to a camera preview with a lens on it in
your own app. The [Swift SDK](../sdk/swift/README.md) is the surface; the
[demo](../sdk/swift/demo) is a full working reference for the frame loop.

## Build the engine slices

The SDK is thin Swift over a static engine. Build the engine for the slices
you target; the output lands in `zig-out`.

    zig build ios
    zig build ios-simulator -Dios-simulator-sdk="$(xcrun --sdk iphonesimulator --show-sdk-path)"

The device step reads the SDK from your `--sysroot`; the simulator step needs
the SDK path passed in, and its error message prints the exact `xcrun` line if
you leave it out. Each step writes `libgosslens.a` and the vendored archives
(bgfx, the inference stack, ANGLE, QuickJS, Jolt) into `zig-out/ios` and
`zig-out/ios-simulator`, all aligned and ready to link.

The simulator slice is arm64 only. On an Apple-silicon Mac build with
`ONLY_ACTIVE_ARCH=YES` against a concrete simulator, not a universal
destination that would also ask for an x86_64 half.

## Add the package

Point SwiftPM at the repository, either as a local path while you develop or
as a git dependency:

    .package(path: "../gosslens")
    .package(url: "https://github.com/myzonerocks/gosslens", branch: "main")

The `Gosslens` product carries the whole `-l` list and the frameworks it needs
in its own linker settings, so you do not copy them by hand. It cannot know
where you put `zig-out`, so set the two search paths on your app target, one
per slice:

    LIBRARY_SEARCH_PATHS[sdk=iphoneos*]        = .../gosslens/zig-out/ios
    LIBRARY_SEARCH_PATHS[sdk=iphonesimulator*] = .../gosslens/zig-out/ios-simulator

That is the whole build setup. The header comes from the package's C module,
so there is nothing else to wire.

## The render loop

Create the engine and a session once, then submit and render per frame. Submit
and render run on the same thread.

    let engine = try GossEngine.create()
    try engine.initRenderer(surface: metalLayer, width: w, height: h)
    let session = try GossSession.create(engine: engine)

    // per camera frame
    let desc = GossFrameDesc(width: w, height: h, pixelFormat: .nv12,
                             rotationDegrees: 90, timestampUs: ts)
    try session.submitFrame(desc: desc, planes: [yTextureHandle, uvTextureHandle])
    try engine.renderFrame(session: session)

`submitFrame` takes platform texture handles for the zero-copy path;
`submitFrameCopy` is the CPU fallback from an NV12 byte buffer.
[`CameraController`](../sdk/swift/demo/Sources/CameraController.swift) and
[`PreviewViewController`](../sdk/swift/demo/Sources/PreviewViewController.swift)
are the copy-pasteable version of this, including the `CADisplayLink` loop and
the NV12 to Metal-texture handoff.

## Lenses

A lens is a manifest plus its assets. Activate one on the session:

    try session.activateLens(manifestJson: manifestData)

A lens that reads face, hand, or pose landmarks needs the matching ML model
enabled first, or it loads and renders nothing with no error:

    try session.enableFaceTracking(taskBundle: faceTaskData, threads: 2)

The `.task` bundles (`face_landmarker.task`, `gesture_recognizer.task`,
`pose_landmarker_full.task`) are separate resources you ship with your app;
they are not part of the engine archive. Bundle the ones your lenses use.

## Lives and calls

Publishing the lens-baked frames into a LiveKit or WebRTC call is a custom
video source fed one frame per tick. `GossLiveOutput` is the zero-copy path:
it renders the composited frame straight into an IOSurface-backed BGRA pixel
buffer - no readback - which VideoToolbox then encodes from the same surface.
Create one per broadcast on the renderer's `MTLDevice` (your `CAMetalLayer`'s):

    let live = GossLiveOutput(engine: engine, device: metalLayer.device!, width: w, height: h)!

    // per tick
    if let buffer = live.nextFrame(session: session) {
        capturer.capture(buffer)   // publish; show the same buffer locally too
    }

`nextFrame` renders once per call, so a broadcast source needs no separate
preview render - display the same buffer locally. It returns nil to skip a
frame while a fresh pool texture warms up bgfx's override, so just wait for
the next tick. Under the hood it calls `renderToLiveTexture`, which points the
final composite pass at your texture instead of the swap chain.

If you would rather own the pixels, `captureLiveFrame(format:)` reads the
frame back in BGRA, RGBA, or NV12 - one copy, for a software encoder or a
frame you inspect. The zero-copy `GossLiveOutput` is the broadcast default.

For audio, `submitAudio` feeds the mic in so audio-reactive lenses respond, and
`pullAudio` pulls a lens's own sound out. Mix that PCM into your outgoing
LiveKit audio track's buffer the way you would any custom audio source.

## Method names

The operation names are the same across all three SDKs and are the ones in the
source: `GossEngine.create(config:)`, `GossSession.create(engine:)`,
`submitFrame`, `renderFrame`. The full table is in [API.md](API.md).
