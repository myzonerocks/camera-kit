// The GPU-side bridge from the beauty chain's own output texture into an
// IOSurface-backed CVPixelBuffer bgfx's Metal backend can read zero-copy
// from that point on (CVMetalTextureCache, the same primitive capture
// ingress already uses for camera frames). gpupixel's Framebuffer always
// allocates its own texture with no hook to render into an externally
// supplied one, so this does one GPU-to-GPU blit - no CPU readback, no
// per-frame allocation, no changes to the vendored source.
//
// gpupixel dispatches all of its own GL work onto its own dedicated
// worker thread (SyncRunWithContext blocks the caller but runs the task
// there, not on the calling thread), so the blit has to run there too or
// the wrong GL context - or none - is current when it executes. That
// dispatcher is reached through GPUPixelContext, which the engine does
// not expose in its public headers; same situation as
// GPUPixelFramebuffer, a publicly reachable facility whose header just
// is not under the public include tree.
//
// macOS reads the shared surface through CVOpenGLTextureCache. iOS
// renders through ANGLE's EGL/GLES-over-Metal now (see adapters/angle),
// so it reads through ANGLE's own EGL_IOSURFACE_ANGLE surface instead -
// CVOpenGLESTextureCache has no real EAGLContext to bind to anymore.

#include <cstdint>
#include <new>

#include <TargetConditionals.h>

#if TARGET_OS_OSX || TARGET_OS_IOS

#include "core/gpupixel_context.h"

#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#if TARGET_OS_OSX
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>
#else
#include <EGL/egl.h>
#include <EGL/eglext_angle.h>
#include <GLES2/gl2ext.h>
#include <GLES3/gl3.h>
#endif

extern "C" int32_t goss_beauty_process_external_texture(void* handle,
                                                       uint32_t gl_texture,
                                                       int32_t sampler_kind,
                                                       int32_t width,
                                                       int32_t height,
                                                       const float* landmarks106);

namespace {

const char* kBlitVertexShader =
    "attribute vec4 position;\n"
    "attribute vec4 inputTextureCoordinate;\n"
    "varying vec2 textureCoordinate;\n"
    "void main() {\n"
    "  gl_Position = position;\n"
    "  textureCoordinate = inputTextureCoordinate.xy;\n"
    "}\n";

const char* kBlitFragmentShader =
    "precision mediump float;\n"
    "varying vec2 textureCoordinate;\n"
    "uniform sampler2D inputTexture;\n"
    "void main() {\n"
    "  gl_FragColor = texture2D(inputTexture, textureCoordinate);\n"
    "}\n";

GLuint CompileShader(GLenum type, const char* source) {
  GLuint shader = glCreateShader(type);
  glShaderSource(shader, 1, &source, nullptr);
  glCompileShader(shader);
  GLint ok = 0;
  glGetShaderiv(shader, GL_COMPILE_STATUS, &ok);
  if (!ok) {
    glDeleteShader(shader);
    return 0;
  }
  return shader;
}

GLuint LinkProgram(const char* vertex_source, const char* fragment_source) {
  GLuint vertex = CompileShader(GL_VERTEX_SHADER, vertex_source);
  GLuint fragment = CompileShader(GL_FRAGMENT_SHADER, fragment_source);
  if (vertex == 0 || fragment == 0) {
    if (vertex) glDeleteShader(vertex);
    if (fragment) glDeleteShader(fragment);
    return 0;
  }
  GLuint program = glCreateProgram();
  glAttachShader(program, vertex);
  glAttachShader(program, fragment);
  glBindAttribLocation(program, 0, "position");
  glBindAttribLocation(program, 1, "inputTextureCoordinate");
  glLinkProgram(program);
  glDeleteShader(vertex);
  glDeleteShader(fragment);
  GLint ok = 0;
  glGetProgramiv(program, GL_LINK_STATUS, &ok);
  if (!ok) {
    glDeleteProgram(program);
    return 0;
  }
  return program;
}

// The blit itself: draws source_texture (a normal GL_TEXTURE_2D, gpupixel's
// own beauty output) into whatever texture/target fbo currently has bound
// at GL_COLOR_ATTACHMENT0. Shared between both platforms; only how that
// attachment gets set up differs.
bool DrawBlit(GLuint fbo, GLuint blit_program, GLuint source_texture,
              int32_t width, int32_t height) {
  if (glCheckFramebufferStatus(GL_FRAMEBUFFER) != GL_FRAMEBUFFER_COMPLETE) return false;

  GLint previous_fbo = 0;
  glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);
  GLint previous_viewport[4];
  glGetIntegerv(GL_VIEWPORT, previous_viewport);
  GLuint previous_program = 0;
  glGetIntegerv(GL_CURRENT_PROGRAM, reinterpret_cast<GLint*>(&previous_program));

