import CGosslens
import Foundation

/// Whole-pipeline frame budget; zero means the built-in default (30 fps).
public struct SessionConfig {
    public var frameBudgetUs: UInt32

    public init(frameBudgetUs: UInt32 = 0) {
        self.frameBudgetUs = frameBudgetUs
    }
}

private func frameDesc(width: UInt32, height: UInt32, pixelFormat: UInt32, colorStandard: UInt32, colorRange: UInt32, rotationDegrees: UInt32, mirrored: Bool, timestampUs: Int64) -> goss_frame_desc {
    var flags = (rotationDegrees / 90) << GOSS_FRAME_ROTATION_SHIFT
    if mirrored { flags |= GOSS_FRAME_FLAG_MIRROR }
    return goss_frame_desc(
        width: width, height: height,
        pixel_format: pixelFormat, color_standard: colorStandard, color_range: colorRange,
        flags: flags, timestamp_us: timestampUs
    )
}

/// Per-preview runtime: frame submission, beauty, tracking, segmentation,
/// telemetry. Confined to the graph thread, same as Engine - unchecked
/// for the same reason (see Engine's own note).
public final class Session: @unchecked Sendable {
    let handle: OpaquePointer
    private var destroyed = false

    public static func create(engine: Engine, config: SessionConfig = SessionConfig()) throws -> Session {
        var raw = goss_session_config(frame_budget_us: config.frameBudgetUs, reserved: 0)
        var handle: OpaquePointer?
        try checked(goss_session_create(engine.handle, &raw, &handle))
        guard let handle else { throw GossStatus.outOfMemory }
        return Session(handle: handle)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if !destroyed { goss_session_destroy(handle) }
    }

