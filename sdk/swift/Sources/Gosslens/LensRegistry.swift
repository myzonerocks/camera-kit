import CGosslens
import Foundation

/// The live signals goss_session_tick_lens evaluates a lens's compiled
/// triggers against. hasFace false means every face-driven signal reads
/// as false regardless of what blendshapes holds.
public struct LensSignals {
    public var hasFace: Bool
    public var handsPresent: Bool
    public var tap: Bool
    public var worldTrackingState: Double
    public var audioLevel: Double
    public var blendshapes: [Float]

    public init(hasFace: Bool = false, handsPresent: Bool = false, tap: Bool = false, worldTrackingState: Double = 0, audioLevel: Double = 0, blendshapes: [Float] = []) {
        self.hasFace = hasFace
        self.handsPresent = handsPresent
        self.tap = tap
        self.worldTrackingState = worldTrackingState
        self.audioLevel = audioLevel
        self.blendshapes = blendshapes
    }

    func withRaw<R>(_ body: (inout goss_lens_signals) throws -> R) rethrows -> R {
        var raw = goss_lens_signals()
        raw.has_face = hasFace
        raw.hands_present = handsPresent
        raw.tap = tap
        raw.world_tracking_state = worldTrackingState
        raw.audio_level = audioLevel
        withUnsafeMutableBytes(of: &raw.blendshapes) { dest in
            let floats = dest.bindMemory(to: Float.self)
            for i in 0..<min(floats.count, blendshapes.count) {
                floats[i] = blendshapes[i]
            }
        }
        return try body(&raw)
    }
}

/// Lens lifecycle, reached directly off Session rather than its own
/// handle type.
extension Session {
    /// Replaces any currently active lens with the one manifestJson
    /// describes, and applies its default effect values to the beauty
    /// chain if one is enabled.
    public func activateLens(manifestJson: Data) throws {
        try manifestJson.withUnsafeBytes { buffer in
            try checked(goss_session_activate_lens(handle, buffer.bindMemory(to: UInt8.self).baseAddress, buffer.count))
        }
    }

    /// Same activation activateLens performs, from
    /// bundlePath/manifest.json, plus compiling a program for every
    /// shader.pass node the lens splices.
    public func activateLensFromDirectory(bundlePath: String) throws {
        let bytes = Array(bundlePath.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_session_activate_lens_from_directory(handle, buffer.baseAddress, buffer.count))
        }
    }

    /// Unsplices the active lens. Accepts no active lens and does
    /// nothing.
    public func deactivateLens() {
        goss_session_deactivate_lens(handle)
    }

    /// Advances the active lens by dtUs of real time, applying every
    /// effect value its triggers change to the beauty chain. Throws
    /// .again with no active lens.
    public func tickLens(dtUs: UInt32, signals: LensSignals) throws {
        try signals.withRaw { raw in
            try checked(goss_session_tick_lens(handle, dtUs, &raw))
        }
    }
}
