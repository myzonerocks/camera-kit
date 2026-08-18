# Roadmap

Work lands in dependency order. Each stage is built to production
completeness and merges as a single squash PR.

- [x] Repo scaffold: pinned toolchain, source gate, hooks, CI
- [x] Math: SIMD vectors, matrices, quaternions, poses, color conversion
- [x] Frame graph: nodes, typed edges, cached schedule, pooled textures and buffers, the degradation ladder
- [x] C ABI: gosslens.h, the goss_ exports, the ABI diff gate
- [x] Render and assets: bgfx backend node, glTF loading, capture ingress on all three shells
- [x] Tracking: MediaPipe-class face pipeline behind a C shim, model fetching against a tracked lock
- [x] Beauty: GPUPixel behind a C shim, host/iOS/Android; live GPU compositing through bgfx (macOS proven end to end, iOS/Android compile clean pending physical-device proof, batched to end of project)
- [ ] Lens format: spec, manifest/trigger/animation runtime, graph splice/unsplice, validator, fuzzers, and one reference lens (beauty-baseline) shipped; shader pass/glTF draw/LUT pass/compositing node types and the remaining four reference lenses (face-mask, background-swap, trigger-anim, world-anchor) still need their own execution primitives, not yet built
- [ ] Shells: Swift, Kotlin, and TypeScript packages with demo apps
- [ ] Conformance: headless harness, frame corpora, performance enforcement

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
