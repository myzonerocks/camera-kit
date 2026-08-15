# Roadmap

Work lands in dependency order. Each stage is built to production
completeness and merges as a single squash PR.

- [x] Repo scaffold: pinned toolchain, source gate, hooks, CI
- [x] Math: SIMD vectors, matrices, quaternions, poses, color conversion
- [x] Frame graph: nodes, typed edges, cached schedule, pooled textures and buffers, the degradation ladder
- [x] C ABI: camerakit.h, the ck_ exports, the ABI diff gate
- [x] Render and assets: bgfx backend node, glTF loading, capture ingress on all three shells
- [x] Tracking: MediaPipe-class face pipeline behind a C shim, model fetching against a tracked lock
- [x] Beauty: GPUPixel behind a C shim, host/iOS/Android; live compositing through bgfx (not yet CPU-side data path only) is the current work
- [ ] Lens format: the .glens spec, manifest/trigger/animation runtime shipped; graph splice/unsplice, validator, fuzzers, and reference lenses remain
- [ ] Shells: Swift, Kotlin, and TypeScript packages with demo apps
- [ ] Conformance: headless harness, frame corpora, performance enforcement

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
