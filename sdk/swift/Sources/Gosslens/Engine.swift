import CGosslens

/// Frame-path pool bounds; zero means the built-in default.
public struct EngineConfig {
    public var texturePoolCapacity: UInt32
    public var stagingPoolCapacity: UInt32

    public init(texturePoolCapacity: UInt32 = 0, stagingPoolCapacity: UInt32 = 0) {
        self.texturePoolCapacity = texturePoolCapacity
        self.stagingPoolCapacity = stagingPoolCapacity
    }
}

/// Render-surface lifecycle: create/destroy/init/resize/render. Confined
/// to the thread that creates it, the graph thread - unchecked because
/// that confinement is the ABI's own contract, not something the
/// compiler can see through an opaque handle.
public final class Engine: @unchecked Sendable {
    let handle: OpaquePointer
    private var destroyed = false

    public static func create(config: EngineConfig = EngineConfig()) throws -> Engine {
        var raw = goss_engine_config(
            texture_pool_capacity: config.texturePoolCapacity,
            staging_pool_capacity: config.stagingPoolCapacity
        )
        var handle: OpaquePointer?
        try checked(goss_engine_create(&raw, &handle))
        guard let handle else { throw GossStatus.outOfMemory }
        return Engine(handle: handle)
    }

    private init(handle: OpaquePointer) {
        self.handle = handle
    }

    deinit {
        if !destroyed { goss_engine_destroy(handle) }
    }

    /// Safe to call more than once; only the first call reaches the ABI -
    /// deinit falls back to this same destroy for callers who never call
    /// it explicitly, and must not double-free a handle this already did.
    public func destroy() {
        guard !destroyed else { return }
        destroyed = true
        goss_engine_destroy(handle)
    }

    /// Brings up the render backend on the given surface.
    public func initRenderer(surface: UnsafeMutableRawPointer?, width: UInt32, height: UInt32) throws {
        var desc = goss_renderer_desc(native_window_handle: surface, width: width, height: height)
        try checked(goss_engine_init_renderer(handle, &desc))
    }

    public func resize(width: UInt32, height: UInt32) {
        goss_engine_resize(handle, width, height)
    }

    /// Draws session's most recent frame to the surface and presents. A
    /// nil session presents the clear color.
    public func renderFrame(session: Session?) throws {
        try checked(goss_engine_render_frame(handle, session?.handle))
    }
}
