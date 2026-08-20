# Third-Party Notices

Gosslens includes and depends on third-party software.

Third-party components retain their own copyright, license, attribution, and
other applicable terms. Nothing in the Gosslens license changes or replaces
the terms under which those components are provided.

Third-party source currently present under `third_party/` includes:

- Abseil
- ANGLE
- bgfx
- bimg
- bx
- cgltf
- cpuinfo
- Eigen
- Emscripten
- Emscripten Python tooling
- FarmHash
- fft2d
- FlatBuffers
- FP16
- FXdiv
- gemmlowp
- GLFW
- GPUPixel
- Jolt Physics
- libyuv
- LiteRT
- ml_dtypes
- neon2sse
- pthreadpool
- QuickJS-ng
- ruy
- TensorFlow
- XNNPACK

Some vendored trees bundle their own third-party components, and Gosslens
builds several of those into its artifacts. They are third-party software
in the same sense as the list above:

- Inside bgfx (shader toolchain, built as a host tool): fcpp (BSD-style),
  glsl-optimizer (MIT), glslang (BSD-3/MIT/Apache-2.0), Khronos headers,
  SPIRV-Cross (Apache-2.0), SPIRV-Headers (MIT/Khronos),
  SPIRV-Tools (Apache-2.0)
- Inside bimg (built into the renderer's image path): astc-encoder
  (Apache-2.0), iqa (BSD), lodepng (Zlib), tinyexr (BSD-3)
- Inside GPUPixel (built into the effects library): ghc filesystem (MIT),
  stb (public domain / MIT); GPUPixel's color conversion links the
  repository's own pinned libyuv rather than the copy bundled in its tree
- Inside TensorFlow (built into the inference runtime): XLA (Apache-2.0)
- Inside the Jolt Physics repository: sample assets under Assets/ carry
  their own proprietary licenses and are never built into or
  distributed with Gosslens artifacts; only the MIT-licensed Jolt/
  sources compile

Model and test assets fetched by `zig build fetch-models` are third-party
material as well, recorded with their licenses in `third_party/models.lock`:
MediaPipe task models (Apache-2.0) and public-domain NASA portrait
photographs used as the conformance corpus.

The Zig compiler is also part of the Gosslens development toolchain and is
provided under its own license.

A component appearing in this repository does not place its code under the
Gosslens proprietary license. Its upstream license continues to govern that
component.

Gosslens accepts only dependencies that satisfy the repository's dependency
and license policy. New dependencies MUST be reviewed before adoption.
Permitted dependency licenses are limited to MIT, BSD-family, Apache-2.0,
Zlib, and other permissive licenses expressly approved by the project.
GPL, AGPL, LGPL, FFmpeg/libav, GStreamer, binary-only dependencies,
non-commercial or source-available licenses, and unknown or unreviewed
licenses MUST NOT enter the Gosslens dependency graph.

Where a third-party component requires preservation of a copyright notice,
license text, attribution, or other notice, that material MUST accompany the
component or the distributed Gosslens artifact as required by that
component's license.

This file is a human-readable notice. It MUST describe the dependencies that
actually exist in the repository and MUST NOT list planned libraries as
though they have already been adopted.

When a third-party dependency is added, removed, or replaced, this notice
MUST be reviewed and updated in the same change.
