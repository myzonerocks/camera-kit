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

  // GL/EGL teardown, valid only on gpupixel's own GL thread - the
  // destroy entry point dispatches here; run anywhere else the deletes
  // silently no-op and the EGLImage keeps its buffer reference alive.
  void ReleaseGl() {
    EGLDisplay display = eglGetCurrentDisplay();
    if (gl_texture) { glDeleteTextures(1, &gl_texture); gl_texture = 0; }
    if (image != EGL_NO_IMAGE_KHR && display != EGL_NO_DISPLAY) {
      eglDestroyImageKHR(display, image);
      image = EGL_NO_IMAGE_KHR;
    }
    if (fbo) { glDeleteFramebuffers(1, &fbo); fbo = 0; }
    if (blit_program) { glDeleteProgram(blit_program); blit_program = 0; }
  }

  bool HasGl() const {
    return gl_texture != 0 || image != EGL_NO_IMAGE_KHR || fbo != 0 || blit_program != 0;
  }

  ~AndroidInterop() {
    if (buffer) AHardwareBuffer_release(buffer);
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

// The reverse bridge: bgfx writes the current preview frame into this
// shared AHardwareBuffer on its own thread, gpupixel reads it back out
// on its own thread - the same shared buffer AndroidInterop composites
// through above, just two EGLImage views built for opposite directions
// instead of one. Both bgfx and gpupixel run GLES contexts here (unlike
// the apple bridge's Metal write / GL read split), but a GL texture
// object is still per-context, so each side imports its own EGLImage
// sibling of the same buffer rather than sharing a GLuint directly - the
// same reason AndroidInterop's own gl_texture is never handed across
// contexts either. The two never race in practice: every caller in this
// codebase reaches gpupixel through SyncRunWithContext, which blocks the
// calling (bgfx) thread until gpupixel's own thread is done, so a
// frame's bgfx write always finishes strictly before that same frame's
// gpupixel read starts, and the next frame's write cannot start until
// this one returns.
struct AndroidInputSurface {
  AHardwareBuffer* buffer = nullptr;
  EGLImageKHR write_image = EGL_NO_IMAGE_KHR;
  GLuint write_texture = 0;
  EGLImageKHR read_image = EGL_NO_IMAGE_KHR;
  GLuint read_texture = 0;
  int width = 0;
  int height = 0;

  // The write objects live in the caller's (bgfx's) GL context, the
  // read objects in gpupixel's - a GL object dies only on the thread
  // whose context owns it, so teardown is split the same way creation
  // already is.
  void ReleaseWriteGl() {
    EGLDisplay display = eglGetCurrentDisplay();
    if (write_texture) { glDeleteTextures(1, &write_texture); write_texture = 0; }
    if (write_image != EGL_NO_IMAGE_KHR && display != EGL_NO_DISPLAY) {
      eglDestroyImageKHR(display, write_image);
      write_image = EGL_NO_IMAGE_KHR;
    }
  }

  void ReleaseReadGl() {
    EGLDisplay display = eglGetCurrentDisplay();
    if (read_texture) { glDeleteTextures(1, &read_texture); read_texture = 0; }
    if (read_image != EGL_NO_IMAGE_KHR && display != EGL_NO_DISPLAY) {
      eglDestroyImageKHR(display, read_image);
      read_image = EGL_NO_IMAGE_KHR;
    }
  }

  bool HasReadGl() const {
    return read_texture != 0 || read_image != EGL_NO_IMAGE_KHR;
  }

  ~AndroidInputSurface() {
    if (buffer) AHardwareBuffer_release(buffer);
  }

  // (Re)allocates the shared buffer alone, no GL/EGL touched - shared by
  // EnsureWriteSurface (GLES) and the Vulkan render-target path, which
  // never runs EnsureWriteSurface at all.
  bool EnsureBuffer(int new_width, int new_height) {
    if (buffer != nullptr && width == new_width && height == new_height) return true;

    ReleaseWriteGl();
    if (HasReadGl()) {
      gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { ReleaseReadGl(); });
    }
    if (buffer) { AHardwareBuffer_release(buffer); buffer = nullptr; }

    AHardwareBuffer_Desc desc = {};
    desc.width = static_cast<uint32_t>(new_width);
    desc.height = static_cast<uint32_t>(new_height);
    desc.layers = 1;
    desc.format = AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
    desc.usage = AHARDWAREBUFFER_USAGE_GPU_COLOR_OUTPUT |
                 AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE;
    if (AHardwareBuffer_allocate(&desc, &buffer) != 0) return false;

    width = new_width;
    height = new_height;
    return true;
  }

  bool EnsureWriteSurface(int new_width, int new_height) {
    const bool resized = width != new_width || height != new_height;
    if (write_texture != 0 && !resized) return true;
    if (!Extensions().Ready()) return false;
    if (!EnsureBuffer(new_width, new_height)) return false;

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) return false;

    EGLClientBuffer client_buffer = Extensions().get_native_client_buffer(buffer);
    if (client_buffer == nullptr) return false;

    const EGLint image_attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    write_image = eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                                    client_buffer, image_attrs);
    if (write_image == EGL_NO_IMAGE_KHR) return false;

    glGenTextures(1, &write_texture);
    glBindTexture(GL_TEXTURE_2D, write_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    Extensions().egl_image_target_texture_2d(GL_TEXTURE_2D, write_image);
    glBindTexture(GL_TEXTURE_2D, 0);

    return true;
  }

  // Runs on gpupixel's own GL thread (the caller dispatches through
  // SyncRunWithContext): imports the same buffer bgfx just wrote into as
  // gpupixel's own EGLImage/texture sibling, bound to whichever context
  // is current there. Skipped when a read texture is already live for
  // the current buffer - EnsureWriteSurface only tears read_texture down
  // when it actually reallocates buffer, so the common per-frame case
  // (size unchanged) reimports nothing and just reads fresh content
  // through the texture already bound.
  bool EnsureReadSurface() {
    if (read_texture != 0) return true;
    if (buffer == nullptr) return false;
    if (!Extensions().Ready()) return false;

    EGLDisplay display = eglGetCurrentDisplay();
    if (display == EGL_NO_DISPLAY) return false;

    EGLClientBuffer client_buffer = Extensions().get_native_client_buffer(buffer);
    if (client_buffer == nullptr) return false;

    const EGLint image_attrs[] = {EGL_IMAGE_PRESERVED_KHR, EGL_TRUE, EGL_NONE};
    read_image = eglCreateImageKHR(display, EGL_NO_CONTEXT, EGL_NATIVE_BUFFER_ANDROID,
                                   client_buffer, image_attrs);
    if (read_image == EGL_NO_IMAGE_KHR) return false;

    glGenTextures(1, &read_texture);
    glBindTexture(GL_TEXTURE_2D, read_texture);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MIN_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_MAG_FILTER, GL_LINEAR);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_S, GL_CLAMP_TO_EDGE);
    glTexParameteri(GL_TEXTURE_2D, GL_TEXTURE_WRAP_T, GL_CLAMP_TO_EDGE);
    Extensions().egl_image_target_texture_2d(GL_TEXTURE_2D, read_image);
    glBindTexture(GL_TEXTURE_2D, 0);
    return true;
  }
};

}  // namespace

