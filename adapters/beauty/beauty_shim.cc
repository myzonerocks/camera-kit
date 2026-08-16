// The C boundary around the beauty engine: one context owning the chain
// smooth and whiten, face reshape, lipstick, blusher, fed RGBA frames and
// the tracked contour points, answering with the processed RGBA. The
// engine runs its own offscreen gl context per platform; everything here
// executes on the caller's thread, one frame at a time.

#include <cstdint>
#include <cstring>
#include <memory>
#include <vector>

#include "gpupixel/gpupixel.h"

// Source::GetFramebuffer() (public) returns this type, but the engine
// ships its definition under src/core rather than the public include
// tree - a gap in their own header split, not a private member we are
// reaching around. gpupixel_context.h is the same situation:
// GPUPixelContext::GetInstance()/GetFramebufferFactory()/
// SetActiveGlProgram are how SourceRawData itself renders, just not
// exposed through the public tree either.
#include "core/gpupixel_framebuffer.h"
#include "core/gpupixel_context.h"

namespace {

// BeautyFaceFilter is a FilterGroup, and FilterGroup::GetFramebuffer()
// is hard-coded to return null in the pinned engine (the real delegation
// to its internal terminal filter is dead, commented-out code - a bug in
// gpupixel itself, filed upstream separately). Source::AddSink's fan-out
// is not affected by that bug, so a second, silent sink tapped onto the
// same output reaches the real per-frame framebuffer correctly: this is
// that tap. It renders nothing and holds no framebuffer reference past
// one capture, just the raw GL texture name.
class TextureTapSink : public gpupixel::Sink {
 public:
  TextureTapSink() : gpupixel::Sink(1) {}
  void SetInputFramebuffer(
      std::shared_ptr<gpupixel::GPUPixelFramebuffer> framebuffer,
      gpupixel::RotationMode rotation_mode = gpupixel::NoRotation,
      int tex_idx = 0) override {
    (void)rotation_mode;
    (void)tex_idx;
    captured_texture = framebuffer ? framebuffer->GetTexture() : 0;
  }
  uint32_t captured_texture = 0;
};

// GL_TEXTURE_RECTANGLE has no equivalent in GLES, so the constant only
// exists to compile against on macOS - the only platform whose sampler_
// kind (see ck_beauty_process_external_texture) can ever select it.
#if defined(GPUPIXEL_MAC)
constexpr uint32_t kRectangleTextureTarget = GL_TEXTURE_RECTANGLE_ARB;
#else
constexpr uint32_t kRectangleTextureTarget = GL_TEXTURE_2D;
#endif

const char* kExternalVertexShaderSource = R"(
    attribute vec4 position;
    attribute vec4 inputTextureCoordinate;
    varying vec2 textureCoordinate;
    void main() {
      gl_Position = position;
      textureCoordinate = inputTextureCoordinate.xy;
    })";

const char* kExternal2DFragmentShaderSource = R"(
    varying vec2 textureCoordinate;
    uniform sampler2D inputImageTexture;
    void main() {
      gl_FragColor = texture2D(inputImageTexture, textureCoordinate);
    })";

// samplerRect/texture2DRect is legacy-desktop-GL-only: the platform
// interop layer never selects sampler_kind 1 anywhere but macOS, whose
// CVOpenGLTextureCache always vends rectangle textures.
const char* kExternalRectFragmentShaderSource = R"(
    #extension GL_ARB_texture_rectangle : enable
    varying vec2 textureCoordinate;
    uniform sampler2DRect inputImageTexture;
    uniform vec2 inputImageTextureSize;
    void main() {
      gl_FragColor = texture2DRect(inputImageTexture, textureCoordinate * inputImageTextureSize);
    })";

// Feeds an already-GL-imported external texture (a shared surface bgfx
// just wrote a frame into, imported by the platform interop layer on
// whatever GL context is current there) into the beauty chain by
// blitting it into a framebuffer this class owns - the GPU-input mirror
// of SourceRawData's CPU upload path. Never owns the external texture;
// the platform interop layer keeps its texture cache and source buffer
// alive across calls.
class SourceExternalTexture : public gpupixel::Source {
 public:
  static std::shared_ptr<SourceExternalTexture> Create() {
    auto ret = std::shared_ptr<SourceExternalTexture>(new SourceExternalTexture());
    bool ok = true;
    gpupixel::GPUPixelContext::GetInstance()->SyncRunWithContext(
        [&] { ok = ret->Init(); });
    return ok ? ret : nullptr;
  }

  bool Init() {
    program_2d_ = gpupixel::GPUPixelGLProgram::CreateWithShaderString(
        kExternalVertexShaderSource, kExternal2DFragmentShaderSource);
    if (program_2d_ == nullptr) return false;
    // sampler2DRect/texture2DRect do not exist in GLSL ES - only
    // compiled where sampler_kind can actually select it (macOS).
    // Compiling this on iOS would fail every beauty chain there for a
    // program that platform's interop layer never even asks for.
#if defined(GPUPIXEL_MAC)
    program_rect_ = gpupixel::GPUPixelGLProgram::CreateWithShaderString(
        kExternalVertexShaderSource, kExternalRectFragmentShaderSource);
    return program_rect_ != nullptr;
#else
    return true;
#endif
  }

