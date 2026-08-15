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

#include <cstdint>
#include <new>

#include <TargetConditionals.h>

#if TARGET_OS_OSX

#include "core/gpupixel_context.h"

#import <CoreVideo/CoreVideo.h>
#import <OpenGL/OpenGL.h>
#import <OpenGL/gl.h>

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
  GLuint blit_position_vbo = 0;
  GLuint blit_texcoord_vbo = 0;
  int width = 0;
  int height = 0;

  ~AppleInterop() {
    if (gl_texture) CFRelease(gl_texture);
    if (pixel_buffer) CFRelease(pixel_buffer);
    if (texture_cache) CFRelease(texture_cache);
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (blit_program) glDeleteProgram(blit_program);
    if (blit_position_vbo) glDeleteBuffers(1, &blit_position_vbo);
    if (blit_texcoord_vbo) glDeleteBuffers(1, &blit_texcoord_vbo);
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

    NSDictionary* surface_properties = @{};
    NSDictionary* attributes = @{
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : surface_properties,
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
};

}  // namespace

extern "C" {

void* ck_beauty_interop_create(void) {
  return new (std::nothrow) AppleInterop();
}

void ck_beauty_interop_destroy(void* handle) {
  delete static_cast<AppleInterop*>(handle);
}

// Blits source_texture (a normal GL_TEXTURE_2D, gpupixel's own beauty
// output) into the shared IOSurface-backed buffer and returns the
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

    GLint previous_fbo = 0;
    glGetIntegerv(GL_FRAMEBUFFER_BINDING, &previous_fbo);
    GLint previous_viewport[4];
    glGetIntegerv(GL_VIEWPORT, previous_viewport);
    GLuint previous_program = 0;
    glGetIntegerv(GL_CURRENT_PROGRAM, reinterpret_cast<GLint*>(&previous_program));

    glBindFramebuffer(GL_FRAMEBUFFER, interop->fbo);
    const GLenum target = CVOpenGLTextureGetTarget(interop->gl_texture);
    const GLuint name = CVOpenGLTextureGetName(interop->gl_texture);
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, target, name, 0);

    const GLenum fbo_status = glCheckFramebufferStatus(GL_FRAMEBUFFER);
    if (fbo_status != GL_FRAMEBUFFER_COMPLETE) {
      glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
      ok = false;
      return;
    }

    glViewport(0, 0, width, height);
    glUseProgram(interop->blit_program);

    static const GLfloat position[] = {-1, -1, 1, -1, -1, 1, 1, 1};
    static const GLfloat tex_coords[] = {0, 0, 1, 0, 0, 1, 1, 1};
    glEnableVertexAttribArray(0);
    glVertexAttribPointer(0, 2, GL_FLOAT, GL_FALSE, 0, position);
    glEnableVertexAttribArray(1);
    glVertexAttribPointer(1, 2, GL_FLOAT, GL_FALSE, 0, tex_coords);

    glActiveTexture(GL_TEXTURE0);
    glBindTexture(GL_TEXTURE_2D, source_texture);
    glUniform1i(glGetUniformLocation(interop->blit_program, "inputTexture"), 0);

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(0);
    glDisableVertexAttribArray(1);

    // CVPixelBuffer contents are only guaranteed visible to a different
    // API (Metal, reading through its own texture cache) after the GL
    // work that wrote them has been flushed - CVOpenGLTextureCache does
    // not do this for us.
    glFlush();

    glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
    glViewport(previous_viewport[0], previous_viewport[1], previous_viewport[2],
               previous_viewport[3]);
    glUseProgram(previous_program);
  });

  return ok ? interop->pixel_buffer : nullptr;
}

}  // extern "C"

#else  // !TARGET_OS_OSX (iOS bridge lands separately)

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
}

#endif
