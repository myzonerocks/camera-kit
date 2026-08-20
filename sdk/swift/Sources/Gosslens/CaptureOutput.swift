import CGosslens

/// Pixel/screenshot readback, reached directly off Engine rather than
/// its own handle type.
extension Engine {
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
    public func captureFrame(session: Session?, width: UInt32, height: UInt32) throws -> (pixels: [UInt8], width: UInt32, height: UInt32) {
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
    public func capturePhoto(session: Session?) throws -> (png: [UInt8], width: UInt32, height: UInt32) {
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

    /// Captures the composited frame in a platform photo format. The
    /// PNG capturePhoto stays the deterministic surface.
    public func capturePhoto(session: Session?, as format: PhotoFormat, quality: UInt32 = 0) throws -> (data: [UInt8], width: UInt32, height: UInt32) {
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
    public func startRecording(session: Session, path: String, width: UInt32 = 0, height: UInt32 = 0, bitrate: UInt32 = 0, hevc: Bool = false) throws {
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
    public func submitAudio(session: Session, samples: [Float], frameCount: UInt32, sampleRate: UInt32, channels: UInt32, timestampUs: Int64) throws {
        try samples.withUnsafeBufferPointer { buffer in
            try checked(goss_session_submit_audio(session.handle, buffer.baseAddress, frameCount, sampleRate, channels, timestampUs))
        }
    }
}
