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
- LiteRT
- ml_dtypes
- neon2sse
- pthreadpool
- ruy
- TensorFlow
- XNNPACK

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
