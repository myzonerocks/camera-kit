//! The goss_ export layer: the only file that exports symbols. Everything here
//! mirrors include/gosslens.h exactly; layouts are frozen and asserted at
//! compile time, and the abi gate diffs the surface on every change.
//!
//! Exports delegate to internal functions that take an allocator, so tests
//! exercise the same code paths under the leak-checking test allocator while
//! shipping builds use the platform allocator. The render backend arrives
//! through the `render` module import: the real bgfx binding on platforms
//! with a compiled render stack, a refusing stub elsewhere.

const std = @import("std");
const builtin = @import("builtin");
const graph = @import("graph");
const math = @import("math");
const render = @import("render");
const tracking = @import("tracking");
const segmentation = @import("segmentation");
const face = @import("face");
const face_geometry = @import("face_geometry");
const png = @import("png");
const media_recording = @import("media_recording");
const photo = @import("photo");
const audio_analysis = @import("audio_analysis");
const physics = @import("physics");
const script = @import("script");
const audio_playback = @import("audio_playback");
const particles = @import("particles");
const hand = @import("hand");
const pose = @import("pose");
const beauty = @import("beauty");
const manifest = @import("manifest");
const trigger = @import("trigger");
const asset = @import("asset");
const image = @import("image");
const gltf = @import("gltf");
const face106 = @import("face106");

/// Whether this build targets wasm32-emscripten - the only web target
/// with a real bgfx renderer under it (wasm32-freestanding, the other
/// wasm target this file compiles for, links render_stub.zig instead).
/// adapters/beauty.zig's gpupixel bridge isn't ported to web (2026-08-15
/// GPU-compositing decision), so beauty.face/beauty.reshape need their
/// own dispatch here in place of applyBeautyCompositing's gpupixel
/// calls - guarded on this rather than reachable from every target.
const is_web = builtin.os.tag == .emscripten;
const is_android = builtin.os.tag == .linux and builtin.abi.isAndroid();

// A directory-based lens activation needs to read files (manifest.json,
// compiled shader bytecode) from within an exported goss_ function, which
// no SDK hands an Io instance into - this library owns one blocking
// implementation for that, single-threaded since it's only ever
// occasional small reads at lens activation, never the frame path.
// std.Io.Threaded assumes a POSIX-like host and cannot even be typed
// for wasm32-freestanding (no threads, no file syscalls) - directory-
// based activation is unsupported there the same way beauty/tracking
// already are, guarded before this is ever reached, not by pretending
// the type exists.
const has_file_io = !builtin.cpu.arch.isWasm();
var default_threaded_io: if (has_file_io) std.Io.Threaded else void =
    if (has_file_io) std.Io.Threaded.init_single_threaded else {};
fn defaultIo() std.Io {
    return default_threaded_io.io();
}
const runtime = @import("runtime");

pub const FaceResult = face.Result;
pub const HandResult = hand.Result;
pub const PoseResult = pose.Result;

pub const abi_major: u16 = 0;
pub const abi_minor: u16 = 19;

// As a library embedded in someone else's process the core never
// symbolizes its own stack: the hosting app owns crash reporting, and the
// symbolization machinery drags in loader interfaces mobile platforms do
// not export. A panic prints the message and traps; freestanding wasm has
// nowhere to print, so it traps directly.
pub const panic = if (builtin.os.tag == .freestanding) std.debug.no_panic else std.debug.simple_panic;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    pool_exhausted = 3,
    abi_mismatch = 4,
    renderer_unavailable = 5,
    unsupported = 6,
    again = 7,
};

pub const FrameDesc = extern struct {
    width: u32,
    height: u32,
    pixel_format: u32,
    color_standard: u32,
    color_range: u32,
    flags: u32,
    timestamp_us: i64,
};

pub const frame_flag_mirror: u32 = 1 << 0;
pub const frame_rotation_shift: u5 = 8;
pub const frame_rotation_mask: u32 = 0x3 << 8;

pub const Landmarks = extern struct {
    points: ?[*]const f32,
    point_count: u32,
    confidence: f32,
    timestamp_us: i64,
};

pub const EngineConfig = extern struct {
    texture_pool_capacity: u32,
    staging_pool_capacity: u32,
};

pub const SessionConfig = extern struct {
    frame_budget_us: u32,
    reserved: u32,
};

pub const RendererDesc = extern struct {
    native_window_handle: ?*anyopaque,
    width: u32,
    height: u32,
};

pub const FramePlanes = extern struct {
    plane_count: u32,
    reserved: u32,
    planes: [3]u64,
};

/// The live signals a tick evaluates a lens's compiled triggers against -
/// blendshapes mirrors goss_face_result's own inline-array
/// convention rather than a pointer, so a caller reading a face result
/// can pass its blendshapes straight through. has_face false means no
/// face-driven signal (present or any blendshape) reads as true.
pub const LensSignals = extern struct {
    has_face: bool,
    hands_present: bool,
    tap: bool,
    reserved: u8 = 0,
    world_tracking_state: f64,
    audio_level: f64,
    blendshapes: [face.blendshape_count]f32,
};

comptime {
    std.debug.assert(@sizeOf(FrameDesc) == 32);
    std.debug.assert(@offsetOf(FrameDesc, "timestamp_us") == 24);
    std.debug.assert(@sizeOf(Landmarks) == 24);
    std.debug.assert(@offsetOf(Landmarks, "timestamp_us") == 16);
    std.debug.assert(@sizeOf(EngineConfig) == 8);
    std.debug.assert(@sizeOf(SessionConfig) == 8);
    std.debug.assert(@sizeOf(RendererDesc) == if (@sizeOf(usize) == 8) 16 else 12);
    std.debug.assert(@sizeOf(FramePlanes) == 32);
    std.debug.assert(@offsetOf(FramePlanes, "planes") == 8);
    std.debug.assert(@sizeOf(LensSignals) == 232);
    std.debug.assert(@offsetOf(LensSignals, "world_tracking_state") == 8);
    std.debug.assert(@offsetOf(LensSignals, "blendshapes") == 24);
}

const default_texture_pool_capacity: u32 = 16;
const default_staging_pool_capacity: u32 = 8;
const default_frame_budget_us: u32 = 33_333;

const pixel_format_nv12: u32 = 0;
const pixel_format_nv21: u32 = 1;
const pixel_format_i420: u32 = 2;
const pixel_format_bgra8: u32 = 3;
const pixel_format_rgba8: u32 = 4;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    texture_pool: graph.Pool,
    staging_pool: graph.Pool,
    texture_pool_capacity: u16,
    staging_pool_capacity: u16,
    renderer: ?render.Renderer = null,
    /// Ping-pong offscreen targets a shader.pass chain renders through:
    /// camera capture and every pass but the last write into whichever
    /// of these it isn't reading from that frame. Sized to the active
    /// frame's dimensions and recreated only when that size changes,
    /// never per frame - only one chain is ever in flight at a time, so
    /// two targets are enough regardless of how many passes a lens has.
    chain_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    chain_width: u16 = 0,
    chain_height: u16 = 0,
    /// Dedicated target for goss_engine_capture_frame - separate from
    /// chain_targets, which ping-pong and get overwritten mid-chain, so
    /// this one alone always holds the true final composited image
    /// after a capture-requested frame renders.
    capture_target: ?render.Renderer.OffscreenTarget = null,
    /// CPU-readable blit destination paired with capture_target -
    /// render targets are not directly readable on every backend.
    capture_staging: ?render.TextureHandle = null,
    capture_width: u16 = 0,
    capture_height: u16 = 0,
    /// Active video recording, fed one composited frame per rendered
    /// frame of recording_session; frames commit two engine frames
    /// after they render so the GPU has finished writing them.
    recording: ?media_recording.Recording = null,
    recording_session: ?*Session = null,
    /// External render targets per encoder pool buffer, keyed by the
    /// native texture pointer - the pool cycles a few buffers, each
    /// needing its own persistent wrap.
    recording_slots: std.AutoHashMapUnmanaged(usize, RecordingSlot) = .empty,
    recording_pending: [2]?PendingRecordingFrame = .{ null, null },
    recording_pending_at: u8 = 0,
    /// The slot the current frame's composite renders into, when this
    /// frame both records and its wrap has landed.
    recording_frame_target: ?render.Renderer.OffscreenTarget = null,
    recording_last_timestamp: i64 = std.math.minInt(i64),
    recording_warmups: u32 = 0,
    recording_dropped: u32 = 0,
    /// Window-binding backends only: the encoder surface the composite
    /// re-presents into, separate from the sampleable frame target.
    recording_window_target: ?render.Renderer.OffscreenTarget = null,
};

const WorldStore = struct {
    state: WorldState = .{ .tracking_state = 0, .world_from_camera = identity16, .projection = identity16, .timestamp_us = 0 },
    planes: [max_world_planes]WorldPlane = undefined,
    plane_count: usize = 0,
    anchors: [max_world_anchors]WorldAnchor = undefined,
    anchor_count: usize = 0,
    light: WorldLight = .{ .ambient_intensity = 0, .color_temperature_kelvin = 0 },
    dropped_planes: u32 = 0,
    dropped_anchors: u32 = 0,
};

const identity16 = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };

const RecordingSlot = struct {
    persistent: render.Renderer.PersistentTexture = .{},
    target: ?render.Renderer.OffscreenTarget = null,
};

/// Whether this target's recording backend vends sampleable textures
/// (Apple) or a platform window the composite renders straight into
/// (Android's encoder input surface).
const recording_binds_window = media_recording.native_handle_kind == .window;

const PendingRecordingFrame = struct {
    frame: media_recording.Frame,
    timestamp_us: i64,
};

const CurrentFrame = struct {
    desc: FrameDesc,
    preview: render.PreviewFrame,
    owns_textures: bool = true,
};

pub const Session = struct {
    /// Engine-side audio analysis, fed by goss_session_submit_audio;
    /// once fed, its level and beat outrank the host's tick value.
    audio: audio_analysis.Analysis = .{},
    audio_engine_fed: bool = false,
    /// The platform's world understanding, fed by
    /// goss_session_submit_world; once fed, its tracking state
    /// outranks the host's tick value.
    world: WorldStore = .{},
    world_engine_fed: bool = false,
    /// The lens's rigid-body world, created at activation when any
    /// model node declares a body; poses drive those model matrices.
    physics_world: ?physics.World = null,
    physics_bodies: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    /// Cloth nodes: the solver body and the dynamic render mesh, by
    /// graph index. Cloth replaces the glb mesh with a simulated grid.
    cloth_bodies: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    cloth_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ClothMesh) = .empty,
    cloth_cols: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    /// Hair nodes: the solver hair id and its strand render mesh, by
    /// graph index. Hair is driven by the tracked head pose.
    hair_ids: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    hair_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.HairMesh) = .empty,
    particle_systems: std.AutoHashMapUnmanaged(graph.NodeIndex, particles.System) = .empty,
    particle_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, render.Renderer.ParticleMesh) = .empty,
    hair_vcount: std.AutoHashMapUnmanaged(graph.NodeIndex, u32) = .empty,
    physics_last_us: i64 = 0,

    engine: *Engine,
    controller: graph.DegradeController,
    current: ?CurrentFrame = null,
    /// Zero-copy camera ingress rebinds these every submit rather than
    /// creating a fresh bgfx handle per frame - see
    /// render.Renderer.PersistentTexture.rebind for why.
    preview_bgra: render.Renderer.PersistentTexture = .{},
    preview_y: render.Renderer.PersistentTexture = .{},
    preview_uv: render.Renderer.PersistentTexture = .{},
    copied_frames: u64 = 0,
    /// Set for exactly one renderCompositeChain call by
    /// goss_engine_capture_frame, then cleared - redirects the chain's
    /// true final stage into engine.capture_target instead of the swap
    /// chain directly, with an extra blit afterward so the swap chain
    /// still gets the same frame a normal render would have produced.
    capture_requested: bool = false,
    /// Nonzero only during a still capture: the resolution the capture
    /// target and final composite rect use instead of the preview swap
    /// chain, so a still is not clamped to preview size.
    capture_res_width: u16 = 0,
    capture_res_height: u16 = 0,
    /// Set while compositing one tile of a capture whose full size exceeds
    /// the GPU's max texture size: the capture target is the tile's own
    /// size and the final full-screen pass samples only this tile's UV
    /// span, so the tiles stitch byte-identical to a single full render.
    capture_tile: ?render.Renderer.Tile = null,
    /// Overrides the tile size a still capture splits at; zero uses the
    /// 16384 texture-size floor. Only conformance sets it, to force
    /// tiling at a small resolution and prove the stitch is byte-identical.
    capture_tile_cap: u32 = 0,
    face_tracking: ?*tracking.Tracking = null,
    hand_tracking: ?*tracking.hand_worker.HandTracking = null,
    pose_tracking: ?*tracking.pose_worker.PoseTracking = null,
    segmentation_worker: ?*segmentation.Segmentation = null,
    /// The most recent mask, uploaded as a real GPU texture the same way
    /// a lut.pass asset is - a raw byte array has no reason to cross the
    /// frozen ABI surface when nothing outside the render thread ever
    /// needs it, and a 256x256 texture upload is far cheaper than
    /// copying the mask through it. Recreated (not reused) each time a
    /// fresh mask is ready, since bgfx's static textures are immutable.
    segmentation_texture: ?render.TextureHandle = null,
    beauty_chain: ?*beauty.Beauty = null,
    /// The GPU beauty compositing bridge: beauty_input writes the live
    /// preview into a platform-shared surface gpupixel reads zero-copy,
    /// beauty_interop reads gpupixel's own output back out the same
    /// way. Both lazily created the first time a lens with a beauty
    /// node actually runs with beauty enabled, torn down on disable or
    /// session destroy.
    beauty_input: ?*beauty.InputSurface = null,
    beauty_interop: ?*beauty.Interop = null,
    /// beauty_input's shared surface wrapped as a render target bgfx
    /// draws the current frame into, and beauty_interop's composited
    /// result wrapped as a plain sampled texture - both recreated only
    /// when the underlying native surface actually changes (a resize,
    /// or first creation), tracked by comparing against the native
    /// pointer last wrapped rather than assuming stability from size
    /// alone.
    beauty_input_target: ?render.Renderer.OffscreenTarget = null,
    beauty_input_native: ?*anyopaque = null,
    beauty_input_persistent: render.Renderer.PersistentTexture = .{},
    /// Apple's beauty output handle - rebind every frame like camera
    /// ingress does, not cached-and-overridden-once like Android's below.
    beauty_output_persistent: render.Renderer.PersistentTexture = .{},
    beauty_output_texture: ?render.TextureHandle = null,
    beauty_output_native: ?*anyopaque = null,
    /// beauty.face/beauty.reshape/beauty.lipstick/beauty.blusher's own
    /// state on web, where there is no gpupixel beauty_chain to hold
    /// the six effect amounts or drive compositing - unused on every
    /// other target. Indices match core/lens/runtime.zig's EffectSlot
    /// (smooth, whiten, thin_face, big_eye, lipstick, blush); whiten is
    /// tracked but not yet applied (its four LUT textures aren't loaded
    /// on web yet).
    web_beauty_amounts: [6]f32 = @splat(0),
    /// Native mirror of the amounts goss_session_set_beauty has written
    /// into the gpupixel chain (same EffectSlot order) - the chain is
    /// opaque, so this is what lets beautyActive() see a direct set
    /// with no beauty-node lens active. Unused on web.
    beauty_amounts: [6]f32 = @splat(0),
    /// fs_blur_pass.sc's own two-pass scratch space (H then V) ahead of
    /// submitBeautyFace, plus beauty.reshape's own output target -
    /// sized and recreated the same lazy way ensureChainTargets already
    /// manages the lens chain's own targets.
    web_beauty_blur_h_target: ?render.Renderer.OffscreenTarget = null,
    web_beauty_mean_target: ?render.Renderer.OffscreenTarget = null,
    web_beauty_reshape_target: ?render.Renderer.OffscreenTarget = null,
    /// beauty.lipstick/beauty.blusher's own ping-pong pair: unlike every
    /// other pass here, a makeup draw only rasterizes its own mesh
    /// triangles, never a full-screen quad, so its background sample
    /// and its own write target can never be the same texture - lipstick
    /// reads whichever of these was blitted to first and writes the
    /// other, blush does the same starting from lipstick's output (or
    /// the blit target directly if lipstick is off).
    web_beauty_makeup_targets: [2]?render.Renderer.OffscreenTarget = .{ null, null },
    web_beauty_targets_width: u16 = 0,
    web_beauty_targets_height: u16 = 0,
    /// beauty.face's whiten effect reads these four - gray, origin,
    /// skin, and custom, matching gpupixel's own beauty_face_unit_
    /// filter.cc lookup set. Uploaded via goss_session_set_beauty_lut, a
    /// caller's own PNG decode (a browser's native one, most likely -
    /// there is no decoder wired into this build for web) handed in as
    /// raw RGBA; whiten stays inert until all four are loaded.
    web_beauty_lut_textures: [4]?render.TextureHandle = @splat(null),
    /// beauty.lipstick/beauty.blusher's own source images (gpupixel's
    /// mouth.png/blusher.png) - uploaded via goss_session_set_beauty_
    /// makeup_texture the same caller-decodes-the-PNG way the whiten
    /// LUTs are. An effect stays inert until its own texture loads,
    /// same rule as whiten's four.
    web_beauty_lipstick_texture: ?render.TextureHandle = null,
    web_beauty_blush_texture: ?render.TextureHandle = null,
    /// beauty.reshape/beauty.lipstick/beauty.blusher's face contour on
    /// web, set directly by the caller via goss_session_set_face_landmarks
    /// - the internal tracking worker s.face_tracking drives everywhere
    /// else is permanently unavailable here (goss_session_enable_face_
    /// tracking reports unsupported on this target), so there is no
    /// other way for a landmark-driven web effect to ever see a face.
    /// Null means no face this frame, the same meaning a zero
    /// landmark_count carries elsewhere.
    web_face_landmarks: ?[face.landmark_count]face.Landmark = null,
    lens_graph: graph.Graph,
    camera_node: graph.NodeIndex,
    active_lens: ?runtime.Lens = null,
    /// The active lens's script driver, when it has a script node, plus the
    /// null-terminated parameter names it exchanges each tick. Both are built
    /// at activation and torn down at deactivation, never per frame.
    script_engine: ?script.Script = null,
    script_param_names: []const [:0]const u8 = &.{},
    /// The lens's sound mixer and the mixer id each play_sound path resolves
    /// to, built from the bundle at activation. Playback is pulled out by the
    /// SDK; the engine only decodes and mixes.
    audio_mixer: ?audio_playback.Mixer = null,
    sound_ids: std.StringHashMapUnmanaged(u32) = .{},
    /// One bgfx program per currently-spliced shader.pass node, keyed by
    /// its graph index. Created at activation (goss_session_activate_lens_
    /// from_directory only - the bytes-based activate has no bundle path
    /// to read compiled shaders from), destroyed on deactivation.
    shader_programs: std.AutoHashMapUnmanaged(graph.NodeIndex, u16) = .empty,
    /// shader.pass nodes that named a mask channel, by graph index -
    /// filled at directory activation alongside the programs.
    shader_masks: std.AutoHashMapUnmanaged(graph.NodeIndex, u8) = .empty,
    /// One uploaded texture per named mask channel in use; index 0
    /// (person) aliases segmentation_texture and stays null here.
    segmentation_class_textures: [manifest.mask_channels.len]?render.TextureHandle = @splat(null),
    /// Every shader.pass and lut.pass node the active lens spliced, in
    /// one real draw-order sequence (runtime.Lens.compositePassNodes) -
    /// built once at directory-based activation regardless of whether
    /// each entry's resource (a program, a texture) is ready yet, since
    /// a lut.pass node's load can still be in flight the same frame its
    /// chain position is already known. Owned, rebuilt every
    /// activation, freed on teardown.
    chain_order: []runtime.CompositePass = &.{},
    /// One background loader per currently-spliced lut.pass node still
    /// waiting on its LUT image, keyed by graph index. Started at
    /// activation (directory-based only, same reason as shader_programs
    /// above), removed once goss_engine_render_frame's poll turns its
    /// result into a real texture or observes it failed.
    lut_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    /// One bgfx texture per lut.pass node whose asset finished loading.
    lut_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// One background loader per currently-spliced blend.pass node still
    /// waiting on its background image - mirrors lut_loaders exactly,
    /// one node type over.
    blend_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    /// One bgfx texture per blend.pass node whose background finished
    /// loading.
    blend_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    mesh_face_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ImageLoader) = .empty,
    mesh_face_textures: std.AutoHashMapUnmanaged(graph.NodeIndex, render.TextureHandle) = .empty,
    /// model.gltf nodes anchored to the tracked face, by graph index.
    model_face_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    /// model.gltf nodes anchored to the tracked world, by graph index.
    model_world_anchors: std.AutoHashMapUnmanaged(graph.NodeIndex, void) = .empty,
    /// One background loader per currently-spliced model.gltf node
    /// still waiting on its .glb - mirrors lut_loaders/blend_loaders,
    /// one node type over.
    model_loaders: std.AutoHashMapUnmanaged(graph.NodeIndex, *asset.ModelLoader) = .empty,
    /// One loaded model per model.gltf node whose .glb finished
    /// loading: the gpu mesh plus the plain animation-sampling data
    /// pollModelLoaders keeps around (not a bgfx resource, so it lives
    /// here rather than inside render.Renderer).
    model_meshes: std.AutoHashMapUnmanaged(graph.NodeIndex, LoadedModel) = .empty,
};

