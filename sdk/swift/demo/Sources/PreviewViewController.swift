import AVFoundation
import Gosslens
import QuartzCore
import UIKit
import os

// A UIView whose backing layer is the CAMetalLayer the engine renders into.
final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class PreviewViewController: UIViewController {
    private let log = Logger(subsystem: "com.gosslens.demo", category: "preview")
    private let camera = CameraController()
    private let statusLabel = UILabel()
    private let switchCameraButton = UIButton(type: .system)
    private let beautyStack = UIStackView()
    private let faceLayer = CAShapeLayer()
    private let handLayer = CAShapeLayer()
    private let trackedFace = GossFaceResult()
    private let trackedHands = GossHandResult()
    private let trackedPose = GossPoseResult()
    private let poseLayer = CAShapeLayer()
    private var lastPoseSerial: UInt64 = 0
    private var lastFaceSerial: UInt64 = 0
    private var lastHandSerial: UInt64 = 0

    private var engine: GossEngine?
    private var session: GossSession?
    private var displayLink: CADisplayLink?

    private var renderedFrames = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var fpsWindowFrames = 0
    private var lastFrameStart = CFAbsoluteTimeGetCurrent()

    override func loadView() {
        view = MetalView()
        view.backgroundColor = .black
    }

    private var metalView: MetalView { view as! MetalView }

    override func viewDidLoad() {
        super.viewDidLoad()

        statusLabel.textColor = .white
        statusLabel.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        statusLabel.numberOfLines = 0
        statusLabel.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            statusLabel.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            statusLabel.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            statusLabel.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
        ])

        let version = Gosslens.abiVersion()
        log.info("goss abi \(version >> 16).\(version & 0xffff)")
        guard version >> 16 == 0 else {
            statusLabel.text = "abi major mismatch"
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        camera.onStateChange = { [weak self] state in
            self?.statusLabel.text = "capture \(state.rawValue)"
        }

        switchCameraButton.setImage(UIImage(systemName: "arrow.triangle.2.circlepath.camera"), for: .normal)
        switchCameraButton.tintColor = .white
        switchCameraButton.addTarget(self, action: #selector(switchCameraTapped), for: .touchUpInside)
        switchCameraButton.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(switchCameraButton)
        NSLayoutConstraint.activate([
            switchCameraButton.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            switchCameraButton.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 12),
            switchCameraButton.widthAnchor.constraint(equalToConstant: 44),
            switchCameraButton.heightAnchor.constraint(equalToConstant: 44),
        ])

        faceLayer.fillColor = UIColor.white.cgColor
        faceLayer.strokeColor = nil
        view.layer.addSublayer(faceLayer)

        handLayer.fillColor = UIColor.white.withAlphaComponent(0.8).cgColor
        handLayer.strokeColor = nil
        view.layer.addSublayer(handLayer)

        poseLayer.fillColor = UIColor.white.withAlphaComponent(0.6).cgColor
        poseLayer.strokeColor = nil
        view.layer.addSublayer(poseLayer)

        setupBeautyControls()
    }

    // Each slider reaches setBeauty directly; the effect shows up in the
    // live preview itself, composited on the render thread through the
    // GPU bridge (Metal write, gpupixel GL read, back out through
    // Metal) - no CPU round trip through beautifyFrame involved.
    private func setupBeautyControls() {
        beautyStack.axis = .vertical
        beautyStack.spacing = 8
        beautyStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(beautyStack)
        NSLayoutConstraint.activate([
            beautyStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            beautyStack.trailingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
            beautyStack.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor, constant: -12),
        ])
        for (index, name) in ["smooth", "whiten", "thin face", "big eye", "lipstick", "blush"].enumerated() {
            let label = UILabel()
            label.text = name
            label.textColor = .white
            label.font = .systemFont(ofSize: 12)
            label.widthAnchor.constraint(equalToConstant: 70).isActive = true

            let slider = UISlider()
            slider.minimumValue = 0
            slider.maximumValue = 1
            slider.tag = index
            slider.minimumTrackTintColor = .white
            slider.maximumTrackTintColor = UIColor.white.withAlphaComponent(0.3)
            slider.thumbTintColor = .white
            slider.addTarget(self, action: #selector(beautySliderChanged(_:)), for: .valueChanged)

            let row = UIStackView(arrangedSubviews: [label, slider])
            row.axis = .horizontal
            row.spacing = 8
            beautyStack.addArrangedSubview(row)
        }
    }

    @objc private func beautySliderChanged(_ slider: UISlider) {
        try? session?.setBeauty(effect: Int32(slider.tag), amount: slider.value)
    }

    @objc private func switchCameraTapped() {
        camera.switchCamera()
    }

    private var conformanceStarted = false

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.scale ?? 3.0
        let pixelWidth = UInt32(view.bounds.width * scale)
        let pixelHeight = UInt32(view.bounds.height * scale)
        metalView.metalLayer.contentsScale = scale
        metalView.metalLayer.drawableSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

        // The conformance run reuses this same real window/renderer
        // setup, just feeding a fixed corpus frame instead of live
        // camera - see ConformanceRunner. Own engine/session instances,
        // so the normal live-preview path below never starts.
        if CommandLine.arguments.contains("-GossConformance") {
            if !conformanceStarted, pixelWidth > 0 {
                conformanceStarted = true
                ConformanceRunner.run(metalLayer: metalView.metalLayer, width: pixelWidth, height: pixelHeight)
            }
            return
        }

        if engine == nil, pixelWidth > 0 {
            startEngine(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        } else if let engine {
            engine.resize(width: pixelWidth, height: pixelHeight)
        }
    }

    private func startEngine(pixelWidth: UInt32, pixelHeight: UInt32) {
        guard let newEngine = try? GossEngine.create() else {
            statusLabel.text = "engine create failed"
            return
        }
        engine = newEngine

        do {
            try newEngine.initRenderer(surface: Unmanaged.passUnretained(metalView.metalLayer).toOpaque(), width: pixelWidth, height: pixelHeight)
        } catch {
            statusLabel.text = "renderer init failed"
            log.error("renderer init failed")
            return
        }

        guard let newSession = try? GossSession.create(engine: newEngine) else {
            statusLabel.text = "session create failed"
            return
        }
        session = newSession

        camera.start(session: newSession)

        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderTick() {
        guard let engine, let session else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let frameTimeUs = UInt32(max(0, (start - lastFrameStart) * 1_000_000))
        lastFrameStart = start

        session.reportFrame(frameTimeUs: frameTimeUs, thermal: ProcessInfo.processInfo.thermalState.gossThermal)
        drawFaceOverlay()
        drawHandOverlay()
        drawPoseOverlay()
        tickLens(dtUs: frameTimeUs)
        guard (try? engine.renderFrame(session: session)) != nil else { return }
        renderedFrames += 1
        fpsWindowFrames += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsWindowStart >= 2.0 {
            let fps = Double(fpsWindowFrames) / (now - fpsWindowStart)
            log.info("fps \(String(format: "%.1f", fps)) rendered \(self.renderedFrames) submitted \(self.camera.submittedFrames) state \(self.camera.state.rawValue)")
            statusLabel.text = String(format: "capture %@  %.1f fps", camera.state.rawValue, fps)
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
    }

    /// Landmarks arrive in sensor pixels; the sensor sits one quarter turn
    /// from portrait, the same turn the preview applies.
    private func drawFaceOverlay() {
        guard let session, (try? session.faceResult(trackedFace)) != nil else { return }
        guard trackedFace.frameSerial != lastFaceSerial else { return }
        lastFaceSerial = trackedFace.frameSerial
        guard trackedFace.landmarkCount > 0, trackedFace.presence >= 0.5 else {
            faceLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for index in 0 ..< trackedFace.landmarkCount {
            let x = CGFloat(trackedFace.landmarks[index * 3])
            let y = CGFloat(trackedFace.landmarks[index * 3 + 1])
            // Quarter turn: sensor x runs down the portrait screen. The
            // front camera's preview is mirrored for a selfie view, so
            // the overlay's horizontal axis mirrors along with it.
            var viewX = (sensorHeight - y) * scaleX
            if camera.mirrored {
                viewX = bounds.width - viewX
            }
            let viewY = x * scaleY
            path.addEllipse(in: CGRect(x: viewX - 1.5, y: viewY - 1.5, width: 3, height: 3))
        }
        faceLayer.path = path
    }

    /// The same sensor-to-screen mapping the face overlay uses; hands
    /// ride the same camera pose.
    private func drawHandOverlay() {
        guard let session, (try? session.handResult(trackedHands)) != nil else { return }
        guard trackedHands.frameSerial != lastHandSerial else { return }
        lastHandSerial = trackedHands.frameSerial
        guard trackedHands.handCount > 0 else {
            handLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for handAt in 0 ..< trackedHands.handCount {
            let base = handAt * GossHandResult.landmarkCount * 3
            for point in 0 ..< GossHandResult.landmarkCount {
                let x = CGFloat(trackedHands.landmarks[base + point * 3])
                let y = CGFloat(trackedHands.landmarks[base + point * 3 + 1])
                var viewX = (sensorHeight - y) * scaleX
                if camera.mirrored {
                    viewX = bounds.width - viewX
                }
                let viewY = x * scaleY
                path.addEllipse(in: CGRect(x: viewX - 2, y: viewY - 2, width: 4, height: 4))
            }
        }
        handLayer.path = path
    }

    /// The same sensor-to-screen mapping as the other overlays; only
    /// confidently visible joints draw.
    private func drawPoseOverlay() {
        guard let session, (try? session.poseResult(trackedPose)) != nil else { return }
        guard trackedPose.frameSerial != lastPoseSerial else { return }
        lastPoseSerial = trackedPose.frameSerial
        guard trackedPose.landmarkCount > 0, trackedPose.presence >= 0.5 else {
            poseLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for point in 0 ..< trackedPose.landmarkCount {
            guard trackedPose.visibilities[point] >= 0.5 else { continue }
            let x = CGFloat(trackedPose.landmarks[point * 3])
            let y = CGFloat(trackedPose.landmarks[point * 3 + 1])
            var viewX = (sensorHeight - y) * scaleX
            if camera.mirrored {
                viewX = bounds.width - viewX
            }
            let viewY = x * scaleY
            path.addEllipse(in: CGRect(x: viewX - 3, y: viewY - 3, width: 6, height: 6))
        }
        poseLayer.path = path
    }

    /// Rides the same result drawFaceOverlay just refreshed - ticking
    /// every render frame regardless of whether that particular result
    /// was new keeps the lens's own animation ramps advancing smoothly
    /// at display refresh rate rather than at tracking cadence.
    private func tickLens(dtUs: UInt32) {
        guard let session else { return }
        let signals = GossLensSignals(
            hasFace: trackedFace.presence >= 0.5 && trackedFace.landmarkCount > 0,
            handsPresent: trackedHands.handCount > 0,
            blendshapes: trackedFace.blendshapes
        )
        try? session.tickLens(dtUs: dtUs, signals: signals)
    }

    @objc private func appDidEnterBackground() {
        displayLink?.isPaused = true
        camera.stop()
    }

    @objc private func appWillEnterForeground() {
        displayLink?.isPaused = false
        camera.start(session: session)
    }
}

private extension ProcessInfo.ThermalState {
    var gossThermal: GossThermal {
        switch self {
        case .nominal: return .nominal
        case .fair: return .fair
        case .serious: return .serious
        case .critical: return .critical
        @unknown default: return .critical
        }
    }
}
