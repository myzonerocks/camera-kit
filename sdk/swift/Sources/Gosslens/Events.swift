import CGosslens

/// One face tracking result. landmarks holds landmarkCount * 3 floats
/// (x, y in frame pixels, z in the same scale); blendshapes holds 52
/// scores in zero to one. An empty landmarks means no face this frame.
public struct FaceResult {
    public var frameSerial: UInt64
    public var timestampUs: Int64
    public var presence: Float
    public var landmarks: [Float]
    public var blendshapes: [Float]

    init(_ raw: goss_face_result) {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        presence = raw.presence
        let count = Int(raw.landmark_count) * 3
        landmarks = withUnsafeBytes(of: raw.landmarks) { buffer in
            Array(buffer.bindMemory(to: Float.self).prefix(count))
        }
        blendshapes = withUnsafeBytes(of: raw.blendshapes) { buffer in
            Array(buffer.bindMemory(to: Float.self))
        }
    }
}

/// Tracking/telemetry readouts, reached directly off Session rather
/// than their own handle type.
extension Session {
    /// Reads the newest tracking result. Throws .again until the
    /// tracking worker has published its first result.
    public func faceResult() throws -> FaceResult {
        var result = goss_face_result()
        try checked(goss_session_face_result(handle, &result))
        return FaceResult(result)
    }

    /// The degradation level currently in effect.
    public func degradeLevel() -> goss_degrade_level {
        goss_session_degrade_level(handle)
    }
}