/// A model.gltf node's loaded state: real gpu buffers plus the plain
/// CPU-side animation data renderCompositeChain samples every frame at
/// the lens's own reported elapsed time.
const LoadedModel = struct {
    mesh: render.Renderer.ModelMesh,
    base_color: [4]f32,
    animation: ?gltf.DecodedAnimation,
};

fn abiAllocator() std.mem.Allocator {
    // wasm_allocator grows memory through a raw wasm memory.grow
    // instruction, invisible to Emscripten's own JS-side heap-view
    // tracking - real growth still happens, but any cached HEAP32/
    // HEAPU8 view the JS side is holding across the call goes stale
    // without Emscripten's own growth hook ever firing to refresh it
    // (confirmed: a plain _malloc-triggered growth refreshes correctly,
    // an allocation through here does not). Emscripten provides a real
    // libc malloc that coordinates that refresh correctly; freestanding
    // (the other wasm target this file compiles for) has no libc at
    // all, so it keeps wasm_allocator, the only option there.
    if (is_web) return std.heap.c_allocator;
    if (builtin.cpu.arch.isWasm()) return std.heap.wasm_allocator;
    if (builtin.single_threaded) return std.heap.page_allocator;
    return std.heap.smp_allocator;
}

fn clampCapacity(requested: u32, default: u32) u16 {
    const value = if (requested == 0) default else requested;
    return @intCast(@min(value, std.math.maxInt(u16)));
}

pub fn createEngine(gpa: std.mem.Allocator, config: EngineConfig) error{OutOfMemory}!*Engine {
    const engine = try gpa.create(Engine);
    engine.* = .{
        .gpa = gpa,
        .texture_pool = graph.Pool.init(gpa),
        .staging_pool = graph.Pool.init(gpa),
        .texture_pool_capacity = clampCapacity(config.texture_pool_capacity, default_texture_pool_capacity),
        .staging_pool_capacity = clampCapacity(config.staging_pool_capacity, default_staging_pool_capacity),
    };
    return engine;
}

pub fn destroyEngine(engine: *Engine) void {
    if (engine.recording != null) _ = finishRecording(engine);
    for (engine.chain_targets) |slot| {
        if (slot) |target| render.Renderer.destroyOffscreenTarget(target);
    }
    if (engine.capture_target) |target| render.Renderer.destroyOffscreenTarget(target);
    if (engine.capture_staging) |staging| {
        if (engine.renderer) |*r| r.destroyTexture(staging);
    }
    if (engine.renderer) |*r| r.deinit();
    engine.texture_pool.deinit();
    engine.staging_pool.deinit();
    engine.gpa.destroy(engine);
}

/// (Re)creates both ping-pong chain targets when the frame size changes
/// or they don't exist yet - never per frame once a size is stable, so
/// the render path itself allocates nothing.
fn ensureChainTargets(e: *Engine, width: u16, height: u16) !void {
    if (e.chain_width == width and e.chain_height == height and e.chain_targets[0] != null) return;
    for (&e.chain_targets) |*slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    e.chain_width = width;
    e.chain_height = height;
}

fn ensureCaptureTarget(e: *Engine, width: u16, height: u16) !void {
    if (e.capture_width == width and e.capture_height == height and e.capture_target != null) return;
    if (e.capture_target) |target| render.Renderer.destroyOffscreenTarget(target);
    if (e.capture_staging) |staging| {
        if (e.renderer) |*r| r.destroyTexture(staging);
    }
    e.capture_target = try render.Renderer.createOffscreenTarget(width, height);
    e.capture_staging = try render.Renderer.createReadbackTexture(width, height);
    e.capture_width = width;
    e.capture_height = height;
}

/// Whether the live preview needs the GPU beauty compositing bridge
/// running this frame: an active lens with beauty nodes, or any direct
/// nonzero setBeauty amount - the same two sources webBeautyActive
/// already honors, so a slider works with no lens active on native too.
fn beautyActive(s: *const Session) bool {
    if (s.beauty_chain == null) return false;
    if (s.active_lens) |lens| {
        if (lens.hasBeautyNodes()) return true;
    }
    for (s.beauty_amounts) |amount| {
        if (amount > 0.0) return true;
    }
    return false;
}

/// Runs the beauty chain over the frame the PREVIOUS call wrote into the
/// shared surface, returns that as the composited result, then queues
/// this frame's own camera content into the same surface for the next
/// call to read - one frame of latency, and the reason this is
/// structured read-then-write rather than write-then-read. bgfx only
/// actually executes a queued draw (the write below) when this frame's
/// own bgfx_frame() call runs, at the end of goss_engine_render_frame,
/// strictly after this function returns; reading the surface for
/// content this same call just queued would race a Metal write that has
/// not happened on the GPU yet. Reading what a fully-executed PRIOR
/// frame wrote is what makes the cross-API bridge (Metal write, GL
/// read) correct without forcing a synchronous GPU stall every frame -
/// the CPU roundtrip goss_session_beautify_frame already accepts a much
/// larger per-frame cost than one frame of latency ever could.
///
/// The live-preview integration goss_session_beautify_frame's own doc
/// comment names as this row's device-side counterpart. Draws into its
/// own dedicated, platform-shared target rather than the ping-pong pair
/// the rest of the chain shares, since that target has to stay backed
/// by the same native surface gpupixel reads zero-copy on its own
/// thread; consumes exactly one view id, reserved by the caller in
/// next_view_id before any chain_order stage claims one. Degrades to
/// returning input_texture unchanged if any step fails - the SPEC's
/// rule for a node whose capability is unavailable holding its default
/// state, same as blend.pass's mask.
fn applyBeautyCompositing(r: *render.Renderer, s: *Session, next_view_id: *u8, width: u16, height: u16, rotation: u32, mirror: bool, input_texture: render.TextureHandle) render.TextureHandle {
    const chain = s.beauty_chain.?;

    // Android's GLES fallback has no route from the composited buffer
    // back into bgfx (the Metal-view bridge is apple-only, the
    // AHardwareBuffer import needs Vulkan) - running the chain there
    // burns a full gpupixel pass per frame nothing can ever display.
    if (is_android and !r.isAndroidVulkan()) return input_texture;

    const input_surface = s.beauty_input orelse blk: {
        const created = beauty.inputSurfaceCreate(s.engine.gpa) catch return input_texture;
        s.beauty_input = created;
        break :blk created;
    };
    const interop = s.beauty_interop orelse blk: {
        const created = beauty.interopCreate(s.engine.gpa) catch return input_texture;
        s.beauty_interop = created;
        break :blk created;
    };

    // null device on GLES: a context is implicit and thread-bound,
    // nothing to hand across this boundary - Metal needs one, GLES
    // ignores it.
    const android_vulkan = r.isAndroidVulkan();
    const device = r.nativeDevice();
    const native_texture = if (android_vulkan)
        beauty.inputSurfaceHardwareBuffer(input_surface, width, height) orelse return input_texture
    else
        beauty.inputSurfaceNativeTexture(input_surface, device, width, height) orelse return input_texture;

    const target_has_a_prior_write = s.beauty_input_target != null and s.beauty_input_native == native_texture;
    if (!target_has_a_prior_write) {
        if (s.beauty_input_target) |old| render.Renderer.destroyOffscreenTarget(old);
        s.beauty_input_target = null;
        // May legitimately fail the very first time a given native
        // surface is wrapped: the underlying bgfx texture's own
        // creation is queued, not immediate, and nothing has forced it
        // to actually process yet this frame. Leaving beauty_input_
        // native unset here means the next call retries the whole wrap
        // rather than caching a handle that never resolved.
        const wrapped = if (android_vulkan)
            r.createAndroidBeautyRenderTarget(width, height, native_texture) orelse return input_texture
        else
            r.wrapExternalRenderTarget(&s.beauty_input_persistent, width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, @intFromPtr(native_texture)) orelse return input_texture;
        s.beauty_input_target = render.Renderer.createExternalTarget(wrapped) catch {
            // android's handle is this call's own to destroy; the
            // persistent one beauty_input_persistent owns survives to
            // retry next frame instead of dangling under it.
            if (android_vulkan) r.destroyTexture(wrapped);
            return input_texture;
        };
        s.beauty_input_native = native_texture;
    }

    var beautified = input_texture;
    if (target_has_a_prior_write) {
        var result: face.Result = undefined;
        var tracked: ?*const face.Result = null;
        if (s.face_tracking) |worker| {
            if (tracking.readResult(worker, &result)) tracked = &result;
        }
        const processed = beauty.processTexture(input_surface, chain, width, height, rotation, mirror, tracked);
        if (processed) {
            const composited = beauty.composite(interop, chain, width, height);
            if (composited) |c| {
                if (android_vulkan) {
                    if (s.beauty_output_texture == null or s.beauty_output_native != c) {
                        if (s.beauty_output_texture) |old| r.destroyTexture(old);
                        s.beauty_output_texture = r.wrapAndroidBeautyOutput(width, height, c);
                        s.beauty_output_native = c;
                    }
                    if (s.beauty_output_texture) |output| beautified = output;
                } else if (beauty.interopNativeTexture(interop, device)) |metal_texture| {
                    // metal_texture's override needs a frame gap to land,
                    // same as camera ingress - rebind every frame rather
                    // than caching a still-pending one.
                    beautified = s.beauty_output_persistent.rebind(width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, @intFromPtr(metal_texture));
                }
            }
        }
    }

    const view_id = next_view_id.*;
    next_view_id.* += 1;
    render.Renderer.setViewTarget(view_id, s.beauty_input_target.?, width, height);
    r.submitShaderPass(view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);

    return beautified;
}

/// Whether beauty.face or beauty.reshape has anything to actually draw
/// this frame on web - whiten alone only counts once its four LUT
/// textures have loaded (goss_session_set_beauty_lut), lipstick/blush
/// aren't wired (a mesh draw, not a full-screen pass like these two).
fn webBeautyActive(s: *const Session) bool {
    if (!is_web) return false;
    const smooth = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.smooth)];
    const whiten = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.whiten)];
    const thin_face = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.thin_face)];
    const big_eye = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.big_eye)];
    const lipstick = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.lipstick)];
    const blush = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.blush)];
    const luts_loaded = for (s.web_beauty_lut_textures) |slot| {
        if (slot == null) break false;
    } else true;
    return smooth > 0.0 or thin_face > 0.0 or big_eye > 0.0 or (whiten > 0.0 and luts_loaded) or
        (lipstick > 0.0 and s.web_beauty_lipstick_texture != null) or (blush > 0.0 and s.web_beauty_blush_texture != null);
}

/// The one beauty-active check every caller should reach through -
/// native's gpupixel chain on every other target, web_beauty_amounts
/// here. goss_engine_render_frame's own fast-path gate and
/// renderCompositeChain's chain dispatch both need this, and both once
/// called beautyActive() directly - a real bug, not hypothetical: with
/// no lens active (chain_order empty), render_frame's own gate skipped
/// renderCompositeChain (and therefore applyWebBeautyChain) entirely on
/// web, silently rendering the plain passthrough preview regardless of
/// what web_beauty_amounts held. Caught by an actual browser proof
/// (whiten toggled with real LUTs loaded, zero visible change), not by
/// any Zig-level test - anyBeautyActive exists so the two call sites
/// can't drift apart again the same way.
fn anyBeautyActive(s: *const Session) bool {
    return if (is_web) webBeautyActive(s) else beautyActive(s);
}

fn ensureWebBeautyTargets(s: *Session, width: u16, height: u16) !void {
    if (s.web_beauty_targets_width == width and s.web_beauty_targets_height == height and s.web_beauty_blur_h_target != null) return;
    for ([_]*?render.Renderer.OffscreenTarget{
        &s.web_beauty_blur_h_target,
        &s.web_beauty_mean_target,
        &s.web_beauty_reshape_target,
        &s.web_beauty_makeup_targets[0],
        &s.web_beauty_makeup_targets[1],
    }) |slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = try render.Renderer.createOffscreenTarget(width, height);
    }
    s.web_beauty_targets_width = width;
    s.web_beauty_targets_height = height;
}

/// beauty.face and beauty.reshape's own dispatch on web, in place of
/// applyBeautyCompositing's gpupixel bridge above (not ported to this
/// target). Reshape runs first, matching the reference GLSL's own
/// composition order (warp which pixel gets sampled, then smooth/
/// whiten the color that lands) even though they're two separate bgfx
/// passes here rather than one combined shader.
fn applyWebBeautyChain(r: *render.Renderer, s: *Session, next_view_id: *u8, width: u16, height: u16, input_texture: render.TextureHandle) !render.TextureHandle {
    try ensureWebBeautyTargets(s, width, height);
    var current = input_texture;

    // Shared by beauty.reshape (only needs the base 106) and the
    // lipstick/blush mesh (needs all 111, including face106.zig's five
    // derived hub points) - computed once regardless of which of the
    // four landmark-driven effects are actually active this frame.
    var contour: [face106.point_count * 2]f32 = undefined;
    const has_face = blk: {
        // Web has no internal tracking worker (goss_session_enable_face_
        // tracking reports unsupported on this target) - the caller
        // feeds landmarks directly via goss_session_set_face_landmarks.
        const landmarks = s.web_face_landmarks orelse break :blk false;
        face106.fill(&landmarks, @floatFromInt(width), @floatFromInt(height), &contour);
        break :blk true;
    };

    const thin_face = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.thin_face)];
    const big_eye = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.big_eye)];
    if (has_face and (thin_face > 0.0 or big_eye > 0.0)) {
        const view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_reshape_target.?, width, height);
        const aspect_ratio: f32 = @as(f32, @floatFromInt(width)) / @as(f32, @floatFromInt(height));
        r.submitBeautyReshape(view_id, current, contour[0 .. render.face_point_vec4_count * 4], aspect_ratio, thin_face, big_eye);
        current = s.web_beauty_reshape_target.?.texture;
    }

    const smooth = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.smooth)];
    const whiten_requested = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.whiten)];
    const luts_loaded = for (s.web_beauty_lut_textures) |slot| {
        if (slot == null) break false;
    } else true;
    // Whiten renders inert until all four LUT textures load on web
    // (goss_session_set_beauty_lut) - the amount the caller actually
    // requested still gets tracked either way, just not applied yet.
    const whiten = if (luts_loaded) whiten_requested else 0.0;
    if (smooth > 0.0 or whiten > 0.0) {
        const step_x = 1.0 / @as(f32, @floatFromInt(width));
        const step_y = 1.0 / @as(f32, @floatFromInt(height));
        var view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_blur_h_target.?, width, height);
        r.submitBlurPass(view_id, current, .{ step_x, 0.0 });
        view_id = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id, s.web_beauty_mean_target.?, width, height);
        r.submitBlurPass(view_id, s.web_beauty_blur_h_target.?.texture, .{ 0.0, step_y });

        const view_id2 = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(view_id2, s.web_beauty_blur_h_target.?, width, height);
        // default_mask_texture is a safe 1x1 placeholder for whichever
        // LUT slots aren't loaded yet - the shader never actually
        // samples them while whiten is 0.
        const lut = struct {
            fn textureOr(slot: ?render.TextureHandle, fallback: render.TextureHandle) render.TextureHandle {
                return slot orelse fallback;
            }
        }.textureOr;
        r.submitBeautyFace(
            view_id2,
            current,
            s.web_beauty_mean_target.?.texture,
            lut(s.web_beauty_lut_textures[0], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[1], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[2], r.default_mask_texture),
            lut(s.web_beauty_lut_textures[3], r.default_mask_texture),
            smooth,
            whiten,
        );
        current = s.web_beauty_blur_h_target.?.texture;
    }

    const lipstick = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.lipstick)];
    const blush = s.web_beauty_amounts[@intFromEnum(runtime.EffectSlot.blush)];
    const lipstick_ready = lipstick > 0.0 and s.web_beauty_lipstick_texture != null;
    const blush_ready = blush > 0.0 and s.web_beauty_blush_texture != null;
    if (has_face and (lipstick_ready or blush_ready)) {
        // A makeup draw only rasterizes its own mesh triangles, so its
        // background sample and its write target can never be the same
        // texture (a read-write feedback hazard) - blit current into
        // slot 0 first, then each active effect reads whichever slot
        // holds the frame so far and writes the other.
        const blit_view = next_view_id.*;
        next_view_id.* += 1;
        render.Renderer.setViewTarget(blit_view, s.web_beauty_makeup_targets[0].?, width, height);
        r.submitShaderPass(blit_view, r.passthroughProgram(), current);
        var slot: usize = 0;

        if (lipstick_ready) {
            const view_id = next_view_id.*;
            next_view_id.* += 1;
            const next_slot = 1 - slot;
            render.Renderer.setViewTarget(view_id, s.web_beauty_makeup_targets[next_slot].?, width, height);
            r.submitMakeup(view_id, s.web_beauty_makeup_targets[slot].?.texture, s.web_beauty_lipstick_texture.?, r.makeupLipstickUvBuffer(), &contour, lipstick);
            slot = next_slot;
        }
        if (blush_ready) {
            const view_id = next_view_id.*;
            next_view_id.* += 1;
            const next_slot = 1 - slot;
            render.Renderer.setViewTarget(view_id, s.web_beauty_makeup_targets[next_slot].?, width, height);
            r.submitMakeup(view_id, s.web_beauty_makeup_targets[slot].?.texture, s.web_beauty_blush_texture.?, r.makeupBlushUvBuffer(), &contour, blush);
            slot = next_slot;
        }
        current = s.web_beauty_makeup_targets[slot].?.texture;
    }

    return current;
}