  glBindFramebuffer(GL_FRAMEBUFFER, fbo);
  glViewport(0, 0, width, height);
  glUseProgram(blit_program);

  static const GLfloat position[] = {-1, -1, 1, -1, -1, 1, 1, 1};
  // Y-flipped to match RenderExternalTexture's own input blit
  // (beauty_shim.cc's kTexCoords) - without it, the GL-vs-Metal
  // coordinate convention gpupixel corrects for on the way in never
  // gets undone on the way back out.
  static const GLfloat tex_coords[] = {0, 1, 1, 1, 0, 0, 1, 0};
  glEnableVertexAttribArray(0);
  glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, position);
  glEnableVertexAttribArray(1);
  glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, tex_coords);

  glActiveTexture(GL_TEXTURE0);
  glBindTexture(GL_TEXTURE_2D, source_texture);
  glUniform1i(glGetUniformLocation(blit_program, "inputTexture"), 0);

  glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
  glDisableVertexAttribArray(0);
  glDisableVertexAttribArray(1);

  // CVPixelBuffer contents are only guaranteed visible to a different API
  // (Metal, reading through its own texture cache) after the GL work that
  // wrote them has been flushed - the CoreVideo texture cache does not do
  // this for us.
  glFlush();

  glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
  glViewport(previous_viewport[0], previous_viewport[1], previous_viewport[2],
             previous_viewport[3]);
  glUseProgram(previous_program);
  return true;
}

#if TARGET_OS_OSX

// Owns the state a repeated composite needs across frames: the shared
// surface (recreated only when the requested size changes), the texture
// cache bound to whatever context first created it, the blit target FBO,
// and the blit program (compiled once, this context does not change).
struct AppleInterop {
  CVOpenGLTextureCacheRef texture_cache = nullptr;
  CVPixelBufferRef pixel_buffer = nullptr;
  CVOpenGLTextureRef gl_texture = nullptr;
  CVMetalTextureCacheRef metal_cache = nullptr;
  CVMetalTextureRef metal_texture = nullptr;
  GLuint fbo = 0;
  GLuint blit_program = 0;
  int width = 0;
  int height = 0;

  // Raw GL objects die only on gpupixel's own GL thread - the destroy
  // entry point dispatches here; the CoreVideo CF objects release
  // anywhere and stay in the destructor.
  void ReleaseGl() {
    if (fbo) { glDeleteFramebuffers(1, &fbo); fbo = 0; }
    if (blit_program) { glDeleteProgram(blit_program); blit_program = 0; }
  }

  bool HasGl() const { return fbo != 0 || blit_program != 0; }

  ~AppleInterop() {
    if (metal_texture) CFRelease(metal_texture);
    if (metal_cache) CFRelease(metal_cache);
    if (gl_texture) CFRelease(gl_texture);
    if (pixel_buffer) CFRelease(pixel_buffer);
    if (texture_cache) CFRelease(texture_cache);
  }

