import CGosslens

/// One reusable tracking readout. landmarks holds landmarkCount * 3
/// valid floats (x, y in frame pixels, z in the same scale); blendshapes
/// holds 52 scores in zero to one. landmarkCount zero means no face.
public final class FaceResult {
    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var presence: Float = 0
    public private(set) var landmarkCount: Int = 0
    public private(set) var landmarks: [Float]
    public private(set) var blendshapes: [Float]

    var raw = goss_face_result()

    public init() {
        landmarks = [Float](repeating: 0, count: Int(GOSS_FACE_LANDMARK_COUNT) * 3)
        blendshapes = [Float](repeating: 0, count: Int(GOSS_FACE_BLENDSHAPE_COUNT))
    }

    /// Lifts raw's fields into the preallocated arrays - no per-frame
    /// allocation as long as the caller reuses one instance.
    func parse() {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        presence = raw.presence
        landmarkCount = Int(raw.landmark_count)
        withUnsafeBytes(of: raw.landmarks) { source in
            landmarks.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
        withUnsafeBytes(of: raw.blendshapes) { source in
            blendshapes.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
    }
}

/// Tracking/telemetry readouts, reached directly off Session rather
/// than their own handle type.
extension Session {
    /// Fills result with the newest tracking output. Throws .again until
    /// the tracking worker has published its first result.
    public func faceResult(_ result: FaceResult) throws {
        try checked(goss_session_face_result(handle, &result.raw))
        result.parse()
    }

    /// The degradation level currently in effect.
    public func degradeLevel() -> DegradeLevel {
        DegradeLevel(rawValue: goss_session_degrade_level(handle).rawValue) ?? .passthrough
    }
}
