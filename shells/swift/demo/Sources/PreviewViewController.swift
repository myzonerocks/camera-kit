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
    private let beautyStack = UIStackView()
    private let faceLayer = CAShapeLayer()
    private var lastFaceResult: FaceResult?
    private var lastFaceSerial: UInt64 = 0

    private var engine: Engine?
    private var session: Session?
    private var displayLink: CADisplayLink?

    private var renderedFrames = 0
    private var fpsWindowStart = CFAbsoluteTimeGetCurrent()
    private var fpsWindowFrames = 0
    private var lastFrameStart = CFAbsoluteTimeGetCurrent()
    private var proofLogged = false

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

        faceLayer.fillColor = UIColor.white.cgColor
        faceLayer.strokeColor = nil
        view.layer.addSublayer(faceLayer)

        setupBeautyControls()
    }

    // Each slider reaches setBeauty directly; the effect shows up in the
    // live preview itself, composited on the render thread through the
    // GPU bridge (Metal write, gpupixel GL read, back out through
    // Metal) - no CPU round trip through beautifyFrame involved.
    private func setupBeautyControls() {
        beautyStack.axis = .vertical
        beautyStack.spacing = 4
        beautyStack.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(beautyStack)
        NSLayoutConstraint.activate([
            beautyStack.leadingAnchor.constraint(equalTo: view.safeAreaLayoutGuide.leadingAnchor, constant: 12),
            beautyStack.trailingAnchor.constraint(lessThanOrEqualTo: view.safeAreaLayoutGuide.trailingAnchor, constant: -12),
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
        guard let newEngine = try? Engine.create() else {
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

        guard let newSession = try? Session.create(engine: newEngine) else {
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

        session.reportFrame(frameTimeUs: frameTimeUs, thermal: goss_thermal(rawValue: UInt32(ProcessInfo.processInfo.thermalState.ckThermal)))
        drawFaceOverlay()
        tickLens(dtUs: frameTimeUs)
        guard (try? engine.renderFrame(session: session)) != nil else { return }
        renderedFrames += 1
        fpsWindowFrames += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsWindowStart >= 2.0 {
            let fps = Double(fpsWindowFrames) / (now - fpsWindowStart)
            log.info("GOSSDEMO fps \(String(format: "%.1f", fps)) rendered \(self.renderedFrames) submitted \(self.camera.submittedFrames) state \(self.camera.state.rawValue)")
            statusLabel.text = String(format: "capture %@  %.1f fps", camera.state.rawValue, fps)
            if !proofLogged, camera.submittedFrames > 60, fps > 20 {
                proofLogged = true
                log.info("GOSSDEMO preview active: \(self.camera.submittedFrames) camera frames rendered at \(String(format: "%.1f", fps)) fps")
            }
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
    }

    /// Landmarks arrive in sensor pixels; the sensor sits one quarter turn
    /// from portrait, the same turn the preview applies.
    private func drawFaceOverlay() {
        guard let session, let result = try? session.faceResult() else { return }
        guard result.frameSerial != lastFaceSerial else { return }
        lastFaceSerial = result.frameSerial
        lastFaceResult = result
        guard !result.landmarks.isEmpty, result.presence >= 0.5 else {
            faceLayer.path = nil
            return
        }

        let path = CGMutablePath()
        let bounds = view.bounds
        let sensorWidth = CGFloat(max(camera.frameWidth, 1))
        let sensorHeight = CGFloat(max(camera.frameHeight, 1))
        let scaleX = bounds.width / sensorHeight
        let scaleY = bounds.height / sensorWidth
        for index in 0 ..< result.landmarks.count / 3 {
            let x = CGFloat(result.landmarks[index * 3])
            let y = CGFloat(result.landmarks[index * 3 + 1])
            // Quarter turn: sensor x runs down the portrait screen.
            let viewX = (sensorHeight - y) * scaleX
            let viewY = x * scaleY
            path.addEllipse(in: CGRect(x: viewX - 1.5, y: viewY - 1.5, width: 3, height: 3))
        }
        faceLayer.path = path
    }

    /// Rides the same result drawFaceOverlay just refreshed - ticking
    /// every render frame regardless of whether that particular result
    /// was new keeps the lens's own animation ramps advancing smoothly
    /// at display refresh rate rather than at tracking cadence.
    private func tickLens(dtUs: UInt32) {
        guard let session else { return }
        let result = lastFaceResult
        let signals = LensSignals(
            hasFace: (result?.presence ?? 0) >= 0.5 && !(result?.landmarks.isEmpty ?? true),
            blendshapes: result?.blendshapes ?? []
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
    var ckThermal: Int32 {
        switch self {
        case .nominal: return 0
        case .fair: return 1
        case .serious: return 2
        case .critical: return 3
        @unknown default: return 3
        }
    }
}
