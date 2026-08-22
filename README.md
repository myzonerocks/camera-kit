# Gosslens

A camera and AR engine with a Zig core and three thin SDKs: Swift for
iOS, Kotlin for Android, TypeScript for the web. The core owns the frame
graph, the lens runtime, the effect pipeline, tracking, and the portable
media contract behind a single C ABI. The SDKs own capture, GPU surfaces,
native hardware media APIs, and platform tracking, and nothing else.

The goal is the full surface a modern camera app expects: beauty and
makeup, face/hand/body tracking, segmentation, world anchoring, scripted
and physics-driven lenses, and capture output. All of it on device, with
no lock-in.
The build order lives in [docs/ROADMAP.md](docs/ROADMAP.md).

Everything runs on device. The core makes no network calls and carries no
analytics. A camera frame never leaves the process.

## Layout

    build.zig  build.zig.zon    one build system for Zig, C, and C++, all targets
    .zigversion                 the pinned Zig version
    include/gosslens.h          the C ABI
    core/                       frame graph, lens runtime, tracking, media, math
    adapters/                   native/vendor backends behind engine boundaries
    sdk/                        swift, kotlin, ts packages and demo apps
    lenses/                     the .glens format: spec, validator, reference lenses
    harness/                    headless conformance runner
    third_party/                pinned vendor dependencies
    tools/                      toolchain bootstrap and the source gate

The checked-out layout is authoritative. Existing subsystems stay where they
are; new work extends the nearest existing boundary.

The public architecture and dependency-license contract live in
[docs/ARCHITECTURE.md](docs/ARCHITECTURE.md). The canonical SDK naming and
parameter contract lives in [docs/API.md](docs/API.md).

## Building

    tools/toolchain-sync
    zig build test
    zig build gate -- --tree

toolchain-sync installs the pinned Zig into .local/zig and wires the git
hooks. build.zig refuses any other compiler, so the toolchain question has
exactly one answer. Toolchain decisions are logged in docs/TOOLCHAIN.md.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) before changing code, the C ABI, an SDK,
or a dependency. Gosslens accepts permissively licensed dependencies only and
holds one public operation contract across Swift, Kotlin, and TypeScript.

Participation in the project is covered by
[CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md).
