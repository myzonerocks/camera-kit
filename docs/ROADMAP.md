# Roadmap

Work lands in dependency order. Each stage is built to production
completeness and merges as a single squash PR.

- [x] Repo scaffold: pinned toolchain, source gate, hooks, CI
- [ ] Math: SIMD vectors, matrices, quaternions, poses, color conversion
- [ ] Frame graph: nodes, typed edges, cached schedule, pooled textures and buffers, the degradation ladder
- [ ] C ABI: camerakit.h, the ck_ exports, the ABI diff gate
- [ ] Render and assets: bgfx backend node, glTF loading
- [ ] Tracking and beauty: MediaPipe and GPUPixel behind C shims, model fetching against a tracked lock
- [ ] Lens format: the .glens spec, runtime, validator, reference lenses, fuzzers
- [ ] Shells: Swift, Kotlin, and TypeScript packages with demo apps
- [ ] Conformance: headless harness, frame corpora, performance enforcement

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
