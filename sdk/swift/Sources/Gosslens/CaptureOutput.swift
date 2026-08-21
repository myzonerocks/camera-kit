import CGosslens
import CoreVideo

/// Pixel/screenshot readback, reached directly off GossEngine rather than
/// its own handle type.
extension GossEngine {
    /// Debug/test tooling only. Requests a screenshot of the next
    /// presented frame, written to path with a ".tga" suffix appended.
    public func requestScreenshot(path: String) throws {
        let bytes = Array(path.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_engine_request_screenshot(handle, buffer.baseAddress, buffer.count))
        }
    }

    /// Debug/test tooling only. Renders and presents like renderFrame,
    /// and reads the composited output back as RGBA8, row 0 first, at
    /// the renderer's real dimensions - the returned width and height,
    /// which the caller's requested size only bounds.
    public func captureFrame(session: GossSession?, width: UInt32, height: UInt32) throws -> (pixels: [UInt8], width: UInt32, height: UInt32) {
        var data = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_frame(handle, session?.handle, buffer.baseAddress, buffer.count, &outWidth, &outHeight))
        }
        return (data, outWidth, outHeight)
    }

    /// Renders like captureFrame and returns the composited output
    /// encoded as PNG bytes, sized by a probe call first. Deterministic:
    /// the same composited pixels, the same bytes.
    public func capturePhoto(session: GossSession?) throws -> (png: [UInt8], width: UInt32, height: UInt32) {
        var needed = 0
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        var probe: UInt8 = 0
        let status = goss_engine_capture_photo(handle, session?.handle, &probe, 0, &needed, &outWidth, &outHeight)
        if status == GOSS_OK && needed == 0 {
            return ([], outWidth, outHeight)
        }
        guard status == GOSS_ERROR_INVALID_ARGUMENT, needed > 0 else {
            try checked(status)
            return ([], outWidth, outHeight)
        }
        var data = [UInt8](repeating: 0, count: needed)
        var encoded = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_photo(handle, session?.handle, buffer.baseAddress, buffer.count, &encoded, &outWidth, &outHeight))
        }
        return (Array(data[0..<encoded]), outWidth, outHeight)
    }

    public enum PhotoFormat: UInt32 {
        case jpeg = 1
        case heic = 2
    }

    /// A high-resolution still capture: the composited frame at its own
    /// resolution or a requested one, independent of the preview size.
    public struct StillConfig {
        public enum Format: UInt32 { case png = 0, jpeg = 1, heic = 2 }
        /// The gamut the file is tagged with: PNG carries cHRM/gAMA,
        /// JPEG carries the matching ICC profile.
        public enum ColorSpace: UInt32 { case sRGB = 0, displayP3 = 1, rec2020 = 2 }
        /// Zero captures at the submitted frame's own resolution.
        public var width: UInt32
        public var height: UInt32
        public var supersample: UInt32
        public var format: Format
        public var quality: UInt32
        public var colorSpace: ColorSpace
        /// 8 or 16 bits per channel; 16 is the PNG high-bit-depth path.
        public var bitDepth: UInt32
        public init(width: UInt32 = 0, height: UInt32 = 0, supersample: UInt32 = 0, format: Format = .png, quality: UInt32 = 0, colorSpace: ColorSpace = .sRGB, bitDepth: UInt32 = 8) {
            self.width = width
            self.height = height
            self.supersample = supersample
            self.format = format
            self.quality = quality
            self.colorSpace = colorSpace
            self.bitDepth = bitDepth
        }
    }

    /// Captures a still at the configured resolution - the submitted
    /// frame's own size by default - decoupled from the preview swap
    /// chain, so a full-sensor still is not clamped to preview size.
    public func captureStill(session: GossSession?, config: StillConfig = StillConfig()) throws -> (data: [UInt8], width: UInt32, height: UInt32) {
        var raw = goss_capture_config(width: config.width, height: config.height, supersample: config.supersample, format: config.format.rawValue, quality: config.quality, color_space: config.colorSpace.rawValue, bit_depth: config.bitDepth)
        var needed = 0
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        var probe: UInt8 = 0
        let status = goss_engine_capture_still(handle, session?.handle, &raw, &probe, 0, &needed, &outWidth, &outHeight)
        if status == GOSS_OK && needed == 0 { return ([], outWidth, outHeight) }
        guard status == GOSS_ERROR_INVALID_ARGUMENT, needed > 0 else {
            try checked(status)
            return ([], outWidth, outHeight)
        }
        var data = [UInt8](repeating: 0, count: needed)
        var encoded = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_still(handle, session?.handle, &raw, buffer.baseAddress, buffer.count, &encoded, &outWidth, &outHeight))
        }
        return (Array(data[0..<encoded]), outWidth, outHeight)
    }

    /// Captures the composited frame in a platform photo format. The
    /// PNG capturePhoto stays the deterministic surface.
    public func capturePhoto(session: GossSession?, as format: PhotoFormat, quality: UInt32 = 0) throws -> (data: [UInt8], width: UInt32, height: UInt32) {
        var needed = 0
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        var probe: UInt8 = 0
        let status = goss_engine_capture_photo_as(handle, session?.handle, format.rawValue, quality, &probe, 0, &needed, &outWidth, &outHeight)
        if status == GOSS_OK && needed == 0 { return ([], outWidth, outHeight) }
        guard status == GOSS_ERROR_INVALID_ARGUMENT, needed > 0 else {
            try checked(status)
            return ([], outWidth, outHeight)
        }
        var data = [UInt8](repeating: 0, count: needed)
        var encoded = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_photo_as(handle, session?.handle, format.rawValue, quality, buffer.baseAddress, buffer.count, &encoded, &outWidth, &outHeight))
        }
        return (Array(data[0..<encoded]), outWidth, outHeight)
    }

    /// Starts recording the session's rendered frames, effects baked
    /// in, into an MP4 at path. One recording per engine; every
    /// rendered frame appends until stopRecording.
    public func startRecording(session: GossSession, path: String, width: UInt32 = 0, height: UInt32 = 0, bitrate: UInt32 = 0, hevc: Bool = false) throws {
        var config = goss_recording_config(width: width, height: height, bitrate_bps: bitrate, codec: hevc ? 1 : 0)
        let bytes = Array(path.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_engine_recording_start(handle, session.handle, buffer.baseAddress, buffer.count, &config))
        }
    }

    /// Stops the recording, flushing in-flight frames and finalizing
    /// the file.
    public func stopRecording() throws {
        try checked(goss_engine_recording_stop(handle))
    }

    /// Feeds interleaved f32 PCM into the session: the engine's level
    /// and beat analysis drives audio triggers, and an active recording
    /// muxes it as the audio track.
    public func submitAudio(session: GossSession, samples: [Float], frameCount: UInt32, sampleRate: UInt32, channels: UInt32, timestampUs: Int64) throws {
        try samples.withUnsafeBufferPointer { buffer in
            try checked(goss_session_submit_audio(session.handle, buffer.baseAddress, frameCount, sampleRate, channels, timestampUs))
        }
    }

    /// The composited frame as packed bytes in a WebRTC format (BGRA by
    /// default), the supported per-frame output for a live broadcast source -
    /// feed it to a LiveKit or WebRTC custom video source.
    public func captureLiveFrame(session: GossSession?, width: UInt32, height: UInt32, format: GossPixelFormat = .bgra8) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_live_frame(handle, session?.handle, format.rawValue, buffer.baseAddress, buffer.count, &outWidth, &outHeight))
        }
        return data
    }

    /// Writes the composited frame straight into a BGRA CVPixelBuffer - the
    /// pixel buffer a LiveKit BufferCapturer publishes. The buffer must be
    /// kCVPixelFormatType_32BGRA at the render size; an IOSurface-backed one
    /// keeps the frame ready for a zero-copy encode.
    public func captureLiveFrame(session: GossSession?, into pixelBuffer: CVPixelBuffer) throws {
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let stride = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let tight = width * 4
        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }
        guard let base = CVPixelBufferGetBaseAddress(pixelBuffer) else { throw GossStatus.invalidArgument }
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        let dst = base.assumingMemoryBound(to: UInt8.self)
        // A tightly packed buffer takes the readback directly; a row-padded
        // one takes it through a scratch buffer copied in per row.
        if stride == tight {
            try checked(goss_engine_capture_live_frame(handle, session?.handle, GossPixelFormat.bgra8.rawValue, dst, stride * height, &outWidth, &outHeight))
            return
        }
        var scratch = [UInt8](repeating: 0, count: tight * height)
        try scratch.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_live_frame(handle, session?.handle, GossPixelFormat.bgra8.rawValue, buffer.baseAddress, buffer.count, &outWidth, &outHeight))
        }
        scratch.withUnsafeBufferPointer { buffer in
            for row in 0..<height {
                dst.advanced(by: row * stride).update(from: buffer.baseAddress! + row * tight, count: tight)
            }
        }
    }
}
