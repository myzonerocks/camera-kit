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

/// A canned gesture class, in the classifier's own label order. none is
/// also what a bundle without gesture models reports.
public enum Gesture: UInt32 {
    case none = 0
    case closedFist = 1
    case openPalm = 2
    case pointingUp = 3
    case thumbDown = 4
    case thumbUp = 5
    case victory = 6
    case iLoveYou = 7
}

/// One reusable hand tracking readout, up to two hands per frame.
/// handedness is the model's score that the hand is a right hand; hand
/// h's point p sits at (h * landmarkCount + p) * 3 in landmarks.
public final class HandResult {
    public static let landmarkCount = Int(GOSS_HAND_LANDMARK_COUNT)
    public static let maxHands = Int(GOSS_HAND_MAX)

    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var handCount: Int = 0
    public private(set) var presences: [Float]
    public private(set) var handednesses: [Float]
    public private(set) var gestures: [Gesture]
    public private(set) var gestureScores: [Float]
    public private(set) var landmarks: [Float]

    var raw = goss_hand_result()

    public init() {
        presences = [Float](repeating: 0, count: Self.maxHands)
        handednesses = [Float](repeating: 0, count: Self.maxHands)
        gestures = [Gesture](repeating: .none, count: Self.maxHands)
        gestureScores = [Float](repeating: 0, count: Self.maxHands)
        landmarks = [Float](repeating: 0, count: Self.maxHands * Self.landmarkCount * 3)
    }

    /// Lifts raw's fields into the preallocated arrays - no per-frame
    /// allocation as long as the caller reuses one instance.
    func parse() {
        frameSerial = raw.frame_serial
        timestampUs = raw.timestamp_us
        handCount = Int(raw.hand_count)
        let landmark_floats = Self.landmarkCount * 3
        withUnsafeBytes(of: raw.hands) { source in
            for at in 0 ..< Self.maxHands {
                let base = at * MemoryLayout<goss_hand>.stride
                presences[at] = source.loadUnaligned(fromByteOffset: base, as: Float.self)
                handednesses[at] = source.loadUnaligned(fromByteOffset: base + 4, as: Float.self)
                gestures[at] = Gesture(rawValue: source.loadUnaligned(fromByteOffset: base + 8, as: UInt32.self)) ?? .none
                gestureScores[at] = source.loadUnaligned(fromByteOffset: base + 12, as: Float.self)
                landmarks.withUnsafeMutableBytes { dest in
                    dest.baseAddress!.advanced(by: at * landmark_floats * 4)
                        .copyMemory(from: source.baseAddress!.advanced(by: base + 16), byteCount: landmark_floats * 4)
                }
            }
        }
    }
}

/// One reusable pose tracking readout: a 33-point skeleton with
/// per-point visibility and presence scores.
public final class PoseResult {
    public static let landmarkCount = Int(GOSS_POSE_LANDMARK_COUNT)

    public private(set) var frameSerial: UInt64 = 0
    public private(set) var timestampUs: Int64 = 0
    public private(set) var presence: Float = 0
    public private(set) var landmarkCount: Int = 0
    public private(set) var landmarks: [Float]
    public private(set) var visibilities: [Float]
    public private(set) var presences: [Float]

    var raw = goss_pose_result()

    public init() {
        landmarks = [Float](repeating: 0, count: Self.landmarkCount * 3)
        visibilities = [Float](repeating: 0, count: Self.landmarkCount)
        presences = [Float](repeating: 0, count: Self.landmarkCount)
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
        withUnsafeBytes(of: raw.visibilities) { source in
            visibilities.withUnsafeMutableBytes { $0.copyMemory(from: source) }
        }
        withUnsafeBytes(of: raw.presences) { source in
            presences.withUnsafeMutableBytes { $0.copyMemory(from: source) }
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

    /// Fills result with the newest hand tracking output. Throws .again
    /// until the hand worker has published its first result.
    public func handResult(_ result: HandResult) throws {
        try checked(goss_session_hand_result(handle, &result.raw))
        result.parse()
    }

    /// Fills result with the newest pose tracking output. Throws .again
    /// until the pose worker has published its first result.
    public func poseResult(_ result: PoseResult) throws {
        try checked(goss_session_pose_result(handle, &result.raw))
        result.parse()
    }

    /// Fills matrix with the column-major head transform - canonical
    /// metric space into frame pixels. Throws .again until a face is
    /// tracked; matrix must hold at least sixteen floats.
    public func facePose(_ matrix: inout [Float]) throws {
        precondition(matrix.count >= 16)
        try matrix.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_face_pose(handle, buffer.baseAddress))
        }
    }

    /// The degradation level currently in effect.
    public func degradeLevel() -> DegradeLevel {
        DegradeLevel(rawValue: goss_session_degrade_level(handle).rawValue) ?? .passthrough
    }
}