  bool EnsureSurface(int new_width, int new_height) {
    if (gl_texture && width == new_width && height == new_height) return true;

    CGLContextObj cgl_context = CGLGetCurrentContext();
    if (cgl_context == nullptr) return false;

    if (texture_cache == nullptr) {
      CGLPixelFormatObj pixel_format = CGLGetPixelFormat(cgl_context);
      CVReturn created = CVOpenGLTextureCacheCreate(
          kCFAllocatorDefault, nullptr, cgl_context, pixel_format, nullptr,
          &texture_cache);
      if (created != kCVReturnSuccess) return false;
    }

    if (gl_texture) {
      CFRelease(gl_texture);
      gl_texture = nullptr;
    }
    if (metal_texture) {
      CFRelease(metal_texture);
      metal_texture = nullptr;
    }
    if (pixel_buffer) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
    }

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn buffer_status = CVPixelBufferCreate(
        kCFAllocatorDefault, new_width, new_height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixel_buffer);
    if (buffer_status != kCVReturnSuccess) return false;

    CVReturn texture_status = CVOpenGLTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, texture_cache, pixel_buffer, nullptr,
        &gl_texture);
    if (texture_status != kCVReturnSuccess) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    width = new_width;
    height = new_height;
    return true;
  }

  GLenum Target() const { return CVOpenGLTextureGetTarget(gl_texture); }
  GLuint Name() const { return CVOpenGLTextureGetName(gl_texture); }

  // The id<MTLTexture> view of the same IOSurface the GL blit above just
  // wrote into (see goss_beauty_interop_native_texture). Reused across
  // frames like gl_texture: torn down and recreated only in
  // EnsureSurface, when pixel_buffer itself changes.
  void* EnsureMetalView(id<MTLDevice> device) {
    if (device == nil || pixel_buffer == nullptr) return nullptr;
    if (metal_texture) return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
    if (metal_cache == nullptr) {
      CVReturn created = CVMetalTextureCacheCreate(
          kCFAllocatorDefault, nullptr, device, nullptr, &metal_cache);
      if (created != kCVReturnSuccess) return nullptr;
    }
    CVReturn texture_status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, metal_cache, pixel_buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, width, height, 0, &metal_texture);
    if (texture_status != kCVReturnSuccess) return nullptr;
    return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
  }
};

#else  // TARGET_OS_IOS

// Goes straight at the IOSurface through ANGLE's EGL_IOSURFACE_ANGLE
// client-buffer surface, bound to a normal GL texture via
// eglBindTexImage - the same texture handle DrawBlit already expects.
struct AppleInterop {
  EGLSurface egl_surface = EGL_NO_SURFACE;
  CVPixelBufferRef pixel_buffer = nullptr;
  GLuint texture = 0;
  GLuint fbo = 0;
  GLuint blit_program = 0;
  int width = 0;
  int height = 0;
  CVMetalTextureCacheRef metal_cache = nullptr;
  CVMetalTextureRef metal_texture = nullptr;

  // The EGL surface and its GL texture die only on gpupixel's own GL
  // thread - the resize path below is already there; the destroy entry
  // point dispatches.
  void ReleaseGlSurface() {
    auto* ctx = gpupixel::GPUPixelContext::GetInstance();
    if (egl_surface != EGL_NO_SURFACE) {
      if (texture) eglReleaseTexImage(ctx->GetEglDisplay(), egl_surface, EGL_BACK_BUFFER);
      eglDestroySurface(ctx->GetEglDisplay(), egl_surface);
      egl_surface = EGL_NO_SURFACE;
    }
    if (texture) {
      glDeleteTextures(1, &texture);
      texture = 0;
    }
  }

  void ReleaseGl() {
    ReleaseGlSurface();
    if (fbo) { glDeleteFramebuffers(1, &fbo); fbo = 0; }
    if (blit_program) { glDeleteProgram(blit_program); blit_program = 0; }
  }