extern "C" {

void* goss_beauty_interop_create(void) {
  return new (std::nothrow) AndroidInterop();
}

void goss_beauty_interop_destroy(void* handle) {
  auto* interop = static_cast<AndroidInterop*>(handle);
  if (interop == nullptr) return;
  // GL/EGL objects die on gpupixel's own GL thread; run anywhere else
  // the deletes no-op and the EGLImage pins the buffer forever.
  if (interop->HasGl()) {
    gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { interop->ReleaseGl(); });
  }
  delete interop;
}

// Composites source_texture into the shared AHardwareBuffer and returns
// it, unretained (still owned by this Interop, released on the next
// composite that changes size or on goss_beauty_interop_destroy): the
// caller imports it into Vulkan (adapters/bgfx/android_vk.zig) rather
// than freeing it directly.
void* goss_beauty_interop_composite(void* handle, uint32_t source_texture,
                                  int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* interop = static_cast<AndroidInterop*>(handle);

  // ran tracks whether the lambda actually executed - a dispatch that
  // skips it would otherwise read as a successful composite of a
  // buffer that was never touched this call, since ok defaults true.
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
    // Y-flipped to match the chain's own ingest blit (beauty_shim.cc's
    // kTexCoords) - the convention gpupixel corrects for on the way in
    // has to be undone on the way back out, same as the apple egress.
    static const GLfloat tex_coords[] = {0, 1, 1, 1, 0, 0, 1, 0};
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

  return (ran && ok) ? interop->buffer : nullptr;
}

