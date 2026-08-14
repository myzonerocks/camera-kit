//! The ck_ export layer: the only file that exports symbols. Everything here
//! mirrors include/camerakit.h exactly; layouts are frozen and asserted at
//! compile time, and the abi gate diffs the surface on every change.
//!
//! Exports delegate to internal functions that take an allocator, so tests
//! exercise the same code paths under the leak-checking test allocator while
//! shipping builds use the platform allocator.

const std = @import("std");
const builtin = @import("builtin");
const graph = @import("graph");

pub const abi_major: u16 = 0;
pub const abi_minor: u16 = 1;

pub const Status = enum(c_int) {
    ok = 0,
    invalid_argument = 1,
    out_of_memory = 2,
    pool_exhausted = 3,
    abi_mismatch = 4,
};

pub const FrameDesc = extern struct {
    width: u32,
    height: u32,
    pixel_format: u32,
    color_standard: u32,
    color_range: u32,
    reserved: u32,
    timestamp_us: i64,
};

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

comptime {
    std.debug.assert(@sizeOf(FrameDesc) == 32);
    std.debug.assert(@offsetOf(FrameDesc, "timestamp_us") == 24);
    std.debug.assert(@sizeOf(Landmarks) == 24);
    std.debug.assert(@offsetOf(Landmarks, "timestamp_us") == 16);
    std.debug.assert(@sizeOf(EngineConfig) == 8);
    std.debug.assert(@sizeOf(SessionConfig) == 8);
}

const default_texture_pool_capacity: u32 = 16;
const default_staging_pool_capacity: u32 = 8;
const default_frame_budget_us: u32 = 33_333;

pub const Engine = struct {
    gpa: std.mem.Allocator,
    texture_pool: graph.Pool,
    staging_pool: graph.Pool,
    texture_pool_capacity: u16,
    staging_pool_capacity: u16,
};

pub const Session = struct {
    engine: *Engine,
    controller: graph.DegradeController,
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
    session.engine.gpa.destroy(session);
}

fn thermalFromC(value: c_int) graph.degrade.ThermalState {
    return switch (value) {
        0 => .nominal,
        1 => .fair,
        2 => .serious,
        else => .critical,
    };
}

export fn ck_abi_version() u32 {
    return (@as(u32, abi_major) << 16) | abi_minor;
}

export fn ck_engine_create(config: ?*const EngineConfig, out_engine: ?**Engine) Status {
    const out = out_engine orelse return .invalid_argument;
    const cfg: EngineConfig = if (config) |c| c.* else .{ .texture_pool_capacity = 0, .staging_pool_capacity = 0 };
    const engine = createEngine(abiAllocator(), cfg) catch return .out_of_memory;
    out.* = engine;
    return .ok;
}

export fn ck_engine_destroy(engine: ?*Engine) void {
    destroyEngine(engine orelse return);
}

export fn ck_session_create(engine: ?*Engine, config: ?*const SessionConfig, out_session: ?**Session) Status {
    const out = out_session orelse return .invalid_argument;
    const parent = engine orelse return .invalid_argument;
    const cfg: SessionConfig = if (config) |c| c.* else .{ .frame_budget_us = 0, .reserved = 0 };
    const session = createSession(parent, cfg) catch return .out_of_memory;
    out.* = session;
    return .ok;
}

export fn ck_session_destroy(session: ?*Session) void {
    destroySession(session orelse return);
}

export fn ck_session_report_frame(session: ?*Session, frame_time_us: u32, thermal: c_int) c_int {
    const s = session orelse return 0;
    _ = s.controller.step(.{ .frame_time_us = frame_time_us, .thermal = thermalFromC(thermal) });
    return @intFromEnum(s.controller.level);
}

export fn ck_session_degrade_level(session: ?*const Session) c_int {
    const s = session orelse return 0;
    return @intFromEnum(s.controller.level);
}

const t = std.testing;

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
}
