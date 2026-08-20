// Platform photo encoding on Apple: ImageIO's own encoders produce the
// formats phones actually save (JPEG, HEIC) with correct metadata. C
// surface only; no vendor type escapes.

#import <CoreGraphics/CoreGraphics.h>
#import <ImageIO/ImageIO.h>
#import <Foundation/Foundation.h>

#include <cstdint>
#include <cstring>

namespace {

CFStringRef formatUti(uint32_t format) {
  switch (format) {
    case 1: return CFSTR("public.jpeg");
    case 2: return CFSTR("public.heic");
    default: return nullptr;
  }
}

}  // namespace

// Encodes tightly packed RGBA8 into format (1 = JPEG, 2 = HEIC) at
// quality percent (1..100). out_len always receives the encoded size,
// so a too-small buffer (-2) tells the caller what to retry with; any
// other failure is -1.
extern "C" int32_t goss_photo_encode(const uint8_t* rgba, uint32_t width, uint32_t height,
                                     uint32_t format, uint32_t quality, uint8_t* out_data,
                                     size_t out_capacity, size_t* out_len) {
  if (rgba == nullptr || width == 0 || height == 0 || out_len == nullptr) return -1;
  *out_len = 0;
  CFStringRef uti = formatUti(format);
  if (uti == nullptr) return -1;
  @autoreleasepool {
    CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
    CGContextRef context =
        CGBitmapContextCreate((void*)rgba, width, height, 8, (size_t)width * 4, color_space,
                              kCGImageAlphaNoneSkipLast);
    CGColorSpaceRelease(color_space);
    if (context == nullptr) return -1;
    CGImageRef image = CGBitmapContextCreateImage(context);
    CGContextRelease(context);
    if (image == nullptr) return -1;

    CFMutableDataRef data = CFDataCreateMutable(kCFAllocatorDefault, 0);
    CGImageDestinationRef dest = CGImageDestinationCreateWithData(data, uti, 1, nullptr);
    if (dest == nullptr) {
      CFRelease(data);
      CGImageRelease(image);
      return -1;
    }
    const double lossy_quality = (double)(quality == 0 ? 90 : quality) / 100.0;
    CFNumberRef quality_number =
        CFNumberCreate(kCFAllocatorDefault, kCFNumberFloat64Type, &lossy_quality);
    const void* keys[] = {kCGImageDestinationLossyCompressionQuality};
    const void* values[] = {quality_number};
    CFDictionaryRef properties =
        CFDictionaryCreate(kCFAllocatorDefault, keys, values, 1, &kCFTypeDictionaryKeyCallBacks,
                           &kCFTypeDictionaryValueCallBacks);
    CGImageDestinationAddImage(dest, image, properties);
    const bool finalized = CGImageDestinationFinalize(dest);
    CFRelease(properties);
    CFRelease(quality_number);
    CFRelease(dest);
    CGImageRelease(image);

    int32_t status = -1;
    if (finalized) {
      const size_t len = (size_t)CFDataGetLength(data);
      *out_len = len;
      if (out_data != nullptr && out_capacity >= len) {
        memcpy(out_data, CFDataGetBytePtr(data), len);
        status = 0;
      } else {
        status = -2;
      }
    }
    CFRelease(data);
    return status;
  }
}

// Decodes encoded photo bytes back to RGBA8 - the harness's round-trip
// proof surface, not a production decoder.
extern "C" int32_t goss_photo_decode(const uint8_t* data, size_t data_len, uint8_t* out_rgba,
                                     size_t out_capacity, uint32_t* out_width,
                                     uint32_t* out_height) {
  if (data == nullptr || data_len == 0) return -1;
  @autoreleasepool {
    CFDataRef bytes = CFDataCreate(kCFAllocatorDefault, data, (CFIndex)data_len);
    CGImageSourceRef source = CGImageSourceCreateWithData(bytes, nullptr);
    CFRelease(bytes);
    if (source == nullptr) return -1;
    CGImageRef image = CGImageSourceCreateImageAtIndex(source, 0, nullptr);
    CFRelease(source);
    if (image == nullptr) return -1;

    const size_t width = CGImageGetWidth(image);
    const size_t height = CGImageGetHeight(image);
    if (out_width) *out_width = (uint32_t)width;
    if (out_height) *out_height = (uint32_t)height;
    int32_t status = -2;
    if (out_rgba != nullptr && out_capacity >= width * height * 4) {
      CGColorSpaceRef color_space = CGColorSpaceCreateDeviceRGB();
      CGContextRef context = CGBitmapContextCreate(out_rgba, width, height, 8, width * 4,
                                                   color_space, kCGImageAlphaNoneSkipLast);
      CGColorSpaceRelease(color_space);
      if (context != nullptr) {
        CGContextDrawImage(context, CGRectMake(0, 0, (CGFloat)width, (CGFloat)height), image);
        CGContextRelease(context);
        status = 0;
      } else {
        status = -1;
      }
    }
    CGImageRelease(image);
    return status;
  }
}
