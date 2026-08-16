//! The ck_ export layer: the only file that exports symbols. Everything here
//! mirrors include/camerakit.h exactly; layouts are frozen and asserted at
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
const face = @import("face");
const beauty = @import("beauty");
const manifest = @import("manifest");
const trigger = @import("trigger");

// A directory-based lens activation needs to read files (manifest.json,
// compiled shader bytecode) from within an exported ck_ function, which
// no shell hands an Io instance into - this library owns one blocking
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
pub const abi_minor: u16 = 7;

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

/// The live signals a tick evaluates a lens's compiled triggers against
/// (SPEC.md 6.1) - blendshapes mirrors ck_face_result's own inline-array
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
    copied_frames: u64 = 0,
    face_tracking: ?*tracking.Tracking = null,
    beauty_chain: ?*beauty.Beauty = null,
    lens_graph: graph.Graph,
    camera_node: graph.NodeIndex,
    active_lens: ?runtime.Lens = null,
    /// One bgfx program per currently-spliced shader.pass node, keyed by
    /// its graph index. Created at activation (ck_session_activate_lens_
    /// from_directory only - the bytes-based activate has no bundle path
    /// to read compiled shaders from), destroyed on deactivation.
    shader_programs: std.AutoHashMapUnmanaged(graph.NodeIndex, u16) = .empty,
};

fn abiAllocator() std.mem.Allocator {
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
    if (engine.renderer) |*r| r.deinit();
    engine.texture_pool.deinit();
    engine.staging_pool.deinit();
    engine.gpa.destroy(engine);
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
    if (session.active_lens) |*lens| lens.deinit(&session.lens_graph);
    session.active_lens = null;
    session.lens_graph.deinit();
    if (session.beauty_chain) |chain| beauty.destroy(session.engine.gpa, chain);
    session.beauty_chain = null;
    if (session.face_tracking) |worker| tracking.destroy(worker);
    session.face_tracking = null;
    releaseCurrentFrame(session);
    session.engine.gpa.destroy(session);
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
/// Pair every allocation with ck_free of the same size.
pub export fn ck_alloc(size: usize) ?[*]u8 {
    if (size == 0) return null;
    const slice = abiAllocator().alloc(u8, size) catch return null;
    return slice.ptr;
}

pub export fn ck_free(ptr: ?[*]u8, size: usize) void {
    const p = ptr orelse return;
    if (size == 0) return;
    abiAllocator().free(p[0..size]);
}

pub export fn ck_abi_version() u32 {
    return (@as(u32, abi_major) << 16) | abi_minor;
}

pub export fn ck_engine_create(config: ?*const EngineConfig, out_engine: ?**Engine) Status {
    const out = out_engine orelse return .invalid_argument;
    const cfg: EngineConfig = if (config) |c| c.* else .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 };
    const engine = createEngine(abiAllocator(), cfg) catch return .out_of_memory;
    out.* = engine;
    return .ok;
}

pub export fn ck_engine_destroy(engine: ?*Engine) void {
    destroyEngine(engine orelse return);
}

