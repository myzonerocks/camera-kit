# Roadmap

Work lands in dependency order. Each stage is built to production
completeness and merges as a single squash PR.

- [x] Repo scaffold: pinned toolchain, source gate, hooks, CI
- [x] Math: SIMD vectors, matrices, quaternions, poses, color conversion
- [x] Frame graph: nodes, typed edges, cached schedule, pooled textures and buffers, the degradation ladder
- [x] C ABI: gosslens.h, the goss_ exports, the ABI diff gate
- [x] Render and assets: bgfx backend node, glTF loading, capture ingress on all three SDKs
- [x] Tracking: MediaPipe-class face pipeline behind a C shim, model fetching against a tracked lock
- [x] Beauty: GPUPixel behind a C shim, host/iOS/Android; live GPU compositing through bgfx, proven end to end on macOS and on a physical iPhone; Android compiles clean pending a physical device
- [x] Lens format: spec, manifest/trigger/animation runtime, graph splice/unsplice, validator, fuzzers; shader pass, LUT, blend, and glTF draw node types; four reference lenses shipped (shader-tint, beauty-baseline, background-swap, trigger-anim)
- [ ] Head pose: landmark-driven pose estimation, then the glTF face-anchor node and the face-mask reference lens on top of it
- [ ] World tracking: the goss_world_source seam, ARKit/ARCore/WebXR backends, and the world-anchor reference lens
- [ ] Media: GossMedia contracts in core/media, libyuv behind adapters/image, portable codecs behind adapters/media, photo and video capture output with A/V sync
- [ ] SDKs: packages and demo apps exist on all three; wrapper conformance to the API contract and publishable packaging remain
- [ ] Conformance: the headless harness and corpora exist and gate CI; device leak gates and performance enforcement remain

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
