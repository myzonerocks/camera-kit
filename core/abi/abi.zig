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

pub const abi_major: u16 = 0;
pub const abi_minor: u16 = 3;

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
    const budget = if (config.frame_budget_us == 0) default_frame_budget_us else config.frame_budget_us;
    session.* = .{
        .engine = engine,
        .controller = graph.DegradeController.init(.{ .budget_us = budget }),
    };
    return session;
}

pub fn destroySession(session: *Session) void {
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