/// Draws the active lens's full composite chain - beauty, shader.pass,
/// lut.pass, and blend.pass mixed freely: the camera preview captures
/// into one ping-pong target (view 0), beauty (when active) composites
/// into its own dedicated target right after, every ready lens stage
/// reads the previous stage and writes the other ping-pong target, and
/// whichever stage draws last presents straight to the swap chain
/// instead of an offscreen one. View ids increase monotonically because
/// bgfx orders view execution by id, not by submission order - that
/// ordering is what makes this an actual chain rather than stages
/// racing each other. A lens stage whose resource (a program, a
/// texture) isn't ready yet - most often a lut.pass or blend.pass node
/// whose asset hasn't landed - is skipped outright: the chain just has
/// one fewer stage this frame, not a gap that draws nothing. A
/// blend.pass node whose background HAS landed but segmentation is
/// unavailable still draws, against the renderer's always-foreground
/// default mask.
fn renderCompositeChain(e: *Engine, r: *render.Renderer, s: *Session, current: CurrentFrame, rotation: u32, mirror: bool) !void {
    // The tile is set per final full-screen pass below; every source-res
    // intermediate draw and every non-capture frame renders untiled.
    r.tile = null;
    var ready_count: usize = 0;
    for (s.chain_order) |entry| {
        const ready = switch (entry.kind) {
            .shader => s.shader_programs.contains(entry.graph_index),
            .lut => s.lut_textures.contains(entry.graph_index),
            // A blur pass needs no loaded resource - the blur program is
            // built in - so it is always ready to draw.
            .blur => true,
            // Only the background image gates readiness - the mask
            // degrades to the renderer's always-foreground default
            // when segmentation is unavailable (SPEC's rule: a node
            // consuming an unavailable capability's data holds its
            // default state, not blocks the chain).
            .blend => s.blend_textures.contains(entry.graph_index),
            // Like blend's mask: the face is a capability input whose
            // absence degrades (no draw), never blocks the chain.
            .mesh => s.mesh_face_textures.contains(entry.graph_index),
            .model => s.model_meshes.contains(entry.graph_index) or s.cloth_meshes.contains(entry.graph_index) or s.hair_meshes.contains(entry.graph_index) or s.particle_meshes.contains(entry.graph_index),
        };
        if (ready) ready_count += 1;
    }
    const beauty_active = anyBeautyActive(s);
    const capture_out_width: u16 = if (s.capture_requested and s.capture_res_width != 0) s.capture_res_width else @intCast(r.width);
    const capture_out_height: u16 = if (s.capture_requested and s.capture_res_height != 0) s.capture_res_height else @intCast(r.height);
    if (s.capture_requested) try ensureCaptureTarget(e, capture_out_width, capture_out_height);
    if (ready_count == 0 and !beauty_active) {
        // view 0 may still be bound to an offscreen chain/beauty target
        // from an earlier frame that took the other branch below -
        // bgfx_set_view_frame_buffer is stateful across frames, nothing
        // resets it automatically once the chain/beauty that needed it
        // stops being active. Without this, this branch keeps drawing
        // into that stale offscreen target forever, never the real
        // backbuffer, and the visible canvas simply stops updating -
        // found via a real toggle-on-then-off repro (whiten set to 1
        // then back to 0), not a static read.
        const preview_rect_w: u16 = if (s.capture_requested) capture_out_width else @intCast(r.width);
        const preview_rect_h: u16 = if (s.capture_requested) capture_out_height else @intCast(r.height);
        // A plain capture (no passes) draws straight into the final target,
        // so the tile applies here too; capture_still only sets a tile when
        // the frame is upright, keeping the tiled quad axis-aligned.
        r.tile = s.capture_tile;
        render.Renderer.setViewTarget(0, finalTarget(e, s), preview_rect_w, preview_rect_h);
        r.submitPreview(0, current.preview, rotation * 90, mirror);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, 1);
        blitRecordingToSwapChain(e, r, 1);
        return;
    }

    const width: u16 = @intCast(current.desc.width);
    const height: u16 = @intCast(current.desc.height);
    // The swap chain's own real size, never the source frame's - a
    // stage whose output is null draws straight to the swap chain
    // (see the loop below), and that target is whatever size the
    // renderer was actually initialized/resized to, not the camera
    // frame's own resolution. Conflating the two used to size the
    // final view's rect to the frame's resolution regardless of the
    // swap chain's real size: harmless for a full-screen quad (still
    // fills whatever clamped viewport results) but silently
    // mis-scaled the picture whenever the two sizes differ, which a
    // model.gltf node's own non-full-screen mesh finally made visible
    // - found via a real corpus frame (2400x3000) rendered into a
    // 400x300 swap chain, the mesh landing entirely outside the
    // visible viewport.
    const output_width: u16 = if (s.capture_requested) capture_out_width else @intCast(r.width);
    const output_height: u16 = if (s.capture_requested) capture_out_height else @intCast(r.height);
    try ensureChainTargets(e, width, height);
    const targets = [2]render.Renderer.OffscreenTarget{ e.chain_targets[0].?, e.chain_targets[1].? };

    render.Renderer.setViewTarget(0, targets[0], width, height);
    r.submitPreview(0, current.preview, rotation * 90, mirror);
    var input_texture = targets[0].texture;
    var next_view_id: u8 = 1;

    if (beauty_active) {
        input_texture = if (is_web)
            try applyWebBeautyChain(r, s, &next_view_id, width, height, input_texture)
        else
            applyBeautyCompositing(r, s, &next_view_id, width, height, rotation, mirror, input_texture);
    }

    var drawn: usize = 0;
    var next_slot: usize = 1;
    for (s.chain_order) |entry| {
        switch (entry.kind) {
            .shader => {
                const program_idx = s.shader_programs.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                const shader_mask = blk: {
                    // A named channel with no live data samples zero:
                    // no signal means the subject is absent, so the
                    // effect draws nothing rather than everywhere.
                    const channel = s.shader_masks.get(entry.graph_index) orelse break :blk r.default_mask_texture;
                    if (channel == 0) break :blk s.segmentation_texture orelse r.zero_mask_texture;
                    break :blk s.segmentation_class_textures[channel] orelse r.zero_mask_texture;
                };
                r.submitShaderPass(view_id, .{ .idx = program_idx }, input_texture, shader_mask);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .lut => {
                const lut_texture = s.lut_textures.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitLutPass(view_id, input_texture, lut_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .blur => {
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                const rect_w = if (is_final) output_width else width;
                const rect_h = if (is_final) output_height else height;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, rect_w, rect_h) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                const step: [2]f32 = .{ 1.5 / @as(f32, @floatFromInt(rect_w)), 1.5 / @as(f32, @floatFromInt(rect_h)) };
                r.submitBlurPass(view_id, input_texture, step);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .blend => {
                const background_texture = s.blend_textures.get(entry.graph_index) orelse continue;
                const mask_texture = s.segmentation_texture orelse r.default_mask_texture;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                r.tile = if (is_final) s.capture_tile else null;
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitBlendPass(view_id, input_texture, background_texture, mask_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .mesh => {
                const mesh_texture = s.mesh_face_textures.get(entry.graph_index) orelse continue;
                drawn += 1;
                const view_id = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                // The frame passes through whole; the mesh then draws
                // only its own triangles over it. No tracked face means
                // no draw, the capability's defined degradation.
                r.submitShaderPass(view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);
                if (s.face_tracking) |worker| {
                    var tracked: face.Result = undefined;
                    if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                        r.submitFaceMesh(view_id, input_texture, mesh_texture, &tracked.landmarks, @floatFromInt(width), @floatFromInt(height), 1.0);
                    }
                }
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .model => {
                if (s.particle_meshes.get(entry.graph_index)) |particle_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    // A capture is a snapshot; only a live frame advances the
                    // fountain, at a fixed step so the sim stays deterministic.
                    if (s.particle_systems.getPtr(entry.graph_index)) |sys| {
                        if (!s.capture_requested) sys.step(1.0 / 60.0);
                        const count = sys.field.count;
                        if (s.engine.gpa.alloc(f32, count * 3)) |positions| {
                            defer s.engine.gpa.free(positions);
                            sys.writePositions(positions);
                            r.updateParticleMesh(particle_mesh, positions);
                        } else |_| {}
                    }
                    const aspect_ratio: f32 = @as(f32, @floatFromInt(rect_w)) / @as(f32, @floatFromInt(rect_h));
                    r.submitParticles(blit_view, mesh_view, input_texture, particle_mesh, .{ 0.9, 0.8, 0.3, 1.0 }, aspect_ratio);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.hair_meshes.get(entry.graph_index)) |hair_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    if (s.hair_ids.get(entry.graph_index)) |hid| {
                        if (s.physics_world) |world| {
                            // Drive the hair with the tracked head pose;
                            // identity (hair just hangs) without a face.
                            var head = math.Mat4.identity;
                            if (s.face_tracking) |worker| {
                                var tracked: face.Result = undefined;
                                if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                                    if (face_geometry.estimateHeadPose(&tracked.landmarks)) |h| head = h;
                                }
                            }
                            const dt = if (s.physics_last_us != 0 and s.current != null and s.current.?.desc.timestamp_us > s.physics_last_us)
                                @min(@as(f32, @floatFromInt(s.current.?.desc.timestamp_us - s.physics_last_us)) / 1_000_000.0, 0.25)
                            else
                                1.0 / 60.0;
                            world.hairUpdate(hid, @bitCast(head.cols), dt);
                            const vcount = s.hair_vcount.get(entry.graph_index) orelse 0;
                            if (vcount > 0) {
                                if (s.engine.gpa.alloc(f32, vcount * 3)) |positions| {
                                    defer s.engine.gpa.free(positions);
                                    _ = world.hairRead(hid, positions);
                                    r.updateHairMesh(hair_mesh, positions);
                                } else |_| {}
                            }
                        }
                    }
                    const aspect_ratio: f32 = @as(f32, @floatFromInt(rect_w)) / @as(f32, @floatFromInt(rect_h));
                    r.submitHair(blit_view, mesh_view, input_texture, hair_mesh, .{ 0.15, 0.1, 0.08, 1.0 }, aspect_ratio);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                if (s.cloth_meshes.get(entry.graph_index)) |cloth_mesh| {
                    drawn += 1;
                    const blit_view = next_view_id;
                    next_view_id += 1;
                    const mesh_view = next_view_id;
                    next_view_id += 1;
                    const is_final = drawn == ready_count;
                    const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                    const rect_w = if (output != null and !is_final) width else output_width;
                    const rect_h = if (output != null and !is_final) height else output_height;
                    if (output) |target| {
                        render.Renderer.setViewTarget(blit_view, target, rect_w, rect_h);
                        render.Renderer.setViewTarget(mesh_view, target, rect_w, rect_h);
                    } else {
                        render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                        render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                    }
                    if (s.cloth_bodies.get(entry.graph_index)) |body| {
                        if (s.physics_world) |world| {
                            const vcount = s.cloth_cols.get(entry.graph_index) orelse 0;
                            if (vcount > 0) {
                                if (s.engine.gpa.alloc(f32, vcount * 3)) |positions| {
                                    defer s.engine.gpa.free(positions);
                                    _ = world.clothRead(body, positions);
                                    r.updateClothMesh(cloth_mesh, positions);
                                } else |_| {}
                            }
                        }
                    }
                    const aspect_ratio: f32 = @as(f32, @floatFromInt(rect_w)) / @as(f32, @floatFromInt(rect_h));
                    r.submitCloth(blit_view, mesh_view, input_texture, cloth_mesh, .{ 0.4, 0.55, 0.85, 1.0 }, aspect_ratio);
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                const loaded = s.model_meshes.get(entry.graph_index) orelse continue;
                drawn += 1;
                // Two views, not one: the blit needs the flat ortho
                // every other pass shares, the mesh needs a real 3D
                // view/projection, and bgfx's view transform is a
                // per-view state, not per-draw - see submitModel's own
                // doc comment.
                const blit_view = next_view_id;
                next_view_id += 1;
                const mesh_view = next_view_id;
                next_view_id += 1;
                const is_final = drawn == ready_count;
                const output = if (is_final) finalTarget(e, s) else targets[next_slot % 2];
                const rect_width = if (output != null and !is_final) width else output_width;
                const rect_height = if (output != null and !is_final) height else output_height;
                if (output) |target| {
                    render.Renderer.setViewTarget(blit_view, target, rect_width, rect_height);
                    render.Renderer.setViewTarget(mesh_view, target, rect_width, rect_height);
                } else {
                    render.Renderer.setViewTarget(blit_view, null, output_width, output_height);
                    render.Renderer.setViewTarget(mesh_view, null, output_width, output_height);
                }
                const elapsed_us = if (s.active_lens) |*lens| lens.modelElapsedUs(entry.graph_index) orelse 0 else 0;
                const elapsed_seconds = @as(f32, @floatFromInt(elapsed_us)) / 1_000_000.0;
                var model_matrix = if (loaded.animation) |*anim| anim.sample(elapsed_seconds) else math.Mat4.identity;
                if (s.physics_bodies.get(entry.graph_index)) |body_id| {
                    if (s.physics_world) |world| {
                        if (world.bodyPose(body_id)) |body_pose| {
                            model_matrix = .{ .cols = @bitCast(body_pose) };
                        } else |_| {}
                    }
                }
                if (s.model_world_anchors.contains(entry.graph_index)) {
                    // World-anchored content draws from the platform
                    // camera's own view and projection, at world anchor
                    // zero when one exists, else the world origin; no
                    // tracking means the standard nothing-drawn state.
                    if (s.world_engine_fed and s.world.state.tracking_state == 2) {
                        const world_from_camera: math.Mat4 = .{ .cols = @bitCast(s.world.state.world_from_camera) };
                        const projection: math.Mat4 = .{ .cols = @bitCast(s.world.state.projection) };
                        const view = world_from_camera.inverseRigid();
                        const anchor_pose: math.Mat4 = if (s.world.anchor_count > 0)
                            .{ .cols = @bitCast(s.world.anchors[0].pose) }
                        else
                            math.Mat4.identity;
                        r.submitModelWithCamera(blit_view, mesh_view, input_texture, loaded.mesh, anchor_pose.mul(model_matrix), view, projection, loaded.base_color);
                    } else {
                        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                    }
                    if (output) |target| {
                        input_texture = target.texture;
                        if (!is_final) next_slot += 1;
                    }
                    continue;
                }
                var anchored_without_face = false;
                if (s.model_face_anchors.contains(entry.graph_index)) {
                    anchored_without_face = true;
                    if (s.face_tracking) |worker| {
                        var tracked: face.Result = undefined;
                        if (tracking.readResult(worker, &tracked) and tracked.landmark_count_out > 0 and tracked.presence >= 0.5) {
                            if (face_geometry.estimateHeadPose(&tracked.landmarks)) |head| {
                                // The head transform lands in source-frame
                                // pixels, stretched by the preview blit to
                                // fill a rect whose z=0 plane spans
                                // 4*tan(22.5) world units vertically.
                                const world_height: f32 = 1.6568542;
                                const rect_aspect = @as(f32, @floatFromInt(rect_width)) / @as(f32, @floatFromInt(rect_height));
                                const sx = world_height * rect_aspect / @as(f32, @floatFromInt(width));
                                const sy = world_height / @as(f32, @floatFromInt(height));
                                const pixel_to_world: math.Mat4 = .{ .cols = .{
                                    .{ sx, 0, 0, 0 },
                                    .{ 0, -sy, 0, 0 },
                                    .{ 0, 0, -sy, 0 },
                                    .{ -0.5 * world_height * rect_aspect, 0.5 * world_height, 0, 1 },
                                } };
                                model_matrix = pixel_to_world.mul(head).mul(model_matrix);
                                anchored_without_face = false;
                            }
                        }
                    }
                }
                const aspect_ratio: f32 = @as(f32, @floatFromInt(rect_width)) / @as(f32, @floatFromInt(rect_height));
                if (anchored_without_face) {
                    // The anchor's capability degradation: the frame
                    // still passes through, the mesh alone stays off.
                    r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);
                } else {
                    r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, model_matrix, loaded.base_color, aspect_ratio);
                }
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
        }
    }

    if (s.capture_requested and ready_count > 0) blitCaptureToSwapChain(e, r, next_view_id);
    if (ready_count > 0) blitRecordingToSwapChain(e, r, next_view_id + 1);

    if (ready_count == 0) {
        // beauty_active is guaranteed true here (the ready_count == 0
        // and !beauty_active case already returned above): beauty's own
        // output is a plain sampled texture, never a view's render
        // target, so with no lens stage to hand it off to, it still
        // needs one real draw to actually reach the swap chain.
        render.Renderer.setViewTarget(next_view_id, finalTarget(e, s), output_width, output_height);
        r.submitShaderPass(next_view_id, r.passthroughProgram(), input_texture, r.default_mask_texture);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, next_view_id + 1);
        blitRecordingToSwapChain(e, r, next_view_id + 2);
    }
}

/// The composite chain's true final-stage target: the swap chain
/// directly, or - for exactly the one frame goss_engine_capture_frame
/// requested - the dedicated capture target instead, so the chain's
/// real output lands somewhere bgfx_read_texture can read it back from
/// after the frame completes.
fn finalTarget(e: *Engine, s: *Session) ?render.Renderer.OffscreenTarget {
    if (s.capture_requested) return e.capture_target;
    return e.recording_frame_target;
}

/// Draws the just-composited capture target to the swap chain, so a
/// captured frame still displays normally - the same passthrough blit
/// the ready_count == 0 beauty-only path already uses to reach the
/// swap chain, reused here for the same reason.
fn blitCaptureToSwapChain(e: *Engine, r: *render.Renderer, view_id: u8) void {
    const target = e.capture_target orelse return;
    render.Renderer.setViewTarget(view_id, null, @intCast(r.width), @intCast(r.height));
    r.submitShaderPass(view_id, r.passthroughProgram(), target.texture, r.default_mask_texture);
}

/// The recording sibling of blitCaptureToSwapChain: a recorded frame's
/// composite lands in the encoder's own surface, so the swap chain
/// still needs a passthrough of it to display normally.
fn blitRecordingToSwapChain(e: *Engine, r: *render.Renderer, view_id: u8) void {
    const target = e.recording_frame_target orelse return;
    render.Renderer.setViewTarget(view_id, null, @intCast(r.width), @intCast(r.height));
    r.submitShaderPass(view_id, r.passthroughProgram(), target.texture, r.default_mask_texture);
    if (recording_binds_window) {
        if (e.recording_window_target) |window| {
            const rec = &(e.recording.?);
            render.Renderer.setViewTarget(view_id + 1, window, @intCast(rec.config.width), @intCast(rec.config.height));
            r.submitShaderPass(view_id + 1, r.passthroughProgram(), target.texture, r.default_mask_texture);
        }
    }
}

pub fn createSession(engine: *Engine, config: SessionConfig) error{OutOfMemory}!*Session {
    const session = try engine.gpa.create(Session);
    errdefer engine.gpa.destroy(session);
    const budget = if (config.frame_budget_us == 0) default_frame_budget_us else config.frame_budget_us;
    session.* = .{
        .engine = engine,
        .controller = graph.DegradeController.init(.{ .budget_us = budget }),
        .lens_graph = graph.Graph.init(engine.gpa),
        .camera_node = undefined,
    };
    session.camera_node = session.lens_graph.addNode(.{
        .role = .source,
        .outputs = &.{.{ .kind = .texture }},
    }) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => unreachable, // a fresh graph's first node cannot violate any other EditError
    };
    return session;
}