    /// Safe to call more than once; only the first call reaches the ABI -
    /// deinit falls back to this same destroy for callers who never call
    /// it explicitly, and must not double-free a handle this already did.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        goss_session_destroy(handle)
    }

    // MARK: - Frame submission

    /// Zero-copy: hands over up to three platform texture handles
    /// (MTLTexture and friends) as opaque pointer-sized values. The
    /// platform object must outlive the next rendered frame.
    public func submitFrame(planes: [UInt64], width: UInt32, height: UInt32, pixelFormat: UInt32, colorStandard: UInt32 = GOSS_COLOR_BT709.rawValue, colorRange: UInt32 = GOSS_COLOR_RANGE_VIDEO.rawValue, rotationDegrees: UInt32, mirrored: Bool, timestampUs: Int64) throws {
        var desc = frameDesc(width: width, height: height, pixelFormat: pixelFormat, colorStandard: colorStandard, colorRange: colorRange, rotationDegrees: rotationDegrees, mirrored: mirrored, timestampUs: timestampUs)
        let padded = planes + Array(repeating: UInt64(0), count: max(0, 3 - planes.count))
        var framePlanes = goss_frame_planes(plane_count: UInt32(planes.count), reserved: 0, planes: (padded[0], padded[1], padded[2]))
        try checked(goss_session_submit_frame(handle, &desc, &framePlanes))
    }

    /// The CPU-copy path: copies NV12 planes into pooled textures.
    /// colorStandard/colorRange default to the common camera case
    /// (BT.709, video range); a debug/test corpus decoded at a
    /// different standard passes its own.
    public func submitFrameCopy(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, rotationDegrees: UInt32, mirrored: Bool, timestampUs: Int64, colorStandard: UInt32 = GOSS_COLOR_BT709.rawValue, colorRange: UInt32 = GOSS_COLOR_RANGE_VIDEO.rawValue) throws {
        var desc = frameDesc(width: width, height: height, pixelFormat: GOSS_PIXEL_NV12.rawValue, colorStandard: colorStandard, colorRange: colorRange, rotationDegrees: rotationDegrees, mirrored: mirrored, timestampUs: timestampUs)
        try checked(goss_session_submit_frame_copy(handle, &desc, y, yStride, uv, uvStride))
    }

    /// Zero-copy submission of a platform hardware buffer (AHardwareBuffer,
    /// Android only). Any thrown status means this stream should fall back
    /// to submitFrameCopy.
    public func submitHardwareBuffer(_ buffer: UnsafeMutableRawPointer, width: UInt32, height: UInt32, rotationDegrees: UInt32, mirrored: Bool, timestampUs: Int64) throws {
        var desc = frameDesc(width: width, height: height, pixelFormat: GOSS_PIXEL_NV12.rawValue, colorStandard: GOSS_COLOR_BT709.rawValue, colorRange: GOSS_COLOR_RANGE_VIDEO.rawValue, rotationDegrees: rotationDegrees, mirrored: mirrored, timestampUs: timestampUs)
        try checked(goss_session_submit_hardware_buffer(handle, &desc, buffer))
    }

    /// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a canvas
    /// or video element's own byte buffer.
    public func submitFrameRgbaCopy(rgba: UnsafePointer<UInt8>, width: UInt32, height: UInt32, stride: UInt32, mirrored: Bool, pixelFormat: UInt32 = GOSS_PIXEL_RGBA8.rawValue, timestampUs: Int64 = 0) throws {
        var desc = frameDesc(width: width, height: height, pixelFormat: pixelFormat, colorStandard: GOSS_COLOR_BT709.rawValue, colorRange: GOSS_COLOR_RANGE_VIDEO.rawValue, rotationDegrees: 0, mirrored: mirrored, timestampUs: timestampUs)
        try checked(goss_session_submit_frame_rgba_copy(handle, &desc, rgba, stride))
    }

    // MARK: - Telemetry

    /// Reports one finished frame: measured whole-pipeline time plus
    /// current thermal pressure. Returns the degradation level in
    /// effect for the next frame.
    @discardableResult
    public func reportFrame(frameTimeUs: UInt32, thermal: goss_thermal) -> goss_degrade_level {
        goss_session_report_frame(handle, frameTimeUs, thermal)
    }

    // MARK: - Face tracking

    public func enableFaceTracking(taskBundle: Data, threads: Int32) throws {
        try taskBundle.withUnsafeBytes { buffer in
            try checked(goss_session_enable_face_tracking(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disableFaceTracking() {
        goss_session_disable_face_tracking(handle)
    }

    public func trackFrame(y: UnsafePointer<UInt8>, yStride: UInt32, uv: UnsafePointer<UInt8>, uvStride: UInt32, width: UInt32, height: UInt32, timestampUs: Int64) throws {
        var desc = frameDesc(width: width, height: height, pixelFormat: GOSS_PIXEL_NV12.rawValue, colorStandard: GOSS_COLOR_BT709.rawValue, colorRange: GOSS_COLOR_RANGE_VIDEO.rawValue, rotationDegrees: 0, mirrored: false, timestampUs: timestampUs)
        try checked(goss_session_track_frame(handle, &desc, y, yStride, uv, uvStride))
    }

    public func setFaceLandmarks(points: [Float]) throws {
        try points.withUnsafeBufferPointer { buffer in
            try checked(goss_session_set_face_landmarks(handle, buffer.baseAddress, UInt32(points.count / 3)))
        }
    }

    // MARK: - Segmentation

    public func enableSegmentation(modelBytes: Data, threads: Int32) throws {
        try modelBytes.withUnsafeBytes { buffer in
            try checked(goss_session_enable_segmentation(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count, threads))
        }
    }

    public func disableSegmentation() {
        goss_session_disable_segmentation(handle)
    }

    // MARK: - Beauty

    public func enableBeauty(resourceDir: String) throws {
        try checked(goss_session_enable_beauty(handle, resourceDir))
    }

    public func disableBeauty() {
        goss_session_disable_beauty(handle)
    }

    public func setBeauty(effect: Int32, amount: Float) throws {
        try checked(goss_session_set_beauty(handle, effect, amount))
    }

    public func setWhiten(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_WHITEN, amount: amount) }
    public func setSmooth(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_SMOOTH, amount: amount) }
    public func setThinFace(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_THIN_FACE, amount: amount) }
    public func setBigEye(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_BIG_EYE, amount: amount) }
    public func setLipstick(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_LIPSTICK, amount: amount) }
    public func setBlush(_ amount: Float) throws { try setBeauty(effect: GOSS_BEAUTY_BLUSH, amount: amount) }

    /// Web only; throws .unsupported on every other target.
    public func setBeautyLut(slot: Int32, rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try checked(goss_session_set_beauty_lut(handle, slot, rgba, width, height))
    }

    /// Web only; throws .unsupported on every other target.
    public func setBeautyMakeupTexture(effect: Int32, rgba: [UInt8], width: UInt32, height: UInt32) throws {
        try checked(goss_session_set_beauty_makeup_texture(handle, effect, rgba, width, height))
    }

    public func beautifyFrame(rgbaIn: [UInt8], width: UInt32, height: UInt32) throws -> [UInt8] {
        var rgbaOut = [UInt8](repeating: 0, count: rgbaIn.count)
        try checked(goss_session_beautify_frame(handle, rgbaIn, width, height, &rgbaOut))
        return rgbaOut
    }
}
