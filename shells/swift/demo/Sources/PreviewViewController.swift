import AVFoundation
import QuartzCore
import UIKit
import os

// A UIView whose backing layer is the CAMetalLayer the engine renders into.
final class MetalView: UIView {
    override class var layerClass: AnyClass { CAMetalLayer.self }
    var metalLayer: CAMetalLayer { layer as! CAMetalLayer }
}

final class PreviewViewController: UIViewController {
    private let log = Logger(subsystem: "kit.camera.demo", category: "preview")
    private let camera = CameraController()
    private let statusLabel = UILabel()

    private var engine: OpaquePointer?
    private var session: OpaquePointer?
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

        let version = ck_abi_version()
        log.info("ck abi \(version >> 16).\(version & 0xffff)")
        guard version >> 16 == 0 else {
            statusLabel.text = "abi major mismatch"
            return
        }

        NotificationCenter.default.addObserver(self, selector: #selector(appDidEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(appWillEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)

        camera.onStateChange = { [weak self] state in
            self?.statusLabel.text = "capture \(state.rawValue)"
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        let scale = view.window?.screen.scale ?? 3.0
        let pixelWidth = UInt32(view.bounds.width * scale)
        let pixelHeight = UInt32(view.bounds.height * scale)
        metalView.metalLayer.contentsScale = scale
        metalView.metalLayer.drawableSize = CGSize(width: CGFloat(pixelWidth), height: CGFloat(pixelHeight))

        if engine == nil, pixelWidth > 0 {
            startEngine(pixelWidth: pixelWidth, pixelHeight: pixelHeight)
        } else if engine != nil {
            ck_engine_resize(engine, pixelWidth, pixelHeight)
        }
    }

    private func startEngine(pixelWidth: UInt32, pixelHeight: UInt32) {
        var engineOut: OpaquePointer?
        guard ck_engine_create(nil, &engineOut) == CK_OK else {
            statusLabel.text = "engine create failed"
            return
        }
        engine = engineOut

        var desc = ck_renderer_desc(
            native_window_handle: Unmanaged.passUnretained(metalView.metalLayer).toOpaque(),
            width: pixelWidth,
            height: pixelHeight
        )
        guard ck_engine_init_renderer(engine, &desc) == CK_OK else {
            statusLabel.text = "renderer init failed"
            log.error("renderer init failed")
            return
        }

        var sessionOut: OpaquePointer?
        guard ck_session_create(engine, nil, &sessionOut) == CK_OK else {
            statusLabel.text = "session create failed"
            return
        }
        session = sessionOut

        camera.start(engineSession: session)

        let link = CADisplayLink(target: self, selector: #selector(renderTick))
        link.add(to: .main, forMode: .common)
        displayLink = link
    }

    @objc private func renderTick() {
        guard let engine else { return }
        let start = CFAbsoluteTimeGetCurrent()
        let frameTimeUs = UInt32(max(0, (start - lastFrameStart) * 1_000_000))
        lastFrameStart = start

        _ = ck_session_report_frame(session, frameTimeUs, ck_thermal(rawValue: UInt32(ProcessInfo.processInfo.thermalState.ckThermal)))
        guard ck_engine_render_frame(engine, session) == CK_OK else { return }
        renderedFrames += 1
        fpsWindowFrames += 1

        let now = CFAbsoluteTimeGetCurrent()
        if now - fpsWindowStart >= 2.0 {
            let fps = Double(fpsWindowFrames) / (now - fpsWindowStart)
            log.info("CKDEMO fps \(String(format: "%.1f", fps)) rendered \(self.renderedFrames) submitted \(self.camera.submittedFrames) state \(self.camera.state.rawValue)")
            statusLabel.text = String(format: "capture %@  %.1f fps", camera.state.rawValue, fps)
            if !proofLogged, camera.submittedFrames > 60, fps > 20 {
                proofLogged = true
                log.info("CKDEMO preview active: \(self.camera.submittedFrames) camera frames rendered at \(String(format: "%.1f", fps)) fps")
            }
            fpsWindowStart = now
            fpsWindowFrames = 0
        }
    }

    @objc private func appDidEnterBackground() {
        displayLink?.isPaused = true
        camera.stop()
    }

    @objc private func appWillEnterForeground() {
        displayLink?.isPaused = false
        camera.start(engineSession: session)
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
