Local patches applied on top of the pinned bgfx source after vendor-sync
extracts and verifies it (see pin.zon's archive_sha256, which stays
anchored to the pristine, pre-patch archive - these patches are never
part of what's cryptographically pinned, only what layers on top of it).
Applied in filename order by tools/vendor_sync.zig; a patch that no
longer applies cleanly against the pinned commit fails the sync loudly.

0001-webgpu-timer-query-noop.patch
Real, verified finding (2026-08-17), not assumed: bgfx's WebGPU backend
(src/renderer_webgpu.cpp) calls GPUCommandEncoder.writeTimestamp() once
per frame, unconditionally, from TimerQueryWGPU::begin()/end(). This
method does not exist on Chrome's shipping GPUCommandEncoder.prototype
- confirmed directly against a real browser (Chrome 151), checking the
prototype itself before any device or feature negotiation, so this is
not a missing-feature-request issue. The WebGPU spec moved timestamp
writes off the command encoder entirely, onto timestampWrites in
GPUComputePassDescriptor/GPURenderPassDescriptor instead. Calling the
removed method throws inside an unhandled promise rejection and blocks
bgfx_init from ever completing on this backend.

Verified before patching, not assumed: bgfx's own perfStats.gpuTimeBegin/
gpuTimeEnd are already hardcoded to 0 in this same file's frame()
function, and no code anywhere in renderer_webgpu.cpp ever resolves
TimerQueryWGPU's query set or reads its timestamp buffer back to the
CPU (unlike OcclusionQueryWGPU, which has real resolve/mapAsync logic).
The GPU-timer-stats readback pipeline for this backend is already
vestigial in the pinned commit, independent of this patch. Skipping the
write changes no value any caller can observe; this project does not
consume bgfx's GPU timer stats.

Filed upstream: https://github.com/bkaradzic/bgfx/issues/3902

0002-shaderc-asmjs-wgsl-language-define.patch
Real, verified finding (2026-08-17): tools/shaderc/shaderc.cpp picks the
BGFX_SHADER_LANGUAGE_* preprocessor define per (platform, profile) pair.
Every platform branch (android, linux, windows, the default/else case)
has a ShadingLang::WGSL arm that sets BGFX_SHADER_LANGUAGE_WGSL=1; the
"asm.js" platform branch (the one this project's web build uses) does
not - it unconditionally sets the GLSL/ESSL defines instead, regardless
of profile. With BGFX_SHADER_LANGUAGE_WGSL left at its default-0, none
of bgfx_shader.sh's WGSL-target translations apply (bvec2 -> bool2, and
friends), so the raw GLSL-style source is handed to glslang's HLSL
front end unmodified and fails to parse. Confirmed directly: before
this patch, `shaderc -p wgsl --platform asm.js` failed with HLSL parse
errors on bgfx_shader.sh's own header content; after it, compilation
proceeds into Tint's SPIR-V-to-WGSL path. This is a host build tool
only (shaderc runs at build time to generate shader blobs) - it does
not touch the runtime bgfx library, so the blast radius is the shader
compiler's own source translation, nothing more.

Not yet filed upstream - same bkaradzic/bgfx repo as 0001 above, once
confirmed.
