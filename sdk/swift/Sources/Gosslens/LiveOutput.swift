import CoreVideo
import Metal

/// A pool of IOSurface-backed BGRA pixel buffers the engine renders the
/// composited frame into zero-copy, ready to publish to a LiveKit or WebRTC
/// custom video source. Create one per broadcast on the same MTLDevice the
/// renderer uses (the CAMetalLayer's device), then call nextFrame each tick.
public final class GossLiveOutput {
    private let engine: GossEngine
    private let width: Int
    private let height: Int
    private let pool: CVPixelBufferPool
    private let cache: CVMetalTextureCache

    public init?(engine: GossEngine, device: MTLDevice, width: Int, height: Int) {
        self.engine = engine
        self.width = width
        self.height = height

        // A depth of three so the encoder never reads the surface bgfx is
        // writing while two others cycle.
        let poolAttrs: [String: Any] = [kCVPixelBufferPoolMinimumBufferCountKey as String: 3]
        let bufferAttrs: [String: Any] = [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferIOSurfacePropertiesKey as String: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey as String: true,
        ]
        var pool: CVPixelBufferPool?
        guard CVPixelBufferPoolCreate(nil, poolAttrs as CFDictionary, bufferAttrs as CFDictionary, &pool) == kCVReturnSuccess,
              let pool else { return nil }
        self.pool = pool

        var cache: CVMetalTextureCache?
        guard CVMetalTextureCacheCreate(nil, nil, device, nil, &cache) == kCVReturnSuccess,
              let cache else { return nil }
        self.cache = cache
    }

    /// Renders the current composited frame into a fresh pixel buffer from the
    /// pool and returns it to publish, or nil to skip this frame - the texture
    /// is warming up bgfx's override, or a pool/cache slot was unavailable. The
    /// buffer is IOSurface-backed, so the encoder reads it with no further copy.
    public func nextFrame(session: GossSession) -> CVPixelBuffer? {
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer) == kCVReturnSuccess,
              let pixelBuffer else { return nil }

        var cvTexture: CVMetalTexture?
        let status = CVMetalTextureCacheCreateTextureFromImage(
            nil, cache, pixelBuffer, nil, .bgra8Unorm, width, height, 0, &cvTexture)
        guard status == kCVReturnSuccess, let cvTexture,
              let texture = CVMetalTextureGetTexture(cvTexture) else { return nil }

        // The MTLTexture stays alive through this synchronous render, and the
        // pixel buffer keeps the IOSurface after cvTexture releases.
        let handle = Unmanaged.passUnretained(texture).toOpaque()
        guard engine.renderToLiveTexture(session: session, texture: handle, width: UInt32(width), height: UInt32(height)) else {
            return nil
        }
        return pixelBuffer
    }

    deinit {
        CVMetalTextureCacheFlush(cache, 0)
    }
}