  // Runs on gpupixel's own GL thread - the caller already dispatches
  // through SyncRunWithContext before reaching here (both the apple and,
  // later, android platform interop layers share that contract with
  // SourceRawData::ProcessData).
  bool RenderExternalTexture(uint32_t gl_texture,
                             int32_t sampler_kind,
                             int32_t width,
                             int32_t height) {
    if (!framebuffer_ || framebuffer_->GetWidth() != width ||
        framebuffer_->GetHeight() != height) {
      framebuffer_ = gpupixel::GPUPixelContext::GetInstance()
                         ->GetFramebufferFactory()
                         ->CreateFramebuffer(width, height);
    }
    this->SetFramebuffer(framebuffer_, gpupixel::NoRotation);

    const bool use_rect = sampler_kind == 1;
    gpupixel::GPUPixelGLProgram* program = use_rect ? program_rect_ : program_2d_;
    gpupixel::GPUPixelContext::GetInstance()->SetActiveGlProgram(program);
    this->GetFramebuffer()->Activate();

    static const float kImageVertices[] = {
        -1.0f, -1.0f, 1.0f, -1.0f, -1.0f, 1.0f, 1.0f, 1.0f,
    };
    static const float kTexCoords[] = {
        0.0f, 1.0f, 1.0f, 1.0f, 0.0f, 0.0f, 1.0f, 0.0f,
    };

    const uint32_t position_attribute = program->GetAttribLocation("position");
    const uint32_t tex_coord_attribute =
        program->GetAttribLocation("inputTextureCoordinate");
    glEnableVertexAttribArray(position_attribute);
    glVertexAttribPointer(position_attribute, 2, GL_FLOAT, 0, 0, kImageVertices);
    glEnableVertexAttribArray(tex_coord_attribute);
    glVertexAttribPointer(tex_coord_attribute, 2, GL_FLOAT, 0, 0, kTexCoords);

    const uint32_t target = use_rect ? kRectangleTextureTarget : GL_TEXTURE_2D;
    glActiveTexture(GL_TEXTURE0);
    glBindTexture(target, gl_texture);
    program->SetUniformValue("inputImageTexture", 0);
    if (use_rect) {
      program->SetUniformValue("inputImageTextureSize",
                               gpupixel::Vector2(static_cast<float>(width),
                                                 static_cast<float>(height)));
    }

    glDrawArrays(GL_TRIANGLE_STRIP, 0, 4);
    glDisableVertexAttribArray(position_attribute);
    glDisableVertexAttribArray(tex_coord_attribute);
    glBindTexture(target, 0);
    this->GetFramebuffer()->Deactivate();

    Source::DoRender(true);
    return true;
  }

 private:
  gpupixel::GPUPixelGLProgram* program_2d_ = nullptr;
  gpupixel::GPUPixelGLProgram* program_rect_ = nullptr;
};

struct BeautyContext {
  std::shared_ptr<gpupixel::SourceRawData> source;
  std::shared_ptr<SourceExternalTexture> source_gpu;
  std::shared_ptr<gpupixel::BeautyFaceFilter> beauty;
  std::shared_ptr<gpupixel::FaceReshapeFilter> reshape;
  std::shared_ptr<gpupixel::LipstickFilter> lipstick;
  std::shared_ptr<gpupixel::BlusherFilter> blusher;
  std::shared_ptr<gpupixel::SinkRawData> sink;
  std::shared_ptr<TextureTapSink> texture_tap;
};

void ApplyLandmarks(BeautyContext* context, const float* landmarks106) {
  if (landmarks106 == nullptr) return;
  std::vector<float> points(landmarks106, landmarks106 + 106 * 2);
  context->reshape->SetFaceLandmarks(points);
  context->lipstick->SetFaceLandmarks(points);
  context->blusher->SetFaceLandmarks(points);
}

}  // namespace