pub fn destroySession(session: *Session) void {
    if (session.engine.recording_session == session) _ = finishRecording(session.engine);
    teardownScript(session);
    destroySounds(session);
    destroyShaderPrograms(session);
    session.shader_programs.deinit(session.engine.gpa);
    session.shader_masks.deinit(session.engine.gpa);
    destroyLutState(session);
    session.lut_loaders.deinit(session.engine.gpa);
    session.lut_textures.deinit(session.engine.gpa);
    destroyBlendState(session);
    destroyMeshFaceState(session);
    session.blend_loaders.deinit(session.engine.gpa);
    session.blend_textures.deinit(session.engine.gpa);
    session.mesh_face_loaders.deinit(session.engine.gpa);
    session.mesh_face_textures.deinit(session.engine.gpa);
    session.model_face_anchors.deinit(session.engine.gpa);
    session.model_world_anchors.deinit(session.engine.gpa);
    if (session.physics_world) |world| world.destroy();
    session.physics_bodies.deinit(session.engine.gpa);
    session.cloth_bodies.deinit(session.engine.gpa);
    session.cloth_meshes.deinit(session.engine.gpa);
    session.cloth_cols.deinit(session.engine.gpa);
    session.hair_ids.deinit(session.engine.gpa);
    session.hair_meshes.deinit(session.engine.gpa);
    session.hair_vcount.deinit(session.engine.gpa);
    session.particle_meshes.deinit(session.engine.gpa);
    session.particle_systems.deinit(session.engine.gpa);
    destroyModelState(session);
    session.model_loaders.deinit(session.engine.gpa);
    session.model_meshes.deinit(session.engine.gpa);
    destroyChainOrder(session);
    if (session.active_lens) |*lens| lens.deinit(&session.lens_graph);
    session.active_lens = null;
    session.lens_graph.deinit();
    if (session.beauty_chain) |chain| beauty.destroy(session.engine.gpa, chain);
    session.beauty_chain = null;
    destroyBeautyCompositing(session);
    destroyWebBeautyTargets(session);
    if (session.face_tracking) |worker| tracking.destroy(worker);
    session.face_tracking = null;
    if (session.hand_tracking) |worker| tracking.hand_worker.destroy(worker);
    session.hand_tracking = null;
    if (session.pose_tracking) |worker| tracking.pose_worker.destroy(worker);
    session.pose_tracking = null;
    if (session.segmentation_worker) |worker| segmentation.destroy(worker);
    session.segmentation_worker = null;
    destroySegmentationTexture(session);
    releaseCurrentFrame(session);
    if (session.engine.renderer != null) {
        session.preview_bgra.deinit();
        session.preview_y.deinit();
        session.preview_uv.deinit();
    }
    session.engine.gpa.destroy(session);
}

/// Tears down the GPU beauty compositing bridge's platform surfaces -
/// safe to call whether or not they were ever actually created (both
/// goss_session_disable_beauty and destroySession reach this unconditionally).
fn destroyBeautyCompositing(session: *Session) void {
    if (session.beauty_input_target) |target| render.Renderer.destroyOffscreenTarget(target);
    session.beauty_input_target = null;
    session.beauty_input_native = null;
    session.beauty_input_persistent.deinit();
    session.beauty_output_persistent.deinit();
    if (session.engine.renderer) |*r| {
        if (session.beauty_output_texture) |tex| r.destroyTexture(tex);
    }
    session.beauty_output_texture = null;
    session.beauty_output_native = null;
    if (session.beauty_input) |surface| beauty.inputSurfaceDestroy(session.engine.gpa, surface);
    session.beauty_input = null;
    if (session.beauty_interop) |interop| beauty.interopDestroy(session.engine.gpa, interop);
    session.beauty_interop = null;
}

/// Tears down beauty.face/beauty.reshape's own offscreen targets on
/// web - safe to call whether or not they were ever created, same as
/// destroyBeautyCompositing above.
fn destroyWebBeautyTargets(session: *Session) void {
    for ([_]*?render.Renderer.OffscreenTarget{
        &session.web_beauty_blur_h_target,
        &session.web_beauty_mean_target,
        &session.web_beauty_reshape_target,
        &session.web_beauty_makeup_targets[0],
        &session.web_beauty_makeup_targets[1],
    }) |slot| {
        if (slot.*) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.* = null;
    }
    session.web_beauty_targets_width = 0;
    session.web_beauty_targets_height = 0;
    if (session.engine.renderer) |*r| {
        for (&session.web_beauty_lut_textures) |*slot| {
            if (slot.*) |texture| r.destroyTexture(texture);
            slot.* = null;
        }
        if (session.web_beauty_lipstick_texture) |tex| r.destroyTexture(tex);
        session.web_beauty_lipstick_texture = null;
        if (session.web_beauty_blush_texture) |tex| r.destroyTexture(tex);
        session.web_beauty_blush_texture = null;
    }
}

fn releaseCurrentFrame(session: *Session) void {
    const current = session.current orelse return;
    if (!current.owns_textures) {
        session.current = null;
        return;
    }
    if (session.engine.renderer) |*r| {
        switch (current.preview) {
            .bgra => |p| r.destroyTexture(p.texture),
            .nv12 => |p| {
                r.destroyTexture(p.y);
                r.destroyTexture(p.uv);
            },
        }
    }
    session.current = null;
}

fn thermalFromC(value: c_int) graph.degrade.ThermalState {
    return switch (value) {
        0 => .nominal,
        1 => .fair,
        2 => .serious,
        else => .critical,
    };
}

/// Allocates from the engine allocator for embedders that cannot address
/// module memory themselves, the wasm host being the one that matters.
/// Pair every allocation with goss_free of the same size.
pub export fn goss_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = abiAllocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn goss_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    abiAllocator().free(p[0..size]);
}

pub export fn goss_abi_version() u32 {
    return (@as(u32, abi_major) << 16) | abi_minor;
}

pub export fn goss_engine_create(config: ?*const EngineConfig, out_engine: ?**Engine) Status {
    const out = out_engine orelse return .invalid_argument;
    const cfg: EngineConfig = if (config) |c| c.* else .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 };
    const engine = createEngine(abiAllocator(), cfg) catch return .out_of_memory;
    out.* = engine;
    return .ok;
}

pub export fn goss_engine_destroy(engine: ?*Engine) void {
    destroyEngine(engine orelse return);
}

pub export fn goss_engine_init_renderer(engine: ?*Engine, desc: ?*const RendererDesc) Status {
    const e = engine orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    if (e.renderer != null) return .invalid_argument;
    e.renderer = render.Renderer.init(e.gpa, .{
        .native_window_handle = d.native_window_handle,
        .width = d.width,
        .height = d.height,
    }) catch return .renderer_unavailable;
    return .ok;
}

pub export fn goss_engine_resize(engine: ?*Engine, width: u32, height: u32) void {
    const e = engine orelse return;
    if (e.renderer) |*r| r.resize(width, height);
}

const screenshot_path_max = 480;

/// Requests a screenshot of the next presented frame, written as
/// path ++ ".tga" through the renderer's own default callback (the same
/// mechanism harness/conformance.zig already drives internally, exposed
/// here so a real SDK target - the ios simulator conformance run this
/// exists for - can trigger it too). Debug/test tooling only; no SDK
/// ships this behind a user-facing control.
pub export fn goss_engine_request_screenshot(engine: ?*Engine, path: ?[*]const u8, path_len: usize) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const p = path orelse return .invalid_argument;
    if (path_len == 0 or path_len >= screenshot_path_max) return .invalid_argument;
    var buf: [screenshot_path_max]u8 = undefined;
    @memcpy(buf[0..path_len], p[0..path_len]);
    buf[path_len] = 0;
    const zpath: [:0]u8 = buf[0..path_len :0];
    r.requestScreenshot(zpath.ptr);
    return .ok;
}

/// Begins an encoder frame and wraps its surface as this frame's final
/// render target. Null while a pool slot warms up (its first wrap
/// cannot land the same frame) - that frame displays normally and is
/// counted, never silently lost.
fn prepareRecordingFrame(e: *Engine, r: *render.Renderer) ?media_recording.Frame {
    var rec = &(e.recording.?);
    const frame = rec.beginFrame() catch return null;
    const width: u16 = @intCast(rec.config.width);
    const height: u16 = @intCast(rec.config.height);
    const key = @intFromPtr(frame.native_texture);
    if (recording_binds_window) {
        // The window is not sampleable, so the composite lands in the
        // capture target (sampleable) and re-presents into both the
        // swap chain and the encoder window each frame.
        const slot = e.recording_slots.getOrPut(e.gpa, key) catch {
            rec.abortFrame(frame);
            return null;
        };
        if (!slot.found_existing) slot.value_ptr.* = .{};
        if (slot.value_ptr.target == null) {
            slot.value_ptr.target = render.Renderer.createWindowTarget(frame.native_texture, width, height) catch {
                e.recording_warmups += 1;
                rec.abortFrame(frame);
                return null;
            };
        }
        ensureCaptureTarget(e, @intCast(r.width), @intCast(r.height)) catch {
            e.recording_warmups += 1;
            rec.abortFrame(frame);
            return null;
        };
        e.recording_window_target = slot.value_ptr.target;
        e.recording_frame_target = e.capture_target;
        return frame;
    }
    const slot = e.recording_slots.getOrPut(e.gpa, key) catch {
        rec.abortFrame(frame);
        return null;
    };
    if (!slot.found_existing) slot.value_ptr.* = .{};
    const wrapped = r.wrapExternalRenderTarget(&slot.value_ptr.persistent, width, height, render.c.BGFX_TEXTURE_FORMAT_BGRA8, key) orelse {
        e.recording_warmups += 1;
        rec.abortFrame(frame);
        return null;
    };
    if (slot.value_ptr.target == null) {
        slot.value_ptr.target = render.Renderer.createExternalTarget(wrapped) catch {
            e.recording_warmups += 1;
            rec.abortFrame(frame);
            return null;
        };
    }
    e.recording_frame_target = slot.value_ptr.target;
    return frame;
}

/// Commits the pending frame whose GPU work two engine frames have now
/// finished, then queues this frame's own. Non-monotonic timestamps
/// abort rather than fail the writer.
fn queueRecordingCommit(e: *Engine, frame: ?media_recording.Frame, timestamp_us: i64) void {
    var rec = &(e.recording.?);
    const at = e.recording_pending_at % 2;
    if (e.recording_pending[at]) |aged| {
        if (aged.timestamp_us > e.recording_last_timestamp) {
            rec.commitFrame(aged.frame, aged.timestamp_us) catch {
                e.recording_dropped += 1;
            };
            e.recording_last_timestamp = aged.timestamp_us;
        } else {
            rec.abortFrame(aged.frame);
            e.recording_dropped += 1;
        }
        e.recording_pending[at] = null;
    }
    if (frame) |live| {
        e.recording_pending[at] = .{ .frame = live, .timestamp_us = timestamp_us };
    }
    e.recording_pending_at +%= 1;
}

/// Flushes the in-flight tail, finalizes the container, and releases
/// every recording resource. Returns whether the file finalized.
fn finishRecording(e: *Engine) bool {
    var ok = true;
    if (e.recording) |*rec| {
        if (e.renderer) |*r| {
            _ = r.frame();
            _ = r.frame();
        }
        for (0..2) |_| queueRecordingCommit(e, null, 0);
        rec.finish() catch {
            ok = false;
        };
    } else {
        ok = false;
    }
    var it = e.recording_slots.valueIterator();
    while (it.next()) |slot| {
        if (slot.target) |target| render.Renderer.destroyOffscreenTarget(target);
        slot.persistent.deinit();
    }
    e.recording_slots.deinit(e.gpa);
    e.recording_slots = .empty;
    e.recording = null;
    e.recording_session = null;
    e.recording_frame_target = null;
    e.recording_window_target = null;
    e.recording_pending = .{ null, null };
    e.recording_pending_at = 0;
    e.recording_last_timestamp = std.math.minInt(i64);
    return ok;
}

pub export fn goss_engine_render_frame(engine: ?*Engine, session: ?*Session) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    e.recording_frame_target = null;
    var recording_frame: ?media_recording.Frame = null;
    var recording_timestamp: i64 = 0;
    if (session) |s| {
        pollLutLoaders(s, r, s.engine.gpa);
        pollBlendLoaders(s, r, s.engine.gpa);
        pollMeshFaceLoaders(s, r, s.engine.gpa);
        pollModelLoaders(s, r, s.engine.gpa);
        pollSegmentationMask(s);
        if (e.recording != null and e.recording_session == s and !s.capture_requested) {
            if (s.current) |current| {
                recording_frame = prepareRecordingFrame(e, r);
                recording_timestamp = current.desc.timestamp_us;
            }
        }
        if (s.physics_world) |world| {
            if (s.current) |current| {
                const now_us = current.desc.timestamp_us;
                if (s.physics_last_us != 0 and now_us > s.physics_last_us) {
                    const dt: f32 = @as(f32, @floatFromInt(now_us - s.physics_last_us)) / 1_000_000.0;
                    world.step(@min(dt, 0.25));
                }
                s.physics_last_us = now_us;
            }
        }
        if (s.current) |current| {
            const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
            const mirror = current.desc.flags & frame_flag_mirror != 0;
            // Always through renderCompositeChain, which owns the one
            // authoritative "is anything actually active" check and its
            // own view-0-target reset for the plain-preview case. This
            // used to duplicate that same check here first (skipping
            // renderCompositeChain, and its reset, whenever nothing was
            // active) - a real, found bug: once a frame went through
            // the composite path and rebound view 0 to an offscreen
            // target, this outer check took over again on the very next
            // frame beauty/chain state went back to inactive and called
            // submitPreview directly, with view 0 still pointed at that
            // now-stale offscreen target - the canvas simply stopped
            // updating. Same class of drift anyBeautyActive's own
            // comment already names for exactly this dispatch: two call
            // sites deciding the same thing separately eventually
            // disagree.
            renderCompositeChain(e, r, s, current, rotation, mirror) catch {
                // A chain target failed to (re)create - present the
                // plain preview rather than nothing this frame.
                r.submitPreview(0, current.preview, rotation * 90, mirror);
            };
        } else {
            r.touch();
        }
    } else {
        r.touch();
    }
    if (e.recording != null and (recording_frame != null or e.recording_pending[e.recording_pending_at % 2] != null)) {
        queueRecordingCommit(e, recording_frame, recording_timestamp);
    } else if (recording_frame) |frame| {
        e.recording.?.abortFrame(frame);
    }
    _ = r.frame();
    return .ok;
}