  bool HasGl() const {
    return egl_surface != EGL_NO_SURFACE || texture != 0 || fbo != 0 || blit_program != 0;
  }

  void ReleaseSurface() {
    ReleaseGlSurface();
    if (metal_texture) {
      CFRelease(metal_texture);
      metal_texture = nullptr;
    }
    if (pixel_buffer) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
    }
  }

  ~AppleInterop() {
    if (metal_texture) CFRelease(metal_texture);
    if (pixel_buffer) CFRelease(pixel_buffer);
    if (metal_cache) CFRelease(metal_cache);
  }

  bool EnsureSurface(int new_width, int new_height) {
    if (texture && width == new_width && height == new_height) return true;
    ReleaseSurface();

    auto* ctx = gpupixel::GPUPixelContext::GetInstance();
    EGLDisplay display = ctx->GetEglDisplay();

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn buffer_status = CVPixelBufferCreate(
        kCFAllocatorDefault, new_width, new_height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixel_buffer);
    if (buffer_status != kCVReturnSuccess) return false;

    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    if (io_surface == nullptr) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    const EGLint surface_attribs[] = {
        EGL_WIDTH, new_width,
        EGL_HEIGHT, new_height,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE,
    };
    egl_surface = eglCreatePbufferFromClientBuffer(
        display, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)io_surface,
        ctx->GetEglConfig(), surface_attribs);
    if (egl_surface == EGL_NO_SURFACE) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    glGenTextures(1, &texture);
    glBindTexture(GL_TEXTURE_2D, texture);
    if (!eglBindTexImage(display, egl_surface, EGL_BACK_BUFFER)) {
      glDeleteTextures(1, &texture);
      texture = 0;
      eglDestroySurface(display, egl_surface);
      egl_surface = EGL_NO_SURFACE;
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    width = new_width;
    height = new_height;
    return true;
  }

  GLenum Target() const { return GL_TEXTURE_2D; }
  GLuint Name() const { return texture; }

  // Same Metal-side view as the macOS struct above, over the IOSurface-
  // backed pixel_buffer ANGLE's EGL_IOSURFACE_ANGLE surface already
  // shares with the GL texture DrawBlit wrote into.
  void* EnsureMetalView(id<MTLDevice> device) {
    if (device == nil || pixel_buffer == nullptr) return nullptr;
    if (metal_texture) return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
    if (metal_cache == nullptr) {
      CVReturn created = CVMetalTextureCacheCreate(
          kCFAllocatorDefault, nullptr, device, nullptr, &metal_cache);
      if (created != kCVReturnSuccess) return nullptr;
    }
    CVReturn texture_status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, metal_cache, pixel_buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, width, height, 0, &metal_texture);
    if (texture_status != kCVReturnSuccess) return nullptr;
    return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
  }
};

#endif

#if TARGET_OS_OSX

// The reverse bridge: bgfx (Metal) writes the current preview frame into
// this shared surface on its own thread, gpupixel (GL) reads it back out
// on its own thread - the same shared CVPixelBuffer AppleInterop composites
// through, just two API-specific views built for opposite directions. The
// Metal side and the GL side each own their own cache (a texture cache is
// bound to whatever context created it, and these are never the same
// context), so EnsureMetalSurface and EnsureGLImport touch disjoint fields
// until both have run at least once. The two never race in practice: every
// caller in this codebase reaches gpupixel through SyncRunWithContext,
// which blocks the calling (bgfx) thread until gpupixel's own thread is
// done, so a frame's Metal write always finishes strictly before that same
// frame's GL read starts, and the next frame's Metal write cannot start
// until this one returns.
struct AppleInputSurface {
  CVPixelBufferRef pixel_buffer = nullptr;
  CVMetalTextureCacheRef metal_cache = nullptr;
  CVMetalTextureRef metal_texture = nullptr;
  CVOpenGLTextureCacheRef gl_cache = nullptr;
  CVOpenGLTextureRef gl_texture = nullptr;
  int width = 0;
  int height = 0;

