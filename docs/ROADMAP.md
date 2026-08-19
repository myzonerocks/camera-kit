# Roadmap

Gosslens is a full camera and AR engine: every camera-manipulation
capability and every AR capability, measured against the strongest
proprietary stacks and aiming past them. New capabilities ride the rails
that already exist — the tracking module's model path, the lens format's
node and trigger system, the bgfx graph — rather than arriving as
parallel machinery.

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
- [ ] Hands: hand landmark and gesture models on the existing tracking rail, goss_hand_* mirroring the face surface, gesture signals into the lens trigger system
- [ ] Segmentation: the image-segmenter model path, mask textures as lens node inputs, class-mask effects beyond the shipped background swap
- [ ] Pose: body landmark tracking, skeleton attachment points in the lens format
- [ ] Head pose: landmark-driven pose estimation, then the glTF face-anchor node and the face-mask reference lens on top of it
- [ ] Face-mesh effects: the canonical face topology and UVs over the tracked landmarks, mesh-warp lens nodes for makeup, masks, and face paint
- [ ] World tracking: the goss_world_source seam, ARKit/ARCore/WebXR backends, and the world-anchor reference lens
- [ ] Media: GossMedia contracts in core/media, libyuv behind adapters/image, portable codecs behind adapters/media, photo and video capture output with A/V sync
- [ ] Physics: a rigid-body world for lens content, cloth and hair after rigid, behind an engine boundary like every other vendored component
- [ ] Scripting: a sandboxed per-lens script node with the trigger and parameter surface as its API and a determinism contract
- [ ] Audio: lens audio playback plus level and beat signals feeding the trigger system
- [ ] Particles and post effects: GPU particle nodes and bloom/blur/grade passes on the bgfx graph
- [ ] SDKs: packages and demo apps exist on all three; wrapper conformance to the API contract holds as of the sdk-conformance pass; publishable packaging remains
- [ ] Conformance: the headless harness and corpora exist and gate CI; device leak gates and performance enforcement remain

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