/// Renders one frame the same way goss_engine_render_frame does, and also
/// reads its composited output back into out_data as RGBA8, row 0
/// first. The WebGPU render path's own equivalent to what a WebGL2
/// canvas's readPixels already gives a caller directly - WebGPU has no
/// synchronous equivalent, so this does the capture on the render side
/// instead. out_width/out_height report the real image size; out_data
/// must be at least out_width * out_height * 4 bytes, reported through
/// the same two out params, and the call fails with invalid_argument
/// rather than truncating silently if out_capacity is smaller.
/// render.Renderer.readTexture only enqueues a read - bgfx's own
/// documented contract (bgfx_p.h's Context::readTexture) is that its
/// return value is the frame number bgfx_frame() must reach before the
/// buffer is safe to read, backend-dependent and not always the same
/// small number of extra calls, so this loops on frame()'s own return
/// value rather than assuming a fixed count.
/// Past every id the composite chain can allocate, so the readback
/// blit always runs after the last draw of the frame.
const capture_blit_view: u8 = 255;

/// Renders the session's current frame with capture enabled and
/// returns the landed capture target. Shared by the raw-pixel and
/// encoded-photo capture operations below.
fn renderForCapture(e: *Engine, r: *render.Renderer, s: *Session) ?render.Renderer.OffscreenTarget {
    s.capture_requested = true;
    defer s.capture_requested = false;

    pollLutLoaders(s, r, s.engine.gpa);
    pollBlendLoaders(s, r, s.engine.gpa);
    pollModelLoaders(s, r, s.engine.gpa);
    pollSegmentationMask(s);
    if (s.current) |current| {
        const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
        const mirror = current.desc.flags & frame_flag_mirror != 0;
        renderCompositeChain(e, r, s, current, rotation, mirror) catch {
            r.submitPreview(0, current.preview, rotation * 90, mirror);
        };
    } else {
        r.touch();
    }
    _ = r.frame();
    return e.capture_target;
}

pub export fn goss_engine_capture_frame(engine: ?*Engine, session: ?*Session, out_data: ?[*]u8, out_capacity: usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;
    if (out_capacity < full_size) return .invalid_argument;

    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, data);
    while (r.frame() < ready_frame) {}
    return .ok;
}

/// Captures the composited frame and encodes it as a PNG into out_data.
/// out_len always receives the encoded size, so a too-small buffer
/// (invalid_argument) tells the caller exactly what to retry with.
/// Deterministic: the same composited pixels, the same bytes.
pub export fn goss_engine_capture_photo(engine: ?*Engine, session: ?*Session, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    len_out.* = 0;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;

    const gpa = e.gpa;
    const pixels = gpa.alloc(u8, full_size) catch return .out_of_memory;
    defer gpa.free(pixels);
    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, pixels.ptr);
    while (r.frame() < ready_frame) {}

    var encoded: std.ArrayList(u8) = .empty;
    defer encoded.deinit(gpa);
    png.encodeRgba(gpa, &encoded, pixels, e.capture_width, e.capture_height) catch return .out_of_memory;
    len_out.* = encoded.items.len;
    if (out_capacity < encoded.items.len) return .invalid_argument;
    @memcpy(data[0..encoded.items.len], encoded.items);
    return .ok;
}

/// Harness-facing re-exports of the recording backend's proof surface
/// (decode-probe and frame export); never part of the C ABI.
pub const recordingProbe = media_recording.probe;
pub const recordingProbeAudio = media_recording.probeAudio;
pub const recordingExportFrame = media_recording.exportFrame;
pub const recording_supported = media_recording.supported;

/// Harness-facing re-export of the photo backend's decode proof
/// surface; never part of the C ABI.
pub const photoDecode = photo.decode;
pub const photoProbeMetadata = photo.probeMetadata;
pub const photo_supported = photo.supported;

/// Captures the composited frame as a platform photo (1 = JPEG,
/// 2 = HEIC) at quality percent; out_len always receives the needed
/// size. Lossy and not bit-stable across runs, so the plain
/// goss_engine_capture_photo stays the deterministic PNG surface.
pub export fn goss_engine_capture_photo_as(engine: ?*Engine, session: ?*Session, format: u32, quality: u32, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    len_out.* = 0;
    if (!photo.supported) return .unsupported;
    if (format < 1 or format > 2 or quality > 100) return .invalid_argument;

    const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;

    const gpa = e.gpa;
    const pixels = gpa.alloc(u8, full_size) catch return .out_of_memory;
    defer gpa.free(pixels);
    const staging = e.capture_staging orelse return .renderer_unavailable;
    render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
    const ready_frame = render.Renderer.readTexture(staging, pixels.ptr);
    while (r.frame() < ready_frame) {}

    photo.encode(pixels, e.capture_width, e.capture_height, @enumFromInt(format), quality, data[0..out_capacity], len_out) catch return .invalid_argument;
    return .ok;
}

pub const WorldState = extern struct {
    tracking_state: u32,
    world_from_camera: [16]f32,
    projection: [16]f32,
    timestamp_us: i64,
};

pub const WorldPlane = extern struct {
    id: u64,
    pose: [16]f32,
    extent_x: f32,
    extent_z: f32,
    classification: u32,
};

pub const WorldAnchor = extern struct {
    id: u64,
    pose: [16]f32,
};

pub const WorldLight = extern struct {
    ambient_intensity: f32,
    color_temperature_kelvin: f32,
};

pub const max_world_planes = 32;
pub const max_world_anchors = 32;

/// Feeds the platform's world understanding into the session: drives
/// the world.tracking_state signal and world-anchored lens content.
/// Planes and anchors beyond the fixed capacity are dropped oldest
/// last (the platform lists closest-first), counted, never silent.
pub export fn goss_session_submit_world(session: ?*Session, state: ?*const WorldState, planes: ?[*]const WorldPlane, plane_count: usize, anchors: ?[*]const WorldAnchor, anchor_count: usize, light: ?*const WorldLight) Status {
    const s = session orelse return .invalid_argument;
    const st = state orelse return .invalid_argument;
    if (st.tracking_state > 3) return .invalid_argument;
    if (plane_count > 0 and planes == null) return .invalid_argument;
    if (anchor_count > 0 and anchors == null) return .invalid_argument;

    s.world.state = st.*;
    s.world.plane_count = @min(plane_count, max_world_planes);
    if (planes) |p| @memcpy(s.world.planes[0..s.world.plane_count], p[0..s.world.plane_count]);
    s.world.dropped_planes +|= @intCast(plane_count -| max_world_planes);
    s.world.anchor_count = @min(anchor_count, max_world_anchors);
    if (anchors) |a| @memcpy(s.world.anchors[0..s.world.anchor_count], a[0..s.world.anchor_count]);
    s.world.dropped_anchors +|= @intCast(anchor_count -| max_world_anchors);
    if (light) |l| s.world.light = l.*;
    s.world_engine_fed = true;
    return .ok;
}

pub const RecordingConfig = extern struct {
    /// Zero picks the renderer's own output size (rounded down to
    /// even, as the encoders require).
    width: u32,
    height: u32,
    /// Zero lets the backend pick a rate fitting the dimensions.
    bitrate_bps: u32,
    /// 0 = H.264, 1 = HEVC.
    codec: u32,
};

/// Starts recording session's rendered frames, effects baked in, into
/// the file at path. One recording per engine; every subsequent
/// goss_engine_render_frame of this session appends one video frame at
/// the frame's own timestamp until goss_engine_recording_stop.
pub export fn goss_engine_recording_start(engine: ?*Engine, session: ?*Session, path: ?[*]const u8, path_len: usize, config: ?*const RecordingConfig) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const p = path orelse return .invalid_argument;
    if (path_len == 0) return .invalid_argument;
    if (!media_recording.supported) return .unsupported;
    if (e.recording != null) return .invalid_argument;

    const cfg: RecordingConfig = if (config) |c_| c_.* else .{ .width = 0, .height = 0, .bitrate_bps = 0, .codec = 0 };
    const width = (if (cfg.width == 0) @as(u32, r.width) else cfg.width) & ~@as(u32, 1);
    const height = (if (cfg.height == 0) @as(u32, r.height) else cfg.height) & ~@as(u32, 1);
    if (width == 0 or height == 0 or cfg.codec > 1) return .invalid_argument;

    e.recording = media_recording.Recording.start(p[0..path_len], .{
        .width = width,
        .height = height,
        .bitrate_bps = cfg.bitrate_bps,
        .codec = @enumFromInt(cfg.codec),
    }) catch return .invalid_argument;
    e.recording_session = s;
    e.recording_warmups = 0;
    e.recording_dropped = 0;
    return .ok;
}

/// Stops the engine's recording and finalizes the container, flushing
/// the frames still in flight first.
pub export fn goss_engine_recording_stop(engine: ?*Engine) Status {
    const e = engine orelse return .invalid_argument;
    if (e.recording == null) return .invalid_argument;
    return if (finishRecording(e)) .ok else .invalid_argument;
}

/// Feeds interleaved f32 PCM into the session: the engine's own level
/// and beat analysis always consumes it (driving audio.level and
/// audio.beat triggers), and an active recording of this session muxes
/// it as the audio track where the backend supports audio.
pub export fn goss_session_submit_audio(session: ?*Session, samples: ?[*]const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Status {
    const s = session orelse return .invalid_argument;
    const data = samples orelse return .invalid_argument;
    if (frame_count == 0 or sample_rate == 0 or channels == 0 or channels > 8) return .invalid_argument;
    const slice = data[0 .. @as(usize, frame_count) * channels];
    s.audio.feed(slice, channels);
    s.audio_engine_fed = true;

    const e = s.engine;
    if (e.recording != null and e.recording_session == s) {
        if (media_recording.audio_supported) {
            var rec = &(e.recording.?);
            rec.submitAudio(slice, frame_count, sample_rate, channels, timestamp_us) catch {
                e.recording_dropped += 1;
            };
        }
    }
    return .ok;
}

pub const CaptureConfig = extern struct {
    /// Zero captures at the submitted frame's own resolution, so the
    /// still is not clamped to the preview swap chain.
    width: u32,
    height: u32,
    /// Reserved for the supersample factor; 0 or 1 means 1:1 today.
    supersample: u32,
    /// 0 = PNG, 1 = JPEG, 2 = HEIC (the photo format enum).
    format: u32,
    /// 1..100 for the lossy formats; 0 = the backend default.
    quality: u32,
};

/// Composites the still at the configured resolution (the submitted
/// frame's own size when width and height are zero), independent of
/// the preview swap chain, and encodes it. PNG has no size ceiling;
/// JPEG and HEIC need the platform photo backend.
pub export fn goss_engine_capture_still(engine: ?*Engine, session: ?*Session, config: ?*const CaptureConfig, out_data: ?[*]u8, out_capacity: usize, out_len: ?*usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const len_out = out_len orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;
    const cfg: CaptureConfig = if (config) |c_| c_.* else .{ .width = 0, .height = 0, .supersample = 0, .format = 0, .quality = 0 };
    len_out.* = 0;
    if (cfg.format > 2) return .invalid_argument;
    if (cfg.format != 0 and !photo.supported) return .unsupported;

    const current = s.current orelse return .again;
    const still_w: u16 = if (cfg.width != 0) @intCast(@min(cfg.width, 65535)) else @intCast(current.desc.width);
    const still_h: u16 = if (cfg.height != 0) @intCast(@min(cfg.height, 65535)) else @intCast(current.desc.height);
    if (still_w == 0 or still_h == 0) return .invalid_argument;

    // Supersample: render at N times the still size then box-downsample,
    // for photo-grade anti-aliased edges. 16384 is the conservative
    // texture-size floor; larger renders wait on the tiling path.
    const supersample: u16 = switch (cfg.supersample) {
        0, 1 => 1,
        2 => 2,
        4 => 4,
        else => return .invalid_argument,
    };
    const render_w: u32 = @as(u32, still_w) * supersample;
    const render_h: u32 = @as(u32, still_h) * supersample;
    // Above the max texture size a single target is impossible, so the
    // output composites in tiles and stitches. Exact only when the final
    // draw is the axis-aligned full-screen pass: 3D content and rotated or
    // mirrored plain frames stay single-target under the cap.
    const tile_cap: u32 = if (s.capture_tile_cap != 0) s.capture_tile_cap else 16384;
    const has_3d = s.model_meshes.count() > 0 or s.mesh_face_textures.count() > 0 or
        s.cloth_meshes.count() > 0 or s.hair_meshes.count() > 0 or s.particle_meshes.count() > 0;
    const rot = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
    const upright = rot == 0 and (current.desc.flags & frame_flag_mirror) == 0;
    const tileable = !has_3d and upright;
    if ((render_w > tile_cap or render_h > tile_cap) and !tileable) return .invalid_argument;

    const gpa = e.gpa;
    const render_size = @as(usize, render_w) * @as(usize, render_h) * 4;
    if (render_size == 0) {
        w.* = 0;
        h.* = 0;
        return .ok;
    }
    const rendered = gpa.alloc(u8, render_size) catch return .out_of_memory;
    defer gpa.free(rendered);

    const cols: u32 = if (render_w > tile_cap) (render_w + tile_cap - 1) / tile_cap else 1;
    const rows: u32 = if (render_h > tile_cap) (render_h + tile_cap - 1) / tile_cap else 1;
    defer {
        s.capture_res_width = 0;
        s.capture_res_height = 0;
        s.capture_tile = null;
    }

    if (cols == 1 and rows == 1) {
        // Whole frame in one target: read straight into the output buffer,
        // the same fast path a preview-size capture already takes.
        s.capture_res_width = @intCast(render_w);
        s.capture_res_height = @intCast(render_h);
        s.capture_tile = null;
        const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
        if (e.capture_width == 0 or e.capture_height == 0) {
            w.* = 0;
            h.* = 0;
            return .ok;
        }
        const staging = e.capture_staging orelse return .renderer_unavailable;
        render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
        const ready_frame = render.Renderer.readTexture(staging, rendered.ptr);
        while (r.frame() < ready_frame) {}
    } else {
        // Composite each tile into its own small target and stitch the
        // rows into the full buffer at the tile's offset.
        var ty: u32 = 0;
        while (ty < rows) : (ty += 1) {
            const tile_y = ty * tile_cap;
            const th: u32 = @min(tile_cap, render_h - tile_y);
            var tx: u32 = 0;
            while (tx < cols) : (tx += 1) {
                const tile_x = tx * tile_cap;
                const tw: u32 = @min(tile_cap, render_w - tile_x);
                s.capture_res_width = @intCast(tw);
                s.capture_res_height = @intCast(th);
                s.capture_tile = .{
                    .u0 = @as(f32, @floatFromInt(tile_x)) / @as(f32, @floatFromInt(render_w)),
                    .v0 = @as(f32, @floatFromInt(tile_y)) / @as(f32, @floatFromInt(render_h)),
                    .u1 = @as(f32, @floatFromInt(tile_x + tw)) / @as(f32, @floatFromInt(render_w)),
                    .v1 = @as(f32, @floatFromInt(tile_y + th)) / @as(f32, @floatFromInt(render_h)),
                };
                const target = renderForCapture(e, r, s) orelse return .renderer_unavailable;
                if (e.capture_width == 0 or e.capture_height == 0) {
                    w.* = 0;
                    h.* = 0;
                    return .ok;
                }
                const staging = e.capture_staging orelse return .renderer_unavailable;
                const tile_size = @as(usize, tw) * @as(usize, th) * 4;
                const tile_buf = gpa.alloc(u8, tile_size) catch return .out_of_memory;
                defer gpa.free(tile_buf);
                render.Renderer.blitTexture(capture_blit_view, staging, target.texture, e.capture_width, e.capture_height);
                const ready_frame = render.Renderer.readTexture(staging, tile_buf.ptr);
                while (r.frame() < ready_frame) {}
                var row: u32 = 0;
                while (row < th) : (row += 1) {
                    const dst = (@as(usize, tile_y + row) * @as(usize, render_w) + tile_x) * 4;
                    const src = @as(usize, row) * @as(usize, tw) * 4;
                    @memcpy(rendered[dst..][0 .. @as(usize, tw) * 4], tile_buf[src..][0 .. @as(usize, tw) * 4]);
                }
            }
        }
    }

    // The pixels to encode: the rendered buffer directly at 1x, or the
    // box-downsampled buffer at the still size when supersampling.
    var pixels: []u8 = rendered;
    var out_w: u32 = render_w;
    var out_h: u32 = render_h;
    var downsampled: []u8 = &.{};
    defer if (downsampled.len > 0) gpa.free(downsampled);
    if (supersample > 1) {
        downsampled = gpa.alloc(u8, @as(usize, still_w) * still_h * 4) catch return .out_of_memory;
        image.downsampleBox(rendered, render_w, render_h, downsampled, still_w, still_h) catch return .unsupported;
        pixels = downsampled;
        out_w = still_w;
        out_h = still_h;
    }
    w.* = out_w;
    h.* = out_h;

    if (cfg.format == 0) {
        var encoded: std.ArrayList(u8) = .empty;
        defer encoded.deinit(gpa);
        png.encodeRgba(gpa, &encoded, pixels, out_w, out_h) catch return .out_of_memory;
        len_out.* = encoded.items.len;
        if (out_capacity < encoded.items.len) return .invalid_argument;
        @memcpy(data[0..encoded.items.len], encoded.items);
        return .ok;
    }
    photo.encode(pixels, out_w, out_h, @enumFromInt(cfg.format), cfg.quality, data[0..out_capacity], len_out) catch return .invalid_argument;
    return .ok;
}

pub export fn goss_session_create(engine: ?*Engine, config: ?*const SessionConfig, out_session: ?**Session) Status {
    const out = out_session orelse return .invalid_argument;
    const parent = engine orelse return .invalid_argument;
    const cfg: SessionConfig = if (config) |c| c.* else .{ .frame_budget_us = 0, .reserved = 0 };
    const session = createSession(parent, cfg) catch return .out_of_memory;
    out.* = session;
    return .ok;
}

pub export fn goss_session_destroy(session: ?*Session) void {
    destroySession(session orelse return);
}

pub export fn goss_session_submit_frame(session: ?*Session, desc: ?*const FrameDesc, planes: ?*const FramePlanes) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const p = planes orelse return .invalid_argument;
    if (s.engine.renderer == null) return .renderer_unavailable;

    releaseCurrentFrame(s);
    switch (d.pixel_format) {
        pixel_format_bgra8, pixel_format_rgba8 => {
            if (p.plane_count != 1) return .invalid_argument;
            const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
            const texture = s.preview_bgra.rebind(@intCast(d.width), @intCast(d.height), format, @intCast(p.planes[0]));
            s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
        },
        pixel_format_nv12 => {
            if (p.plane_count != 2) return .invalid_argument;
            const y = s.preview_y.rebind(@intCast(d.width), @intCast(d.height), render.c.BGFX_TEXTURE_FORMAT_R8, @intCast(p.planes[0]));
            const uv = s.preview_uv.rebind(@intCast(d.width / 2), @intCast(d.height / 2), render.c.BGFX_TEXTURE_FORMAT_RG8, @intCast(p.planes[1]));
            const standard: math.color.Standard = switch (d.color_standard) {
                0 => .bt601,
                2 => .bt2020,
                else => .bt709,
            };
            const range: math.color.Range = if (d.color_range == 1) .full else .video;
            s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .nv12 = .{
                .y = y,
                .uv = uv,
                .conversion = math.color.yuvToRgb(standard, range),
            } } };
        },
        else => return .invalid_argument,
    }
    return .ok;
}

