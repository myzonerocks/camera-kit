# Performance budgets

Normative targets, enforced by the harness (layer 8) on the device lab set:
one recent iPhone, one mid-tier 3-year-old Android, one low-tier Android, one
mid-tier laptop browser. Measured p95 numbers are recorded per tier when the
harness lands and ratchet from there.

| Metric | Low tier | Mid tier | High tier |
|--------|----------|----------|-----------|
| Preview frame rate | >= 30 fps | >= 60 fps where the sensor allows | >= 60 fps |
| Full pipeline p95 frame time (capture, tracking, beauty, lens, render) | measured, then ratcheted | measured, then ratcheted | measured, then ratcheted |
| Time to first frame, warm | < 500 ms | < 500 ms | < 500 ms |
| Steady-state frame-path allocations | 0 | 0 | 0 |

Standing rules:

- The camera never drops below smooth preview; effects degrade along the
  named ladder (full, reduced ML cadence, segmentation off, beauty
  simplified, tracking-free passthrough), capture does not.
- Zero allocations after warmup is asserted with an allocation-counting
  allocator in the harness build, not eyeballed.
- Pool high-water marks and any counted CPU pixel conversions are part of the
  harness frame budget report.
