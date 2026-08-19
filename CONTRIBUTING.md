# Contributing

Gosslens is a low-level camera engine. Changes are expected to preserve the
architecture, the ABI, the API contract, the performance model, and the
dependency policy. A feature is not complete because it compiles.

Read [docs/ARCHITECTURE.md](docs/ARCHITECTURE.md) before changing structure or
adding a dependency. Read [docs/API.md](docs/API.md) before changing
`include/gosslens.h` or any Swift, Kotlin, or TypeScript wrapper. These are
build contracts, not suggestions.

## Start here

Use the project toolchain. Do not substitute a global Zig installation.

    tools/toolchain-sync
    zig build test
    zig build gate -- --tree

The pinned compiler lives in `.zigversion`. `build.zig` rejects a different
version.

## Keep the structure

Work in the boundary that already owns the feature.

- tracking work stays in `core/tracking/` and `adapters/tracking/`
- beauty work stays in `adapters/beauty/` and the existing shader paths
- rendering work stays in `adapters/bgfx/`
- CPU image conversion stays behind `adapters/image/`
- portable media backends stay behind `adapters/media/`
- engine-owned media contracts stay in `core/media/`
- platform-only code stays under the matching SDK

Do not create a parallel subsystem because a dependency has a convenient name.
There is no `adapters/libyuv/`; libyuv belongs to `adapters/image/`. There is no
FFmpeg adapter.

Do not move working code as part of unrelated work. If a structural change is
actually required, make it a separate change and explain the defect it fixes.

## Dependencies

New dependencies must be necessary, narrow, pinned, and permissively licensed.
The default allowlist is MIT, BSD-2-Clause, BSD-3-Clause, Apache-2.0, and Zlib.
An equivalent permissive license requires explicit project approval before the
dependency lands.

GPL, AGPL, LGPL, SSPL/source-available, non-commercial, research-only,
binary-only, and unknown/custom dependencies are not accepted.

FFmpeg, libav, and GStreamer are explicitly excluded. Do not introduce them by
static link, dynamic link, runtime loading, subprocess, package dependency, or
transitive dependency.

A dependency change must include:

- exact upstream revision or release
- integrity digest
- upstream license files
- NOTICE or patent material where required
- only the features and backends Gosslens actually ships
- build integration through the existing project build
- tests or conformance coverage for the capability it adds

The license gate must stay green. "Only used on one platform" is not a license
exception.

## C and C++

Zig owns the engine. C and C++ dependencies stay behind adapters.

Use a direct C binding when the upstream API is C-compatible. Use a small
`extern "C"` shim when a C++ API requires one. Do not expose C++ classes,
templates, exceptions, STL types, vendor allocators, or vendor lifecycle across
an adapter boundary.

The C ABI in `include/gosslens.h` contains Gosslens-owned types only.

## Frames and memory

Do not add avoidable copies or frame-path allocations.

Native/GPU zero-copy paths are preferred. libyuv is the canonical CPU fallback,
not a mandatory stage. A new CPU pixel consumer must use the existing image
adapter rather than implementing its own YUV/RGB conversion.

Every allocation has an owner and a release path. Error paths are release paths
too. Pools are bounded. Steady-state frame execution allocates nothing after
warmup.

## Public API

`include/gosslens.h` is the engine ABI. [docs/API.md](docs/API.md) is the
tracked public SDK naming and parameter contract.

Do not name a wrapper independently on each platform. A new public `goss_*`
operation must add its owning type, canonical method name, complete parameter
shape, and platform scope to `docs/API.md` in the same change that adds the ABI
operation. SDK wrappers come after that decision, not before it.

Swift, Kotlin, and TypeScript use the same canonical camelCase operation name.
Only the narrow exceptions documented in `docs/API.md` are allowed. Future SDKs
mechanically re-case the canonical name; they do not redesign it.

Do not expose an unresolved API. If the public parameter contract is not frozen,
the wrapper does not ship. Do not hide missing parameters by hardcoding them in
one SDK.

Portable engine behavior belongs in the core. Platform and vendor types do not
belong in the public API.

## API changes

A public API change must answer all of these in the PR:

- which `goss_*` ABI operation it adds or changes
- which public type owns it
- the canonical SDK operation name and parameters
- which platforms support it and how unsupported capability degrades
- whether the change is additive within the current ABI major
- which conformance tests prove parity

A C ABI addition without the matching `docs/API.md` entry is incomplete. An SDK
wrapper whose name or parameter shape differs from the public contract is a
regression.

## Tests and proof

Run the relevant unit, gate, harness, and platform tests for the change. A
camera capability is proven on the target that uses it, not by a host-only
compile.

At minimum, changes must leave these green:

    zig build test
    zig build gate -- --tree

Changes that affect capture, rendering, tracking, lenses, media, ABI, or SDK
behavior also need the corresponding harness or device/browser proof.

## Git

Work on a feature branch cut from current `main`. Keep one coherent feature
cluster on the branch. Keep unrelated changes out. Every commit should build.
Merge only with required gates green.

Commit messages are terse and imperative. Describe the code change, not the
process used to discover it.

Do not commit generated build output, model payloads, vendor caches, local
configuration, or anything under `docs/private/`. That directory is
intentionally local-only and gitignored. Public code and CI must never depend on
a file under `docs/private/`.

## Pull requests

A pull request should answer five things plainly:

- what capability or defect it changes
- which architectural boundary owns the change
- what ABI/API surface, if any, it changes
- what dependency, if any, it introduces
- what executed proof shows the behavior works

If a change weakens the architecture, API contract, or license policy, it is
not ready for review.
