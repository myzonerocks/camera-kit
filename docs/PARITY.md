# Capability parity

One capability matrix, kept true by the conformance harness. A feature
landing on one platform without the other two, or without a dated roadmap
row, fails review.

Shell APIs are idiomatic per platform but are the same shapes: Session,
LensRegistry, CaptureOutput, Events.

| Capability | iOS (Swift) | Android (Kotlin) | Web (TS) |
|------------|-------------|------------------|----------|

Rows are added as capabilities land, starting at layer 7. World tracking is
always the shell-side backend behind `ck_world_source` (ARKit, ARCore,
WebXR); a lens declaring the `world` capability degrades to its defined
preview behavior where the backend reports unavailable.