  // Everything GL-facing here is a CoreVideo CF object, safe to release
  // on any thread - nothing needs gpupixel's GL thread, unlike the iOS
  // sibling below whose EGL import does.
  void ReleaseGLImport() {}
  bool HasGlImport() const { return false; }

  ~AppleInputSurface() {
    if (gl_texture) CFRelease(gl_texture);
    if (gl_cache) CFRelease(gl_cache);
    if (metal_texture) CFRelease(metal_texture);
    if (metal_cache) CFRelease(metal_cache);
    if (pixel_buffer) CFRelease(pixel_buffer);
  }

  // Runs on bgfx's own thread. device is bgfx's own MTL::Device, handed
  // in by the caller rather than queried here - this file stays free of
  // any bgfx dependency, matching every other adapter boundary in this
  // codebase, and a build that links gpupixel without linking real bgfx
  // (harness/tracking.zig, real beauty over the stub renderer) still
  // compiles and links clean.
  bool EnsureMetalSurface(id<MTLDevice> device, int new_width, int new_height) {
    if (metal_texture && width == new_width && height == new_height) return true;
    if (device == nil) return false;

    if (gl_texture) { CFRelease(gl_texture); gl_texture = nullptr; }
    if (gl_cache) { CFRelease(gl_cache); gl_cache = nullptr; }
    if (metal_texture) { CFRelease(metal_texture); metal_texture = nullptr; }
    if (pixel_buffer) { CFRelease(pixel_buffer); pixel_buffer = nullptr; }

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferOpenGLCompatibilityKey : @YES,
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn buffer_status = CVPixelBufferCreate(
        kCFAllocatorDefault, new_width, new_height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixel_buffer);
    if (buffer_status != kCVReturnSuccess) return false;

    if (metal_cache == nullptr) {
      CVReturn created = CVMetalTextureCacheCreate(
          kCFAllocatorDefault, nullptr, device, nullptr, &metal_cache);
      if (created != kCVReturnSuccess) {
        CFRelease(pixel_buffer);
        pixel_buffer = nullptr;
        return false;
      }
    }

    CVReturn texture_status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, metal_cache, pixel_buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, new_width, new_height, 0, &metal_texture);
    if (texture_status != kCVReturnSuccess) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    width = new_width;
    height = new_height;
    return true;
  }

  // The unretained id<MTLTexture> bgfx wraps with wrapExternalTexture -
  // valid until the next EnsureMetalSurface call that actually resizes,
  // exactly like AppleInterop::pixel_buffer's own contract.
  void* NativeTexture() const {
    if (metal_texture == nullptr) return nullptr;
    return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
  }

  // Runs on gpupixel's own GL thread (the caller dispatches through
  // SyncRunWithContext): imports the same pixel_buffer bgfx just wrote
  // into as a GL texture bound to whichever context is current there.
  // Skipped when a GL texture is already live for the current
  // pixel_buffer - EnsureMetalSurface only tears gl_texture down when it
  // actually recreates pixel_buffer, so the common per-frame case (size
  // unchanged) reimports nothing and just reads fresh content through
  // the texture already bound.
  bool EnsureGLImport() {
    if (gl_texture) return true;
    if (pixel_buffer == nullptr) return false;

    CGLContextObj cgl_context = CGLGetCurrentContext();
    if (cgl_context == nullptr) return false;

    if (gl_cache == nullptr) {
      CGLPixelFormatObj pixel_format = CGLGetPixelFormat(cgl_context);
      CVReturn created = CVOpenGLTextureCacheCreate(
          kCFAllocatorDefault, nullptr, cgl_context, pixel_format, nullptr,
          &gl_cache);
      if (created != kCVReturnSuccess) return false;
    }

    CVReturn texture_status = CVOpenGLTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, gl_cache, pixel_buffer, nullptr, &gl_texture);
    return texture_status == kCVReturnSuccess;
  }

  GLenum GLTarget() const { return CVOpenGLTextureGetTarget(gl_texture); }
  GLuint GLName() const { return CVOpenGLTextureGetName(gl_texture); }
  // 0 = GL_TEXTURE_2D (sampler2D), 1 = GL_TEXTURE_RECTANGLE (samplerRect) -
  // beauty_shim.cc picks its blit shader from this without itself
  // depending on any apple-only GL constant. The legacy desktop GL
  // texture cache always vends rectangle textures on macOS, never 2D.
  int32_t SamplerKind() const { return GLTarget() != GL_TEXTURE_2D ? 1 : 0; }
};

