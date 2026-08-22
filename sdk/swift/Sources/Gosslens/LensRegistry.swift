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

    /// Stores validated camera-hardware intent on the session; the engine
    /// normalizes every field. Read it back with `cameraControls` and apply it
    /// to the platform camera - the engine never touches camera hardware.
    public func setCameraControls(_ controls: goss_camera_controls) throws {
        var c = controls
        try checked(goss_session_set_camera_controls(handle, &c))
    }

    /// The normalized camera controls for the SDK to apply to the platform camera.
    public var cameraControls: goss_camera_controls {
        get throws {
            var out = goss_camera_controls()
            try checked(goss_session_camera_controls(handle, &out))
            return out
        }
    }

    /// Fires a named event the next `tickLens` delivers to the lens's
    /// `event('name')` triggers for one tick. Drive an on-screen effect from an
    /// app moment; the engine knows the name, never its meaning.
    public func fireEvent(_ name: String) throws {
        var bytes = Array(name.utf8)
        try bytes.withUnsafeMutableBufferPointer { buf in
            try checked(goss_session_fire_event(handle, buf.baseAddress, buf.count))
        }
    }

    /// Registers a named RGBA source for multi-source composition (Duet, Stitch,
    /// live grids). The camera is the implicit source 0.
    public func defineSource(_ name: String) throws {
        var b = Array(name.utf8)
        try b.withUnsafeMutableBufferPointer { buf in
            try checked(goss_session_define_source(handle, buf.baseAddress, buf.count))
        }
    }

    public func removeSource(_ name: String) throws {
        var b = Array(name.utf8)
        try b.withUnsafeMutableBufferPointer { buf in
            try checked(goss_session_remove_source(handle, buf.baseAddress, buf.count))
        }
    }

    /// Uploads one RGBA/BGRA frame into a named source (pixelFormat 3 BGRA, 4 RGBA).
    public func submitSourceFrame(_ name: String, rgba: [UInt8], width: UInt32, height: UInt32, stride: UInt32, pixelFormat: UInt32 = 4) throws {
        var nameBytes = Array(name.utf8)
        var desc = goss_frame_desc(width: width, height: height, pixel_format: pixelFormat, color_standard: 0, color_range: 1, flags: 0, timestamp_us: 0)
        try nameBytes.withUnsafeMutableBufferPointer { nb in
            try rgba.withUnsafeBufferPointer { rb in
                try checked(goss_session_submit_source_frame_rgba_copy(handle, nb.baseAddress, nb.count, &desc, rb.baseAddress, stride))
            }
        }
    }

    /// Arranges the camera and named sources: 0 custom, 1 side-by-side, 2 top-bottom, 3 pip, 4 grid.
    public func setLayout(_ arrangement: UInt32) throws {
        try checked(goss_session_set_layout(handle, arrangement))
    }

    public func clearLayout() throws {
        try checked(goss_session_clear_layout(handle))
    }

    /// Feeds a location fix for on-device geo.in_region membership; the location never leaves the engine.
    public func submitLocation(latitude: Double, longitude: Double, accuracyM: Float, timestampUs: Int64) throws {
        try checked(goss_session_submit_location(handle, latitude, longitude, accuracyM, timestampUs))
    }

    /// Sets the geofence circle the app derives from a lens's intended place.
    public func setGeofence(latitude: Double, longitude: Double, radiusM: Double) throws {
        try checked(goss_session_set_geofence(handle, latitude, longitude, radiusM))
    }

    public func clearGeofence() throws {
        try checked(goss_session_clear_geofence(handle))
    }
}
