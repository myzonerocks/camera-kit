//! The Android binding: JNI exports over the ck_ ABI, written in Zig and
//! compiled into the same shared library as the core, so one build system
//! produces the whole .so. The layer holds no logic beyond marshalling;
//! JNIEnv is touched only for the two capabilities Java cannot hand over as
//! plain values: resolving a Surface to its native window and reading a
//! direct buffer address.

const std = @import("std");
const abi = @import("abi");

const JniEnv = opaque {};
const jobject = ?*anyopaque;

extern fn ANativeWindow_fromSurface(env: *JniEnv, surface: jobject) ?*anyopaque;
extern fn ANativeWindow_release(window: ?*anyopaque) void;

// JNIEnv points at a pointer to the JNI function table. Only one entry is
// used: GetDirectBufferAddress, index 230 in the JNI specification.
fn getDirectBufferAddress(env: *JniEnv, buffer: jobject) ?[*]u8 {
    const table: *align(1) const [*]const ?*const anyopaque = @ptrCast(env);
    const entry = table.*[230] orelse return null;
    const call: *const fn (*JniEnv, jobject) callconv(.c) ?[*]u8 = @ptrCast(@alignCast(entry));
    return call(env, buffer);
}

var attached_window: ?*anyopaque = null;

export fn Java_kit_camera_CameraKit_nativeAbiVersion(env: *JniEnv, cls: jobject) i32 {
    _ = env;
    _ = cls;
    return @bitCast(abi.ck_abi_version());
}

export fn Java_kit_camera_CameraKit_nativeEngineCreate(env: *JniEnv, cls: jobject) i64 {
    _ = env;
    _ = cls;
    var engine: ?*abi.Engine = null;
    if (abi.ck_engine_create(null, @ptrCast(&engine)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(engine.?)));
}

export fn Java_kit_camera_CameraKit_nativeEngineDestroy(env: *JniEnv, cls: jobject, engine: i64) void {
    _ = env;
    _ = cls;
    abi.ck_engine_destroy(engineFromHandle(engine));
    if (attached_window) |window| {
        ANativeWindow_release(window);
        attached_window = null;
    }
}

fn engineFromHandle(handle: i64) ?*abi.Engine {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

fn sessionFromHandle(handle: i64) ?*abi.Session {
    if (handle == 0) return null;
    return @ptrFromInt(@as(usize, @intCast(handle)));
}

export fn Java_kit_camera_CameraKit_nativeInitRenderer(env: *JniEnv, cls: jobject, engine: i64, surface: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const window = ANativeWindow_fromSurface(env, surface) orelse return @intFromEnum(abi.Status.invalid_argument);
    attached_window = window;
    var desc: abi.RendererDesc = .{
        .native_window_handle = window,
        .width = @intCast(width),
        .height = @intCast(height),
    };
    return @intFromEnum(abi.ck_engine_init_renderer(engineFromHandle(engine), &desc));
}

export fn Java_kit_camera_CameraKit_nativeResize(env: *JniEnv, cls: jobject, engine: i64, width: i32, height: i32) void {
    _ = env;
    _ = cls;
    abi.ck_engine_resize(engineFromHandle(engine), @intCast(width), @intCast(height));
}

export fn Java_kit_camera_CameraKit_nativeRenderFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.ck_engine_render_frame(engineFromHandle(engine), sessionFromHandle(session)));
}

export fn Java_kit_camera_CameraKit_nativeSessionCreate(env: *JniEnv, cls: jobject, engine: i64) i64 {
    _ = env;
    _ = cls;
    var session: ?*abi.Session = null;
    if (abi.ck_session_create(engineFromHandle(engine), null, @ptrCast(&session)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(session.?)));
}

export fn Java_kit_camera_CameraKit_nativeSessionDestroy(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.ck_session_destroy(sessionFromHandle(session));
}

export fn Java_kit_camera_CameraKit_nativeSubmitFrameCopy(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    y_buffer: jobject,
    y_stride: i32,
    uv_buffer: jobject,
    uv_stride: i32,
    width: i32,
    height: i32,
    flags: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const y = getDirectBufferAddress(env, y_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const uv = getDirectBufferAddress(env, uv_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = 0,
        .color_standard = @intCast(color_standard),
        .color_range = @intCast(color_range),
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.ck_session_submit_frame_copy(sessionFromHandle(session), &desc, y, @intCast(y_stride), uv, @intCast(uv_stride)));
}

export fn Java_kit_camera_CameraKit_nativeReportFrame(env: *JniEnv, cls: jobject, session: i64, frame_time_us: i32, thermal: i32) i32 {
    _ = env;
    _ = cls;
    return abi.ck_session_report_frame(sessionFromHandle(session), @intCast(frame_time_us), thermal);
}