/// Writes the YCbCr to RGB conversion for a standard and range as one
/// column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).xyz. SDKs
/// that own their GPU pipeline, the web SDK today, get their color math
/// from the core instead of hardcoding it.
pub export fn goss_color_yuv_to_rgb(color_standard: u32, color_range: u32, out_matrix: ?*[16]f32) Status {
    const out = out_matrix orelse return .invalid_argument;
    const standard: math.color.Standard = switch (color_standard) {
        0 => .bt601,
        1 => .bt709,
        2 => .bt2020,
        else => return .invalid_argument,
    };
    const range: math.color.Range = switch (color_range) {
        0 => .video,
        1 => .full,
        else => return .invalid_argument,
    };
    const m = math.color.yuvToRgb(standard, range).homogeneous();
    var index: usize = 0;
    inline for (0..4) |col| {
        inline for (0..4) |row| {
            out[index] = m.cols[col][row];
            index += 1;
        }
    }
    return .ok;
}

/// Copies NV12 planes into pooled textures. The stated CPU path: an SDK
/// uses it only where the zero-copy import is not wired yet, and the copy
/// is counted so the budget report shows it.
pub export fn goss_session_submit_frame_copy(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const y_ptr = y orelse return .invalid_argument;
    const uv_ptr = uv orelse return .invalid_argument;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    releaseCurrentFrame(s);
    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const uploaded = r.uploadNv12(
        @intCast(d.width),
        @intCast(d.height),
        y_ptr,
        y_stride,
        uv_ptr,
        uv_stride,
    ) catch return .out_of_memory;
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .nv12 = .{
        .y = uploaded.y,
        .uv = uploaded.uv,
        .conversion = math.color.yuvToRgb(standard, range),
    } } };
    s.copied_frames += 1;
    return .ok;
}

/// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a canvas or
/// video element's own byte buffer, most likely, with no native GPU
/// handle behind it the way goss_session_submit_frame's zero-copy path
/// needs. Same shape as goss_session_submit_frame_copy above, just a
/// single interleaved plane instead of NV12's two.
pub export fn goss_session_submit_frame_rgba_copy(session: ?*Session, desc: ?*const FrameDesc, rgba: ?[*]const u8, stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const rgba_ptr = rgba orelse return .invalid_argument;
    if (d.pixel_format != pixel_format_bgra8 and d.pixel_format != pixel_format_rgba8) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    releaseCurrentFrame(s);
    const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
    const texture = r.uploadRgba(@intCast(d.width), @intCast(d.height), format, rgba_ptr, stride) catch return .out_of_memory;
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
    s.copied_frames += 1;
    return .ok;
}

/// Zero-copy camera submission for platforms delivering hardware buffers.
/// The render adapter converts on the gpu; a status other than ok means the
/// caller falls back to the declared copy path for this stream.
pub export fn goss_session_submit_hardware_buffer(session: ?*Session, desc: ?*const FrameDesc, hardware_buffer: ?*anyopaque) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const buffer = hardware_buffer orelse return .invalid_argument;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const texture = r.submitHardwareBuffer(buffer, d.width, d.height, math.color.yuvToRgb(standard, range)) catch {
        return .renderer_unavailable;
    };
    releaseCurrentFrame(s);
    s.current = .{ .desc = d.*, .owns_textures = false, .preview = .{ .bgra = .{ .texture = texture } } };
    return .ok;
}

pub export fn goss_session_report_frame(session: ?*Session, frame_time_us: u32, thermal: c_int) c_int {
    const s = session orelse return 0;
    _ = s.controller.step(.{ .frame_time_us = frame_time_us, .thermal = thermalFromC(thermal) });
    return @intFromEnum(s.controller.level);
}

pub export fn goss_session_degrade_level(session: ?*const Session) c_int {
    const s = session orelse return 0;
    return @intFromEnum(s.controller.level);
}

/// Stands the face tracking worker up from a model bundle. The bundle
/// bytes are copied; the caller may release them on return. On platforms
/// built without the inference stack this reports unsupported.
pub export fn goss_session_enable_face_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.face_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.face_tracking = tracking.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_face_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.face_tracking) |worker| tracking.destroy(worker);
    s.face_tracking = null;
}

/// Stands the hand tracking worker up from a hand landmarker task bundle.
/// The bundle bytes are copied; the caller may release them on return. On
/// platforms built without the inference stack this reports unsupported.
pub export fn goss_session_enable_hand_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.hand_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.hand_tracking = tracking.hand_worker.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_hand_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.hand_tracking) |worker| tracking.hand_worker.destroy(worker);
    s.hand_tracking = null;
}

