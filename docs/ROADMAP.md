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
- [x] Hands: palm detection and hand landmarks on the existing tracking rail, up to two hands with handedness and canned gestures, goss_hand_* mirroring the face surface, Swift/Kotlin wrappers and demo overlays, proven on the pinned corpus through the public surface; the hands-present signal feeds lens triggers, per-gesture trigger signals and the web tracking module still open
- [x] Segmentation: the multiclass model on the segmentation worker with per-class masks, named mask channels for shader passes, and the hair-recolor reference lens, proven on the corpus and bit-stable in conformance; on-device visual passes still owner-gated
- [x] Pose: the 33-point body landmark pipeline on the tracking rail with per-point visibility and presence, goss_pose_* mirroring the face surface, Swift/Kotlin wrappers and demo overlays, proven on a pinned standing-figure corpus frame through the public surface; skeleton attachment points land with the anchor-node family alongside head pose
- [x] Head pose: weighted similarity fit of the canonical face's metric geometry to the live landmarks (deterministic, allocation-free), goss_session_face_pose with Swift/Kotlin wrappers, the model.gltf face-anchor node posing glTF content in canonical centimeter space, and the face-mask reference lens proven bit-stable on the pinned portrait corpus; skeleton anchors ride the same anchor field later
- [x] Face-mesh effects: the canonical 468-point topology over the tracked landmarks as the mesh.face lens node, with the face-paint reference lens proven bit-stable in conformance with real tracking; makeup and mask variants ride the same node with their own textures
- [x] World tracking: goss_session_submit_world (pose, projection, planes, anchors, light) driving the world.tracking_state trigger and world-anchored glTF content drawn from the platform camera, proven bit-stable on a deterministic replay orbit with the world-anchor reference lens; all three backends written - ARKit WorldSource (compile-proven, device run pending hardware), the ARCore demo feeder, and the WebXR source with typed submitWorld on the web SDK (device and browser runs pending per the completion bar); depth/occlusion into the mask rail is the named follow-up
- [x] Media: deterministic PNG photo capture, platform photo formats with EXIF intact (JPEG/HEIC, decode-back proved), zero-copy video recording with an aligned audio track (goss_session_submit_audio feeding level and beat triggers plus the muxed track, zero end drift proved), libyuv behind adapters/image as the one CPU conversion authority; the MediaCodec backend is built on the encoder input surface (device proof pending hardware, video-only until its audio encoder lands)
- [ ] High-resolution capture: full-resolution stills decoupled from the preview, supersampled (rendered larger, box-downsampled) for photo-grade anti-aliased edges, and tiled composition that breaks the texture-size ceiling on very large captures by compositing the output in tiles and stitching them on the CPU, all proven through the public ABI (full-sensor size recovered, supersampling deterministic and pixel-different from 1x, tiling byte-identical to a single-target render on 2x2 and 3x2 grids); the Android and web still-submit backends and HDR/wide-gamut stills remain
- [x] Physics: rigid bodies drive lens content - the physics field on model.gltf nodes (box/sphere, static/dynamic), per-lens worlds stepped from frame timestamps, proven deterministic by the physics-drop reference lens; constraint chains on kinematic anchors and distance constraints, proven by the earring reference lens; cloth sheets, a cloth field on model.gltf nodes with Jolt soft bodies driving a dynamic mesh, proven to drape by the flag reference lens; and Jolt 5.6 strand hair, a hair field on model.gltf with compute-backed soft strands driven by the head pose and drawn as lines, proven to settle by the hair reference lens; all four bit-stable through the public surface, with device targets and the on-device head-driven hair swing the named follow-up
- [ ] Scripting: a sandboxed per-lens script node with the trigger and parameter surface as its API and a determinism contract
- [ ] Audio: lens audio playback plus level and beat signals feeding the trigger system
- [ ] Particles and post effects: GPU particle nodes and bloom/blur/grade passes on the bgfx graph
- [ ] SDKs: packages and demo apps exist on all three; wrapper conformance to the API contract holds as of the sdk-conformance pass; publishable packaging remains
- [ ] Conformance: the headless harness and corpora exist and gate CI; device leak gates and performance enforcement remain

Always on: leak gates in tests and in running binaries, the license gate over
vendored code, a weekly build against Zig master, a monthly review of every
pin.
