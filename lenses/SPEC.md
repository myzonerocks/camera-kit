# The goss lens format (GLF)

GLF is the bundle format for a lens: a declarative package of parameters,
triggers, shaders, and assets that the engine's lens runtime splices
into a session's frame graph. This document is the format's spec, versioned
independently of the engine itself. The engine's lens runtime is one
conforming implementation; the validator (`lenses/validator`) is the reference
implementation of validation. Anything a conforming runtime does with a
`.glens` bundle, this document defines — if the runtime's behavior and this
document disagree, this document is right and the runtime has a bug.

Format version: GLF 1.0. Versions are `major.minor`. A runtime built against
major version N refuses any bundle declaring a different major version. A
minor version bump is additive only: new optional fields, new trigger
actions, new capability names. A runtime built against minor version M
accepts a bundle declaring any minor version ≤ M, and tolerates unknown
fields in a bundle declaring minor version > M (accept-and-ignore, not
reject) so old runtimes keep working against slightly newer content within
the same major version.

## 1. Bundle layout

A `.glens` bundle is a directory (or a zip archive of the same layout — the
runtime treats both identically, reading through a virtual file interface):

```
mylens.glens/
  manifest.json          required, described below
  shaders/                *.glsl source, plus *.<profile>.bin next to each
                          one once packaged (section 7) - metal/spirv/essl
  assets/                 *.gltf, *.glb, *.png, LUTs, referenced by relative path
```

No other file types are permitted inside a bundle. No file may reference a
path outside the bundle root (no `..` segments, no absolute paths, no
symlinks followed outside the root) — the loader rejects any reference that
would escape, closed, before opening the file.

### 1.1 Size and depth limits

These bound the cost of loading and validating untrusted content; they are
part of the format, not an implementation detail:

- Bundle: 64 MiB total, uncompressed, all files combined.
- `manifest.json`: 256 KiB, parsed with a JSON depth limit of 32 (a
  manifest cannot recursively describe an unbounded trigger or parameter
  tree).
- Any single shader source file: 256 KiB.
- Any single asset file: 32 MiB.
- Parameters: 256 per lens. Triggers: 256 per lens. Nodes in the subgraph:
  128. Each of these is a flat count, not a nesting depth — the graph and
  trigger list are arrays, not trees, so there is no recursive case to
  bound separately.

A bundle exceeding any limit fails validation closed with a diagnostic
naming the limit and the measured value. The runtime never partially loads
an over-limit bundle.

## 2. manifest.json

Top level, all fields required unless marked optional:

```jsonc
{
  "glf": "1.0",                    // format version this manifest targets
  "id": "com.example.mylens",      // reverse-DNS style, stable identity
  "version": "1.2.0",              // semver, the lens's own version
  "display_name": "My Lens",
  "engine_compat": ">=0.5 <1.0",   // range against the engine's goss_abi_version
  "capabilities": ["face"],        // see 3
  "parameters": [ /* see 4 */ ],
  "nodes": [ /* see 5 */ ],
  "triggers": [ /* see 6 */ ]
}
```

`engine_compat` is a range expression over the ABI's `major.minor`
(`goss_abi_version`), checked at load time against the running engine; a
bundle whose range excludes the running engine fails validation closed
before any node, shader, or asset is touched.

## 3. Capabilities

A lens declares the inputs it needs so the runtime can decide, before
splicing, whether it can run: `face` (landmarks + blendshapes), `hands`
(hand landmarks), `segmentation` (selfie or hair mask), `world` (pose,
planes, anchors, light — Part 6 of the engineering brief), `audio_level`
(input signal envelope, for audio-reactive triggers). A capability the
running session cannot provide is a defined degradation, not a load
failure: the lens still splices, its triggers gated on that capability
simply never fire, and any node consuming that capability's data holds its
last-known or default state. A lens whose *every* node depends on an
unavailable capability degrades to not rendering, which the host app is
told about (so it can hide the lens from its picker) rather than the
runtime silently producing a blank frame with no explanation.

