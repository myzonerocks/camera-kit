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
// macOS renders through legacy desktop GL (NSOpenGLContext/CGL); iOS
// through GLES2 (EAGLContext). Both speak the same core GL ES 2.0 subset
// this file actually uses, and CVOpenGLTextureCache/CVOpenGLESTextureCache
// are the same shape one level up, so the blit itself and the shaders it
// runs are shared; only surface setup differs.

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
#import <OpenGLES/EAGL.h>
#import <OpenGLES/ES2/gl.h>
#endif

extern "C" int32_t ck_beauty_process_external_texture(void* handle,
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
  const GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
  if (fbo_status != GL_FRAMEBUFFER_COMPLETE) return false;

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
  static const GLfloat tex_coords[] = {0, 0, 1, 0, 0, 1, 1, 1};
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
  GLuint fbo = 0;
  GLuint blit_program = 0;
  int width = 0;
  int height = 0;

  ~AppleInterop() {
    if (gl_texture) CFRelease(gl_texture);
    if (pixel_buffer) CFRelease(pixel_buffer);
    if (texture_cache) CFRelease(texture_cache);
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (blit_program) glDeleteProgram(blit_program);
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
};

#else  // TARGET_OS_IOS

// Same shape as the macOS struct above, over CVOpenGLESTextureCache
// instead: bound to whatever EAGLContext is current when first created
// rather than a CGL pixel format, and the vended texture target is always
// GL_TEXTURE_2D (the ES cache never yields rectangle textures the way the
// legacy desktop one does).
struct AppleInterop {
  CVOpenGLESTextureCacheRef texture_cache = nullptr;
  CVPixelBufferRef pixel_buffer = nullptr;
  CVOpenGLESTextureRef gl_texture = nullptr;
  GLuint fbo = 0;
  GLuint blit_program = 0;
  int width = 0;
  int height = 0;

  ~AppleInterop() {
    if (gl_texture) CFRelease(gl_texture);
    if (pixel_buffer) CFRelease(pixel_buffer);
    if (texture_cache) CFRelease(texture_cache);
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (blit_program) glDeleteProgram(blit_program);
  }

  bool EnsureSurface(int new_width, int new_height) {
    if (gl_texture && width == new_width && height == new_height) return true;

    EAGLContext* eagl_context = [EAGLContext currentContext];
    if (eagl_context == nullptr) return false;

    if (texture_cache == nullptr) {
      CVReturn created = CVOpenGLESTextureCacheCreate(
          kCFAllocatorDefault, nullptr, eagl_context, nullptr, &texture_cache);
      if (created != kCVReturnSuccess) return false;
    }

    if (gl_texture) {
      CFRelease(gl_texture);
      gl_texture = nullptr;
    }
    if (pixel_buffer) {
      CFRelease(pixel_buffer);
      pixel_buffer = nullptr;
    }

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    CVReturn buffer_status = CVPixelBufferCreate(
        kCFAllocatorDefault, new_width, new_height, kCVPixelFormatType_32BGRA,
        (__bridge CFDictionaryRef)attributes, &pixel_buffer);
    if (buffer_status != kCVReturnSuccess) return false;

    CVReturn texture_status = CVOpenGLESTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, texture_cache, pixel_buffer, nullptr, GL_TEXTURE_2D,
        GL_RGBA, new_width, new_height, GL_BGRA_EXT, GL_UNSIGNED_BYTE, 0,
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

  GLenum Target() const { return CVOpenGLESTextureGetTarget(gl_texture); }
  GLuint Name() const { return CVOpenGLESTextureGetName(gl_texture); }
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

// Same shape as the macOS struct above, over CVOpenGLESTextureCache
// instead of CVOpenGLTextureCache - the ES cache always vends
// GL_TEXTURE_2D, unlike the legacy desktop one, so SamplerKind is
// always 0 here.
struct AppleInputSurface {
  CVPixelBufferRef pixel_buffer = nullptr;
  CVMetalTextureCacheRef metal_cache = nullptr;
  CVMetalTextureRef metal_texture = nullptr;
  CVOpenGLESTextureCacheRef gl_cache = nullptr;
  CVOpenGLESTextureRef gl_texture = nullptr;
  int width = 0;
  int height = 0;

  ~AppleInputSurface() {
    if (gl_texture) CFRelease(gl_texture);
    if (gl_cache) CFRelease(gl_cache);
    if (metal_texture) CFRelease(metal_texture);
    if (metal_cache) CFRelease(metal_cache);
    if (pixel_buffer) CFRelease(pixel_buffer);
  }

  bool EnsureMetalSurface(id<MTLDevice> device, int new_width, int new_height) {
    if (metal_texture && width == new_width && height == new_height) return true;
    if (device == nil) return false;

    if (gl_texture) { CFRelease(gl_texture); gl_texture = nullptr; }
    if (gl_cache) { CFRelease(gl_cache); gl_cache = nullptr; }
    if (metal_texture) { CFRelease(metal_texture); metal_texture = nullptr; }
    if (pixel_buffer) { CFRelease(pixel_buffer); pixel_buffer = nullptr; }

    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferOpenGLESCompatibilityKey : @YES,
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

    EAGLContext* eagl_context = [EAGLContext currentContext];
    if (eagl_context == nullptr) return false;

    if (gl_cache == nullptr) {
      CVReturn created = CVOpenGLESTextureCacheCreate(
          kCFAllocatorDefault, nullptr, eagl_context, nullptr, &gl_cache);
      if (created != kCVReturnSuccess) return false;
    }

    CVReturn texture_status = CVOpenGLESTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, gl_cache, pixel_buffer, nullptr, GL_TEXTURE_2D,
        GL_RGBA, width, height, GL_BGRA_EXT, GL_UNSIGNED_BYTE, 0, &gl_texture);
    return texture_status == kCVReturnSuccess;
  }

  GLenum GLTarget() const { return CVOpenGLESTextureGetTarget(gl_texture); }
  GLuint GLName() const { return CVOpenGLESTextureGetName(gl_texture); }
  int32_t SamplerKind() const { return 0; }
};

#endif

}  // namespace

extern "C" {

void* ck_beauty_interop_create(void) {
  return new (std::nothrow) AppleInterop();
}

void ck_beauty_interop_destroy(void* handle) {
  delete static_cast<AppleInterop*>(handle);
}

// Composites source_texture into the shared surface and returns the
// CVPixelBufferRef, unretained: valid until the next call on this handle
// or ck_beauty_interop_destroy, never released by the caller.
void* ck_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* interop = static_cast<AppleInterop*>(handle);

  bool ok = true;
  gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] {
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

  return ok ? interop->pixel_buffer : nullptr;
}

void* ck_beauty_input_create(void) {
  return new (std::nothrow) AppleInputSurface();
}

void ck_beauty_input_destroy(void* handle) {
  delete static_cast<AppleInputSurface*>(handle);
}

// Runs on bgfx's own thread. (Re)creates the shared surface against
// device (bgfx's own MTL::Device, reinterpreted from the raw pointer the
// caller already extracted from bgfx_get_internal_data) and returns the
// id<MTLTexture> view of it, unretained: valid until the next call that
// actually resizes, or ck_beauty_input_destroy.
void* ck_beauty_input_surface(void* handle, void* device, int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* input = static_cast<AppleInputSurface*>(handle);
  id<MTLDevice> mtl_device = (__bridge id<MTLDevice>)device;
  if (!input->EnsureMetalSurface(mtl_device, width, height)) return nullptr;
  return input->NativeTexture();
}

// Runs on gpupixel's own GL thread by dispatching through
// SyncRunWithContext itself - the caller never needs to know that detail,
// matching ck_beauty_interop_composite's own contract. Imports the shared
// surface bgfx just wrote into and pushes it through the beauty chain via
// ck_beauty_process_external_texture (beauty_shim.cc); returns 0 on
// success, matching ck_beauty_process's own status convention.
int32_t ck_beauty_input_process(void* input_handle, void* beauty_handle,
                                int32_t width, int32_t height,
                                const float* landmarks106) {
  if (input_handle == nullptr || beauty_handle == nullptr) return 1;
  auto* input = static_cast<AppleInputSurface*>(input_handle);

  bool ok = true;
  gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] {
    if (!input->EnsureGLImport()) {
      ok = false;
      return;
    }
    ok = ck_beauty_process_external_texture(
             beauty_handle, input->GLName(), input->SamplerKind(),
             width, height, landmarks106) == 0;
  });
  return ok ? 0 : 1;
}

}  // extern "C"

#else  // Every other apple-adjacent target this file might compile for.

extern "C" {
void* ck_beauty_interop_create(void) { return nullptr; }
void ck_beauty_interop_destroy(void* handle) { (void)handle; }
void* ck_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  (void)handle;
  (void)source_texture;
  (void)width;
  (void)height;
  return nullptr;
}
void* ck_beauty_input_create(void) { return nullptr; }
void ck_beauty_input_destroy(void* handle) { (void)handle; }
void* ck_beauty_input_surface(void* handle, void* device, int32_t width, int32_t height) {
  (void)handle;
  (void)device;
  (void)width;
  (void)height;
  return nullptr;
}
int32_t ck_beauty_input_process(void* input_handle, void* beauty_handle,
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
