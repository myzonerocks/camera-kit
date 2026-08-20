// Video recording on Apple platforms: AVAssetWriter drives the
// hardware encoder and MP4 muxer, fed zero-copy from an IOSurface pool
// whose Metal textures bgfx composites into (the beauty bridge's own
// interop shape). C surface only; no vendor type escapes.

#import <AVFoundation/AVFoundation.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <Metal/Metal.h>

#include <cstddef>
#include <cstdint>

namespace {

struct Recording {
  AVAssetWriter* writer = nil;
  AVAssetWriterInput* input = nil;
  AVAssetWriterInputPixelBufferAdaptor* adaptor = nil;
  AVAssetWriterInput* audio_input = nil;
  CMAudioFormatDescriptionRef audio_format = nullptr;
  uint32_t sample_rate = 0;
  uint32_t channels = 0;
  id<MTLDevice> device = nil;
  CVMetalTextureCacheRef metal_cache = nullptr;
  uint32_t width = 0;
  uint32_t height = 0;
  int64_t first_timestamp_us = -1;
  bool failed = false;
};

// One vended frame in flight between begin and commit/abort. The
// caller may hold several at once - the GPU finishes writing a frame's
// surface a couple of engine frames after it was vended, so commits
// trail begins.
struct RecordingFrame {
  CVPixelBufferRef pixel_buffer = nullptr;
  CVMetalTextureRef metal_texture = nullptr;
};

void releaseFrame(RecordingFrame* frame) {
  if (frame->metal_texture) CFRelease(frame->metal_texture);
  if (frame->pixel_buffer) CVPixelBufferRelease(frame->pixel_buffer);
  delete frame;
}

}  // namespace

extern "C" void* goss_recording_open(const uint8_t* path, size_t path_len,
                                     uint32_t width, uint32_t height,
                                     uint32_t bitrate_bps, uint32_t codec) {
  if (path == nullptr || path_len == 0 || width == 0 || height == 0) return nullptr;
  @autoreleasepool {
    NSString* ns_path = [[NSString alloc] initWithBytes:path
                                                 length:path_len
                                               encoding:NSUTF8StringEncoding];
    if (ns_path == nil) return nullptr;
    [[NSFileManager defaultManager] removeItemAtPath:ns_path error:nil];
    NSURL* url = [NSURL fileURLWithPath:ns_path];
    NSError* error = nil;
    AVAssetWriter* writer = [[AVAssetWriter alloc] initWithURL:url
                                                      fileType:AVFileTypeMPEG4
                                                         error:&error];
    if (writer == nil || error != nil) return nullptr;

    AVVideoCodecType codec_type = codec == 1 ? AVVideoCodecTypeHEVC : AVVideoCodecTypeH264;
    NSDictionary* settings = @{
      AVVideoCodecKey : codec_type,
      AVVideoWidthKey : @(width),
      AVVideoHeightKey : @(height),
      AVVideoCompressionPropertiesKey : @{
        AVVideoAverageBitRateKey : @(bitrate_bps == 0 ? 8'000'000 : bitrate_bps),
      },
    };
    AVAssetWriterInput* input =
        [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeVideo
                                       outputSettings:settings];
    input.expectsMediaDataInRealTime = YES;
    if (![writer canAddInput:input]) return nullptr;
    [writer addInput:input];

    NSDictionary* pool_attributes = @{
      (NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA),
      (NSString*)kCVPixelBufferWidthKey : @(width),
      (NSString*)kCVPixelBufferHeightKey : @(height),
      (NSString*)kCVPixelBufferIOSurfacePropertiesKey : @{},
      (NSString*)kCVPixelBufferMetalCompatibilityKey : @YES,
    };
    AVAssetWriterInputPixelBufferAdaptor* adaptor = [[AVAssetWriterInputPixelBufferAdaptor alloc]
        initWithAssetWriterInput:input
     sourcePixelBufferAttributes:pool_attributes];

    // The audio track appends only once goss_recording_submit_audio
    // configures it; adding the input up front keeps the writer's
    // session shape fixed.
    AVAssetWriterInput* audio_input = nil;
    {
      AudioChannelLayout layout = {};
      layout.mChannelLayoutTag = kAudioChannelLayoutTag_Stereo;
      NSDictionary* audio_settings = @{
        AVFormatIDKey : @(kAudioFormatMPEG4AAC),
        AVSampleRateKey : @48000,
        AVNumberOfChannelsKey : @2,
        AVEncoderBitRateKey : @128000,
        AVChannelLayoutKey : [NSData dataWithBytes:&layout length:sizeof(layout)],
      };
      audio_input = [[AVAssetWriterInput alloc] initWithMediaType:AVMediaTypeAudio
                                                   outputSettings:audio_settings];
      audio_input.expectsMediaDataInRealTime = YES;
      if ([writer canAddInput:audio_input]) {
        [writer addInput:audio_input];
      } else {
        audio_input = nil;
      }
    }

    if (![writer startWriting]) return nullptr;
    [writer startSessionAtSourceTime:kCMTimeZero];

    auto* recording = new Recording();
    recording->writer = writer;
    recording->input = input;
    recording->adaptor = adaptor;
    recording->device = MTLCreateSystemDefaultDevice();
    recording->audio_input = audio_input;
    recording->width = width;
    recording->height = height;
    return recording;
  }
}

