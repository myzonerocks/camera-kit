#if canImport(ARKit) && os(iOS)
import ARKit
import CGosslens

/// Feeds ARKit's world understanding into the engine: camera pose and
/// projection, plane anchors, world anchors, and the light estimate,
/// one submit per rendered AR frame.
public final class GossWorldSource: NSObject, ARSessionDelegate {
    private let arSession = ARSession()
    private weak var engineSession: GossSession?
    private var planes: [goss_world_plane] = []
    private var anchors: [goss_world_anchor] = []

    public init(session: GossSession) {
        self.engineSession = session
        super.init()
        arSession.delegate = self
    }

    /// Starts world tracking with plane detection; the caller owns
    /// camera capture separately, this source only tracks.
    public func start() {
        let configuration = ARWorldTrackingConfiguration()
        configuration.planeDetection = [.horizontal, .vertical]
        configuration.isLightEstimationEnabled = true
        arSession.run(configuration)
    }

    public func pause() {
        arSession.pause()
    }

    public func session(_ session: ARSession, didUpdate frame: ARFrame) {
        guard let engine = engineSession else { return }

        var state = goss_world_state()
        state.tracking_state = trackingState(frame.camera.trackingState)
        state.timestamp_us = Int64(frame.timestamp * 1_000_000)
        copyColumns(frame.camera.transform, into: &state.world_from_camera)
        copyColumns(frame.camera.projectionMatrix(for: .portrait, viewportSize: CGSize(width: 1080, height: 1920), zNear: 0.1, zFar: 100), into: &state.projection)

        planes.removeAll(keepingCapacity: true)
        anchors.removeAll(keepingCapacity: true)
        for anchor in frame.anchors {
            if let plane = anchor as? ARPlaneAnchor {
                var out = goss_world_plane()
                out.id = UInt64(bitPattern: Int64(anchor.identifier.hashValue))
                copyColumns(plane.transform, into: &out.pose)
                out.extent_x = plane.planeExtent.width
                out.extent_z = plane.planeExtent.height
                out.classification = planeClass(plane.classification)
                planes.append(out)
            } else {
                var out = goss_world_anchor()
                out.id = UInt64(bitPattern: Int64(anchor.identifier.hashValue))
                copyColumns(anchor.transform, into: &out.pose)
                anchors.append(out)
            }
        }

        var light = goss_world_light()
        if let estimate = frame.lightEstimate {
            light.ambient_intensity = Float(estimate.ambientIntensity / 1000.0)
            light.color_temperature_kelvin = Float(estimate.ambientColorTemperature)
        }

        planes.withUnsafeBufferPointer { planeBuffer in
            anchors.withUnsafeBufferPointer { anchorBuffer in
                _ = goss_session_submit_world(engine.handle, &state, planeBuffer.baseAddress, planeBuffer.count, anchorBuffer.baseAddress, anchorBuffer.count, &light)
            }
        }
    }

    private func trackingState(_ state: ARCamera.TrackingState) -> UInt32 {
        switch state {
        case .normal: return 2
        case .limited: return 3
        case .notAvailable: return 0
        }
    }

    private func planeClass(_ classification: ARPlaneAnchor.Classification) -> UInt32 {
        switch classification {
        case .floor: return 1
        case .wall: return 2
        case .ceiling: return 3
        case .table: return 4
        default: return 0
        }
    }

    private func copyColumns<T>(_ matrix: simd_float4x4, into out: inout T) {
        withUnsafeMutableBytes(of: &out) { raw in
            var flat: [Float] = []
            flat.reserveCapacity(16)
            for column in [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3] {
                flat.append(contentsOf: [column.x, column.y, column.z, column.w])
            }
            raw.copyBytes(from: flat.withUnsafeBytes { $0 })
        }
    }
}

#endif
