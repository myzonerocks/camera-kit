# API

Gosslens has one C ABI and three public SDKs: Swift, Kotlin, and TypeScript.
The ABI is the engine contract. This file is the public SDK naming and shape
contract built on top of it.

A developer who learns one Gosslens SDK should not have to relearn the same
operation on another platform.

## Rule

Every public `goss_*` ABI operation has one canonical SDK operation name and
one canonical parameter shape before wrappers are implemented independently.
Swift, Kotlin, and TypeScript use that operation identity rather than inventing
platform-specific names for the same engine action.

A new ABI function and its public API contract land together. A wrapper must
not ship first and be reconciled later.

## Public types

Every public ABI operation belongs to one public construct.

| Type | Owns |
|---|---|
| `Gosslens` | ABI bootstrap and pure stateless helpers |
| `Engine` | engine and render-surface lifecycle |
| `CaptureOutput` | screenshots, pixel readback, photo/video output |
| `Session` | frame submission, tracking, beauty, segmentation, runtime control |
| `Events` | per-session state and pull-based results |
| `LensRegistry` | lens activation, deactivation, and ticking |

`CaptureOutput`, `Events`, and `LensRegistry` may be exposed as borrowed views
or flattened convenience methods where the SDK already does so, but operation
names and parameter meaning do not change.

New media work does not automatically create new public types. If a new ABI
operation cannot fit this ontology cleanly, the type model is extended here
before any SDK exposes it.

## Naming

Use one verb for one class of operation.

| Form | Meaning |
|---|---|
| `create` / `destroy` | opaque-handle lifecycle |
| `init*` / `resize` | engine or surface setup |
| `render*` | render/advance a frame |
| `request*` | deferred operation whose result arrives later |
| `capture*` | capture/read data now |
| `submit*` | submit a frame to the engine pipeline |
| `track*` | submit work to tracking |
| `enable*` / `disable*` | binary capability state |
| `activate*` / `deactivate*` | swappable lens/content lifecycle |
| `set*` | synchronous state/parameter update |
| `load*` | I/O convenience that resolves into a canonical `set*` operation |
| `tick*` | advance a time-driven subsystem |
| `report*` | one-way telemetry input |
| bare noun | pure non-boolean query |
| `is*` / `has*` | pure boolean query |
| source-to-target name | pure stateless conversion, such as `yuvToRgb` |

Do not add `get*` merely because one language commonly uses it. Pure state
queries use the rules above.

A boolean returned from an action still uses the action name. For example,
`enableBeauty()` does not become `isBeautyEnabled()` merely because the ABI
returns success/failure.

## Async shape

The operation name stays the same even when platform-native async syntax
differs.

Operations with real I/O or GPU-readback latency may use:

- TypeScript: `Promise<T>`
- Swift: `async throws -> T`
- Kotlin: `suspend fun`

Pure engine operations stay synchronous unless the underlying contract itself
changes.

## Platform idioms

Two narrow exceptions are allowed.

1. Kotlin may expose `destroy()` as `close()` when the type implements
   `AutoCloseable` and participates in `use {}`. The lifecycle semantics must
   remain identical.
2. Swift may elide the first argument label when Swift API conventions require
   it. The base method name and every remaining parameter name stay canonical.

These are language-shape exceptions, not permission to rename operations.

## Future SDKs

The canonical operation identity is language-neutral even though the current
canonical spelling is camelCase.

- camelCase languages copy the name literally.
- snake_case languages mechanically convert camelCase to snake_case.
- PascalCase APIs mechanically uppercase the first character while preserving
  the remaining word boundaries.

Parameter names transform by the same mechanical rule. A new SDK does not
reopen naming decisions.

## Canonical operations

The table below is the tracked public contract. `include/gosslens.h` and this
file must move together.

### Gosslens

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_abi_version` | `Gosslens.abiVersion()` | all SDKs |
| `goss_color_yuv_to_rgb` | `Gosslens.yuvToRgb(colorStandard, colorRange)`, returning the conversion matrix | all SDKs |
| `goss_alloc` | ABI buffer plumbing for the wasm boundary; no public SDK operation | web internal |
| `goss_free` | ABI buffer plumbing for the wasm boundary; no public SDK operation | web internal |

### Engine

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_engine_create` | `Engine.create(config)` | all SDKs |
| `goss_engine_destroy` | `destroy()`; Kotlin may use `close()` | all SDKs |
| `goss_engine_init_renderer` | `initRenderer(surface, width, height)` | all SDKs |
| `goss_engine_resize` | `resize(width, height)` | all SDKs |
| `goss_engine_render_frame` | `renderFrame(session)` | all SDKs |

### CaptureOutput

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_engine_request_screenshot` | `requestScreenshot(path)` | debug/test where supported |
| `goss_engine_capture_frame` | `captureFrame()`, returning pixels plus the renderer's real width and height | supported SDKs |

### Session lifecycle

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_create` | `Session.create(engine, config)` | all SDKs |
| `goss_session_destroy` | `destroy()`; Kotlin may use `close()` | all SDKs |

### Frame submission

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_submit_frame` | `submitFrame(desc, planes)` | native zero-copy-capable SDKs |
| `goss_session_submit_frame_copy` | `submitFrameCopy(y, yStride, uv, uvStride, width, height, rotationDegrees, mirrored, colorStandard, colorRange, timestampUs)` | platforms that expose this copy path |
| `goss_session_submit_hardware_buffer` | `submitHardwareBuffer(buffer, width, height, rotationDegrees, mirrored, timestampUs)` | Android |
| `goss_session_submit_frame_rgba_copy` | `submitFrameRgbaCopy(rgba, stride, width, height, pixelFormat, rotationDegrees, mirrored, timestampUs)` | copy-path SDKs |

### Events and degradation

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_report_frame` | `reportFrame(frameTimeUs, thermal)` | all SDKs |
| `goss_session_degrade_level` | `degradeLevel()` | all SDKs |

