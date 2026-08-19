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
| Beauty (six effects) | demonstrated on device | built, no hardware yet | demonstrated in browser |
| Lens runtime | demonstrated on device | built, no hardware yet | demonstrated in browser, beauty-baseline only |

"Demonstrated" means executed on the real target through the public
path; "built" means the code exists and compiles but no physical device
has run it yet. Rows appear as capabilities land. World tracking always comes from the
platform, ARKit on iOS, ARCore on Android, WebXR in the browser, behind one
core interface. A lens that wants world data falls back to a defined preview
behavior when tracking is unavailable.
