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

pub const abi_major: u16 = 0;
pub const abi_minor: u16 = 8;

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
    capture_width: u16 = 0,
    capture_height: u16 = 0,
};

const CurrentFrame = struct {
    desc: FrameDesc,
    preview: render.PreviewFrame,
    owns_textures: bool = true,
};

pub const Session = struct {
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
    face_tracking: ?*tracking.Tracking = null,
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
    /// One bgfx program per currently-spliced shader.pass node, keyed by
    /// its graph index. Created at activation (goss_session_activate_lens_
    /// from_directory only - the bytes-based activate has no bundle path
    /// to read compiled shaders from), destroyed on deactivation.
    shader_programs: std.AutoHashMapUnmanaged(graph.NodeIndex, u16) = .empty,
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
    for (engine.chain_targets) |slot| {
        if (slot) |target| render.Renderer.destroyOffscreenTarget(target);
    }
    if (engine.capture_target) |target| render.Renderer.destroyOffscreenTarget(target);
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
    e.capture_target = try render.Renderer.createOffscreenTarget(width, height);
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
    r.submitShaderPass(view_id, r.passthroughProgram(), input_texture);

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
    var ready_count: usize = 0;
    for (s.chain_order) |entry| {
        const ready = switch (entry.kind) {
            .shader => s.shader_programs.contains(entry.graph_index),
            .lut => s.lut_textures.contains(entry.graph_index),
            // Only the background image gates readiness - the mask
            // degrades to the renderer's always-foreground default
            // when segmentation is unavailable (SPEC's rule: a node
            // consuming an unavailable capability's data holds its
            // default state, not blocks the chain).
            .blend => s.blend_textures.contains(entry.graph_index),
            .model => s.model_meshes.contains(entry.graph_index),
        };
        if (ready) ready_count += 1;
    }
    const beauty_active = anyBeautyActive(s);
    if (s.capture_requested) try ensureCaptureTarget(e, @intCast(r.width), @intCast(r.height));
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
        render.Renderer.setViewTarget(0, finalTarget(e, s), @intCast(r.width), @intCast(r.height));
        r.submitPreview(0, current.preview, rotation * 90, mirror);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, 1);
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
    const output_width: u16 = @intCast(r.width);
    const output_height: u16 = @intCast(r.height);
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
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitShaderPass(view_id, .{ .idx = program_idx }, input_texture);
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
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitLutPass(view_id, input_texture, lut_texture);
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
                if (output) |target| render.Renderer.setViewTarget(view_id, target, if (is_final) output_width else width, if (is_final) output_height else height) else render.Renderer.setViewTarget(view_id, null, output_width, output_height);
                r.submitBlendPass(view_id, input_texture, background_texture, mask_texture);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
            .model => {
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
                const model_matrix = if (loaded.animation) |*anim| anim.sample(elapsed_seconds) else math.Mat4.identity;
                const aspect_ratio: f32 = @as(f32, @floatFromInt(rect_width)) / @as(f32, @floatFromInt(rect_height));
                r.submitModel(blit_view, mesh_view, input_texture, loaded.mesh, model_matrix, loaded.base_color, aspect_ratio);
                if (output) |target| {
                    input_texture = target.texture;
                    if (!is_final) next_slot += 1;
                }
            },
        }
    }

    if (s.capture_requested and ready_count > 0) blitCaptureToSwapChain(e, r, next_view_id);

    if (ready_count == 0) {
        // beauty_active is guaranteed true here (the ready_count == 0
        // and !beauty_active case already returned above): beauty's own
        // output is a plain sampled texture, never a view's render
        // target, so with no lens stage to hand it off to, it still
        // needs one real draw to actually reach the swap chain.
        render.Renderer.setViewTarget(next_view_id, finalTarget(e, s), output_width, output_height);
        r.submitShaderPass(next_view_id, r.passthroughProgram(), input_texture);
        if (s.capture_requested) blitCaptureToSwapChain(e, r, next_view_id + 1);
    }
}

/// The composite chain's true final-stage target: the swap chain
/// directly, or - for exactly the one frame goss_engine_capture_frame
/// requested - the dedicated capture target instead, so the chain's
/// real output lands somewhere bgfx_read_texture can read it back from
/// after the frame completes.
fn finalTarget(e: *Engine, s: *Session) ?render.Renderer.OffscreenTarget {
    return if (s.capture_requested) e.capture_target else null;
}