## 4. Parameters

A parameter is a named, typed, bounded value the host app or a trigger can
drive:

```jsonc
{
  "name": "smooth_amount",
  "type": "float",           // float | bool | int | color
  "default": 0.5,
  "min": 0.0, "max": 1.0     // required for float and int, ignored otherwise
}
```

Parameters are the *only* way a lens's numeric state changes at runtime.
There is no scripting surface — a parameter's value flows into node inputs
and shader uniforms by name binding declared in the node's `params` map
(section 5), and nowhere else. Out-of-range values from a trigger ramp or a
host app write are clamped, never rejected at runtime (rejection is a
load-time validation concern; a running lens never errors on a parameter
write, it clamps and continues).

## 5. Node subgraph

The `nodes` array is a flat list of graph node instances the runtime
splices into the session graph as one fragment, wired by `inputs` naming
other nodes in the same list by their `id`:

```jsonc
{
  "id": "reshape",
  "type": "beauty.reshape",      // one of the runtime's known node types
  "inputs": { "frame": "camera" },  // "camera" is the implicit capture input
  "params": { "thin_face": "$smooth_amount" }  // "$name" binds a parameter
}
```

The set of known `type` values is closed and versioned with the *engine*, not
the format — GLF 1.0 does not let a lens introduce a new node type, only
compose the runtime's built-in ones (capture input, beauty filters, shader
passes reading `shaders/*.glsl`, glTF model draws, LUT passes, compositing).
Splice happens once, at lens activation, not per frame; unsplice reverses
it exactly, freeing every resource the splice allocated. Both are edit-time
operations on the graph's edit-time API (Part 3 of the engineering brief),
never touching the frame-time path.

## 6. Triggers

A trigger binds a signal expression to an action, evaluated once per frame,
O(1) per trigger with no allocation. An action fires once, on the frame
the expression transitions from false to true - not on every frame it
holds true. A level-triggered `param_ramp` would restart its ramp from
wherever the in-flight value currently sits every single frame and never
converge on its target; edge-triggered firing is the only reading under
which the curve primitives in 6.3 behave as described.

```jsonc
{
  "when": "face.blendshape('jawOpen') > 0.6",
  "action": { "kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200 }
}
```

### 6.1 Expression grammar

The `when` field is not a scripting language; it is one production from a
small closed grammar, parsed once at load time into a typed expression tree
(no runtime parsing, no `eval`):

