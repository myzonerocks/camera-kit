# Toolchain

The Zig version is pinned in .zigversion and installed by
tools/toolchain-sync, which verifies the published digest before unpacking.
build.zig refuses any other compiler.

## 2026-08-14

Pinned Zig 0.16.0, the current stable release. Code is written against the
0.16 standard library from the start: std.Io for filesystem and process
work, std.process.Init for entry points. Zig also compiles the C and C++ we
vendor, so bumping the pin moves the whole native toolchain at once.

A weekly job builds everything against Zig master and files an issue when
something breaks, so a new stable release is a scheduled chore instead of a
surprise. GOSS_ALLOW_ZIG_MISMATCH=1 exists for that job alone. When a new
stable ships, the bump lands within a month with every gate green.

Platform floors are current stable Xcode, current stable Android Gradle
plugin and NDK, and evergreen browsers. They are reviewed monthly and
recorded here as the shells take shape.