#else  // TARGET_OS_IOS

// Same Metal-side capture as the macOS struct above; the GL-side import
// goes through ANGLE's EGL_IOSURFACE_ANGLE instead of
// CVOpenGLESTextureCache, same reasoning as AppleInterop above. ANGLE
// only ever vends GL_TEXTURE_2D, so SamplerKind is always 0 here.
struct AppleInputSurface {
  CVPixelBufferRef pixel_buffer = nullptr;
  CVMetalTextureCacheRef metal_cache = nullptr;
  CVMetalTextureRef metal_texture = nullptr;
  EGLSurface egl_surface = EGL_NO_SURFACE;
  GLuint gl_texture = 0;
  int width = 0;
  int height = 0;

  // The EGL surface and its GL texture belong to gpupixel's GL thread
  // (EnsureGLImport runs there) - teardown dispatches there too, from
  // the resize path below and the destroy entry point alike.
  void ReleaseGLImport() {
    auto* ctx = gpupixel::GPUPixelContext::GetInstance();
    if (egl_surface != EGL_NO_SURFACE) {
      if (gl_texture) eglReleaseTexImage(ctx->GetEglDisplay(), egl_surface, EGL_BACK_BUFFER);
      eglDestroySurface(ctx->GetEglDisplay(), egl_surface);
      egl_surface = EGL_NO_SURFACE;
    }
    if (gl_texture) {
      glDeleteTextures(1, &gl_texture);
      gl_texture = 0;
    }
  }

  bool HasGlImport() const {
    return egl_surface != EGL_NO_SURFACE || gl_texture != 0;
  }

  ~AppleInputSurface() {
    if (metal_texture) CFRelease(metal_texture);
    if (metal_cache) CFRelease(metal_cache);
    if (pixel_buffer) CFRelease(pixel_buffer);
  }

  bool EnsureMetalSurface(id<MTLDevice> device, int new_width, int new_height) {
    if (metal_texture && width == new_width && height == new_height) return true;
    if (device == nil) return false;

    if (HasGlImport()) {
      gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { ReleaseGLImport(); });
    }
    if (metal_texture) { CFRelease(metal_texture); metal_texture = nullptr; }
    if (pixel_buffer) { CFRelease(pixel_buffer); pixel_buffer = nullptr; }

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn buffer_status = CVPixelBufferCreate(
        kCFAllocatorDefault, new_width, new_height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixel_buffer);
    if (buffer_status != kCVReturnSuccess) return false;

    if (metal_cache == nullptr) {
      CVReturn created = CVMetalTextureCacheCreate(
          kCFAllocatorDefault, nullptr, device, nullptr, &metal_cache);
      if (created != kCVReturnSuccess) {
        CFRelease(pixel_buffer);
        pixel_buffer = nullptr;
        return false;
      }
    }

