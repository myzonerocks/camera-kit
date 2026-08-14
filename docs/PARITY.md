# Parity

Every capability ships on all three platforms or it does not ship, and the
conformance harness keeps this table honest. The public APIs are idiomatic
per platform but share the same shapes: Session, LensRegistry,
CaptureOutput, Events.

| Capability | iOS | Android | Web |
|------------|-----|---------|-----|

Rows appear as capabilities land. World tracking always comes from the
platform, ARKit on iOS, ARCore on Android, WebXR in the browser, behind one
core interface. A lens that wants world data falls back to a defined preview
behavior when tracking is unavailable.
