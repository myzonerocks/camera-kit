import AVFoundation
@preconcurrency import CoreVideo
import Gosslens
import Metal
import UIKit
import os

// Owns the capture side: device discovery, permission, the NV12 output, and
// zero-copy hand-off of each frame's Metal textures into the engine. Frames
// never touch the CPU; CVMetalTextureCache wraps the camera planes as
// MTLTextures backed by the same IOSurface. Unchecked Sendable: mutable
// state is confined to outputQueue and an explicit hop to main, by
// construction, not something the compiler can see through captures.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate, @unchecked Sendable {
    enum State: String {
        case idle
        case running
        case denied
        case interrupted
        case failed
    }

    private let log = Logger(subsystem: "com.gosslens.demo", category: "capture")
    private let captureSession = AVCaptureSession()
    private let outputQueue = DispatchQueue(label: "com.gosslens.demo.capture")
    private var textureCache: CVMetalTextureCache?
    private var session: Session?

    // Main-thread only: the two most recently SUBMITTED frames' platform
    // objects. Advancing on successful submits rather than captures means
    // a stall can never recycle a frame the engine still samples; the
    // submit hop's capture list keeps each frame alive until it lands.
    private var retainedFrames: [[Any]] = [[], []]

    private(set) var state: State = .idle
    private(set) var submittedFrames = 0
    private(set) var frameWidth = 0
    private(set) var frameHeight = 0
    private(set) var position: AVCaptureDevice.Position = .back
    private(set) var mirrored = false
    private var rotationQuarterTurns: UInt32 = 0
    var onStateChange: ((State) -> Void)?

    private var activeObserver: NSObjectProtocol?
    private var engineFeaturesEnabled = false

    // gpupixel's context creation silently no-ops with no retry while
    // the app isn't foreground-active (GPXObjcHelper's s_isAppActive) -
    // viewDidLayoutSubviews routinely calls this before that's true,
    // losing the one shot for good. Wait for real activation first.
    // Runs the enables exactly once: every foreground re-entry calls
    // start() again, and re-running them would reset the active lens
    // and pile up one leaked observer per cycle.
    private func enableEngineFeaturesWhenActive() {
        if let observer = activeObserver {
            NotificationCenter.default.removeObserver(observer)
            activeObserver = nil
        }
        guard !engineFeaturesEnabled else { return }
        if UIApplication.shared.applicationState == .active {
            engineFeaturesEnabled = true
            enableFaceTracking()
            enableBeauty()
            activateLens()
            return
        }
        activeObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            if let observer = self.activeObserver {
                NotificationCenter.default.removeObserver(observer)
                self.activeObserver = nil
            }
            guard !self.engineFeaturesEnabled else { return }
            self.engineFeaturesEnabled = true
            self.enableFaceTracking()
            self.enableBeauty()
            self.activateLens()
        }
    }

    func start(session: Session?, position: AVCaptureDevice.Position = .front) {
        self.session = session
        enableEngineFeaturesWhenActive()

        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            configureAndRun(position: position)
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted {
                        self.configureAndRun(position: position)
                    } else {
                        self.transition(to: .denied)
                    }
                }
            }
        default:
            transition(to: .denied)
        }
    }

    func stop() {
        captureSession.stopRunning()
        transition(to: .idle)
    }

    // Swaps the input device in place rather than tearing the session
    // down - output, connection, and the beauty/tracking session stay
    // untouched. mirrored and rotationQuarterTurns both flip with it,
    // matching configureAndRun's own per-position values.
    func switchCamera() {
        let newPosition: AVCaptureDevice.Position = position == .back ? .front : .back
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: newPosition) else { return }

        outputQueue.async { [weak self] in
            guard let self, let input = try? AVCaptureDeviceInput(device: device) else { return }
            self.captureSession.beginConfiguration()
            for existingInput in self.captureSession.inputs {
                self.captureSession.removeInput(existingInput)
            }
            guard self.captureSession.canAddInput(input) else {
                self.captureSession.commitConfiguration()
                return
            }
            self.captureSession.addInput(input)
            self.captureSession.commitConfiguration()
            // rotationQuarterTurns is read on this queue (captureOutput);
            // position/mirrored are read on main (the face overlay), so
            // each updates on its reader's own thread.
            self.rotationQuarterTurns = newPosition == .front ? 1 : 3
            DispatchQueue.main.async {
                self.position = newPosition
                self.mirrored = newPosition == .front
            }
        }
    }

    private func enableFaceTracking() {
        guard let session,
              let url = Bundle.main.url(forResource: "face_landmarker", withExtension: "task"),
              let bundleData = try? Data(contentsOf: url)
        else {
            log.info("face tracking bundle not present")
            return
        }
        do {
            try session.enableFaceTracking(taskBundle: bundleData, threads: 0)
            log.info("face tracking enabled")
        } catch {
            log.info("face tracking enable failed: \(String(describing: error))")
        }
    }

    // The engine's own loader appends "res/" to whatever root it is given,
    // so the bundle root is the argument, not the res folder itself.
    private func enableBeauty() {
        guard let session else { return }
        let resourceRoot = Bundle.main.bundlePath
        guard FileManager.default.fileExists(atPath: resourceRoot + "/res") else {
            log.info("beauty resources not present")
            return
        }
        do {
            try session.enableBeauty(resourceDir: resourceRoot)
            log.info("beauty enabled")
        } catch {
            log.info("beauty enable failed: \(String(describing: error))")
        }
    }

    // The reference lens ships as a bundled folder (project.yml) keeping
    // its own name, so its manifest sits at <bundle>/beauty-baseline/manifest.json.
    private func activateLens() {
        guard let session,
              let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "beauty-baseline"),
              let manifestData = try? Data(contentsOf: url)
        else {
            log.info("reference lens not present")
            return
        }
        do {
            try session.activateLens(manifestJson: manifestData)
            log.info("lens activated")
        } catch {
            log.info("lens activate failed: \(String(describing: error))")
        }
    }

    // The AVCaptureSession notification observers fire on the session's
    // own posting thread; state and onStateChange (which touches UIKit)
    // are main-thread concerns, so everything funnels through one hop.
    private func transition(to newState: State) {
        guard Thread.isMainThread else {
            DispatchQueue.main.async { self.transition(to: newState) }
            return
        }
        state = newState
        log.info("capture state \(newState.rawValue)")
        onStateChange?(newState)
    }

    private func configureAndRun(position: AVCaptureDevice.Position) {
        var cache: CVMetalTextureCache?
        guard let metalDevice = MTLCreateSystemDefaultDevice(),
              CVMetalTextureCacheCreate(nil, nil, metalDevice, nil, &cache) == kCVReturnSuccess
        else {
            transition(to: .failed)
            return
        }
        textureCache = cache

        captureSession.beginConfiguration()
        captureSession.sessionPreset = .hd1920x1080

        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: position),
              let input = try? AVCaptureDeviceInput(device: device),
              captureSession.canAddInput(input)
        else {
            captureSession.commitConfiguration()
            transition(to: .failed)
            return
        }
        captureSession.addInput(input)
        self.position = position
        mirrored = position == .front

        let output = AVCaptureVideoDataOutput()
        output.videoSettings = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
        ]
        output.alwaysDiscardsLateVideoFrames = true
        output.setSampleBufferDelegate(self, queue: outputQueue)
        guard captureSession.canAddOutput(output) else {
            captureSession.commitConfiguration()
            transition(to: .failed)
            return
        }
        captureSession.addOutput(output)
        if let connection = output.connection(with: .video) {
            let angle: CGFloat = 90
            if connection.isVideoRotationAngleSupported(angle) {
                connection.videoRotationAngle = 0
            }
        }
        captureSession.commitConfiguration()

        NotificationCenter.default.addObserver(self, selector: #selector(interrupted), name: AVCaptureSession.wasInterruptedNotification, object: captureSession)
        NotificationCenter.default.addObserver(self, selector: #selector(interruptionEnded), name: AVCaptureSession.interruptionEndedNotification, object: captureSession)
        NotificationCenter.default.addObserver(self, selector: #selector(runtimeError), name: AVCaptureSession.runtimeErrorNotification, object: captureSession)

        // rotationZ's positive angle is counter-clockwise: the rear
        // sensor's clockwise correction is 3 quarter-turns, the front
        // one mounted 180 degrees opposite on the same PCB needs the
        // complementary 1 - real device testing caught 3 landing upside down.
        rotationQuarterTurns = position == .front ? 1 : 3

        outputQueue.async {
            self.captureSession.startRunning()
            self.transition(to: self.captureSession.isRunning ? .running : .failed)
        }
    }

    @objc private func interrupted() {
        transition(to: .interrupted)
    }

    @objc private func interruptionEnded() {
        transition(to: .running)
    }

    @objc private func runtimeError(_ notification: Notification) {
        log.error("capture runtime error: \(String(describing: notification.userInfo))")
        transition(to: .failed)
        outputQueue.async {
            self.captureSession.startRunning()
            let restarted = self.captureSession.isRunning
            self.transition(to: restarted ? .running : .failed)
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let session,
              let cache = textureCache,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)

        var yTextureRef: CVMetalTexture?
        var uvTextureRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .r8Unorm, width, height, 0, &yTextureRef) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &uvTextureRef) == kCVReturnSuccess,
              let yRef = yTextureRef, let uvRef = uvTextureRef,
              let yTexture = CVMetalTextureGetTexture(yRef),
              let uvTexture = CVMetalTextureGetTexture(uvRef)
        else { return }

        var standard: UInt32 = GOSS_COLOR_BT709.rawValue
        if let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
                standard = GOSS_COLOR_BT601.rawValue
            } else if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
                standard = GOSS_COLOR_BT2020.rawValue
            }
        }

        let rotationDegrees = rotationQuarterTurns * 90
        let timestampUs = Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)
        let yPlane = UInt64(UInt(bitPattern: Unmanaged.passUnretained(yTexture).toOpaque()))
        let uvPlane = UInt64(UInt(bitPattern: Unmanaged.passUnretained(uvTexture).toOpaque()))

        // bgfx runs on the main thread only, so this hops off the capture
        // queue; the capture list retains this frame's platform objects
        // (planes only carries raw pointer values) until they land in
        // retainedFrames on a successful submit.
        DispatchQueue.main.async { [weak self, session, pixelBuffer, yRef, uvRef] in
            guard let self else { return }
            if (try? session.submitFrame(planes: [yPlane, uvPlane], width: UInt32(width), height: UInt32(height), pixelFormat: GOSS_PIXEL_NV12.rawValue, colorStandard: standard, rotationDegrees: rotationDegrees, mirrored: self.mirrored, timestampUs: timestampUs)) != nil {
                self.submittedFrames += 1
                self.frameWidth = width
                self.frameHeight = height
                self.retainedFrames = [[pixelBuffer, yRef, uvRef], self.retainedFrames[0]]
            }
        }

        // Tracking reads the same frame's planes on the CPU; the worker
        // copies before this callback returns and the buffer recycles.
        if CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess {
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
               let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                try? session.trackFrame(
                    y: yBase.assumingMemoryBound(to: UInt8.self), yStride: UInt32(yStride),
                    uv: uvBase.assumingMemoryBound(to: UInt8.self), uvStride: UInt32(uvStride),
                    width: UInt32(width), height: UInt32(height), timestampUs: timestampUs
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
    }
}