    CVReturn texture_status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, metal_cache, pixel_buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, new_width, new_height, 0, &metal_texture);
    if (texture_status != kCVReturnSuccess) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
      return false;
    }

    width = new_width;
    height = new_height;
    return true;
  }

  void* NativeTexture() const {
    if (metal_texture == nullptr) return nullptr;
    return (__bridge void*)CVMetalTextureGetTexture(metal_texture);
  }

  bool EnsureGLImport() {
    if (gl_texture) return true;
    if (pixel_buffer == nullptr) return false;

    IOSurfaceRef io_surface = CVPixelBufferGetIOSurface(pixel_buffer);
    if (io_surface == nullptr) return false;

    auto* ctx = gpupixel::GPUPixelContext::GetInstance();
    EGLDisplay display = ctx->GetEglDisplay();

    const EGLint surface_attribs[] = {
        EGL_WIDTH, width,
        EGL_HEIGHT, height,
        EGL_IOSURFACE_PLANE_ANGLE, 0,
        EGL_TEXTURE_TARGET, EGL_TEXTURE_2D,
        EGL_TEXTURE_FORMAT, EGL_TEXTURE_RGBA,
        EGL_TEXTURE_INTERNAL_FORMAT_ANGLE, GL_BGRA_EXT,
        EGL_TEXTURE_TYPE_ANGLE, GL_UNSIGNED_BYTE,
        EGL_NONE,
    };
    egl_surface = eglCreatePbufferFromClientBuffer(
        display, EGL_IOSURFACE_ANGLE, (EGLClientBuffer)io_surface,
        ctx->GetEglConfig(), surface_attribs);
    if (egl_surface == EGL_NO_SURFACE) return false;

    glGenTextures(1, &gl_texture);
    glBindTexture(GL_TEXTURE_2D, gl_texture);
    // A fresh texture defaults to GL_NEAREST_MIPMAP_LINEAR minification,
    // which needs a mipmap chain this single-level EGL-bound surface
    // never has - RenderExternalTexture's texture2D() sampling of an
    // incomplete texture always returns black, regardless of real content.
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    if (!eglBindTexImage(display, egl_surface, EGL_BACK_BUFFER)) {
      glDeleteTextures(1, &gl_texture);
      gl_texture = 0;
      eglDestroySurface(display, egl_surface);
      egl_surface = EGL_NO_SURFACE;
      return false;
    }
    return true;
  }

  GLenum GLTarget() const { return GL_TEXTURE_2D; }
  GLuint GLName() const { return gl_texture; }
  int32_t SamplerKind() const { return 0; }
};

#endif

}  // namespace

extern "C" {

void* goss_beauty_interop_create(void) {
  return new (std::nothrow) AppleInterop();
}

void goss_beauty_interop_destroy(void* handle) {
  auto* interop = static_cast<AppleInterop*>(handle);
  if (interop == nullptr) return;
  // GL objects die on gpupixel's own GL thread - deleted anywhere else
  // they silently leak; the CF objects release in the destructor.
  if (interop->HasGl()) {
    gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { interop->ReleaseGl(); });
  }
  delete interop;
}

// Composites source_texture into the shared surface and returns the
// CVPixelBufferRef, unretained: valid until the next call on this handle
// or goss_beauty_interop_destroy, never released by the caller.
void* goss_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* interop = static_cast<AppleInterop*>(handle);

  // ran tracks whether the lambda actually executed - SyncRunWithContext
  // silently skips it while the app isn't foreground-active, and ok alone
  // defaults to true, which would otherwise read as a successful composite
  // of a pixel_buffer that was never touched this call.
  bool ran = false;
  bool ok = true;
  gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] {
    ran = true;
    if (!interop->EnsureSurface(width, height)) {
      ok = false;
      return;
    }
    if (interop->blit_program == 0) {
      interop->blit_program = LinkProgram(kBlitVertexShader, kBlitFragmentShader);
      if (interop->blit_program == 0) {
        ok = false;
        return;
      }
    }
    if (interop->fbo == 0) {
      glGenFramebuffers(1, &interop->fbo);
    }

    glBindFramebuffer(GL_FRAMEBUFFER, interop->fbo);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0,
                           interop->Target(), interop->Name(), 0);

    ok = DrawBlit(interop->fbo, interop->blit_program, source_texture, width, height);
  });

  return (ran && ok) ? interop->pixel_buffer : nullptr;
}