/// Draws the just-composited capture target to the swap chain, so a
/// captured frame still displays normally - the same passthrough blit
/// the ready_count == 0 beauty-only path already uses to reach the
/// swap chain, reused here for the same reason.
fn blitCaptureToSwapChain(e: *Engine, r: *render.Renderer, view_id: u8) void {
    const target = e.capture_target orelse return;
    render.Renderer.setViewTarget(view_id, null, @intCast(r.width), @intCast(r.height));
    r.submitShaderPass(view_id, r.passthroughProgram(), target.texture);
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
    destroyShaderPrograms(session);
    session.shader_programs.deinit(session.engine.gpa);
    destroyLutState(session);
    session.lut_loaders.deinit(session.engine.gpa);
    session.lut_textures.deinit(session.engine.gpa);
    destroyBlendState(session);
    session.blend_loaders.deinit(session.engine.gpa);
    session.blend_textures.deinit(session.engine.gpa);
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

pub export fn goss_engine_render_frame(engine: ?*Engine, session: ?*Session) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    if (session) |s| {
        pollLutLoaders(s, r, s.engine.gpa);
        pollBlendLoaders(s, r, s.engine.gpa);
        pollModelLoaders(s, r, s.engine.gpa);
        pollSegmentationMask(s);
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
pub export fn goss_engine_capture_frame(engine: ?*Engine, session: ?*Session, out_data: ?[*]u8, out_capacity: usize, out_width: ?*u32, out_height: ?*u32) Status {
    const e = engine orelse return .invalid_argument;
    const s = session orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    const data = out_data orelse return .invalid_argument;
    const w = out_width orelse return .invalid_argument;
    const h = out_height orelse return .invalid_argument;

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

    const target = e.capture_target orelse return .renderer_unavailable;
    w.* = e.capture_width;
    h.* = e.capture_height;
    const full_size = @as(usize, e.capture_width) * @as(usize, e.capture_height) * 4;
    if (full_size == 0) return .ok;
    if (out_capacity < full_size) return .invalid_argument;

    const ready_frame = render.Renderer.readTexture(target.texture, data);
    while (r.frame() < ready_frame) {}
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
    if (s.face_tracking == null and s.segmentation_worker == null) return .again;
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
    const texture = session.segmentation_texture orelse return;
    if (session.engine.renderer) |*r| r.destroyTexture(texture);
    session.segmentation_texture = null;
}

/// Turns the newest published mask into a real GPU texture - runs every
/// frame from goss_engine_render_frame since texture creation belongs on
/// the render thread, mirroring pollLutLoaders. Replaces the previous
/// texture outright since bgfx's static textures are immutable; nothing
/// consumes segmentation_texture yet (background-swap compositing is
/// future work), so this only ever does the upload.
fn pollSegmentationMask(session: *Session) void {
    const worker = session.segmentation_worker orelse return;
    var mask: [segmentation.mask_len]f32 = undefined;
    if (!segmentation.readMask(worker, &mask)) return;

    var bytes: [segmentation.mask_len]u8 = undefined;
    for (mask, 0..) |value, i| {
        bytes[i] = @intFromFloat(std.math.clamp(value, 0.0, 1.0) * 255.0);
    }
    const texture = render.Renderer.createMaskTexture(segmentation.mask_side, segmentation.mask_side, &bytes);
    destroySegmentationTexture(session);
    session.segmentation_texture = texture;
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
    destroyModelState(session);
    destroyChainOrder(session);
    if (session.active_lens) |*old| old.deinit(&session.lens_graph);
    session.active_lens = new_lens;
    applyLensEffects(session, effects);
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
        };
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

/// Starts a background load for every spliced model.gltf node's .glb
/// (assets/<stem>.glb) - mirrors createLutLoaders/createBlendLoaders
/// exactly, one node type over.
fn createModelLoaders(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const models = try lens.modelNodes(gpa, &session.lens_graph);
    defer gpa.free(models);
    for (models) |model| {
        const path = std.fmt.allocPrint(gpa, "{s}/assets/{s}.glb", .{ bundle_path, model.model_stem }) catch continue;
        defer gpa.free(path);
        const loader = asset.ModelLoader.start(gpa, path) catch continue;
        session.model_loaders.put(gpa, model.graph_index, loader) catch {
            loader.deinit();
        };
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
    try createModelLoaders(session, gpa, bundle_path);
    try buildChainOrder(session, gpa);
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
    destroyModelState(s);
    destroyChainOrder(s);
    if (s.active_lens) |*lens| lens.deinit(&s.lens_graph);
    s.active_lens = null;
}

/// Advances the active lens by dt_us of real time and applies every
/// effect value its triggers/ramps changed to the beauty chain, if one
/// is enabled. Reports GOSS_AGAIN with no active lens, matching the
/// no-chain-yet convention goss_session_set_beauty already uses.
pub export fn goss_session_tick_lens(session: ?*Session, dt_us: u32, signals: ?*const LensSignals) Status {
    const s = session orelse return .invalid_argument;
    const sig = signals orelse return .invalid_argument;
    if (s.active_lens == null) return .again;
    const effects = runtime.tick(&s.active_lens.?, s.engine.gpa, dt_us, toTriggerSignals(sig)) catch return .out_of_memory;
    defer s.engine.gpa.free(effects);
    applyLensEffects(s, effects);
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
