Local patches applied on top of the pinned gpupixel source after
vendor-sync extracts and verifies it (see pin.zon's archive_sha256, which
stays anchored to the pristine, pre-patch archive). Applied in filename
order by tools/vendor_sync.zig.

0001-ios-angle-egl-context.patch
gpupixel's iOS context creation calls
`[[EAGLContext alloc] initWithAPI:kEAGLRenderingAPIOpenGLES2]` directly.
Real OpenGL ES is gone on current iOS hardware, so this fails outright
and the whole beauty chain never initializes there. Android already
works around the same problem class through EGL; this gives iOS the
same EGL-shaped context, but backed by ANGLE (vendored separately, see
third_party/angle) forced onto its Metal backend via
EGL_PLATFORM_ANGLE_TYPE_METAL_ANGLE, since iOS has no native EGL of its
own to hand eglGetPlatformDisplay. CreateContext, UseAsCurrent,
PresentBufferForDisplay, and ReleaseContext all move to the same shape
GPUPIXEL_ANDROID already uses.

adapters/beauty/interop_apple.mm's iOS path pulled
`[EAGLContext currentContext]` to stand up its CVOpenGLESTextureCache,
which returns nil once this patch lands, since ANGLE never creates a
real EAGLContext. That bridge is rewired separately (not part of this
patch, since it's this project's own code, not gpupixel's) onto
ANGLE's EGL_IOSURFACE_ANGLE client-buffer surface instead.

0002-fragment-shader-precision.patch
Confirmed on real hardware, not assumed: ANGLE's GLSL ES translator
rejected gpupixel's own filter fragment shaders with "No precision
specified for (float)". GLSL ES gives fragment shaders no default
float precision (vertex shaders get an implicit highp), and these
shader strings were never written with one - whatever GL driver
compiled them before tolerated the gap and supplied a default anyway.
Fixed once in GPUPixelGLProgram::InitWithShaderString, which every
filter's shader compiles through, rather than editing each of the
~40 filter source files individually.
