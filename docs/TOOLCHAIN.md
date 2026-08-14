# Toolchain

Dated record of every toolchain decision. The pin itself lives in
`.zigversion` and nowhere else; `tools/toolchain-sync` installs it to
`.local/zig/<version>` after verifying the published digest, and `build.zig`
fails closed on any mismatch.

## 2026-08-14 — Zig 0.16.0

- Pinned Zig 0.16.0, the latest stable (released 2026-04-13). Verified
  against ziglang.org/download at pin time.
- Code is written against 0.16 std from day one: the `std.Io` interface for
  all filesystem/process work, `std.process.Init` main signatures. No
  pre-0.16 idioms.
- Zig is also the C/C++ compiler for shims and vendored engines; one
  `.zigversion` bump moves the whole native toolchain atomically.
- Shadow lane: `.github/workflows/zig-next.yml` builds the gate suite weekly
  against Zig master (currently 0.17.0-dev), allowed to fail, failures filed
  as `zig-next` issues. `CK_ALLOW_ZIG_MISMATCH=1` is the single sanctioned
  bypass of the pin check and exists only for that lane.
- Upgrade SLO: when a new stable releases, the upgrade branch is cut within
  1 week and merged within 4, with every gate green on every target and a
  dated entry here.

## Platform SDK floors

Reviewed in the monthly currency pass; recorded per shell when each shell
lands (layer 7). Policy: current stable Xcode, current stable AGP/NDK,
evergreen browser baselines.
