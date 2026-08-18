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
    /// and reads the composited output back as RGBA8, row 0 first.
    public func captureFrame(session: Session?, width: UInt32, height: UInt32) throws -> [UInt8] {
        var data = [UInt8](repeating: 0, count: Int(width) * Int(height) * 4)
        var outWidth: UInt32 = 0
        var outHeight: UInt32 = 0
        try data.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_engine_capture_frame(handle, session?.handle, buffer.baseAddress, buffer.count, &outWidth, &outHeight))
        }
        return data
    }
}
