# Architecture

Gosslens is one Zig camera engine with three thin SDKs: Swift for iOS,
Kotlin for Android, TypeScript for the web. The core owns portable engine
behavior. Platform code owns only what the platform has to own.

It is built in the open as a full camera and AR engine: camera
manipulation, face/hand/body understanding, segmentation, world anchoring,
physics-driven and scripted lens content, and a portable media rail, all
behind one frozen C ABI. Capability growth reuses the rails below — the
tracking module's model path, the lens format's nodes and triggers, the
bgfx graph — so a new capability is a new model or node on an existing
seam, not new machinery.

The checked-out repository is the structural source of truth. New work extends
an existing boundary where one already exists. It does not move working code
into a cleaner-looking tree for its own sake.

## Shape

    include/gosslens.h          the single C ABI

    core/
      abi/                      C ABI exports
      graph/                    frame graph, scheduling, pools, degradation
      lens/                     .glens parsing, triggers, animation, runtime
      math/                     vectors, matrices, poses, color math
      tracking/                 engine-owned tracking models and logic
      media/                    media contracts and orchestration; additive

    adapters/
      android/                  existing Android/JNI bridge
      angle/                    ANGLE integration and support
      asset/                    asset boundary
      beauty/                   GPUPixel and beauty interop
      bgfx/                     rendering backend and shader plumbing
      gltf/                     cgltf asset loading
      image/                    image operations; libyuv's planned home
      tracking/                 tracking/inference vendor boundary
      media/                    portable codec/container backends; additive

    sdk/
      swift/                    iOS API and platform-only backends
      kotlin/                   Android API and platform-only backends
      ts/                       web API and platform-only backends

    lenses/
      reference/                reference .glens bundles
      shaders/                  lens/effect shaders
      validator/                .glens validation
      SPEC.md                   public lens-format contract

    harness/                    desktop and conformance runners
    third_party/                pinned vendor sources and metadata
    tools/                      toolchain bootstrap and repository gates
    docs/                       public project documentation
      API.md                    canonical public SDK naming/shape contract
    docs/private/               local-only engineering material; never tracked

The media work is additive. It does not rename or relocate `adapters/image`,
`adapters/tracking`, `adapters/beauty`, `adapters/bgfx`, `core/tracking`,
`lenses/shaders`, or any other established subsystem.

## Ownership

The Zig core owns the frame graph, lens runtime, media model, scheduling,
resource lifetime, capability selection, degradation policy, timestamps,
packet descriptions, synchronization policy, and portable behavior.

The SDKs own capture ingress, native GPU handles, native hardware media APIs,
world-tracking APIs, and the idiomatic Swift/Kotlin/TypeScript surface. A
feature that can live in Zig does not belong in an SDK.

Vendor libraries are implementation details. Their types, allocators, threads,
exceptions, frames, packets, and lifecycle do not escape their adapter. The
public ABI contains Gosslens types only.

## Media

Gosslens owns its media contract. It does not wrap a general multimedia
framework.

`core/media/` owns Gosslens video/audio codec descriptions, packets, timebases,
timestamps, mux/demux contracts, backend selection, A/V synchronization, and
capture-output orchestration.

`adapters/media/` owns portable codec and container bindings. Platform-native
media implementations stay under the existing SDK trees. Targets link only the
backends they require.

The preferred path is native and zero-copy:

    camera buffer -> graph/effects -> native/GPU consumer

CPU materialization is a fallback:

    camera/native buffer -> adapters/image -> libyuv -> CPU consumer

libyuv, once vendored as part of the media rail, is the single CPU
image-conversion authority. CPU YUV/RGB conversion, scaling, and rotation go
through the existing `adapters/image/` boundary. Code must not grow a second
private converter in tracking, media, capture, or an SDK.
"Central" means one CPU conversion path. It does not mean every frame is copied
through libyuv.

## Capability rails

The AR capability plan rides existing seams; each component below is
planned, arrives pinned under `third_party/` with license metadata like
every other dependency, and stays behind its adapter:

- Hand, body-pose, and segmentation models run on the tracking module's
  existing inference rail, the same way the face pipeline already does.
  Creator-supplied models use that rail's model-loading contract too.
- Face-mesh effects (makeup, masks, face paint) build on the canonical
  face topology over landmarks the engine already tracks.
- World tracking is platform-owned: ARKit, ARCore, and WebXR behind one
  engine seam. Open SLAM stacks are copyleft-licensed and do not enter
  the dependency graph.
- Physics for lens content is a vendored permissive engine behind an
  adapter; cloth and hair follow rigid bodies.
- Lens scripting is a sandboxed embedded engine whose API is the lens
  format's trigger and parameter surface, with a determinism contract
  and no ambient I/O. Lenses remain untrusted content.
- Audio playback and analysis feed level and beat signals into the lens
  trigger system.
