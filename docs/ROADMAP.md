# Roadmap

Layers land in dependency order, each built to full production completeness
before the next, each as one squash-merged PR. The active todo list refills
from this table.

| # | Layer | Contents | Status |
|---|-------|----------|--------|
| 0 | scaffold | repo, toolchain pin + sync, source-tracked gate, hooks, CI gates, docs | in review |
| 1 | core/math | SIMD-friendly linalg: vec, mat, quat, transforms; zero deps | next |
| 2 | core/graph | nodes, typed edges, cached topological schedule, texture/staging pools, degradation ladder | |
| 3 | core/abi + include/camerakit.h | ck_* exports, opaque handles, POD descriptors, ABI diff gate | |
| 4 | adapters: bgfx, gltf | render backend node (Metal/Vulkan-GLES/WebGL2-WebGPU), cgltf asset loader, vendor pin + license gates | |
| 5 | adapters: mediapipe, gpupixel | C++ shims, tracking + segmentation + beauty nodes, models.lock + fetch-models | |
| 6 | core/lens | GLF runtime: manifest, triggers, params, asset lifecycle; lenses/SPEC.md, validator, fuzzers | |
| 7 | shells: swift, kotlin, ts | idiomatic APIs over the one ABI, capture ingress, GPU handoff, world-tracking seam, demo apps | |
| 8 | harness | headless conformance runner, frame corpora, budgets enforcement, determinism assertions | |

Cross-cutting, standing:

- ABI diff gate from layer 3 on; additive evolution only within a major.
- License gate from layer 4 on: MIT/BSD/Apache-2.0/Zlib allowed; GPL-class blocked.
- Leak gates always: std.testing.allocator in tests, leak-checking allocator in running binaries, zero frame-path allocations after warmup.
- Weekly zig-next shadow lane; monthly currency review of every pin and SDK floor.
