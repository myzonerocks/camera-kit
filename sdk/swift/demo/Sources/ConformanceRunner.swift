import CryptoKit
import Gosslens
import QuartzCore
import UIKit
import os

/// Mirrors harness/conformance.zig's own determinism check (the same
/// reference lens, the same corpus frame, rendered twice through the
/// real ABI, byte-identical screenshots) but driven from a real Swift
/// SDK instead of a desktop GLFW window - the same real
/// goss_engine_init_renderer/goss_session_activate_lens_from_directory/
/// goss_engine_render_frame path the live demo already runs, just fed a
/// fixed frame instead of the camera. Reached only behind the
/// -GossConformance launch argument; a normal launch never touches this
/// file. Simulator output is a dev signal, not a substitute for a run
/// on real hardware.
///
/// Proves shader-tint, not beauty-baseline: GPUPixelContext's EAGLContext
/// creation fails cleanly (goss_session_enable_beauty returns unsupported,
/// nothing crashes) on the iOS Simulator - a real platform limitation,
/// not a bug here. Recent iOS Simulator runtimes on Apple Silicon do not
/// back a real OpenGL ES driver the way a physical device does; gpupixel
/// only speaks GLES on apple platforms. bgfx/Metal has no such gap
/// (confirmed: BGFX Init/backbuffer/reset all succeed here), so
/// shader-tint - a shader.pass lens with no gpupixel dependency at all -
/// is what this proves. beauty-baseline's own live-preview compositing
/// stays proven on macOS (harness/conformance.zig) and real iOS/Android
/// devices/GLES only, left open here rather than chased further; a real
/// device run is the next escalation, not a simulator workaround.
enum ConformanceRunner {
    private static let log = Logger(subsystem: "com.gosslens.demo", category: "conformance")

    // Plain stdout, not os.Logger: a driving script captures this over
    // simctl launch --console-pty, which streams the process's own
    // stdout/stderr, never the unified logging system os.Logger writes
    // to - os_log lines never reach it no matter how long the script
    // waits. Logger stays alongside for a human watching Console.app.
    private static func report(_ line: String) {
        log.info("\(line, privacy: .public)")
        print(line)
        fflush(stdout)
    }

    static func run(metalLayer: CAMetalLayer, width: UInt32, height: UInt32) {
        defer { exit(0) }
        guard let corpus = loadCorpusNV12() else {
            report("GOSSCONFORMANCE FAIL: corpus frame missing or undecodable")
            return
        }
        let pathA = NSTemporaryDirectory() + "ckconformance-a"
        let pathB = NSTemporaryDirectory() + "ckconformance-b"
        guard let hashA = renderOnce(metalLayer: metalLayer, width: width, height: height, corpus: corpus, outPath: pathA) else {
            report("GOSSCONFORMANCE FAIL: first render failed")
            return
        }
        guard let hashB = renderOnce(metalLayer: metalLayer, width: width, height: height, corpus: corpus, outPath: pathB) else {
            report("GOSSCONFORMANCE FAIL: second render failed")
            return
        }
        if hashA == hashB {
            report("GOSSCONFORMANCE PROOF shader-tint bit-stable sha256 \(hashA)")
        } else {
            report("GOSSCONFORMANCE FAIL non-deterministic: \(hashA) vs \(hashB)")
        }
    }

    private struct Nv12Corpus {
        let width: UInt32
        let height: UInt32
        let y: [UInt8]
        let uv: [UInt8]
    }