- Particles and post effects are engine-owned bgfx passes, not a
  dependency.

Portable codec/container libraries, when required by a target, live behind
`adapters/media/`. The intended stack includes narrowly scoped backends such as
OpenH264, libaom, dav1d, libvpx, libopus, and libwebm. Each dependency must pass
the license, provenance, build, and conformance gates before it is introduced.
Their presence never changes the Gosslens media types or public API.

FFmpeg is not a fallback. Neither are libav or GStreamer. A missing codec,
container, importer, scaler, resampler, or streaming feature is implemented
through a permissive component, a platform API, or a narrow Gosslens-owned
piece without changing this rule.

## Dependency licenses

Gosslens is proprietary-compatible by construction. Dependencies must use a
permissive license that allows the surrounding Gosslens code and SDKs to remain
private or closed source. Upstream copyright, attribution, NOTICE, patent, and
redistribution obligations still apply.

Allowed without a separate policy change:

- MIT
- BSD-2-Clause
- BSD-3-Clause
- Apache-2.0
- Zlib
- an explicitly approved permissive equivalent with substantially the same
  proprietary-use posture

Explicitly approved exceptions, recorded per component under `third_party/`
and enforced by the vendor sync's license check: Eigen under MPL-2.0
(file-level copyleft on Eigen's own files only, consumed unmodified),
fft2d under the Ooura permission notice, and the Emscripten Python
runtime under PSF-2.0. Each was reviewed against the proprietary-use
posture above; an exception here never widens the general allowlist.

Blocked:

- GPL, any version
- AGPL, any version
- LGPL, any version and any linkage form
- SSPL and other source-available/copyleft-style licenses outside the allowlist
- non-commercial, research-only, or field-of-use restrictions
- binary-only dependencies
- unknown or custom licenses without explicit project approval

Static linking, dynamic linking, runtime loading, subprocess use, vendoring, or
transitive inclusion does not create a license exception.

FFmpeg, `libavcodec`, `libavformat`, `libavutil`, `libswscale`,
`libswresample`, `libavfilter`, and GStreamer are explicitly forbidden in the
shipping dependency graph. They must not appear as source dependencies, linked
libraries, runtime-loaded libraries, bundled tools, or transitive native
dependencies.

Every third-party addition must carry an exact upstream revision, digest,
license material, required NOTICE/patent material, and the smallest build we
actually ship. The license gate checks direct and transitive dependencies. A
red license gate is a failed change, not an exception request hidden in a PR.

## ABI

`include/gosslens.h` is the one C ABI. It uses opaque handles and plain data
descriptors. Swift imports it, Kotlin reaches it through JNI, and the web uses
the same core compiled to wasm.

No C++ type crosses it. No vendor type crosses it. No platform object crosses
it except as an opaque platform handle described by the ABI contract.

ABI changes are additive within a major version and are checked against all
three SDKs.

## Public API contract

`include/gosslens.h` is the engine ABI. [API.md](API.md) is the tracked public
contract that maps ABI operations to SDK operation names, parameter shapes,
ownership, and platform scope.

Swift, Kotlin, and TypeScript do not independently invent names for the same
engine operation. The canonical operation identity is decided once in
`docs/API.md`; wrappers implement that decision. A new public `goss_*` ABI
operation and its API entry land together. A wrapper with an unresolved or
different parameter shape does not ship.

Future SDKs derive names mechanically from the same canonical operation rather
than reopening the naming decision. Platform idiom may change async syntax or a
narrow lifecycle spelling where `docs/API.md` explicitly permits it; operation
meaning and parameter semantics do not drift.

Public code and CI never depend on `docs/private/`. Private conformance material
may audit implementation status in more detail, but the tracked public contract
is the source available to contributors and gates.

## Performance

The hot path is allocation-free after warmup. Frames stay zero-copy wherever
the platform allows it. Pools are bounded. Analysis does not stall rendering.
CPU conversion is counted and visible. A zero-copy path that unexpectedly calls
libyuv is a regression.

Correctness includes color. Pixel format, range, matrix, transfer, primaries,
and orientation are data, not guesses. `core/math/color.zig` remains the color
math home; CPU and GPU paths must agree within conformance tolerance.

## Structure changes

Structure follows the repository, not a diagram. A new capability extends the
nearest correct existing boundary. A new top-level or domain directory needs a
real architectural reason.

Do not rename or relocate working subsystems as part of unrelated work. A
structural migration is its own change, preserves behavior through the move,
and passes every affected gate.

The media rail adds only what the current tree does not already have:

    core/media/
    adapters/media/
    adapters/image/libyuv.zig
    harness/media.zig
    media vendor entries under third_party/
    platform-media implementation files under sdk/swift, sdk/kotlin, sdk/ts

Everything else stays where it is unless the change fixes a concrete structural
defect.
