// The GPU-side bridge from the beauty chain's own output texture into a
// shared AHardwareBuffer, on the write side: an EGLImage view of the
// buffer becomes gpupixel's blit target, the same shape as the ios/macos
// CoreVideo bridge with EGLImage standing in for the texture cache. The
// read side - importing the same buffer into Vulkan for bgfx - lives in
// adapters/bgfx/android_vk.zig, since that already owns the device this
// needs an import into.
//
// gpupixel dispatches all of its own GL work onto its own dedicated
// worker thread even for calls that look synchronous (SyncRunWithContext
// blocks the caller but runs the task elsewhere), so the blit runs
// through that same dispatcher or the wrong EGL context - or none - is
// current when it executes.

#include <android/hardware_buffer.h>
#include <cstdint>
#include <new>

// eglCreateImageKHR/eglDestroyImageKHR are real, linkable libEGL symbols
// on Android; the header only declares them as callable functions (rather
// than just the PFNEGLCREATEIMAGEKHRPROC pointer typedefs) behind this
// guard.
#define EGL_EGLEXT_PROTOTYPES
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <GLES2/gl2.h>
#include <GLES2/gl2ext.h>

#include "core/gpupixel_context.h"

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

typedef EGLClientBuffer(EGLAPIENTRYP PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC)(
    const AHardwareBuffer* buffer);

// The two extension entry points this needs are not guaranteed statically
// linkable across NDK levels, so both are resolved once through EGL's own
// lookup rather than declared and hoped for.
struct AndroidGlExtensions {
  PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC get_native_client_buffer = nullptr;
  PFNGLEGLIMAGETARGETTEXTURE2DOESPROC egl_image_target_texture_2d = nullptr;
  bool loaded = false;

  bool Ready() {
    if (!loaded) {
      get_native_client_buffer = reinterpret_cast<PFNEGLGETNATIVECLIENTBUFFERANDROIDPROC>(
          eglGetProcAddress("eglGetNativeClientBufferANDROID"));
      egl_image_target_texture_2d = reinterpret_cast<PFNGLEGLIMAGETARGETTEXTURE2DOESPROC>(
          eglGetProcAddress("glEGLImageTargetTexture2DOES"));
      loaded = true;
    }
    return get_native_client_buffer != nullptr && egl_image_target_texture_2d != nullptr;
  }
};

AndroidGlExtensions& Extensions() {
  static AndroidGlExtensions extensions;
  return extensions;
}

// Owns the state a repeated composite needs across frames: the shared
// buffer (recreated only when the requested size changes), its EGLImage
// view and the GL texture bound to it, the blit target FBO, and the blit
// program (compiled once).
struct AndroidInterop {
  AHardwareBuffer* buffer = nullptr;
  EGLImageKHR image = EGL_NO_IMAGE_KHR;
  GLuint gl_texture = 0;
  GLuint fbo = 0;
  GLuint blit_program = 0;
  int width = 0;
  int height = 0;

  ~AndroidInterop() {
    EGLDisplay display = eglGetCurrentDisplay();
    if (gl_texture) glDeleteTextures(1, &gl_texture);
    if (image != EGL_NO_IMAGE_KHR && display != EGL_NO_DISPLAY) {
      eglDestroyImageKHR(display, image);
    }
    if (buffer) AHardwareBuffer_release(buffer);
    if (fbo) glDeleteFramebuffers(1, &fbo);
    if (blit_program) glDeleteProgram(blit_program);
  }

  bool EnsureSurface(int new_width, int new_height) {
    if (gl_texture != 0 && width == new_width && height == new_height) return true;
    if (!Extensions().Ready()) return false;

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) return false;

    if (gl_texture) {
      glDeleteTextures(1, &gl_texture);
      gl_texture = 0;
    }
    if (image != EGL_NO_IMAGE_KHR) {
      eglDestroyImageKHR(display, image);
      image = EGL_NO_IMAGE_KHR;
    }
    if (buffer) {
      AHardwareBuffer_release(buffer);
      buffer = nullptr;
    }

    AHardwareBuffer_Desc desc = {};
    desc.width = static_cast<uint32_t>(new_width);
    desc.height = static_cast<uint32_t>(new_height);
    desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    desc.usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT |
                 AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE;
    if (AHardwareBuffer_allocate(&desc, &buffer) != 0) return false;

    EGLClientBuffer client_buffer = Extensions().get_native_client_buffer(buffer);
    if (client_buffer == nullptr) return false;

    const EGLint image_attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    image = eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                              client_buffer, image_attrs);
    if (image == EGL_NO_IMAGE_KHR) return false;

    glGenTextures(1, &gl_texture);
    glBindTexture(GL_TEXTURE_2D, gl_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    Extensions().egl_image_target_texture_2d(GL_TEXTURE_2D, image);
    glBindTexture(GL_TEXTURE_2D, 0);

    width = new_width;
    height = new_height;
    return true;
  }
};

}  // namespace

extern "C" {

void* ck_beauty_interop_create(void) {
  return new (std::nothrow) AndroidInterop();
}

void ck_beauty_interop_destroy(void* handle) {
  delete static_cast<AndroidInterop*>(handle);
}

// Composites source_texture into the shared AHardwareBuffer and returns
// it, unretained (still owned by this Interop, released on the next
// composite that changes size or on ck_beauty_interop_destroy): the
// caller imports it into Vulkan (adapters/bgfx/android_vk.zig) rather
// than freeing it directly.
void* ck_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* interop = static_cast<AndroidInterop*>(handle);

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
    glFramebufferTexture2D(GL_FRAMEBUFFER, GL_COLOR_ATTACHMENT0, GL_TEXTURE_2D,
                           interop->gl_texture, 0);

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

    // The AHardwareBuffer's contents are only guaranteed visible to a
    // different API (Vulkan, importing the same buffer) once the GL work
    // that wrote them has actually completed, not just been issued.
    glFinish();

    glBindFramebuffer(GL_FRAMEBUFFER, previous_fbo);
    glViewport(previous_viewport[0], previous_viewport[1], previous_viewport[2],
               previous_viewport[3]);
    glUseProgram(previous_program);
  });

  return ok ? interop->buffer : nullptr;
}

}  // extern "C"