extern "C" {

void* ck_beauty_create(const char* resource_path) {
  if (resource_path != nullptr) {
    gpupixel::GPUPixel::SetResourcePath(resource_path);
  }
  auto* context = new (std::nothrow) BeautyContext();
  if (context == nullptr) {
    return nullptr;
  }
  context->source = gpupixel::SourceRawData::Create();
  context->source_gpu = SourceExternalTexture::Create();
  context->beauty = gpupixel::BeautyFaceFilter::Create();
  context->reshape = gpupixel::FaceReshapeFilter::Create();
  context->lipstick = gpupixel::LipstickFilter::Create();
  context->blusher = gpupixel::BlusherFilter::Create();
  context->sink = gpupixel::SinkRawData::Create();
  context->texture_tap = std::make_shared<TextureTapSink>();
  if (!context->source || !context->source_gpu || !context->beauty ||
      !context->reshape || !context->lipstick || !context->blusher ||
      !context->sink || !context->texture_tap) {
    delete context;
    return nullptr;
  }
  context->source->AddSink(context->lipstick)
      ->AddSink(context->blusher)
      ->AddSink(context->reshape)
      ->AddSink(context->beauty)
      ->AddSink(context->sink);
  // A second, independent entry point into the same downstream chain:
  // source_gpu is its own Source with its own empty sinks_ map, so this
  // only adds one new edge (source_gpu -> lipstick) without touching
  // lipstick's own already-wired sinks at all.
  context->source_gpu->AddSink(context->lipstick);
  context->beauty->AddSink(context->texture_tap);
  return context;
}

void ck_beauty_destroy(void* handle) {
  delete static_cast<BeautyContext*>(handle);
}

/// The beauty chain's own GL output texture (a normal GL_TEXTURE_2D
/// gpupixel owns), valid after ck_beauty_process has run at least once.
/// The GPU compositing path blits from this rather than reading the CPU
/// buffer back; ownership stays with gpupixel, never freed by the caller.
uint32_t ck_beauty_output_texture(void* handle) {
  auto* context = static_cast<BeautyContext*>(handle);
  if (context == nullptr) return 0;
  return context->texture_tap->captured_texture;
}

/// Parameters are zero to one; zero leaves the frame untouched for that
/// effect. Identifier order: smooth, whiten, thin face, big eye, lipstick,
/// blush.
void ck_beauty_set(void* handle, int32_t effect, float value) {
  auto* context = static_cast<BeautyContext*>(handle);
  if (context == nullptr) {
    return;
  }
  switch (effect) {
    case 0:
      context->beauty->SetBlurAlpha(value);
      break;
    case 1:
      context->beauty->SetWhite(value);
      break;
    case 2:
      context->reshape->SetFaceSlimLevel(value);
      break;
    case 3:
      context->reshape->SetEyeZoomLevel(value);
      break;
    case 4:
      context->lipstick->SetBlendLevel(value);
      break;
    case 5:
      context->blusher->SetBlendLevel(value);
      break;
    default:
      break;
  }
}

/// Landmarks are the engine's contour layout, x then y per point
/// normalized to the frame, or null while no face holds; the landmark
/// driven effects pass through untouched without them.
int32_t ck_beauty_process(void* handle,
                          const uint8_t* rgba_in,
                          int32_t width,
                          int32_t height,
                          const float* landmarks106,
                          uint8_t* rgba_out) {
  auto* context = static_cast<BeautyContext*>(handle);
  if (context == nullptr || rgba_in == nullptr || rgba_out == nullptr ||
      width <= 0 || height <= 0) {
    return 1;
  }
  ApplyLandmarks(context, landmarks106);
  context->source->ProcessData(rgba_in, width, height, width * 4,
                               gpupixel::GPUPIXEL_FRAME_TYPE_RGBA);
  const uint8_t* processed = context->sink->GetRgbaBuffer();
  if (processed == nullptr) {
    return 1;
  }
  if (context->sink->GetWidth() != width || context->sink->GetHeight() != height) {
    return 1;
  }
  std::memcpy(rgba_out, processed, static_cast<size_t>(width) * height * 4);
  return 0;
}

/// The GPU-input mirror of ck_beauty_process: gl_texture is already
/// live on whatever GL context is current on the calling thread (the
/// platform interop layer guarantees that before calling this, the same
/// way it guarantees a current context for ck_beauty_interop_composite).
/// sampler_kind: 0 = GL_TEXTURE_2D, 1 = GL_TEXTURE_RECTANGLE (macOS
/// only). Pulls the result back out through ck_beauty_output_texture,
/// same as the CPU path's own chain.
int32_t ck_beauty_process_external_texture(void* handle,
                                           uint32_t gl_texture,
                                           int32_t sampler_kind,
                                           int32_t width,
                                           int32_t height,
                                           const float* landmarks106) {
  auto* context = static_cast<BeautyContext*>(handle);
  if (context == nullptr || gl_texture == 0 || width <= 0 || height <= 0) {
    return 1;
  }
  ApplyLandmarks(context, landmarks106);
  if (!context->source_gpu->RenderExternalTexture(gl_texture, sampler_kind, width, height)) {
    return 1;
  }
  return 0;
}

// The GPU compositing bridge is platform-specific: interop_apple.mm on
// ios/macos, interop_android.cc on android. Everywhere else (the x86-64
// linux CI target, which has neither a windowing GL context nor gpupixel
// linked at all) it stays an explicit refusal, rather than an undefined
// symbol at link time.
#if !defined(__APPLE__) && !defined(__ANDROID__)
void* ck_beauty_interop_create() {
  return nullptr;
}
void ck_beauty_interop_destroy(void* handle) {
  (void)handle;
}
void* ck_beauty_interop_composite(void* handle, uint32_t source_texture, int32_t width, int32_t height) {
  (void)handle;
  (void)source_texture;
  (void)width;
  (void)height;
  return nullptr;
}
#endif

}  // extern "C"
