# Gosslens

A camera engine with a Zig core and three thin SDKs: Swift for iOS, Kotlin
for Android, TypeScript for the web. The core owns the frame
graph, the lens runtime, and the effect pipeline behind a single C ABI. The
SDKs own capture, GPU surfaces, and platform tracking, and nothing else.

Everything runs on device. The core makes no network calls and carries no
analytics. A camera frame never leaves the process.

## Layout

    build.zig  build.zig.zon    one build system for Zig, C, and C++, all targets
    .zigversion                 the pinned Zig version
    include/gosslens.h          the C ABI
    core/                       frame graph, lens runtime, effects, math
    adapters/                   vendored engines bound as graph nodes
    sdk/                        swift, kotlin, ts packages and demo apps
    lenses/                     the .glens format: spec, validator, reference lenses
    harness/                    headless conformance runner
    third_party/                vendor pins
    tools/                      toolchain bootstrap and the source gate

## Building

    tools/toolchain-sync
    zig build test
    zig build gate -- --tree

toolchain-sync installs the pinned Zig into .local/zig and wires the git
hooks. build.zig refuses any other compiler, so the toolchain question has
exactly one answer. The roadmap lives in docs/ROADMAP.md and toolchain
decisions are logged in docs/TOOLCHAIN.md.