- Signal reads: `face.blendshape('name')`, `face.present`, `hands.present`,
  `world.tracking_state`, `audio.level`, `timer('name')` (seconds since the
  timer's last reset, see actions below), `tap`, `param('name')`.
- Comparisons: `>`, `<`, `>=`, `<=`, `==`, `!=` between a signal and a
  numeric or boolean literal.
- Boolean combinators: `&&`, `||`, `!`, grouped with parens.

That is the entire grammar. No arithmetic between two signals, no function
calls beyond the fixed signal readers above, no string concatenation, no
loops. A `when` expression nests at most 8 deep (parens or combinators);
deeper fails validation closed.

### 6.2 Actions

`param_ramp` (animate a parameter to a target over a duration, one of the
curve primitives in 6.3), `param_set` (immediate), `show` / `hide` (a node
by id), `play_animation` (a named glTF animation clip), `swap_subgraph`
(splice a different set of this lens's own nodes in place of a named
group — still edit-time, deferred to the next frame boundary so it never
tears a frame), `reset_timer` (name a timer signal back to zero).

### 6.3 Parameter animation

Two curve primitives, chosen per `param_ramp`: `linear` (duration_ms, from
current value to target) and `spring` (stiffness, damping, target — a
standard critically-damped-tunable spring integrated at the fixed graph
timestep, not wall-clock, so it is frame-rate independent and
deterministic across platforms for the conformance harness). No custom
easing curves in GLF 1.0; if a future version adds them, they arrive as a
minor-version-gated new `curve` field a 1.0 runtime tolerates and ignores,
falling back to `linear`.

## 7. Assets

Every file in `shaders/` is a fragment shader for a full-screen pass over
the current frame — a lens does not author its own vertex stage. The
runtime supplies one fixed vertex contract, `lenses/shaders/varying.def.sc`,
shared by every lens shader pass: `a_position`/`a_texcoord0` in,
`v_texcoord0` out, the same shape as the engine's own preview passes. A lens
fragment shader is GLSL source written to that contract (bgfx's shader
dialect: `$input v_texcoord0`, `#include <bgfx_shader.sh>`).

Compilation happens at package time, not on the device: the engine's pinned
shader toolchain runs wherever a bundle is built or validated, producing
compiled bytecode for every platform profile a conforming runtime ships
(Metal / SPIR-V / ESSL), under the same resource limits the engine's own
shaders compile under (Part 1.4/14 of the engineering history — bounded
compile time, no toolchain escape hatches, compiler diagnostics surfaced
as validation errors naming the source file and line). A shader that
fails to compile fails the bundle's validation; there is no partial
lens. The runtime never compiles GLSL — it loads whichever precompiled
profile matches its own active graphics backend and hands the bytes
straight to its shader loader, the same call the engine's own built-in
passes already go through. This is deliberate, not a shortcut: nothing
else in the engine compiles a shader on the device, a mobile app has no
business carrying a C++ shader compiler toolchain just to run
user-authored effects, and a bundle that fails to compile is caught at
package time by the same validator a lens author already runs, not
discovered by an end user's device.

glTF/GLB assets bind through the engine's existing cgltf adapter — same
allocator-bridged parse, same refusal of external file references (a glTF
asset inside a bundle may not reference textures or buffers outside that
bundle). Textures and LUTs are plain image files decoded through the engine's
existing image decode path, bounded by the per-file size limit in 1.1.

## 8. Validation and the error model

Validation is total and ordered: bundle structure and size limits first,
then `manifest.json` schema and JSON depth, then `engine_compat`, then
capability names, then parameter/node/trigger cross-references (a node's
`inputs` or `params` naming an id or parameter that does not exist, a
trigger's action naming a node id that does not exist), then shader compile,
then asset decode. Validation stops at the first failing stage and reports
every error found *within* that stage (not just the first) — a manifest
with three unknown node types reports all three, not one followed by a
second run to find the next. Every diagnostic names the exact JSON pointer
or file path and line it came from; "invalid manifest" alone is not a
conforming diagnostic.

A bundle that passes validation is guaranteed, by this document, to never
crash the engine, never allocate past its declared node/parameter/trigger
counts, and never execute anything the manifest did not declare. This is
the load-bearing security property: **lenses are untrusted content, and
untrusted content only ever flows through typed, bounded, validated data —
never through code.**

## 9. Conformance

A lens exercises exactly one distinct capability class per the reference
set (`lenses/reference/`): beauty-baseline (capabilities: face; the beauty
node type), face-mask (capabilities: face; a glTF model anchored to
landmarks), background-swap (capabilities: segmentation), trigger-anim
(capabilities: none required; a timer-driven trigger playing a glTF
animation clip, proving 6.2/6.3 without needing a live face), world-anchor
(capabilities: world). Each reference lens runs through the conformance
harness on all three platforms and is asserted bit-stable per platform
(pixel output) and value-stable across platforms for anything
resolution-independent (trigger fire timing, parameter curve values at
fixed timestamps). The validator CLI (`lenses/validator`) is run against
every reference lens, and against a fuzz corpus of malformed manifests and
malformed shader inputs, in CI — a fuzz-found crash or leak is a spec
violation of section 8, filed and fixed before the next lens ships, not
triaged as a lens-author error.