void* goss_beauty_input_create(void) {
  return new (std::nothrow) AndroidInputSurface();
}

void goss_beauty_input_destroy(void* handle) {
  auto* input = static_cast<AndroidInputSurface*>(handle);
  if (input == nullptr) return;
  // Write objects die here on the caller's own (bgfx) GL thread; read
  // objects die on gpupixel's, same split as their creation.
  input->ReleaseWriteGl();
  if (input->HasReadGl()) {
    gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] { input->ReleaseReadGl(); });
  }
  delete input;
}

// Runs on bgfx's own thread. device is unused - GL has no separate
// device handle to pass the way Metal does, a context is implicit and
// thread-bound - kept only so the caller (abi.zig) can stay platform-
// neutral about the parameter. (Re)creates the shared surface and
// returns the write-side GLuint texture id (cast to a pointer) bgfx can
// wrap with wrapExternalRenderTarget, unretained: valid until the next
// call that actually resizes, or goss_beauty_input_destroy.
void* goss_beauty_input_surface(void* handle, void* device, int32_t width, int32_t height) {
  (void)device;
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* input = static_cast<AndroidInputSurface*>(handle);
  if (!input->EnsureWriteSurface(width, height)) return nullptr;
  return reinterpret_cast<void*>(static_cast<uintptr_t>(input->write_texture));
}

// Vulkan-backend sibling of goss_beauty_input_surface above - no GL/EGL
// context needed, just the shared buffer allocation.
void* goss_beauty_input_hardware_buffer(void* handle, int32_t width, int32_t height) {
  if (handle == nullptr || width <= 0 || height <= 0) return nullptr;
  auto* input = static_cast<AndroidInputSurface*>(handle);
  if (!input->EnsureBuffer(width, height)) return nullptr;
  return input->buffer;
}

// Runs on gpupixel's own GL thread by dispatching through
// SyncRunWithContext itself - the caller never needs to know that
// detail, matching goss_beauty_interop_composite's own contract. Imports
// the shared buffer bgfx just wrote into (its own EGLImage/texture
// sibling, not bgfx's write_texture directly - a GL texture object is
// per-context) and pushes it through the beauty chain via
// goss_beauty_process_external_texture (beauty_shim.cc); returns 0 on
// success, matching goss_beauty_process's own status convention.
int32_t goss_beauty_input_process(void* input_handle, void* beauty_handle,
                                int32_t width, int32_t height,
                                const float* landmarks106) {
  if (input_handle == nullptr || beauty_handle == nullptr) return 1;
  auto* input = static_cast<AndroidInputSurface*>(input_handle);

  bool ran = false;
  bool ok = true;
  gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext([&] {
    ran = true;
    if (!input->EnsureReadSurface()) {
      ok = false;
      return;
    }
    // Imported as GL_TEXTURE_2D (sampler_kind 0), the same target
    // AndroidInterop's own EGLImage import already uses successfully -
    // GL_OES_EGL_image_external's samplerExternalOES is a different,
    // unrelated extension this bridge never needs.
    ok = goss_beauty_process_external_texture(beauty_handle, input->read_texture, 0,
                                            width, height, landmarks106) == 0;
  });
  return (ran && ok) ? 0 : 1;
}

}  // extern "C"