// Vends the next pool buffer as an opaque frame token plus the Metal
// texture bgfx renders into. The token stays owned by the caller until
// commit or abort, and several may be in flight at once.
extern "C" int32_t goss_recording_begin_frame(void* handle, void** out_frame, void** out_metal_texture) {
  auto* r = static_cast<Recording*>(handle);
  if (r == nullptr || out_frame == nullptr || out_metal_texture == nullptr || r->failed) return -1;
  @autoreleasepool {
    CVPixelBufferPoolRef pool = r->adaptor.pixelBufferPool;
    if (pool == nullptr) return -1;
    auto* frame = new RecordingFrame();
    CVReturn created =
        CVPixelBufferPoolCreatePixelBuffer(kCFAllocatorDefault, pool, &frame->pixel_buffer);
    if (created != kCVReturnSuccess || frame->pixel_buffer == nullptr) {
      releaseFrame(frame);
      return -1;
    }
    if (r->metal_cache == nullptr) {
      if (CVMetalTextureCacheCreate(kCFAllocatorDefault, nullptr, r->device, nullptr,
                                    &r->metal_cache) != kCVReturnSuccess) {
        releaseFrame(frame);
        return -1;
      }
    }
    CVReturn texture_status = CVMetalTextureCacheCreateTextureFromImage(
        kCFAllocatorDefault, r->metal_cache, frame->pixel_buffer, nullptr,
        MTLPixelFormatBGRA8Unorm, r->width, r->height, 0, &frame->metal_texture);
    if (texture_status != kCVReturnSuccess) {
      releaseFrame(frame);
      return -1;
    }
    *out_frame = frame;
    *out_metal_texture = (__bridge void*)CVMetalTextureGetTexture(frame->metal_texture);
    return 0;
  }
}

extern "C" int32_t goss_recording_commit_frame(void* handle, void* frame_token, int64_t timestamp_us) {
  auto* r = static_cast<Recording*>(handle);
  auto* frame = static_cast<RecordingFrame*>(frame_token);
  if (r == nullptr || frame == nullptr || frame->pixel_buffer == nullptr || r->failed) {
    if (frame) releaseFrame(frame);
    return -1;
  }
  @autoreleasepool {
    if (r->first_timestamp_us < 0) r->first_timestamp_us = timestamp_us;
    CMTime time = CMTimeMake(timestamp_us - r->first_timestamp_us, 1'000'000);
    // The writer applies backpressure through readyForMoreMediaData;
    // real-time input drains fast, so a short spin is the contract.
    int spins = 0;
    while (!r->input.readyForMoreMediaData) {
      if (++spins > 10'000) {
        r->failed = true;
        releaseFrame(frame);
        return -1;
      }
      [NSThread sleepForTimeInterval:0.001];
    }
    const BOOL appended = [r->adaptor appendPixelBuffer:frame->pixel_buffer withPresentationTime:time];
    releaseFrame(frame);
    if (!appended) {
      r->failed = true;
      return -1;
    }
    return 0;
  }
}

extern "C" void goss_recording_abort_frame(void* handle, void* frame_token) {
  (void)handle;
  auto* frame = static_cast<RecordingFrame*>(frame_token);
  if (frame) releaseFrame(frame);
}

