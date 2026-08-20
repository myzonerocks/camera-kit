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
| Segmentation | proven in the host harness, multiclass with per-class lens channels | built, no hardware yet | not wired |
| Pose tracking | proven in the host harness | built, no hardware yet | not wired |
| Beauty (six effects) | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Lens runtime | demonstrated on device | built, no hardware yet | demonstrated in browser, beauty-baseline only |
| Photo capture (deterministic PNG) | proven in the host harness | built, no hardware yet | not wired |
| Video recording | proven in the host harness on the Apple encoder | built on MediaCodec, no hardware yet | backend not landed, reports unsupported |
| Platform photo formats (JPEG, HEIC) | proven in the host harness | backend not landed, reports unsupported | backend not landed, reports unsupported |
| High-resolution still capture (decoupled from preview) | proven in the host harness at full source and explicit resolutions | Swift wrapper pending | binding pending |
| Audio triggers (level, beat) | proven in the host harness | built, no hardware yet | not wired |
| Recording audio track + A/V sync | proven in the host harness, zero end drift | video-only until the audio encoder lands | backend not landed |
| World tracking (pose, planes, anchors, light) | ARKit source built, no hardware yet; seam proven on the replay track in the host harness | ARCore demo feeder built, no hardware yet | WebXR source built and typechecked, no browser run yet |
| Lens physics (rigid bodies on model nodes) | proven in the host harness, deterministic settle | stub, holds initial pose | stub, holds initial pose |

"Demonstrated" means executed on the real target through the public
path; "built" means the code exists and compiles but no physical device
has run it yet. Rows appear as capabilities land. World tracking always comes from the
platform, ARKit on iOS, ARCore on Android, WebXR in the browser, behind one
core interface. A lens that wants world data falls back to a defined preview
behavior when tracking is unavailable.
