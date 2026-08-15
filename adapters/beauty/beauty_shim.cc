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

namespace {

struct BeautyContext {
  std::shared_ptr<gpupixel::SourceRawData> source;
  std::shared_ptr<gpupixel::BeautyFaceFilter> beauty;
  std::shared_ptr<gpupixel::FaceReshapeFilter> reshape;
  std::shared_ptr<gpupixel::LipstickFilter> lipstick;
  std::shared_ptr<gpupixel::BlusherFilter> blusher;
  std::shared_ptr<gpupixel::SinkRawData> sink;
};

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
  context->beauty = gpupixel::BeautyFaceFilter::Create();
  context->reshape = gpupixel::FaceReshapeFilter::Create();
  context->lipstick = gpupixel::LipstickFilter::Create();
  context->blusher = gpupixel::BlusherFilter::Create();
  context->sink = gpupixel::SinkRawData::Create();
  if (!context->source || !context->beauty || !context->reshape ||
      !context->lipstick || !context->blusher || !context->sink) {
    delete context;
    return nullptr;
  }
  context->source->AddSink(context->lipstick)
      ->AddSink(context->blusher)
      ->AddSink(context->reshape)
      ->AddSink(context->beauty)
      ->AddSink(context->sink);
  return context;
}

void ck_beauty_destroy(void* handle) {
  delete static_cast<BeautyContext*>(handle);
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
  if (landmarks106 != nullptr) {
    std::vector<float> points(landmarks106, landmarks106 + 106 * 2);
    context->reshape->SetFaceLandmarks(points);
    context->lipstick->SetFaceLandmarks(points);
    context->blusher->SetFaceLandmarks(points);
  }
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

}  // extern "C"