/// Stands the pose tracking worker up from a pose landmarker task
/// bundle. The bundle bytes are copied; the caller may release them on
/// return. Builds without the inference stack report unsupported.
pub export fn goss_session_enable_pose_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = task_bytes orelse return .invalid_argument;
    if (task_len == 0) return .invalid_argument;
    if (s.pose_tracking != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.pose_tracking = tracking.pose_worker.create(s.engine.gpa, bytes[0..task_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidBundle => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_pose_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.pose_tracking) |worker| tracking.pose_worker.destroy(worker);
    s.pose_tracking = null;
}

/// Stands the segmentation worker up from a raw model (selfie or hair
/// segmenter, not bundled the way face_landmarker.task is). The model
/// bytes are copied; the caller may release them on return. On platforms
/// built without the inference stack this reports unsupported.
pub export fn goss_session_enable_segmentation(session: ?*Session, model_bytes: ?[*]const u8, model_len: usize, threads: i32) Status {
    const s = session orelse return .invalid_argument;
    const bytes = model_bytes orelse return .invalid_argument;
    if (model_len == 0) return .invalid_argument;
    if (s.segmentation_worker != null) return .ok;
    const worker_threads = if (threads <= 0) 2 else threads;
    s.segmentation_worker = segmentation.create(s.engine.gpa, bytes[0..model_len], worker_threads) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.InvalidModel => return .invalid_argument,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_segmentation(session: ?*Session) void {
    const s = session orelse return;
    if (s.segmentation_worker) |worker| segmentation.destroy(worker);
    s.segmentation_worker = null;
    destroySegmentationTexture(s);
}

/// Feeds one NV12 frame to the tracking worker. The planes are CPU
/// addresses valid for the duration of the call; the worker copies and
/// returns immediately, dropping stale frames in favor of this one.
pub export fn goss_session_track_frame(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const y_plane = y orelse return .invalid_argument;
    const uv_plane = uv orelse return .invalid_argument;
    if (s.face_tracking == null and s.hand_tracking == null and s.pose_tracking == null and s.segmentation_worker == null) return .again;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    if (d.width == 0 or d.height == 0) return .invalid_argument;
    if (y_stride < d.width or uv_stride < ((d.width + 1) / 2) * 2) return .invalid_argument;
    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    const conversion = math.color.yuvToRgb(standard, range);
    if (s.face_tracking) |worker| {
        tracking.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.hand_tracking) |worker| {
        tracking.hand_worker.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.pose_tracking) |worker| {
        tracking.pose_worker.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    if (s.segmentation_worker) |worker| {
        segmentation.submitNv12(worker, d.width, d.height, d.timestamp_us, conversion, y_plane, y_stride, uv_plane, uv_stride);
    }
    return .ok;
}

/// Reads the newest tracking result into caller memory. Reports again
/// until the worker has published its first result.
pub export fn goss_session_face_result(session: ?*Session, out_result: ?*face.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    if (!tracking.readResult(worker, out)) return .again;
    return .ok;
}

/// Reads the newest hand tracking result into caller memory. Reports
/// again until the worker has published its first result.
pub export fn goss_session_hand_result(session: ?*Session, out_result: ?*hand.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.hand_tracking orelse return .again;
    if (!tracking.hand_worker.readResult(worker, out)) return .again;
    return .ok;
}

/// Reads the newest pose tracking result into caller memory. Reports
/// again until the worker has published its first result.
pub export fn goss_session_pose_result(session: ?*Session, out_result: ?*pose.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.pose_tracking orelse return .again;
    if (!tracking.pose_worker.readResult(worker, out)) return .again;
    return .ok;
}

/// Fits the canonical face onto the newest tracked landmarks and writes
/// the head transform - canonical metric space into frame pixels - as a
/// column-major 4x4. Reports again until a face is tracked or while the
/// fit is degenerate.
pub export fn goss_session_face_pose(session: ?*Session, out_matrix: ?*[16]f32) Status {
    const s = session orelse return .invalid_argument;
    const out = out_matrix orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    var result: face.Result = undefined;
    if (!tracking.readResult(worker, &result)) return .again;
    if (result.landmark_count_out == 0 or result.presence < 0.5) return .again;
    const head = face_geometry.estimateHeadPose(&result.landmarks) orelse return .again;
    var at: usize = 0;
    for (head.cols) |col| {
        out[at] = col[0];
        out[at + 1] = col[1];
        out[at + 2] = col[2];
        out[at + 3] = col[3];
        at += 4;
    }
    return .ok;
}

/// Stands the beauty chain up for a session. The resource path names the
/// directory holding the effect engine's shader and image assets; builds
/// without the effects engine report unsupported.
pub export fn goss_session_enable_beauty(session: ?*Session, resource_path: ?[*:0]const u8) Status {
    const s = session orelse return .invalid_argument;
    const path = resource_path orelse return .invalid_argument;
    if (s.beauty_chain != null) return .ok;
    s.beauty_chain = beauty.create(s.engine.gpa, path) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn goss_session_disable_beauty(session: ?*Session) void {
    const s = session orelse return;
    if (s.beauty_chain) |chain| beauty.destroy(s.engine.gpa, chain);
    s.beauty_chain = null;
    s.beauty_amounts = @splat(0);
    destroyBeautyCompositing(s);
    if (is_web) {
        s.web_beauty_amounts = @splat(0);
        destroyWebBeautyTargets(s);
    }
}

/// Effect identifiers follow the header: smooth, whiten, thin face, big
/// eye, lipstick, blush. Values clamp to zero and one; zero disables the
/// effect. On web this writes web_beauty_amounts directly rather than a
/// gpupixel chain (there is no chain on this target, so it works
/// regardless of goss_session_enable_beauty's own result - that call
/// still goes through the native/stub beauty module unchanged).
pub export fn goss_session_set_beauty(session: ?*Session, effect: i32, value: f32) Status {
    const s = session orelse return .invalid_argument;
    if (effect < 0 or effect > 5) return .invalid_argument;
    if (is_web) {
        s.web_beauty_amounts[@intCast(effect)] = std.math.clamp(value, 0.0, 1.0);
        return .ok;
    }
    const chain = s.beauty_chain orelse return .again;
    beauty.set(chain, @enumFromInt(effect), value);
    s.beauty_amounts[@intCast(effect)] = std.math.clamp(value, 0.0, 1.0);
    return .ok;
}

/// Uploads one of beauty.face's four whiten lookup textures on web -
/// slot 0 gray, 1 origin, 2 skin, 3 custom, matching gpupixel's own
/// lookup_gray/lookup_origin/lookup_skin/lookup_light asset order. rgba
/// is a caller-decoded image (this build has no PNG decoder wired in
/// for web); whiten renders inert until all four slots are loaded.
/// Unsupported on every other target - native's whiten runs through
/// adapters/beauty.zig's own gpupixel chain, not this texture set.
pub export fn goss_session_set_beauty_lut(session: ?*Session, slot: i32, rgba: ?[*]const u8, width: u32, height: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    if (slot < 0 or slot > 3) return .invalid_argument;
    const bytes = rgba orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;
    const texture = render.Renderer.createStaticTexture(@intCast(width), @intCast(height), bytes[0 .. @as(usize, width) * height * 4]);
    const index: usize = @intCast(slot);
    if (s.web_beauty_lut_textures[index]) |old| r.destroyTexture(old);
    s.web_beauty_lut_textures[index] = texture;
    return .ok;
}

/// Uploads beauty.lipstick's (effect 0) or beauty.blusher's (effect 1)
/// own source image on web - gpupixel's mouth.png/blusher.png,
/// caller-decoded the same way goss_session_set_beauty_lut's rgba is.
/// Unsupported on every other target - native's lipstick/blush run
/// through adapters/beauty.zig's own gpupixel chain.
pub export fn goss_session_set_beauty_makeup_texture(session: ?*Session, effect: i32, rgba: ?[*]const u8, width: u32, height: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    const bytes = rgba orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;
    const texture = render.Renderer.createStaticTexture(@intCast(width), @intCast(height), bytes[0 .. @as(usize, width) * height * 4]);
    const slot = switch (effect) {
        @intFromEnum(runtime.EffectSlot.lipstick) => &s.web_beauty_lipstick_texture,
        @intFromEnum(runtime.EffectSlot.blush) => &s.web_beauty_blush_texture,
        else => {
            r.destroyTexture(texture);
            return .invalid_argument;
        },
    };
    if (slot.*) |old| r.destroyTexture(old);
    slot.* = texture;
    return .ok;
}

/// Feeds one frame's tracked face landmarks into a web session directly.
/// There is no internal tracking worker to drive beauty.reshape/
/// beauty.lipstick/beauty.blusher on web (goss_session_enable_face_
/// tracking reports unsupported here) - the caller runs its own
/// tracker (a separate wasm module, most likely) and hands the result
/// straight in. points holds point_count * 3 floats (x, y in frame
/// pixels, z in the same scale, matching goss_face_result's own
/// landmarks convention); point_count must be GOSS_FACE_LANDMARK_COUNT,
/// or zero to clear any previously set landmarks (no face this frame).
/// Unsupported on every other target, where goss_session_track_frame
/// feeds the same three effects instead.
pub export fn goss_session_set_face_landmarks(session: ?*Session, points: ?[*]const f32, point_count: u32) Status {
    if (!is_web) return .unsupported;
    const s = session orelse return .invalid_argument;
    if (point_count == 0) {
        s.web_face_landmarks = null;
        return .ok;
    }
    if (point_count != face.landmark_count) return .invalid_argument;
    const p = points orelse return .invalid_argument;
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{ .x = p[at * 3], .y = p[at * 3 + 1], .z = p[at * 3 + 2] };
    }
    s.web_face_landmarks = landmarks;
    return .ok;
}

/// Runs the beauty chain over one RGBA frame on the calling thread,
/// reading the newest tracking result for the landmark driven effects
/// when face tracking is enabled. The stated CPU path: live preview
/// integration on the render thread is the device side of this row.
pub export fn goss_session_beautify_frame(session: ?*Session, rgba_in: ?[*]const u8, width: u32, height: u32, rgba_out: ?[*]u8) Status {
    const s = session orelse return .invalid_argument;
    const source = rgba_in orelse return .invalid_argument;
    const destination = rgba_out orelse return .invalid_argument;
    if (width == 0 or height == 0) return .invalid_argument;
    const chain = s.beauty_chain orelse return .again;

    var result: face.Result = undefined;
    var tracked: ?*const face.Result = null;
    if (s.face_tracking) |worker| {
        if (tracking.readResult(worker, &result)) tracked = &result;
    }
    beauty.process(chain, source, width, height, tracked, destination) catch return .invalid_argument;
    return .ok;
}

/// Takes s by pointer, not value: the returned Signals borrows
/// &s.blendshapes directly, and a by-value parameter's address does not
/// outlive this call - the caller's own LensSignals storage (guaranteed
/// live for the whole ABI call per goss_session_tick_lens's own contract)
/// is what the borrow must point into instead.
fn toTriggerSignals(s: *const LensSignals) trigger.Signals {
    return .{
        .face_present = s.has_face,
        .hands_present = s.hands_present,
        .world_tracking_state = s.world_tracking_state,
        .audio_level = s.audio_level,
        .tap = s.tap,
        .blendshapes = if (s.has_face) &s.blendshapes else null,
    };
}

fn applyLensEffects(session: *Session, effects: []const runtime.AppliedEffect) void {
    if (is_web) {
        for (effects) |applied| session.web_beauty_amounts[@intFromEnum(applied.effect)] = std.math.clamp(applied.value, 0.0, 1.0);
        return;
    }
    const chain = session.beauty_chain orelse return;
    for (effects) |applied| beauty.set(chain, @enumFromInt(@intFromEnum(applied.effect)), applied.value);
}

fn destroyShaderPrograms(session: *Session) void {
    var it = session.shader_programs.valueIterator();
    while (it.next()) |handle| render.Renderer.destroyProgram(.{ .idx = handle.* });
    session.shader_programs.clearRetainingCapacity();
    session.shader_masks.clearRetainingCapacity();
}

fn destroyChainOrder(session: *Session) void {
    session.engine.gpa.free(session.chain_order);
    session.chain_order = &.{};
}

/// Tears down every in-flight LUT load and every already-created LUT
/// texture for the session's current lens - a load still running when
/// its lens deactivates is not a leak, just a loader whose result
/// nobody will ever collect.
fn destroySegmentationTexture(session: *Session) void {
    if (session.engine.renderer) |*r| {
        if (session.segmentation_texture) |texture| r.destroyTexture(texture);
        for (&session.segmentation_class_textures) |*maybe_texture| {
            if (maybe_texture.*) |texture| r.destroyTexture(texture);
            maybe_texture.* = null;
        }
    }
    session.segmentation_texture = null;
}

/// Turns the newest published mask into a real GPU texture - runs every
/// frame from goss_engine_render_frame since texture creation belongs on
/// the render thread, mirroring pollLutLoaders. Replaces the previous
/// texture outright since bgfx's static textures are immutable; nothing
/// consumes segmentation_texture yet (background-swap compositing is
/// future work), so this only ever does the upload.
fn maskToTexture(mask: *const [segmentation.mask_len]f32) ?render.TextureHandle {
    var bytes: [segmentation.mask_len]u8 = undefined;
    for (mask, 0..) |value, i| {
        bytes[i] = @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
    }
    return render.Renderer.createMaskTexture(segmentation.mask_side, segmentation.mask_side, &bytes);
}

fn pollSegmentationMask(session: *Session) void {
    const worker = session.segmentation_worker orelse return;
    var mask: [segmentation.mask_len]f32 = undefined;
    if (!segmentation.readMask(worker, &mask)) return;

    destroySegmentationTexture(session);
    session.segmentation_texture = maskToTexture(&mask);

    // Class channels upload only when the active lens names them; the
    // person channel (index zero) rides the subject texture above.
    var it = session.shader_masks.valueIterator();
    var needed: [manifest.mask_channels.len]bool = @splat(false);
    while (it.next()) |channel| needed[channel.*] = true;
    for (needed[1..], 1..) |need, channel| {
        if (!need) continue;
        if (!segmentation.readClassMask(worker, @intCast(channel - 1), &mask)) continue;
        session.segmentation_class_textures[channel] = maskToTexture(&mask);
    }
}

fn destroyLutState(session: *Session) void {
    var loader_it = session.lut_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.lut_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.lut_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.lut_textures.clearRetainingCapacity();
}

fn destroyBlendState(session: *Session) void {
    var loader_it = session.blend_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.blend_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.blend_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.blend_textures.clearRetainingCapacity();
}

fn destroyMeshFaceState(session: *Session) void {
    session.model_face_anchors.clearRetainingCapacity();
    session.model_world_anchors.clearRetainingCapacity();
    if (session.engine.renderer) |*r| {
        _ = r;
        var cm_it = session.cloth_meshes.valueIterator();
        while (cm_it.next()) |mesh| render.Renderer.destroyClothMesh(mesh.*);
    }
    if (session.engine.renderer) |*r| {
        _ = r;
        var hm_it = session.hair_meshes.valueIterator();
        while (hm_it.next()) |mesh| render.Renderer.destroyHairMesh(mesh.*);
    }
    if (session.engine.renderer) |*r| {
        _ = r;
        var pm_it = session.particle_meshes.valueIterator();
        while (pm_it.next()) |mesh| render.Renderer.destroyParticleMesh(mesh.*);
    }
    var ps_it = session.particle_systems.valueIterator();
    while (ps_it.next()) |sys| sys.deinit();
    session.particle_meshes.clearRetainingCapacity();
    session.particle_systems.clearRetainingCapacity();
    session.hair_meshes.clearRetainingCapacity();
    session.hair_ids.clearRetainingCapacity();
    session.hair_vcount.clearRetainingCapacity();
    session.cloth_meshes.clearRetainingCapacity();
    session.cloth_bodies.clearRetainingCapacity();
    session.cloth_cols.clearRetainingCapacity();
    if (session.physics_world) |world| world.destroy();
    session.physics_world = null;
    session.physics_bodies.clearRetainingCapacity();
    var loader_it = session.mesh_face_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.mesh_face_loaders.clearRetainingCapacity();

    if (session.engine.renderer) |*r| {
        var texture_it = session.mesh_face_textures.valueIterator();
        while (texture_it.next()) |handle| r.destroyTexture(handle.*);
    }
    session.mesh_face_textures.clearRetainingCapacity();
}

fn destroyModelState(session: *Session) void {
    var loader_it = session.model_loaders.valueIterator();
    while (loader_it.next()) |loader| loader.*.deinit();
    session.model_loaders.clearRetainingCapacity();

    var mesh_it = session.model_meshes.valueIterator();
    while (mesh_it.next()) |loaded| {
        render.Renderer.destroyModelMesh(loaded.mesh);
        if (loaded.animation) |*anim| gltf.freeAnimation(session.engine.gpa, anim);
    }
    session.model_meshes.clearRetainingCapacity();
}

/// Replaces any currently active lens with the one manifest_json
/// describes, splicing its nodes into the session's graph and applying
/// its default effect values to the beauty chain if one is enabled. The
/// new lens is fully parsed and spliced before the old one is torn
/// down: a manifest that fails to parse, or that names an unsupported
/// node type, leaves whatever was already active running rather than
/// destroying a working lens over a failed swap.
fn activateLens(session: *Session, gpa: std.mem.Allocator, manifest_json: []const u8) !void {
    var diag_arena = std.heap.ArenaAllocator.init(gpa);
    defer diag_arena.deinit();
    var diags = manifest.Diagnostics{ .arena = diag_arena.allocator() };
    var parsed = try manifest.parse(gpa, &diags, manifest_json) orelse return error.InvalidManifest;
    errdefer parsed.deinit();

    var new_lens = try runtime.activate(gpa, &session.lens_graph, session.camera_node, parsed);
    errdefer new_lens.deinit(&session.lens_graph);

    const effects = try new_lens.currentEffects(gpa);
    defer gpa.free(effects);

    destroyShaderPrograms(session);
    destroyLutState(session);
    destroyBlendState(session);
    destroyMeshFaceState(session);
    destroyModelState(session);
    destroyChainOrder(session);
    teardownScript(session);
    destroySounds(session);
    if (session.active_lens) |*old| old.deinit(&session.lens_graph);
    session.active_lens = new_lens;
    setupScript(session);
    applyLensEffects(session, effects);
}

const script_fuel_per_tick: u32 = 2_000_000;

/// Frees the active script driver and its parameter-name table. Safe to
/// call when there is no script; leaves the fields empty.
fn teardownScript(s: *Session) void {
    if (s.script_engine) |*e| e.destroy();
    s.script_engine = null;
    for (s.script_param_names) |n| s.engine.gpa.free(n);
    s.engine.gpa.free(s.script_param_names);
    s.script_param_names = &.{};
}

/// Builds the script driver for the just-activated lens, if it carries a
/// script node. A compile or allocation failure leaves the script absent,
/// the defined degradation: the lens keeps its default parameter values.
fn setupScript(s: *Session) void {
    const lens = if (s.active_lens) |*l| l else return;
    const src = lens.scriptSource() orelse return;
    var engine = script.Script.create(src, script_fuel_per_tick) catch return;
    const params = lens.manifest.parameters;
    const names = s.engine.gpa.alloc([:0]const u8, params.len) catch {
        engine.destroy();
        return;
    };
    var built: usize = 0;
    for (params, 0..) |p, i| {
        names[i] = s.engine.gpa.dupeZ(u8, p.name) catch {
            for (names[0..built]) |n| s.engine.gpa.free(n);
            s.engine.gpa.free(names);
            engine.destroy();
            return;
        };
        built += 1;
    }
    s.script_engine = engine;
    s.script_param_names = names;
}

/// Runs the lens script's update(lens) once, exposing the current signals
/// and passing the live parameters in and out. Bounded stack buffers, no
/// per-frame allocation; a script exception or timeout just skips the write.
fn runScript(s: *Session, signals: *const trigger.Signals) void {
    const engine = if (s.script_engine) |*e| e else return;
    const lens = if (s.active_lens) |*l| l else return;
    const sig_names = [_][*:0]const u8{ "face_present", "hands_present", "audio_level", "audio_beat", "world_tracking_state", "tap" };
    const sig_values = [_]f64{
        if (signals.face_present) 1.0 else 0.0,
        if (signals.hands_present) 1.0 else 0.0,
        signals.audio_level,
        if (signals.audio_beat) 1.0 else 0.0,
        signals.world_tracking_state,
        if (signals.tap) 1.0 else 0.0,
    };
    const n = @min(s.script_param_names.len, 256);
    var name_ptrs: [256][*:0]const u8 = undefined;
    var values: [256]f64 = undefined;
    for (0..n) |i| {
        name_ptrs[i] = s.script_param_names[i].ptr;
        values[i] = lens.param_values[i];
    }
    engine.tick(&sig_names, &sig_values, name_ptrs[0..n], values[0..n]) catch return;
    for (0..n) |i| lens.setParam(s.script_param_names[i], @floatCast(values[i]));
}

const audio_sample_rate: u32 = 48000;
const audio_channels: u32 = 1;

/// Frees the lens mixer and its decoded sounds. Safe with no audio active.
fn destroySounds(s: *Session) void {
    if (s.audio_mixer) |*m| m.destroy();
    s.audio_mixer = null;
    var it = s.sound_ids.keyIterator();
    while (it.next()) |k| s.engine.gpa.free(k.*);
    s.sound_ids.deinit(s.engine.gpa);
    s.sound_ids = .{};
}

/// Builds the lens mixer and decodes every play_sound target from the bundle.
/// Best-effort: a missing or unreadable sound is skipped, the defined
/// degradation, rather than failing activation.
fn createSounds(s: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) void {
    const lens = if (s.active_lens) |*l| l else return;
    var has_sound = false;
    for (lens.manifest.triggers) |trig| {
        if (trig.action.kind == .play_sound and trig.action.target.len > 0) {
            has_sound = true;
            break;
        }
    }
    if (!has_sound) return;
    var mixer = audio_playback.Mixer.create(audio_sample_rate, audio_channels) catch return;
    for (lens.manifest.triggers) |trig| {
        if (trig.action.kind != .play_sound) continue;
        const rel = trig.action.target;
        if (rel.len == 0 or s.sound_ids.contains(rel)) continue;
        const full = std.fmt.allocPrint(gpa, "{s}/{s}", .{ bundle_path, rel }) catch continue;
        defer gpa.free(full);
        const id = mixer.load(full) catch continue;
        const key = s.engine.gpa.dupe(u8, rel) catch continue;
        s.sound_ids.put(s.engine.gpa, key, id) catch {
            s.engine.gpa.free(key);
            continue;
        };
    }
    s.audio_mixer = mixer;
}

/// Starts a voice for every sound a play_sound trigger fired this tick.
fn playFiredSounds(s: *Session) void {
    const mixer = if (s.audio_mixer) |*m| m else return;
    const lens = if (s.active_lens) |*l| l else return;
    for (lens.firedSounds()) |path| {
        if (s.sound_ids.get(path)) |id| mixer.play(id, false, 1.0);
    }
}

/// Pulls the next block of mixed lens audio (frames * channels, s16) for the
/// SDK to play. Silence when no lens sound is active.
pub export fn goss_session_pull_audio(session: ?*Session, out: ?[*]i16, frames: u32) Status {
    const s = session orelse return .invalid_argument;
    const data = out orelse return .invalid_argument;
    const buf = data[0 .. frames * audio_channels];
    if (s.audio_mixer) |*mixer| mixer.pull(buf, frames) else @memset(buf, 0);
    return .ok;
}

pub export fn goss_session_activate_lens(session: ?*Session, manifest_json: ?[*]const u8, manifest_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const bytes = manifest_json orelse return .invalid_argument;
    if (manifest_len == 0) return .invalid_argument;
    activateLens(s, s.engine.gpa, bytes[0..manifest_len]) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        else => .invalid_argument,
    };
    return .ok;
}

/// Loads whatever compiled bytecode a spliced shader.pass node names
/// (shaders/<stem>.<profile>.bin) and creates its bgfx program.
/// Best-effort per node: a packaged bundle was already proven
/// to compile by the validator, so a failure here is a genuine runtime
/// anomaly (missing file, wrong profile) rather than an authoring
/// error - that one pass simply has no program and does not draw,
/// rather than failing the whole activation over it.
fn createShaderPrograms(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const passes = try lens.shaderPassNodes(gpa, &session.lens_graph);
    defer gpa.free(passes);
    if (passes.len == 0) return;

    const tag = render.Renderer.currentShaderProfileTag() catch return;
    const io = defaultIo();
    for (passes) |pass| {
        const bin_path = std.fmt.allocPrint(gpa, "{s}/shaders/{s}.{s}.bin", .{ bundle_path, pass.shader_stem, tag }) catch continue;
        defer gpa.free(bin_path);
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, bin_path, gpa, .limited(256 * 1024)) catch continue;
        defer gpa.free(bytes);
        const program = render.Renderer.loadLensProgram(bytes) catch continue;
        session.shader_programs.put(gpa, pass.graph_index, program.idx) catch {
            render.Renderer.destroyProgram(program);
            continue;
        };
        if (pass.mask_channel) |channel| {
            session.shader_masks.put(gpa, pass.graph_index, channel) catch {};
        }
    }
}

/// The active lens's real chain draw order, spanning both node kinds -
/// built once here regardless of whether each entry's resource is
/// ready yet, since a lut.pass node's load can still be in flight the
/// same frame its position in the chain is already fixed.
fn buildChainOrder(session: *Session, gpa: std.mem.Allocator) !void {
    const lens = if (session.active_lens) |*l| l else return;
    session.chain_order = try lens.compositePassNodes(gpa, &session.lens_graph);
}

/// Starts a background load for every spliced lut.pass node's LUT image
/// (assets/<stem>.png). Best-effort per node like createShaderPrograms:
/// a loader that fails to even start just leaves that node without a
/// texture rather than failing the whole activation.
fn createLutLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const luts = try lens.lutPassNodes(gpa, &session.lens_graph);
    defer gpa.free(luts);
    for (luts) |lut| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, lut.lut_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.lut_loaders.put(gpa, lut.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every LUT load that finished (or failed) since the last frame
/// into a real texture (or drops it) - runs every frame from
/// goss_engine_render_frame since texture creation belongs on the render
/// thread, but each loader is otherwise untouched here except the one
/// frame its result actually lands on.
fn pollLutLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.lut_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.lut_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.lut_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Starts a background load for every spliced blend.pass node's
/// background image (assets/<stem>.png) - mirrors createLutLoaders
/// exactly, one node type over.
fn createBlendLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const blends = try lens.blendPassNodes(gpa, &session.lens_graph);
    defer gpa.free(blends);
    for (blends) |blend| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, blend.background_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.blend_loaders.put(gpa, blend.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every background load that finished (or failed) since the last
/// frame into a real texture (or drops it) - mirrors pollLutLoaders
/// exactly, one node type over.
fn pollBlendLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.blend_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.blend_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.blend_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Starts a background load for every spliced mesh.face node's texture
/// (assets/<stem>.png) - mirrors createBlendLoaders exactly.
fn createMeshFaceLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const meshes = try lens.meshFaceNodes(gpa, &session.lens_graph);
    defer gpa.free(meshes);
    for (meshes) |mesh| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.png", .{ bundle_path, mesh.texture_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ImageLoader.start(gpa, path) catch continue;
        session.mesh_face_loaders.put(gpa, mesh.graph_index, loader) catch {
            loader.deinit();
        };
    }
}

/// Turns every finished mesh.face texture load into a real texture -
/// mirrors pollBlendLoaders exactly.
fn pollMeshFaceLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.mesh_face_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const texture = render.Renderer.createStaticTexture(@intCast(decoded.width), @intCast(decoded.height), decoded.rgba);
            gpa.free(decoded.rgba);
            session.mesh_face_textures.put(gpa, entry.key_ptr.*, texture) catch {
                r.destroyTexture(texture);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.mesh_face_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Starts a background load for every spliced model.gltf node's .glb
/// (assets/<stem>.glb) - mirrors createLutLoaders/createBlendLoaders
/// exactly, one node type over.
fn createModelLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const models = try lens.modelNodes(gpa, &session.lens_graph);
    defer gpa.free(models);
    for (models) |model| {
        if (model.face_anchor) {
            session.model_face_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.world_anchor) {
            session.model_world_anchors.put(gpa, model.graph_index, {}) catch {};
        }
        if (model.particles) |pf| {
            if (session.engine.renderer) |*r| {
                if (particles.System.init(gpa, .{ .count = pf.count, .gravity = pf.gravity, .speed = pf.speed, .lifetime = pf.lifetime })) |sys| {
                    if (r.createParticleMesh(pf.count)) |mesh| {
                        session.particle_systems.put(gpa, model.graph_index, sys) catch {
                            var s2 = sys;
                            s2.deinit();
                        };
                        session.particle_meshes.put(gpa, model.graph_index, mesh) catch {};
                    } else |_| {
                        var s2 = sys;
                        s2.deinit();
                    }
                } else |_| {}
            }
            // Particles generate their own points; no glb load.
            continue;
        }
        if (model.hair) |hair| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const hid = world.addHair(hair.strands, hair.verts, hair.length) catch physics.invalid_body;
                    if (hid != physics.invalid_body) {
                        if (session.engine.renderer) |*r| {
                            if (r.createHairMesh(hair.strands, hair.verts)) |mesh| {
                                session.hair_ids.put(gpa, model.graph_index, hid) catch {};
                                session.hair_meshes.put(gpa, model.graph_index, mesh) catch {};
                                session.hair_vcount.put(gpa, model.graph_index, hair.strands * hair.verts) catch {};
                            } else |_| {}
                        }
                    }
                }
            }
            continue;
        }
        if (model.cloth) |cloth| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const body = world.addCloth(cloth.cols, cloth.rows, cloth.width, cloth.height, .{ 0, 0.4, 0 }) catch physics.invalid_body;
                    if (body != physics.invalid_body) {
                        if (session.engine.renderer) |*r| {
                            if (r.createClothMesh(cloth.cols, cloth.rows)) |mesh| {
                                session.cloth_bodies.put(gpa, model.graph_index, body) catch {};
                                session.cloth_meshes.put(gpa, model.graph_index, mesh) catch {};
                                session.cloth_cols.put(gpa, model.graph_index, cloth.cols * cloth.rows) catch {};
                            } else |_| {}
                        }
                    }
                }
            }
            // Cloth generates its own mesh; no glb load.
            continue;
        }
        if (model.physics) |body| {
            if (physics.supported) {
                if (session.physics_world == null) {
                    session.physics_world = physics.World.create(-9.81) catch null;
                    session.physics_last_us = 0;
                }
                if (session.physics_world) |world| {
                    const motion: physics.Motion = if (body.kinematic) .kinematic else if (body.dynamic) .dynamic else .static;
                    const id = world.addBody(
                        if (body.shape == .box) .box else .sphere,
                        body.position,
                        body.size,
                        motion,
                    ) catch physics.invalid_body;
                    if (id != physics.invalid_body) {
                        session.physics_bodies.put(gpa, model.graph_index, id) catch {};
                    }
                }
            }
        }
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.glb", .{ bundle_path, model.model_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ModelLoader.start(gpa, path) catch continue;
        session.model_loaders.put(gpa, model.graph_index, loader) catch {
            loader.deinit();
        };
    }

    // Wire chains now that every body exists: a dynamic node chained to
    // an anchor node hangs off it by a distance constraint. Node counts
    // are tiny, so a direct id match beats a map.
    if (session.physics_world) |world| {
        for (models) |model| {
            const body = model.physics orelse continue;
            const chain_to = body.chain_to orelse continue;
            const child = session.physics_bodies.get(model.graph_index) orelse continue;
            for (models) |anchor_model| {
                if (!std.mem.eql(u8, anchor_model.node_id, chain_to)) continue;
                const anchor = session.physics_bodies.get(anchor_model.graph_index) orelse break;
                world.constrainDistance(anchor, child, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 0.0, body.chain_length) catch {};
                break;
            }
        }
    }
}