### Face tracking

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_face_tracking` | `enableFaceTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_face_tracking` | `disableFaceTracking()` | native tracking path |
| `goss_session_enable_hand_tracking` | `enableHandTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_hand_tracking` | `disableHandTracking()` | native tracking path |
| `goss_session_enable_pose_tracking` | `enablePoseTracking(taskBundle, threads)` | native tracking path |
| `goss_session_disable_pose_tracking` | `disablePoseTracking()` | native tracking path |
| `goss_session_track_frame` | `trackFrame(y, yStride, uv, uvStride, width, height, colorStandard, colorRange, timestampUs)`; feeds every enabled tracking worker | native tracking path |
| `goss_session_face_result` | `faceResult(result)` | native tracking path |
| `goss_session_hand_result` | `handResult(result)` | native tracking path |
| `goss_session_pose_result` | `poseResult(result)` | native tracking path |
| `goss_session_face_pose` | `facePose(matrix)`, filling a caller-owned 16-float column-major array | native tracking path |
| `goss_session_set_face_landmarks` | `setFaceLandmarks(points)`; web adds `sourceWidth, sourceHeight` since its analysis resolution is decoupled from the rendered frame's | Web analysis-producer path |

### Segmentation

`goss_session_enable_segmentation` exists at the ABI level, but its public
parameter contract is not frozen yet. **No SDK may invent and ship a public
`enableSegmentation(...)` signature until this section is updated with the
complete parameter list.**

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_segmentation` | `enableSegmentation(...)` — reserved, parameters not yet frozen | pending contract |
| `goss_session_disable_segmentation` | `disableSegmentation()` | all SDKs once exposed |

### Beauty

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_enable_beauty` | `enableBeauty(resourceDir)` | supported SDKs |
| `goss_session_disable_beauty` | `disableBeauty()` | supported SDKs |
| `goss_session_set_beauty` | `setBeauty(effect, amount)` | supported SDKs |
| convenience | `setWhiten(amount)` | supported SDKs |
| convenience | `setSmooth(amount)` | supported SDKs |
| convenience | `setThinFace(amount)` | supported SDKs |
| convenience | `setBigEye(amount)` | supported SDKs |
| convenience | `setLipstick(amount)` | supported SDKs |
| convenience | `setBlush(amount)` | supported SDKs |
| `goss_session_set_beauty_lut` | `setBeautyLut(slot, rgba, width, height)` | Web ABI path; `loadWhitenLuts(url)` may exist as I/O sugar |
| `goss_session_set_beauty_makeup_texture` | `setBeautyMakeupTexture(effect, rgba, width, height)` | Web ABI path; `loadMakeupTextures(url)` may exist as I/O sugar |
| `goss_session_beautify_frame` | `beautifyFrame(rgbaIn, rgbaOut, width, height)` | supported SDKs |

### LensRegistry

| ABI function | Public operation | Scope |
|---|---|---|
| `goss_session_activate_lens` | `activateLens(manifestJson)` | all SDKs |
| `goss_session_activate_lens_from_directory` | `activateLensFromDirectory(bundlePath)` | native SDKs |
| `goss_session_deactivate_lens` | `deactivateLens()` | all SDKs |
| `goss_session_tick_lens` | `tickLens(dtUs, signals)` | all SDKs |

## Web tracking module

The web SDK's face tracking runs in a separate wasm module
(`gosslens_tracking.wasm`, built by `zig build tracking-wasm`), not through
the frozen C ABI - wasm has no threads here, so the main engine module
can't host the tracking worker the native targets run in-process. Its
exports are their own small contract, wrapped only by the web SDK's
`FaceTracker`:

| Export | Contract |
|---|---|
| `goss_tracking_alloc(size)` / `goss_tracking_free(ptr, size)` | module-heap staging for the buffers below |
| `goss_tracking_result_size()` | byte size of the result struct, `goss_face_result`'s frozen layout |
| `goss_tracking_create(taskPtr, taskLen)` | instance from task-bundle bytes; zero on rejection |
| `goss_tracking_destroy(instance)` | releases the instance |
| `goss_tracking_process(instance, rgba, width, height, timestampUs)` | synchronous inference over one RGBA frame; nonzero refuses the frame |
| `goss_tracking_result(instance, out)` | copies the newest published result; nonzero until one exists |

These names stay `goss_tracking_*`, never gain platform variants, and a
change here is an ABI change with the same review bar as
`include/gosslens.h`.

## Media additions

GossMedia follows the same rule. A new encoder, decoder, muxer, demuxer,
recording, import, metadata, audio, or capture-output ABI function is not
special because it is new infrastructure.

Before an SDK wrapper lands:

1. the `goss_*` ABI operation exists in `include/gosslens.h`;
2. its owning public type is settled;
3. its canonical operation name and full parameter shape are added here;
4. platform scope and capability/degradation behavior are stated;
5. Swift, Kotlin, and TypeScript implementations use that contract.

Do not expose vendor vocabulary such as FFmpeg/libav contexts, codec-library
handles, VideoToolbox objects, `MediaCodec` objects, WebCodecs objects, or
vendor packet/frame types in this contract.

## Gate

CI should mechanically compare the public ABI function list against this
contract and reject a new public `goss_*` operation with no API entry.
SDK wrapper lint should compare each wrapper's operation name and parameter
shape against this file.

An API mismatch is a failed change, not an SDK-specific style preference.