    /// BT.601 full range, chroma averaged 2x2 - the same standard and
    /// range harness/conformance.zig's own rgbaToNv12 uses on the same
    /// corpus frame, so a future cross-platform byte comparison (not
    /// attempted here, only within-platform determinism) would stay
    /// meaningful.
    private static func loadCorpusNV12() -> Nv12Corpus? {
        guard let url = Bundle.main.url(forResource: "face_frontal_b", withExtension: "jpg"),
              let data = try? Data(contentsOf: url),
              let image = UIImage(data: data)?.cgImage
        else { return nil }

        let width = image.width
        let height = image.height
        var rgba = [UInt8](repeating: 0, count: width * height * 4)
        let ok: Bool = rgba.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(
                data: raw.baseAddress,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { return false }
            ctx.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard ok else { return nil }

        func toYuv(_ r: Double, _ g: Double, _ b: Double) -> (y: Double, cb: Double, cr: Double) {
            let y = 0.299 * r + 0.587 * g + 0.114 * b
            let cb = -0.168736 * r - 0.331264 * g + 0.5 * b + 0.5
            let cr = 0.5 * r - 0.418688 * g - 0.081312 * b + 0.5
            return (y, cb, cr)
        }
        func toByte(_ v: Double) -> UInt8 { UInt8(max(0, min(1, v)) * 255.0) }

        let halfWidth = (width + 1) / 2
        let halfHeight = (height + 1) / 2
        var yPlane = [UInt8](repeating: 0, count: width * height)
        var uvPlane = [UInt8](repeating: 0, count: halfWidth * halfHeight * 2)

        for row in 0 ..< height {
            for col in 0 ..< width {
                let at = (row * width + col) * 4
                let r = Double(rgba[at]) / 255.0
                let g = Double(rgba[at + 1]) / 255.0
                let b = Double(rgba[at + 2]) / 255.0
                yPlane[row * width + col] = toByte(toYuv(r, g, b).y)
            }
        }
        for row in 0 ..< halfHeight {
            for col in 0 ..< halfWidth {
                var cbSum = 0.0
                var crSum = 0.0
                var samples = 0.0
                for dy in 0 ..< 2 {
                    for dx in 0 ..< 2 {
                        let sourceY = row * 2 + dy
                        let sourceX = col * 2 + dx
                        if sourceY >= height || sourceX >= width { continue }
                        let at = (sourceY * width + sourceX) * 4
                        let r = Double(rgba[at]) / 255.0
                        let g = Double(rgba[at + 1]) / 255.0
                        let b = Double(rgba[at + 2]) / 255.0
                        let yuv = toYuv(r, g, b)
                        cbSum += yuv.cb
                        crSum += yuv.cr
                        samples += 1
                    }
                }
                let at = (row * halfWidth + col) * 2
                uvPlane[at] = toByte(cbSum / samples)
                uvPlane[at + 1] = toByte(crSum / samples)
            }
        }
        return Nv12Corpus(width: UInt32(width), height: UInt32(height), y: yPlane, uv: uvPlane)
    }

    /// A fresh engine/session per call, mirroring harness/conformance.zig's
    /// own renderOnce - proves activation and teardown aren't hiding state
    /// that would make a second run trivially match the first.
    private static func renderOnce(metalLayer: CAMetalLayer, width: UInt32, height: UInt32, corpus: Nv12Corpus, outPath: String) -> String? {
        guard let engine = try? Engine.create() else { return nil }
        defer { engine.destroy() }

        guard (try? engine.initRenderer(surface: Unmanaged.passUnretained(metalLayer).toOpaque(), width: width, height: height)) != nil else { return nil }

        guard let session = try? Session.create(engine: engine) else { return nil }
        defer { session.destroy() }

        guard let lensManifestURL = Bundle.main.url(forResource: "manifest", withExtension: "json", subdirectory: "shader-tint") else { return nil }
        guard (try? session.activateLensFromDirectory(bundlePath: lensManifestURL.deletingLastPathComponent().path)) != nil else { return nil }

        let uvStride = UInt32((corpus.width + 1) / 2) * 2
        let submitted: ()? = corpus.y.withUnsafeBufferPointer { yBuf in
            corpus.uv.withUnsafeBufferPointer { uvBuf in
                try? session.submitFrameCopy(
                    y: yBuf.baseAddress!, yStride: corpus.width,
                    uv: uvBuf.baseAddress!, uvStride: uvStride,
                    width: corpus.width, height: corpus.height,
                    rotationDegrees: 0, mirrored: false, timestampUs: 1000,
                    colorStandard: GOSS_COLOR_BT601.rawValue, colorRange: GOSS_COLOR_RANGE_FULL.rawValue
                )
            }
        }
        guard submitted != nil else { return nil }

        for _ in 0 ..< 5 { try? engine.renderFrame(session: session) }
        guard (try? engine.requestScreenshot(path: outPath)) != nil else { return nil }
        for _ in 0 ..< 5 { try? engine.renderFrame(session: session) }

        guard let shot = try? Data(contentsOf: URL(fileURLWithPath: outPath + ".tga")) else { return nil }
        return SHA256.hash(data: shot).map { String(format: "%02x", $0) }.joined()
    }
}