// Appends interleaved f32 PCM to the recording's audio track at the
// same microsecond clock the video frames ride, so the muxer keeps the
// two streams aligned.
extern "C" int32_t goss_recording_submit_audio(void* handle, const float* samples,
                                               uint32_t frame_count, uint32_t sample_rate,
                                               uint32_t channels, int64_t timestamp_us) {
  auto* r = static_cast<Recording*>(handle);
  if (r == nullptr || samples == nullptr || frame_count == 0 || channels == 0 || r->failed) return -1;
  if (r->audio_input == nil) return -1;
  @autoreleasepool {
    if (r->audio_format == nullptr || r->sample_rate != sample_rate || r->channels != channels) {
      if (r->audio_format) CFRelease(r->audio_format);
      AudioStreamBasicDescription asbd = {};
      asbd.mSampleRate = sample_rate;
      asbd.mFormatID = kAudioFormatLinearPCM;
      asbd.mFormatFlags = kAudioFormatFlagIsFloat | kAudioFormatFlagIsPacked;
      asbd.mChannelsPerFrame = channels;
      asbd.mBitsPerChannel = 32;
      asbd.mBytesPerFrame = 4 * channels;
      asbd.mFramesPerPacket = 1;
      asbd.mBytesPerPacket = 4 * channels;
      if (CMAudioFormatDescriptionCreate(kCFAllocatorDefault, &asbd, 0, nullptr, 0, nullptr,
                                         nullptr, &r->audio_format) != noErr) {
        return -1;
      }
      r->sample_rate = sample_rate;
      r->channels = channels;
    }
    if (r->first_timestamp_us < 0) r->first_timestamp_us = timestamp_us;
    CMTime time = CMTimeMake(timestamp_us - r->first_timestamp_us, 1'000'000);

    const size_t byte_count = (size_t)frame_count * channels * 4;
    CMBlockBufferRef block = nullptr;
    if (CMBlockBufferCreateWithMemoryBlock(kCFAllocatorDefault, nullptr, byte_count,
                                           kCFAllocatorDefault, nullptr, 0, byte_count, 0,
                                           &block) != noErr) {
      return -1;
    }
    if (CMBlockBufferReplaceDataBytes(samples, block, 0, byte_count) != noErr) {
      CFRelease(block);
      return -1;
    }
    CMSampleBufferRef sample = nullptr;
    const OSStatus created = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
        kCFAllocatorDefault, block, r->audio_format, frame_count, time, nullptr, &sample);
    CFRelease(block);
    if (created != noErr || sample == nullptr) return -1;

    int spins = 0;
    while (!r->audio_input.readyForMoreMediaData) {
      if (++spins > 10'000) {
        CFRelease(sample);
        return -1;
      }
      [NSThread sleepForTimeInterval:0.001];
    }
    const BOOL appended = [r->audio_input appendSampleBuffer:sample];
    CFRelease(sample);
    return appended ? 0 : -1;
  }
}

extern "C" int32_t goss_recording_finish(void* handle) {
  auto* r = static_cast<Recording*>(handle);
  if (r == nullptr) return -1;
  int32_t status = 0;
  @autoreleasepool {
    if (r->failed || r->writer.status != AVAssetWriterStatusWriting) {
      [r->writer cancelWriting];
      status = -1;
    } else {
      [r->input markAsFinished];
      if (r->audio_input) [r->audio_input markAsFinished];
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      [r->writer finishWritingWithCompletionHandler:^{
        dispatch_semaphore_signal(done);
      }];
      dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
      if (r->writer.status != AVAssetWriterStatusCompleted) status = -1;
    }
    if (r->metal_cache) CFRelease(r->metal_cache);
    if (r->audio_format) CFRelease(r->audio_format);
  }
  delete r;
  return status;
}

// Decodes a finished file and copies one frame's BGRA pixels out -
// the harness's by-eye artifact, not a production surface.
extern "C" int32_t goss_recording_export_frame(const uint8_t* path, size_t path_len,
                                               uint32_t frame_index, uint8_t* out_bgra,
                                               size_t capacity, uint32_t* out_width,
                                               uint32_t* out_height) {
  if (path == nullptr || path_len == 0 || out_bgra == nullptr) return -1;
  @autoreleasepool {
    NSString* ns_path = [[NSString alloc] initWithBytes:path
                                                 length:path_len
                                               encoding:NSUTF8StringEncoding];
    if (ns_path == nil) return -1;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ns_path] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack*>* result, NSError* load_error) {
                   tracks = load_error == nil ? result : nil;
                   dispatch_semaphore_signal(loaded);
                 }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (tracks.count == 0) return -1;

    NSError* error = nil;
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (reader == nil || error != nil) return -1;
    AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:tracks.firstObject
       outputSettings:@{(NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
    if (![reader canAddOutput:output]) return -1;
    [reader addOutput:output];
    if (![reader startReading]) return -1;

    uint32_t at = 0;
    while (true) {
      CMSampleBufferRef sample = [output copyNextSampleBuffer];
      if (sample == nullptr) return -1;
      if (at == frame_index) {
        CVImageBufferRef image = CMSampleBufferGetImageBuffer(sample);
        if (image == nullptr) {
          CFRelease(sample);
          return -1;
        }
        CVPixelBufferLockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        const size_t width = CVPixelBufferGetWidth(image);
        const size_t height = CVPixelBufferGetHeight(image);
        const size_t stride = CVPixelBufferGetBytesPerRow(image);
        const uint8_t* base = (const uint8_t*)CVPixelBufferGetBaseAddress(image);
        int32_t status = 0;
        if (capacity < width * height * 4 || base == nullptr) {
          status = -1;
        } else {
          for (size_t y = 0; y < height; y++) {
            memcpy(out_bgra + y * width * 4, base + y * stride, width * 4);
          }
          if (out_width) *out_width = (uint32_t)width;
          if (out_height) *out_height = (uint32_t)height;
        }
        CVPixelBufferUnlockBaseAddress(image, kCVPixelBufferLock_ReadOnly);
        CFRelease(sample);
        [reader cancelReading];
        return status;
      }
      at += 1;
      CFRelease(sample);
    }
  }
}