/// Turns every .glb load that finished (or failed) since the last
/// frame into a real gpu mesh (or drops it) - mirrors pollLutLoaders/
/// pollBlendLoaders, except the decoded geometry is freed right after
/// upload (bgfx_copy takes its own copy) while the decoded animation
/// data is kept: there is no gpu resource for it, renderCompositeChain
/// samples it fresh every frame at the lens's own reported elapsed
/// time.
fn pollModelLoaders(session: *Session, r: *render.Renderer, gpa: std.mem.Allocator) void {
    var finished: std.ArrayList(graph.NodeIndex) = .empty;
    defer finished.deinit(gpa);

    var it = session.model_loaders.iterator();
    while (it.next()) |entry| {
        const loader = entry.value_ptr.*;
        if (loader.take()) |decoded| {
            const mesh = r.createModelMesh(decoded.positions, decoded.indices) catch {
                gpa.free(decoded.positions);
                gpa.free(decoded.indices);
                if (decoded.animation) |*anim| gltf.freeAnimation(gpa, anim);
                finished.append(gpa, entry.key_ptr.*) catch {};
                continue;
            };
            gpa.free(decoded.positions);
            gpa.free(decoded.indices);
            session.model_meshes.put(gpa, entry.key_ptr.*, .{
                .mesh = mesh,
                .base_color = decoded.base_color,
                .animation = decoded.animation,
            }) catch {
                render.Renderer.destroyModelMesh(mesh);
                if (decoded.animation) |*anim| gltf.freeAnimation(gpa, anim);
            };
            finished.append(gpa, entry.key_ptr.*) catch {};
        } else if (loader.hasFailed()) {
            finished.append(gpa, entry.key_ptr.*) catch {};
        }
    }
    for (finished.items) |graph_index| {
        if (session.model_loaders.fetchRemove(graph_index)) |kv| kv.value.deinit();
    }
}

/// Activates the lens bundle at bundle_path (bundle_path/manifest.json),
/// then creates a bgfx program for every shader.pass node it spliced
/// and starts a background load for every lut.pass node's LUT image.
/// Additive alongside goss_session_activate_lens rather than a new
/// parameter on it: that function's signature is frozen the moment it
/// shipped, and only a bundle directory - not raw manifest bytes - can
/// name where a shader.pass node's compiled bytecode or a lut.pass
/// node's image lives.
// Explicit anyerror, not inferred: the has_file_io branch below prunes
// away entirely on wasm, which would otherwise narrow the inferred
// error set to just Unsupported there and break the OutOfMemory arm
// goss_session_activate_lens_from_directory's catch already handles for
// every other target.
fn activateLensFromDirectory(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) anyerror!void {
    if (comptime !has_file_io) return error.Unsupported;
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{bundle_path});
    defer gpa.free(manifest_path);
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), manifest_path, gpa, .limited(manifest.max_manifest_bytes + 1));
    defer gpa.free(manifest_json);
    try activateLens(session, gpa, manifest_json);
    try createShaderPrograms(session, gpa, bundle_path);
    try createLutLoaders(session, gpa, bundle_path);
    try createBlendLoaders(session, gpa, bundle_path);
    try createMeshFaceLoaders(session, gpa, bundle_path);
    try createModelLoaders(session, gpa, bundle_path);
    try buildChainOrder(session, gpa);
    createSounds(session, gpa, bundle_path);
}

pub export fn goss_session_activate_lens_from_directory(session: ?*Session, bundle_path: ?[*]const u8, bundle_path_len: usize) Status {
    const s = session orelse return .invalid_argument;
    const path = bundle_path orelse return .invalid_argument;
    if (bundle_path_len == 0) return .invalid_argument;
    activateLensFromDirectory(s, s.engine.gpa, path[0..bundle_path_len]) catch |err| return switch (err) {
        error.OutOfMemory => .out_of_memory,
        error.Unsupported => .unsupported,
        else => .invalid_argument,
    };
    return .ok;
}

pub export fn goss_session_deactivate_lens(session: ?*Session) void {
    const s = session orelse return;
    destroyShaderPrograms(s);
    destroyLutState(s);
    destroyBlendState(s);
    destroyMeshFaceState(s);
    destroyModelState(s);
    destroyChainOrder(s);
    teardownScript(s);
    destroySounds(s);
    if (s.active_lens) |*lens| lens.deinit(&s.lens_graph);
    s.active_lens = null;
}

/// Reads a live parameter of the active lens by name, including whatever a
/// script node last wrote. Returns again with no lens active, and
/// invalid_argument for an unknown name, so the two cases stay distinct.
pub export fn goss_session_parameter_value(session: ?*Session, name: ?[*]const u8, name_len: usize, out_value: ?*f32) Status {
    const s = session orelse return .invalid_argument;
    const n = name orelse return .invalid_argument;
    const out = out_value orelse return .invalid_argument;
    const lens = if (s.active_lens) |*l| l else return .again;
    out.* = lens.paramValue(n[0..name_len]) orelse return .invalid_argument;
    return .ok;
}

/// Advances the active lens by dt_us of real time and applies every
/// effect value its triggers/ramps changed to the beauty chain, if one
/// is enabled. Reports GOSS_AGAIN with no active lens, matching the
/// no-chain-yet convention goss_session_set_beauty already uses.
pub export fn goss_session_tick_lens(session: ?*Session, dt_us: u32, signals: ?*const LensSignals) Status {
    const s = session orelse return .invalid_argument;
    const sig = signals orelse return .invalid_argument;
    if (s.active_lens == null) return .again;
    // Borrowed from the lens's own activation-sized storage, valid
    // until the next tick - nothing to free, nothing allocated.
    var live_signals = toTriggerSignals(sig);
    if (s.audio_engine_fed) {
        live_signals.audio_level = s.audio.level;
        live_signals.audio_beat = s.audio.beat;
    }
    if (s.world_engine_fed) {
        live_signals.world_tracking_state = @floatFromInt(s.world.state.tracking_state);
    }
    // The script drives parameters before triggers and ramps read them, so
    // its writes flow into this tick's effects.
    runScript(s, &live_signals);
    const effects = runtime.tick(&s.active_lens.?, dt_us, live_signals);
    applyLensEffects(s, effects);
    playFiredSounds(s);
    return .ok;
}

const t = std.testing;

test "alloc and free round-trip through the abi allocator" {
    const p = goss_alloc(64) orelse return error.TestUnexpectedResult;
    p[0] = 0xa5;
    p[63] = 0x5a;
    goss_free(p, 64);
    try t.expect(goss_alloc(0) == null);
    goss_free(null, 16);
}

test "abi version packs major and minor" {
    try t.expectEqual((@as(u32, abi_major) << 16) | abi_minor, goss_abi_version());
}

test "engine and session lifecycle is leak-free" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    try t.expectEqual(@as(u16, 16), engine.texture_pool_capacity);

    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);
    try t.expectEqual(@as(u32, default_frame_budget_us), session.controller.config.budget_us);
}

test "report frame walks the ladder like the controller" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 4, .staging_pool_capacity = 4 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 16_000, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(@as(c_int, 0), goss_session_degrade_level(session));
    var level: c_int = 0;
    for (0..64) |_| level = goss_session_report_frame(session, 40_000, 0);
    try t.expect(level > 0);
    try t.expectEqual(level, goss_session_degrade_level(session));

    const jumped = goss_session_report_frame(session, 8_000, 3);
    try t.expectEqual(@as(c_int, 4), jumped);
}

test "null arguments are rejected without crashing" {
    try t.expectEqual(Status.invalid_argument, goss_engine_create(null, null));
    try t.expectEqual(Status.invalid_argument, goss_session_create(null, null, null));
    goss_engine_destroy(null);
    goss_session_destroy(null);
    try t.expectEqual(@as(c_int, 0), goss_session_degrade_level(null));
    try t.expectEqual(Status.invalid_argument, goss_engine_init_renderer(null, null));
    try t.expectEqual(Status.invalid_argument, goss_engine_render_frame(null, null));
}

test "frame submission without a renderer reports it" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const desc: FrameDesc = .{
        .width = 1920,
        .height = 1080,
        .pixel_format = pixel_format_nv12,
        .color_standard = 1,
        .color_range = 0,
        .flags = frame_flag_mirror | (1 << frame_rotation_shift),
        .timestamp_us = 0,
    };
    const planes: FramePlanes = .{ .plane_count = 2, .reserved = 0, .planes = .{ 1, 2, 0 } };
    try t.expectEqual(Status.renderer_unavailable, goss_session_submit_frame(session, &desc, &planes));
    try t.expectEqual(Status.renderer_unavailable, goss_engine_render_frame(engine, session));
}

test "color conversion export writes the homogeneous matrix" {
    var out: [16]f32 = undefined;
    try t.expectEqual(Status.ok, goss_color_yuv_to_rgb(1, 0, &out));
    const direct = math.color.yuvToRgb(.bt709, .video).homogeneous();
    try t.expectEqual(direct.cols[0][0], out[0]);
    try t.expectEqual(direct.cols[3][2], out[14]);
    try t.expectEqual(Status.invalid_argument, goss_color_yuv_to_rgb(9, 0, &out));
    try t.expectEqual(Status.invalid_argument, goss_color_yuv_to_rgb(0, 9, null));
}

test "rotation and mirror decode from the flags field" {
    const flags: u32 = frame_flag_mirror | (3 << frame_rotation_shift);
    try t.expectEqual(@as(u32, 3), (flags & frame_rotation_mask) >> frame_rotation_shift);
    try t.expect(flags & frame_flag_mirror != 0);
}

test "face tracking on a build without the inference stack refuses" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const bytes = [_]u8{ 1, 2, 3 };
    try t.expectEqual(Status.unsupported, goss_session_enable_face_tracking(session, &bytes, bytes.len, 0));
    var result: FaceResult = undefined;
    try t.expectEqual(Status.again, goss_session_face_result(session, &result));
    const desc: FrameDesc = .{ .width = 2, .height = 2, .pixel_format = 0, .color_standard = 0, .color_range = 0, .flags = 0, .timestamp_us = 0 };
    const planes = [_]u8{0} ** 8;
    try t.expectEqual(Status.again, goss_session_track_frame(session, &desc, &planes, 2, &planes, 2));
    goss_session_disable_face_tracking(session);
    try t.expectEqual(Status.invalid_argument, goss_session_face_result(session, null));
}

test "beauty on a build without the effects engine refuses" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.unsupported, goss_session_enable_beauty(session, "res"));
    try t.expectEqual(Status.again, goss_session_set_beauty(session, 0, 0.5));
    var pixels = [_]u8{0} ** 16;
    try t.expectEqual(Status.again, goss_session_beautify_frame(session, &pixels, 2, 2, &pixels));
    goss_session_disable_beauty(session);
}

const test_lens_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.abi", "version": "1.0.0", "display_name": "ABI",
    \\  "engine_compat": ">=0.5", "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.25, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('jawOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

test "activating a lens splices its nodes and applies its default effect values" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    try t.expectEqual(@as(f32, 0.25), session.active_lens.?.param_values[0]);
    // No beauty chain enabled: applying effect values is a silent no-op,
    // not an error - activation still succeeds.

    goss_session_deactivate_lens(session);
    try t.expect(session.active_lens == null);
    // Only the camera source remains scheduled - the lens node was
    // unspliced, not just detached.
    try t.expectEqual(@as(usize, 1), (try session.lens_graph.executionOrder()).len);
}

test "activating a second lens replaces the first, and invalid input is rejected cleanly" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);

    const garbage = "not a manifest";
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(session, garbage.ptr, garbage.len));
    // A failed activation does not disturb the previously active lens.
    try t.expect(session.active_lens != null);

    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(null, garbage.ptr, garbage.len));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens(session, null, 0));

    goss_session_deactivate_lens(session);
    goss_session_deactivate_lens(session); // idempotent
}

test "ticking with no active lens reports again; ticking a firing trigger advances its ramp" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var closed_signals = std.mem.zeroes(LensSignals);
    try t.expectEqual(Status.again, goss_session_tick_lens(session, 8_333, &closed_signals));

    try t.expectEqual(Status.ok, goss_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));

    var open_signals = std.mem.zeroes(LensSignals);
    open_signals.has_face = true;
    const jaw_open = face.blendshapeIndex("jawOpen").?;
    open_signals.blendshapes[jaw_open] = 0.9;

    try t.expectEqual(Status.ok, goss_session_tick_lens(session, 8_333, &open_signals));
    try t.expect(session.active_lens.?.param_values[0] > 0.25);
    try t.expect(session.active_lens.?.param_values[0] < 1.0);

    try t.expectEqual(Status.invalid_argument, goss_session_tick_lens(session, 8_333, null));
}

test "a script node drives a parameter from a signal" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const manifest_json =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "intensity", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\ "nodes": [{"id": "drive", "type": "script", "params": {},
        \\   "source": "function update(lens) { lens.params.intensity = lens.signals.face_present > 0.5 ? 0.8 : 0.2; }"}],
        \\ "triggers": []}
    ;
    try t.expectEqual(Status.ok, goss_session_activate_lens(session, manifest_json.ptr, manifest_json.len));

    var present = std.mem.zeroes(LensSignals);
    present.has_face = true;
    try t.expectEqual(Status.ok, goss_session_tick_lens(session, 16_000, &present));

    var v: f32 = -1;
    try t.expectEqual(Status.ok, goss_session_parameter_value(session, "intensity", "intensity".len, &v));
    try t.expectApproxEqAbs(@as(f32, 0.8), v, 1e-6);
}

test "activating a lens from a real bundle directory splices it, and a build without a renderer creates no shader programs" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const bundle_path = "lenses/reference/shader-tint";
    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    // This build has no compiled render stack (the stub always reports
    // RendererUnavailable) - the lens still activates cleanly, its
    // shader.pass node just has no program, exactly the degradation
    // goss_session_set_beauty already establishes for a missing engine.
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());
    // The chain's structure is still known even though nothing in it
    // has a resource yet - that's what lets a lut.pass node's load
    // land on some later frame without needing to reactivate.
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.shader, session.chain_order[0].kind);

    goss_session_deactivate_lens(session);
    try t.expect(session.active_lens == null);
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());
    try t.expectEqual(@as(usize, 0), session.chain_order.len);

    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(null, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(session, null, 0));
    try t.expectEqual(Status.invalid_argument, goss_session_activate_lens_from_directory(session, bundle_path.ptr, 0));
}

const lut_pass_bundle_manifest =
    \\{"glf":"1.0","id":"com.example.lut","version":"1.0.0","display_name":"LUT",
    \\ "engine_compat":">=0.5","capabilities":[],"parameters":[],
    \\ "nodes":[{"id":"warm-lut","type":"lut.pass","inputs":{"frame":"camera"},"params":{}}],
    \\ "triggers":[]}
;

// The same 8x8 checker PNG adapters/image and adapters/asset's own
// tests decode - real bytes, so this proves the real background thread
// and real lodepng decode, not a mock standing in for either.
const lut_checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

test "activating a lens with a lut.pass node loads its LUT image for real, off the calling thread" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = lut_pass_bundle_manifest });
    try tmp.dir.createDirPath(t.io, "assets");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "assets/warm-lut.png", .data = &lut_checker_png });

    var path_buf: [64]u8 = undefined;
    const bundle_path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(@as(usize, 1), session.lut_loaders.count());
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.lut, session.chain_order[0].kind);

    var loader_it = session.lut_loaders.valueIterator();
    const loader = loader_it.next().?.*;
    var decoded: ?image.Image = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.rgba);
    try t.expectEqual(@as(u32, 8), got.width);
    try t.expectEqual(@as(u32, 8), got.height);
    try t.expect(!loader.hasFailed());

    // A load that finished but was never polled through
    // goss_engine_render_frame (this build has no compiled render stack)
    // is still cleaned up correctly on deactivation, not leaked or
    // double-freed.
    goss_session_deactivate_lens(session);
    try t.expectEqual(@as(usize, 0), session.lut_loaders.count());
}

const blend_pass_bundle_manifest =
    \\{"glf":"1.0","id":"com.example.blend","version":"1.0.0","display_name":"Blend",
    \\ "engine_compat":">=0.5","capabilities":["segmentation"],"parameters":[],
    \\ "nodes":[{"id":"beach","type":"blend.pass","inputs":{"frame":"camera"},"params":{}}],
    \\ "triggers":[]}
;

test "activating a lens with a blend.pass node loads its background image for real, off the calling thread" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = blend_pass_bundle_manifest });
    try tmp.dir.createDirPath(t.io, "assets");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "assets/beach.png", .data = &lut_checker_png });

    var path_buf: [64]u8 = undefined;
    const bundle_path = std.fmt.bufPrint(&path_buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;

    try t.expectEqual(Status.ok, goss_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(@as(usize, 1), session.blend_loaders.count());
    try t.expectEqual(@as(usize, 1), session.chain_order.len);
    try t.expectEqual(runtime.PassKind.blend, session.chain_order[0].kind);

    var loader_it = session.blend_loaders.valueIterator();
    const loader = loader_it.next().?.*;
    var decoded: ?image.Image = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.rgba);
    try t.expectEqual(@as(u32, 8), got.width);
    try t.expectEqual(@as(u32, 8), got.height);
    try t.expect(!loader.hasFailed());

    goss_session_deactivate_lens(session);
    try t.expectEqual(@as(usize, 0), session.blend_loaders.count());
}
