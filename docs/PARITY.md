# Parity

Every capability ships on all three platforms or it does not ship, and the
conformance harness keeps this table honest. The public APIs are idiomatic
per platform but share the same shapes: Session, LensRegistry,
CaptureOutput, Events.

| Capability | iOS | Android | Web |
|------------|-----|---------|-----|
| Live capture | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Preview render | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Face tracking | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Segmentation | proven in the host harness, multiclass with per-class lens channels | built, no hardware yet | built, the sync segmentation core on the wasm tracking module, fed back through set_segmentation_mask |
| Pose tracking | proven in the host harness | built, no hardware yet | built, the pose pipeline on the wasm tracking module, read through a PoseTracker |
| Hand tracking (landmarks, handedness, gestures) | proven in the host harness | built, no hardware yet | built, the hand pipeline on the wasm tracking module, read through a HandTracker |
| Beauty (six effects) | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Lens runtime | demonstrated on device | built, no hardware yet | demonstrated in browser, beauty-baseline only |
| Photo capture (deterministic PNG) | proven in the host harness | built, no hardware yet | not wired |
| Video recording | proven in the host harness on the Apple encoder | built on MediaCodec, no hardware yet | backend not landed, reports unsupported |
| Photo formats (JPEG built-in, HEIC platform) | JPEG and HEIC proven in the host harness | JPEG from the engine's own encoder, built; HEIC backend not landed | JPEG from the engine's own encoder, built; HEIC backend not landed |
| Color-managed stills (Display-P3/Rec2020 tags, 16-bit PNG) | proven in the host harness: wide-gamut PNG carries cHRM/gAMA and JPEG an ICC, sRGB carries neither, 16-bit PNG reports bit depth 16 | core encoder, every target | core encoder, every target |
| High-resolution still capture (decoupled from preview, supersampled) | proven in the host harness: full-sensor size, anti-aliased supersampling, deterministic | Kotlin wrapper landed, no hardware yet | web wrapper landed over the wasm core |
| Tiled still composition (2D + 3D sub-frustum, streamed) | proven in the host harness: 2D grids byte-identical to a single target; 3D content tiles past the texture cap (mesh byte-identical, particles within a sub-pixel); the tiled PNG streams a band at a time, peak heap a full render buffer below the full-buffer path | Kotlin wrapper landed, no hardware yet | web wrapper landed over the wasm core |
| Audio triggers (level, beat) | proven in the host harness | built, no hardware yet | not wired |
| Recording audio track + A/V sync | proven in the host harness, zero end drift | video-only until the audio encoder lands | backend not landed |
| World tracking (pose, planes, anchors, light) | ARKit source built, no hardware yet; seam proven on the replay track in the host harness | ARCore demo feeder built, no hardware yet | WebXR source built and typechecked, no browser run yet |
| Lens physics (rigid bodies on model nodes) | proven in the host harness, deterministic settle | built, Jolt on the NDK, no hardware yet | built, Jolt on wasm, single-threaded |
| Lens physics chains (constraints on anchors) | proven in the host harness, deterministic swing | built, Jolt on the NDK, no hardware yet | built, Jolt on wasm, single-threaded |
| Lens cloth (soft-body sheets) | proven in the host harness, deterministic drape | built, Jolt on the NDK, no hardware yet | built, Jolt on wasm, single-threaded |
| Lens strand hair (Jolt compute) | proven in the host harness, deterministic settle | built, Jolt on the NDK, no hardware yet | built, Jolt on wasm, single-threaded |
| Lens scripting (QuickJS-ng, sandboxed, deterministic) | proven in the host harness: a script drives a parameter from a signal, bit-stable | built, QuickJS-ng linked, no hardware yet | built, QuickJS-ng linked for wasm |
| Lens audio playback (miniaudio, deterministic mixer) | proven in the host harness: a play_sound trigger mixes a voice, silent before, bit-stable after | built, miniaudio linked, no hardware yet | built, miniaudio linked for wasm |
| Post-effect nodes (blur, parametric grade, bloom) | proven in the host harness, each with a reference lens and a conformance proof | built, no hardware yet | built |
| Lens particles (deterministic CPU fountain, GPU points) | proven in the host harness: the fountain falls, settled differs from initial, bit-stable across runs | pure-Zig sim, runs on device | pure-Zig sim, runs in browser |

"Demonstrated" means executed on the real target through the public
path; "built" means the code exists and compiles but no physical device
has run it yet. Rows appear as capabilities land. World tracking always comes from the
platform, ARKit on iOS, ARCore on Android, WebXR in the browser, behind one
core interface. A lens that wants world data falls back to a defined preview
behavior when tracking is unavailable.
