# Camera Kit

A brand-neutral, production camera engine. One Zig core — frame graph, lens
runtime, effect pipeline — behind a single frozen C ABI, consumed by three
thin shells: Swift (iOS), Kotlin (Android), TypeScript (Web, wasm).

Everything is on-device. The core runs air-gapped: no network, no analytics,
no product strings. A camera frame never leaves the process through any code
path in this repository.

## Layout

    build.zig  build.zig.zon    one build system: Zig, C, C++ shims, all targets
    .zigversion                 the single pinned Zig version
    include/camerakit.h         the C ABI, hand-written, versioned, diff-gated
    core/                       graph, lens runtime, effects, math, abi exports
    adapters/                   vendored engines bound as graph nodes
    shells/                     swift (SwiftPM), kotlin (AAR), ts (npm + wasm)
    lenses/                     .glens format: spec, validator, reference lenses
    harness/                    headless conformance runner + frame corpora
    third_party/                vendor pins: exact commit + digest + license
    tools/                      toolchain bootstrap, source-tracked gate

## Building

    tools/toolchain-sync        # installs the pinned Zig to .local/zig, wires hooks
    zig build test              # all tests, leak-gated
    zig build gate -- --tree    # source-tracked gate over the full tree

The pinned toolchain is enforced fail-closed by build.zig; a build with the
wrong compiler is impossible. `docs/ROADMAP.md` is the layer plan;
`docs/TOOLCHAIN.md` records every toolchain decision with a date.
