import AVFoundation
import CoreVideo
import Metal
import os

// Owns the capture side: device discovery, permission, the NV12 output, and
// zero-copy hand-off of each frame's Metal textures into the engine. Frames
// never touch the CPU; CVMetalTextureCache wraps the camera planes as
// MTLTextures backed by the same IOSurface.
final class CameraController: NSObject, AVCaptureVideoDataOutputSampleBufferDelegate {
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
    private var engineSession: OpaquePointer?

    // The plane textures of the two most recent frames stay retained so the
    // GPU can still sample the frame in flight while the next one arrives.
    private var inflight: [[Any]] = [[], []]
    private var inflightIndex = 0

    private(set) var state: State = .idle
    private(set) var submittedFrames = 0
    private(set) var frameWidth = 0
    private(set) var frameHeight = 0
    private var mirrored = false
    private var rotationQuarterTurns: UInt32 = 0
    var onStateChange: ((State) -> Void)?

    func start(engineSession: OpaquePointer?, position: AVCaptureDevice.Position = .back) {
        self.engineSession = engineSession
        enableFaceTracking()
        enableBeauty()
        activateLens()

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

    private func enableFaceTracking() {
        guard let engineSession,
              let url = Bundle.main.url(forResource: "face_landmarker", withExtension: "task"),
              let bundleData = try? Data(contentsOf: url)
        else {
            log.info("face tracking bundle not present")
            return
        }
        let status = bundleData.withUnsafeBytes { raw in
            goss_session_enable_face_tracking(engineSession, raw.bindMemory(to: UInt8.self).baseAddress, raw.count, 0)
        }
        log.info("face tracking enable status \(status.rawValue)")
    }

    // The engine's own loader appends "res/" to whatever root it is given,
    // so the bundle root is the argument, not the res folder itself.
    private func enableBeauty() {
        guard let engineSession else { return }
        let resourceRoot = Bundle.main.bundlePath
        guard FileManager.default.fileExists(atPath: resourceRoot + "/res") else {
            log.info("beauty resources not present")
            return
        }
        let status = goss_session_enable_beauty(engineSession, resourceRoot)
        log.info("beauty enable status \(status.rawValue)")
    }

    // The reference lens ships as a bundled folder (project.yml) keeping
    // its own name, so its manifest sits at <bundle>/beauty-baseline/manifest.json.
    private func activateLens() {
        guard let engineSession,
              let url = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "beauty-baseline"),
              let manifestData = try? Data(contentsOf: url)
        else {
            log.info("reference lens not present")
            return
        }
        let status = manifestData.withUnsafeBytes { raw in
            goss_session_activate_lens(engineSession, raw.bindMemory(to: UInt8.self).baseAddress, raw.count)
        }
        log.info("lens activate status \(status.rawValue)")
    }

    private func transition(to newState: State) {
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

        // Sensor sits landscape; one quarter turn shows portrait upright.
        rotationQuarterTurns = 1

        outputQueue.async {
            self.captureSession.startRunning()
            DispatchQueue.main.async { self.transition(to: .running) }
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
            DispatchQueue.main.async { self.transition(to: .running) }
        }
    }

    func captureOutput(_ output: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from connection: AVCaptureConnection) {
        guard let engineSession,
              let cache = textureCache,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        frameWidth = width
        frameHeight = height

        var yTextureRef: CVMetalTexture?
        var uvTextureRef: CVMetalTexture?
        guard CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .r8Unorm, width, height, 0, &yTextureRef) == kCVReturnSuccess,
              CVMetalTextureCacheCreateTextureFromImage(nil, cache, pixelBuffer, nil, .rg8Unorm, width / 2, height / 2, 1, &uvTextureRef) == kCVReturnSuccess,
              let yRef = yTextureRef, let uvRef = uvTextureRef,
              let yTexture = CVMetalTextureGetTexture(yRef),
              let uvTexture = CVMetalTextureGetTexture(uvRef)
        else { return }

        // Keep this frame's platform objects alive until the frame after
        // next has rendered.
        inflight[inflightIndex] = [pixelBuffer, yRef, uvRef, yTexture, uvTexture]
        inflightIndex = (inflightIndex + 1) % inflight.count

        var standard: UInt32 = GOSS_COLOR_BT709.rawValue
        if let matrix = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferYCbCrMatrixKey, nil) as? String {
            if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String) {
                standard = GOSS_COLOR_BT601.rawValue
            } else if matrix == (kCVImageBufferYCbCrMatrix_ITU_R_2020 as String) {
                standard = GOSS_COLOR_BT2020.rawValue
            }
        }

        var flags: UInt32 = rotationQuarterTurns << GOSS_FRAME_ROTATION_SHIFT
        if mirrored { flags |= GOSS_FRAME_FLAG_MIRROR }

        var desc = goss_frame_desc(
            width: UInt32(width),
            height: UInt32(height),
            pixel_format: GOSS_PIXEL_NV12.rawValue,
            color_standard: standard,
            color_range: GOSS_COLOR_RANGE_VIDEO.rawValue,
            flags: flags,
            timestamp_us: Int64(CMTimeGetSeconds(CMSampleBufferGetPresentationTimeStamp(sampleBuffer)) * 1_000_000)
        )
        let planes = goss_frame_planes(
            plane_count: 2,
            reserved: 0,
            planes: (
                UInt64(UInt(bitPattern: Unmanaged.passUnretained(yTexture).toOpaque())),
                UInt64(UInt(bitPattern: Unmanaged.passUnretained(uvTexture).toOpaque())),
                0
            )
        )
        // bgfx is single-threaded (main thread only, via CADisplayLink) -
        // hop off this background capture queue for the submit call.
        DispatchQueue.main.async { [weak self, engineSession] in
            guard let self else { return }
            var desc = desc
            var planes = planes
            if goss_session_submit_frame(engineSession, &desc, &planes) == GOSS_OK {
                self.submittedFrames += 1
            }
        }

        // Tracking reads the same frame's planes on the CPU; the worker
        // copies before this callback returns and the buffer recycles.
        if CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess {
            if let yBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0),
               let uvBase = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 1) {
                let yStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0)
                let uvStride = CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 1)
                _ = goss_session_track_frame(
                    engineSession, &desc,
                    yBase.assumingMemoryBound(to: UInt8.self), UInt32(yStride),
                    uvBase.assumingMemoryBound(to: UInt8.self), UInt32(uvStride)
                )
            }
            CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly)
        }
    }
}