// bgfx's Metal-side view of what goss_beauty_interop_composite just
// wrote - that function's own CVPixelBufferRef return is for CPU
// readback, not something wrapExternalTexture can bind. Call right
// after it succeeds, same frame; device is bgfx's own MTL::Device.
void* goss_beauty_interop_native_texture(void* handle, void* device) {
  if (handle == nullptr) return nullptr;
  auto* interop = static_cast<AppleInterop*>(handle);
  return interop->EnsureMetalView((__bridge id<MTLDevice>)device);
}

void* goss_beauty_input_create(void) {
  return new (std::nothrow) AppleInputSurface();
}

void goss_beauty_input_destroy(void* handle) {
  auto* input = static_cast<AppleInputSurface*>(handle);
  if (input == nullptr) return;
  if (input->HasGlImport()) {
    gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { input->ReleaseGLImport(); });
  }
  delete input;
}

// Runs on bgfx's own thread. (Re)creates the shared surface against
// device (bgfx's own MTL::Device, reinterpreted from the raw pointer the
// caller already extracted from bgfx_get_internal_data) and returns the
// id<MTLTexture> view of it, unretained: valid until the next call that
// actually resizes, or goss_beauty_input_destroy.
void* goss_beauty_input_surface(void* handle, void* device, int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* input = static_cast<AppleInputSurface*>(handle);
  id<MTLDevice> mtl_device = (__bridge id<MTLDevice>)device;
  if (!input->EnsureMetalSurface(mtl_device, width, height)) return nullptr;
  return input->NativeTexture();
}

// Runs on gpupixel's own GL thread by dispatching through
// SyncRunWithContext itself - the caller never needs to know that detail,
// matching goss_beauty_interop_composite's own contract. Imports the shared
// surface bgfx just wrote into and pushes it through the beauty chain via
// goss_beauty_process_external_texture (beauty_shim.cc); returns 0 on
// success, matching goss_beauty_process's own status convention.
int32_t goss_beauty_input_process(void* input_handle, void* beauty_handle,
                                int32_t width, int32_t height,
                                const float* landmarks106) {
  if (input_handle == nullptr || beauty_handle == nullptr) return 1;
  auto* input = static_cast<AppleInputSurface*>(input_handle);

  // Same ran tracking as goss_beauty_interop_composite: a dispatch
  // skipped while the app isn't foreground-active must not report a
  // frame the chain never processed as success.
  bool ran = false;
  bool ok = true;
  gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] {
    ran = true;
    if (!input->EnsureGLImport()) {
      ok = false;
      return;
    }
    ok = goss_beauty_process_external_texture(
             beauty_handle, input->GLName(), input->SamplerKind(),
             width, height, landmarks106) == 0;
  });
  return (ran && ok) ? 0 : 1;
}

}  // extern "C"

#else  // Every other apple-adjacent target this file might compile for.

extern "C" {
void* goss_beauty_interop_create(void) { return nullptr; }
void goss_beauty_interop_destroy(void* handle) { (void)handle; }
void* goss_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  (void)handle;
  (void)source_texture;
  (void)width;
  (void)height;
  return nullptr;
}
void* goss_beauty_input_create(void) { return nullptr; }
void goss_beauty_input_destroy(void* handle) { (void)handle; }
void* goss_beauty_input_surface(void* handle, void* device, int32_t width, int32_t height) {
  (void)handle;
  (void)device;
  (void)width;
  (void)height;
  return nullptr;
}
int32_t goss_beauty_input_process(void* input_handle, void* beauty_handle,
                                int32_t width, int32_t height,
                                const float* landmarks106) {
  (void)input_handle;
  (void)beauty_handle;
  (void)width;
  (void)height;
  (void)landmarks106;
  return 1;
}
}

#endif