pub export fn ck_engine_init_renderer(engine: ?*Engine, desc: ?*const RendererDesc) Status {
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

pub export fn ck_engine_resize(engine: ?*Engine, width: u32, height: u32) void {
    const e = engine orelse return;
    if (e.renderer) |*r| r.resize(width, height);
}

pub export fn ck_engine_render_frame(engine: ?*Engine, session: ?*Session) Status {
    const e = engine orelse return .invalid_argument;
    const r = if (e.renderer) |*r| r else return .renderer_unavailable;
    if (session) |s| {
        if (s.current) |current| {
            const rotation = (current.desc.flags & frame_rotation_mask) >> frame_rotation_shift;
            const mirror = current.desc.flags & frame_flag_mirror != 0;
            r.submitPreview(current.preview, rotation * 90, mirror);
        } else {
            r.touch();
        }
    } else {
        r.touch();
    }
    _ = r.frame();
    return .ok;
}

pub export fn ck_session_create(engine: ?*Engine, config: ?*const SessionConfig, out_session: ?**Session) Status {
    const out = out_session orelse return .invalid_argument;
    const parent = engine orelse return .invalid_argument;
    const cfg: SessionConfig = if (config) |c| c.* else .{ .frame_budget_us = 0, .reserved = 0 };
    const session = createSession(parent, cfg) catch return .out_of_memory;
    out.* = session;
    return .ok;
}

pub export fn ck_session_destroy(session: ?*Session) void {
    destroySession(session orelse return);
}

pub export fn ck_session_submit_frame(session: ?*Session, desc: ?*const FrameDesc, planes: ?*const FramePlanes) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const p = planes orelse return .invalid_argument;
    const r = if (s.engine.renderer) |*r| r else return .renderer_unavailable;

    releaseCurrentFrame(s);
    switch (d.pixel_format) {
        pixel_format_bgra8, pixel_format_rgba8 => {
            if (p.plane_count != 1) return .invalid_argument;
            const format: u32 = if (d.pixel_format == pixel_format_bgra8) render.c.BGFX_TEXTURE_FORMAT_BGRA8 else render.c.BGFX_TEXTURE_FORMAT_RGBA8;
            const texture = r.wrapExternalTexture(@intCast(d.width), @intCast(d.height), format, @intCast(p.planes[0]));
            s.current = .{ .desc = d.*, .preview = .{ .bgra = .{ .texture = texture } } };
        },
        pixel_format_nv12 => {
            if (p.plane_count != 2) return .invalid_argument;
            const y = r.wrapExternalTexture(@intCast(d.width), @intCast(d.height), render.c.BGFX_TEXTURE_FORMAT_R8, @intCast(p.planes[0]));
            const uv = r.wrapExternalTexture(@intCast(d.width / 2), @intCast(d.height / 2), render.c.BGFX_TEXTURE_FORMAT_RG8, @intCast(p.planes[1]));
            const standard: math.color.Standard = switch (d.color_standard) {
                0 => .bt601,
                2 => .bt2020,
                else => .bt709,
            };
            const range: math.color.Range = if (d.color_range == 1) .full else .video;
            s.current = .{ .desc = d.*, .preview = .{ .nv12 = .{
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
/// column-major homogeneous matrix: rgb = (m * vec4(yuv, 1)).xyz. Shells
/// that own their GPU pipeline, the web shell today, get their color math
/// from the core instead of hardcoding it.
pub export fn ck_color_yuv_to_rgb(color_standard: u32, color_range: u32, out_matrix: ?*[16]f32) Status {
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

/// Copies NV12 planes into pooled textures. The stated CPU path: a shell
/// uses it only where the zero-copy import is not wired yet, and the copy
/// is counted so the budget report shows it.
pub export fn ck_session_submit_frame_copy(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
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

/// Zero-copy camera submission for platforms delivering hardware buffers.
/// The render adapter converts on the gpu; a status other than ok means the
/// caller falls back to the declared copy path for this stream.
pub export fn ck_session_submit_hardware_buffer(session: ?*Session, desc: ?*const FrameDesc, hardware_buffer: ?*anyopaque) Status {
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

pub export fn ck_session_report_frame(session: ?*Session, frame_time_us: u32, thermal: c_int) c_int {
    const s = session orelse return 0;
    _ = s.controller.step(.{ .frame_time_us = frame_time_us, .thermal = thermalFromC(thermal) });
    return @intFromEnum(s.controller.level);
}

pub export fn ck_session_degrade_level(session: ?*const Session) c_int {
    const s = session orelse return 0;
    return @intFromEnum(s.controller.level);
}

/// Stands the face tracking worker up from a model bundle. The bundle
/// bytes are copied; the caller may release them on return. On platforms
/// built without the inference stack this reports unsupported.
pub export fn ck_session_enable_face_tracking(session: ?*Session, task_bytes: ?[*]const u8, task_len: usize, threads: i32) Status {
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

pub export fn ck_session_disable_face_tracking(session: ?*Session) void {
    const s = session orelse return;
    if (s.face_tracking) |worker| tracking.destroy(worker);
    s.face_tracking = null;
}

/// Feeds one NV12 frame to the tracking worker. The planes are CPU
/// addresses valid for the duration of the call; the worker copies and
/// returns immediately, dropping stale frames in favor of this one.
pub export fn ck_session_track_frame(session: ?*Session, desc: ?*const FrameDesc, y: ?[*]const u8, y_stride: u32, uv: ?[*]const u8, uv_stride: u32) Status {
    const s = session orelse return .invalid_argument;
    const d = desc orelse return .invalid_argument;
    const y_plane = y orelse return .invalid_argument;
    const uv_plane = uv orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    if (d.pixel_format != pixel_format_nv12) return .invalid_argument;
    if (d.width == 0 or d.height == 0) return .invalid_argument;
    if (y_stride < d.width or uv_stride < ((d.width + 1) / 2) * 2) return .invalid_argument;
    const standard: math.color.Standard = switch (d.color_standard) {
        0 => .bt601,
        2 => .bt2020,
        else => .bt709,
    };
    const range: math.color.Range = if (d.color_range == 1) .full else .video;
    tracking.submitNv12(
        worker,
        d.width,
        d.height,
        d.timestamp_us,
        math.color.yuvToRgb(standard, range),
        y_plane,
        y_stride,
        uv_plane,
        uv_stride,
    );
    return .ok;
}

/// Reads the newest tracking result into caller memory. Reports again
/// until the worker has published its first result.
pub export fn ck_session_face_result(session: ?*Session, out_result: ?*face.Result) Status {
    const s = session orelse return .invalid_argument;
    const out = out_result orelse return .invalid_argument;
    const worker = s.face_tracking orelse return .again;
    if (!tracking.readResult(worker, out)) return .again;
    return .ok;
}

/// Stands the beauty chain up for a session. The resource path names the
/// directory holding the effect engine's shader and image assets; builds
/// without the effects engine report unsupported.
pub export fn ck_session_enable_beauty(session: ?*Session, resource_path: ?[*:0]const u8) Status {
    const s = session orelse return .invalid_argument;
    const path = resource_path orelse return .invalid_argument;
    if (s.beauty_chain != null) return .ok;
    s.beauty_chain = beauty.create(s.engine.gpa, path) catch |err| switch (err) {
        error.Unsupported => return .unsupported,
        error.OutOfMemory => return .out_of_memory,
    };
    return .ok;
}

pub export fn ck_session_disable_beauty(session: ?*Session) void {
    const s = session orelse return;
    if (s.beauty_chain) |chain| beauty.destroy(s.engine.gpa, chain);
    s.beauty_chain = null;
}

/// Effect identifiers follow the header: smooth, whiten, thin face, big
/// eye, lipstick, blush. Values clamp to zero and one; zero disables the
/// effect.
pub export fn ck_session_set_beauty(session: ?*Session, effect: i32, value: f32) Status {
    const s = session orelse return .invalid_argument;
    const chain = s.beauty_chain orelse return .again;
    if (effect < 0 or effect > 5) return .invalid_argument;
    beauty.set(chain, @enumFromInt(effect), value);
    return .ok;
}

/// Runs the beauty chain over one RGBA frame on the calling thread,
/// reading the newest tracking result for the landmark driven effects
/// when face tracking is enabled. The stated CPU path: live preview
/// integration on the render thread is the device side of this row.
pub export fn ck_session_beautify_frame(session: ?*Session, rgba_in: ?[*]const u8, width: u32, height: u32, rgba_out: ?[*]u8) Status {
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

fn toTriggerSignals(s: LensSignals) trigger.Signals {
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
    const chain = session.beauty_chain orelse return;
    for (effects) |applied| beauty.set(chain, @enumFromInt(@intFromEnum(applied.effect)), applied.value);
}

fn destroyShaderPrograms(session: *Session) void {
    var it = session.shader_programs.valueIterator();
    while (it.next()) |handle| render.Renderer.destroyProgram(.{ .idx = handle.* });
    session.shader_programs.clearRetainingCapacity();
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
    if (session.active_lens) |*old| old.deinit(&session.lens_graph);
    session.active_lens = new_lens;
    applyLensEffects(session, effects);
}

pub export fn ck_session_activate_lens(session: ?*Session, manifest_json: ?[*]const u8, manifest_len: usize) Status {
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
/// (shaders/<stem>.<profile>.bin, SPEC.md 7) and creates its bgfx
/// program. Best-effort per node: a packaged bundle was already proven
/// to compile by the validator, so a failure here is a genuine runtime
/// anomaly (missing file, wrong profile) rather than an authoring
/// error - that one pass simply has no program and does not draw,
/// rather than failing the whole activation over it.
fn createShaderPrograms(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) !void {
    const lens = if (session.active_lens) |*l| l else return;
    const passes = try lens.shaderPassNodes(gpa);
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

/// Activates the lens bundle at bundle_path (bundle_path/manifest.json),
/// then creates a bgfx program for every shader.pass node it spliced.
/// Additive alongside ck_session_activate_lens rather than a new
/// parameter on it: that function's signature is frozen the moment it
/// shipped, and only a bundle directory - not raw manifest bytes - can
/// name where a shader.pass node's compiled bytecode lives.
// Explicit anyerror, not inferred: the has_file_io branch below prunes
// away entirely on wasm, which would otherwise narrow the inferred
// error set to just Unsupported there and break the OutOfMemory arm
// ck_session_activate_lens_from_directory's catch already handles for
// every other target.
fn activateLensFromDirectory(session: *Session, gpa: std.mem.Allocator, bundle_path: []const u8) anyerror!void {
    if (comptime !has_file_io) return error.Unsupported;
    const manifest_path = try std.fmt.allocPrint(gpa, "{s}/manifest.json", .{bundle_path});
    defer gpa.free(manifest_path);
    const manifest_json = try std.Io.Dir.cwd().readFileAlloc(defaultIo(), manifest_path, gpa, .limited(manifest.max_manifest_bytes + 1));
    defer gpa.free(manifest_json);
    try activateLens(session, gpa, manifest_json);
    try createShaderPrograms(session, gpa, bundle_path);
}

pub export fn ck_session_activate_lens_from_directory(session: ?*Session, bundle_path: ?[*]const u8, bundle_path_len: usize) Status {
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

pub export fn ck_session_deactivate_lens(session: ?*Session) void {
    const s = session orelse return;
    destroyShaderPrograms(s);
    if (s.active_lens) |*lens| lens.deinit(&s.lens_graph);
    s.active_lens = null;
}

/// Advances the active lens by dt_us of real time and applies every
/// effect value its triggers/ramps changed to the beauty chain, if one
/// is enabled. Reports CK_AGAIN with no active lens, matching the
/// no-chain-yet convention ck_session_set_beauty already uses.
pub export fn ck_session_tick_lens(session: ?*Session, dt_us: u32, signals: ?*const LensSignals) Status {
    const s = session orelse return .invalid_argument;
    const sig = signals orelse return .invalid_argument;
    if (s.active_lens == null) return .again;
    const effects = runtime.tick(&s.active_lens.?, s.engine.gpa, dt_us, toTriggerSignals(sig.*)) catch return .out_of_memory;
    defer s.engine.gpa.free(effects);
    applyLensEffects(s, effects);
    return .ok;
}

const t = std.testing;

test "alloc and free round-trip through the abi allocator" {
    const p = ck_alloc(64) orelse return error.TestUnexpectedResult;
    p[0] = 0xa5;
    p[63] = 0x5a;
    ck_free(p, 64);
    try t.expect(ck_alloc(0) == null);
    ck_free(null, 16);
}

test "abi version packs major and minor" {
    try t.expectEqual((@as(u32, abi_major) << 16) | abi_minor, ck_abi_version());
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

    try t.expectEqual(@as(c_int, 0), ck_session_degrade_level(session));
    var level: c_int = 0;
    for (0..64) |_| level = ck_session_report_frame(session, 40_000, 0);
    try t.expect(level > 0);
    try t.expectEqual(level, ck_session_degrade_level(session));

    const jumped = ck_session_report_frame(session, 8_000, 3);
    try t.expectEqual(@as(c_int, 4), jumped);
}

test "null arguments are rejected without crashing" {
    try t.expectEqual(Status.invalid_argument, ck_engine_create(null, null));
    try t.expectEqual(Status.invalid_argument, ck_session_create(null, null, null));
    ck_engine_destroy(null);
    ck_session_destroy(null);
    try t.expectEqual(@as(c_int, 0), ck_session_degrade_level(null));
    try t.expectEqual(Status.invalid_argument, ck_engine_init_renderer(null, null));
    try t.expectEqual(Status.invalid_argument, ck_engine_render_frame(null, null));
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
    try t.expectEqual(Status.renderer_unavailable, ck_session_submit_frame(session, &desc, &planes));
    try t.expectEqual(Status.renderer_unavailable, ck_engine_render_frame(engine, session));
}

test "color conversion export writes the homogeneous matrix" {
    var out: [16]f32 = undefined;
    try t.expectEqual(Status.ok, ck_color_yuv_to_rgb(1, 0, &out));
    const direct = math.color.yuvToRgb(.bt709, .video).homogeneous();
    try t.expectEqual(direct.cols[0][0], out[0]);
    try t.expectEqual(direct.cols[3][2], out[14]);
    try t.expectEqual(Status.invalid_argument, ck_color_yuv_to_rgb(9, 0, &out));
    try t.expectEqual(Status.invalid_argument, ck_color_yuv_to_rgb(0, 9, null));
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
    try t.expectEqual(Status.unsupported, ck_session_enable_face_tracking(session, &bytes, bytes.len, 0));
    var result: FaceResult = undefined;
    try t.expectEqual(Status.again, ck_session_face_result(session, &result));
    const desc: FrameDesc = .{ .width = 2, .height = 2, .pixel_format = 0, .color_standard = 0, .color_range = 0, .flags = 0, .timestamp_us = 0 };
    const planes = [_]u8{0} ** 8;
    try t.expectEqual(Status.again, ck_session_track_frame(session, &desc, &planes, 2, &planes, 2));
    ck_session_disable_face_tracking(session);
    try t.expectEqual(Status.invalid_argument, ck_session_face_result(session, null));
}

test "beauty on a build without the effects engine refuses" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    try t.expectEqual(Status.unsupported, ck_session_enable_beauty(session, "res"));
    try t.expectEqual(Status.again, ck_session_set_beauty(session, 0, 0.5));
    var pixels = [_]u8{0} ** 16;
    try t.expectEqual(Status.again, ck_session_beautify_frame(session, &pixels, 2, 2, &pixels));
    ck_session_disable_beauty(session);
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

    try t.expectEqual(Status.ok, ck_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    try t.expectEqual(@as(f32, 0.25), session.active_lens.?.param_values[0]);
    // No beauty chain enabled: applying effect values is a silent no-op,
    // not an error - activation still succeeds.

    ck_session_deactivate_lens(session);
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

    try t.expectEqual(Status.ok, ck_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(Status.ok, ck_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);

    const garbage = "not a manifest";
    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens(session, garbage.ptr, garbage.len));
    // A failed activation does not disturb the previously active lens.
    try t.expect(session.active_lens != null);

    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens(null, garbage.ptr, garbage.len));
    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens(session, null, 0));

    ck_session_deactivate_lens(session);
    ck_session_deactivate_lens(session); // idempotent
}

test "ticking with no active lens reports again; ticking a firing trigger advances its ramp" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    var closed_signals = std.mem.zeroes(LensSignals);
    try t.expectEqual(Status.again, ck_session_tick_lens(session, 8_333, &closed_signals));

    try t.expectEqual(Status.ok, ck_session_activate_lens(session, test_lens_manifest.ptr, test_lens_manifest.len));

    var open_signals = std.mem.zeroes(LensSignals);
    open_signals.has_face = true;
    const jaw_open = face.blendshapeIndex("jawOpen").?;
    open_signals.blendshapes[jaw_open] = 0.9;

    try t.expectEqual(Status.ok, ck_session_tick_lens(session, 8_333, &open_signals));
    try t.expect(session.active_lens.?.param_values[0] > 0.25);
    try t.expect(session.active_lens.?.param_values[0] < 1.0);

    try t.expectEqual(Status.invalid_argument, ck_session_tick_lens(session, 8_333, null));
}

test "activating a lens from a real bundle directory splices it, and a build without a renderer creates no shader programs" {
    const engine = try createEngine(t.allocator, .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 });
    defer destroyEngine(engine);
    const session = try createSession(engine, .{ .frame_budget_us = 0, .reserved = 0 });
    defer destroySession(session);

    const bundle_path = "lenses/reference/shader-tint";
    try t.expectEqual(Status.ok, ck_session_activate_lens_from_directory(session, bundle_path.ptr, bundle_path.len));
    try t.expect(session.active_lens != null);
    try t.expectEqual(@as(usize, 1), session.active_lens.?.nodes.len);
    // This build has no compiled render stack (the stub always reports
    // RendererUnavailable) - the lens still activates cleanly, its
    // shader.pass node just has no program, exactly the degradation
    // ck_session_set_beauty already establishes for a missing engine.
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());

    ck_session_deactivate_lens(session);
    try t.expect(session.active_lens == null);
    try t.expectEqual(@as(usize, 0), session.shader_programs.count());

    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens_from_directory(null, bundle_path.ptr, bundle_path.len));
    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens_from_directory(session, null, 0));
    try t.expectEqual(Status.invalid_argument, ck_session_activate_lens_from_directory(session, bundle_path.ptr, 0));
}
