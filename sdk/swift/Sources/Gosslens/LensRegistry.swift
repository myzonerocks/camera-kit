import CGosslens
import Foundation

/// The live signals goss_session_tick_lens evaluates a lens's compiled
/// triggers against. hasFace false means every face-driven signal reads
/// as false regardless of what blendshapes holds.
public struct GossLensSignals {
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

/// Lens lifecycle, reached directly off GossSession rather than its own
/// handle type.
extension GossSession {
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
    public func tickLens(dtUs: UInt32, signals: GossLensSignals) throws {
        try signals.withRaw { raw in
            try checked(goss_session_tick_lens(handle, dtUs, &raw))
        }
    }

    /// Reads a live parameter of the active lens by name, including whatever
    /// a script node last wrote. Throws .again with no active lens.
    public func parameterValue(_ name: String) throws -> Float {
        var value: Float = 0
        let bytes = Array(name.utf8)
        try bytes.withUnsafeBufferPointer { buffer in
            try checked(goss_session_parameter_value(handle, buffer.baseAddress, buffer.count, &value))
        }
        return value
    }

    /// Pulls the next block of mixed lens audio (frames interleaved s16) that
    /// play_sound triggers produced, for the app to route to platform audio.
    public func pullAudio(into out: inout [Int16], frames: UInt32) throws {
        try out.withUnsafeMutableBufferPointer { buffer in
            try checked(goss_session_pull_audio(handle, buffer.baseAddress, frames))
        }
    }

    /// Folds the active lens sound into the caller's outgoing call/live track:
    /// `mic` (interleaved f32 at `sampleRate`/`channels`, or nil for silence)
    /// summed with the 48 kHz mono lens mixer resampled to that rate; returns
    /// the mixed interleaved s16. Advances the mixer once, replacing `pullAudio`.
    public func mixOutputAudio(mic: [Float]?, frameCount: UInt32, sampleRate: UInt32, channels: UInt32) throws -> [Int16] {
        var out = [Int16](repeating: 0, count: Int(frameCount) * Int(channels))
        try out.withUnsafeMutableBufferPointer { outBuffer in
            if let mic = mic {
                try mic.withUnsafeBufferPointer { micBuffer in
                    try checked(goss_session_mix_output_audio(handle, micBuffer.baseAddress, outBuffer.baseAddress, frameCount, sampleRate, channels))
                }
            } else {
                try checked(goss_session_mix_output_audio(handle, nil, outBuffer.baseAddress, frameCount, sampleRate, channels))
            }
        }
        return out
    }
}