// Decodes a finished file back and reports its real shape - the
// conformance harness's round-trip proof, not a production surface.
extern "C" int32_t goss_recording_probe(const uint8_t* path, size_t path_len,
                                        uint32_t* out_frames, uint32_t* out_width,
                                        uint32_t* out_height, int64_t* out_duration_us) {
  if (path == nullptr || path_len == 0) return -1;
  @autoreleasepool {
    NSString* ns_path = [[NSString alloc] initWithBytes:path
                                                 length:path_len
                                               encoding:NSUTF8StringEncoding];
    if (ns_path == nil) return -1;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ns_path] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeVideo
                 completionHandler:^(NSArray<AVAssetTrack*>* result, NSError* load_error) {
                   tracks = load_error == nil ? result : nil;
                   dispatch_semaphore_signal(loaded);
                 }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (tracks.count == 0) return -1;
    AVAssetTrack* track = tracks.firstObject;

    NSError* error = nil;
    AVAssetReader* reader = [[AVAssetReader alloc] initWithAsset:asset error:&error];
    if (reader == nil || error != nil) return -1;
    AVAssetReaderTrackOutput* output = [[AVAssetReaderTrackOutput alloc]
        initWithTrack:track
       outputSettings:@{(NSString*)kCVPixelBufferPixelFormatTypeKey : @(kCVPixelFormatType_32BGRA)}];
    if (![reader canAddOutput:output]) return -1;
    [reader addOutput:output];
    if (![reader startReading]) return -1;

    uint32_t frames = 0;
    while (true) {
      CMSampleBufferRef sample = [output copyNextSampleBuffer];
      if (sample == nullptr) break;
      frames += 1;
      CFRelease(sample);
    }
    if (reader.status != AVAssetReaderStatusCompleted) return -1;

    if (out_frames) *out_frames = frames;
    if (out_width) *out_width = (uint32_t)track.naturalSize.width;
    if (out_height) *out_height = (uint32_t)track.naturalSize.height;
    if (out_duration_us) {
      const CMTimeRange range = track.timeRange;
      *out_duration_us = (int64_t)((CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)) * 1'000'000.0);
    }
    return 0;
  }
}

// Reports the audio track's duration, the harness's A/V alignment
// proof surface.
extern "C" int32_t goss_recording_probe_audio(const uint8_t* path, size_t path_len,
                                              int64_t* out_duration_us) {
  if (path == nullptr || path_len == 0) return -1;
  @autoreleasepool {
    NSString* ns_path = [[NSString alloc] initWithBytes:path
                                                 length:path_len
                                               encoding:NSUTF8StringEncoding];
    if (ns_path == nil) return -1;
    AVURLAsset* asset = [AVURLAsset URLAssetWithURL:[NSURL fileURLWithPath:ns_path] options:nil];
    __block NSArray<AVAssetTrack*>* tracks = nil;
    dispatch_semaphore_t loaded = dispatch_semaphore_create(0);
    [asset loadTracksWithMediaType:AVMediaTypeAudio
                 completionHandler:^(NSArray<AVAssetTrack*>* result, NSError* load_error) {
                   tracks = load_error == nil ? result : nil;
                   dispatch_semaphore_signal(loaded);
                 }];
    dispatch_semaphore_wait(loaded, DISPATCH_TIME_FOREVER);
    if (tracks.count == 0) return -1;
    if (out_duration_us) {
      const CMTimeRange range = tracks.firstObject.timeRange;
      *out_duration_us = (int64_t)((CMTimeGetSeconds(range.start) + CMTimeGetSeconds(range.duration)) * 1'000'000.0);
    }
    return 0;
  }
}
