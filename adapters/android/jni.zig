//! The Android binding: JNI exports over the goss_ ABI, written in Zig and
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
extern fn AHardwareBuffer_fromHardwareBuffer(env: *JniEnv, hardware_buffer: jobject) ?*anyopaque;
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

export fn Java_com_gosslens_Gosslens_nativeAbiVersion(env: *JniEnv, cls: jobject) i32 {
    _ = env;
    _ = cls;
    return @bitCast(abi.goss_abi_version());
}

export fn Java_com_gosslens_Gosslens_nativeEngineCreate(env: *JniEnv, cls: jobject, texture_pool_capacity: i32, staging_pool_capacity: i32) i64 {
    _ = env;
    _ = cls;
    // Negative capacities mean no config was given; the core's own
    // defaults apply, the same as passing null from C.
    var config: abi.EngineConfig = undefined;
    var config_ptr: ?*const abi.EngineConfig = null;
    if (texture_pool_capacity >= 0 and staging_pool_capacity >= 0) {
        config = .{ .texture_pool_capacity = @intCast(texture_pool_capacity), .staging_pool_capacity = @intCast(staging_pool_capacity) };
        config_ptr = &config;
    }
    var engine: ?*abi.Engine = null;
    if (abi.goss_engine_create(config_ptr, @ptrCast(&engine)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(engine.?)));
}

export fn Java_com_gosslens_Gosslens_nativeEngineDestroy(env: *JniEnv, cls: jobject, engine: i64) void {
    _ = env;
    _ = cls;
    abi.goss_engine_destroy(engineFromHandle(engine));
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

export fn Java_com_gosslens_Gosslens_nativeInitRenderer(env: *JniEnv, cls: jobject, engine: i64, surface: jobject, width: i32, height: i32) i32 {
    _ = cls;
    const window = ANativeWindow_fromSurface(env, surface) orelse return @intFromEnum(abi.Status.invalid_argument);
    attached_window = window;
    var desc: abi.RendererDesc = .{
        .native_window_handle = window,
        .width = @intCast(width),
        .height = @intCast(height),
    };
    return @intFromEnum(abi.goss_engine_init_renderer(engineFromHandle(engine), &desc));
}

export fn Java_com_gosslens_Gosslens_nativeResize(env: *JniEnv, cls: jobject, engine: i64, width: i32, height: i32) void {
    _ = env;
    _ = cls;
    abi.goss_engine_resize(engineFromHandle(engine), @intCast(width), @intCast(height));
}

export fn Java_com_gosslens_Gosslens_nativeRequestScreenshot(env: *JniEnv, cls: jobject, engine: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_engine_request_screenshot(engineFromHandle(engine), path, @intCast(path_len)));
}

export fn Java_com_gosslens_Gosslens_nativeRenderFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_render_frame(engineFromHandle(engine), sessionFromHandle(session)));
}

export fn Java_com_gosslens_Gosslens_nativeSessionCreate(env: *JniEnv, cls: jobject, engine: i64, frame_budget_us: i32) i64 {
    _ = env;
    _ = cls;
    // Negative means no config was given; the core's default budget
    // applies, the same as passing null from C.
    var config: abi.SessionConfig = undefined;
    var config_ptr: ?*const abi.SessionConfig = null;
    if (frame_budget_us >= 0) {
        config = .{ .frame_budget_us = @intCast(frame_budget_us), .reserved = 0 };
        config_ptr = &config;
    }
    var session: ?*abi.Session = null;
    if (abi.goss_session_create(engineFromHandle(engine), config_ptr, @ptrCast(&session)) != .ok) return 0;
    return @bitCast(@as(u64, @intFromPtr(session.?)));
}

export fn Java_com_gosslens_Gosslens_nativeDegradeLevel(env: *JniEnv, cls: jobject, session: i64) i32 {
    _ = env;
    _ = cls;
    return abi.goss_session_degrade_level(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeYuvToRgb(env: *JniEnv, cls: jobject, standard: i32, range: i32, out_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const matrix: *[16]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_color_yuv_to_rgb(@intCast(standard), @intCast(range), matrix));
}

export fn Java_com_gosslens_Gosslens_nativeActivateLensFromDirectory(env: *JniEnv, cls: jobject, session: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_activate_lens_from_directory(sessionFromHandle(session), bytes, @intCast(path_len)));
}

export fn Java_com_gosslens_Gosslens_nativeSessionDestroy(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_destroy(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitFrameCopy(
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
    return @intFromEnum(abi.goss_session_submit_frame_copy(sessionFromHandle(session), &desc, y, @intCast(y_stride), uv, @intCast(uv_stride)));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitHardwareBuffer(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    hardware_buffer: jobject,
    width: i32,
    height: i32,
    flags: i32,
    color_standard: i32,
    color_range: i32,
    timestamp_us: i64,
) i32 {
    _ = cls;
    const buffer = AHardwareBuffer_fromHardwareBuffer(env, hardware_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var desc: abi.FrameDesc = .{
        .width = @intCast(width),
        .height = @intCast(height),
        .pixel_format = 0,
        .color_standard = @intCast(color_standard),
        .color_range = @intCast(color_range),
        .flags = @bitCast(flags),
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_submit_hardware_buffer(sessionFromHandle(session), &desc, buffer));
}

export fn Java_com_gosslens_Gosslens_nativeEnableFaceTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_face_tracking(sessionFromHandle(session), bytes, @intCast(task_len), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisableFaceTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_face_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeTrackFrame(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    y_buffer: jobject,
    y_stride: i32,
    uv_buffer: jobject,
    uv_stride: i32,
    width: i32,
    height: i32,
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
        .flags = 0,
        .timestamp_us = timestamp_us,
    };
    return @intFromEnum(abi.goss_session_track_frame(sessionFromHandle(session), &desc, y, @intCast(y_stride), uv, @intCast(uv_stride)));
}

/// The result buffer is a direct buffer of at least the frozen result
/// size; the SDK reads the fields straight out of it.
export fn Java_com_gosslens_Gosslens_nativeFaceResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.FaceResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeEnableHandTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_hand_tracking(sessionFromHandle(session), bytes, @intCast(task_len), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisableHandTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_hand_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeHandResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.HandResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_hand_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeEnablePoseTracking(env: *JniEnv, cls: jobject, session: i64, task_buffer: jobject, task_len: i32, threads: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, task_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_pose_tracking(sessionFromHandle(session), bytes, @intCast(task_len), threads));
}

export fn Java_com_gosslens_Gosslens_nativeDisablePoseTracking(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_pose_tracking(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativePoseResult(env: *JniEnv, cls: jobject, session: i64, result_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, result_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const result: *abi.PoseResult = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_pose_result(sessionFromHandle(session), result));
}

export fn Java_com_gosslens_Gosslens_nativeFacePose(env: *JniEnv, cls: jobject, session: i64, matrix_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, matrix_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const matrix: *[16]f32 = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_face_pose(sessionFromHandle(session), matrix));
}

/// info_buffer receives {encoded_len: u64, width: u32, height: u32};
/// a too-small data buffer still fills it, so the caller can retry
/// with the exact size (the ABI's own probe contract).
export fn Java_com_gosslens_Gosslens_nativeCapturePhoto(env: *JniEnv, cls: jobject, engine: i64, session: i64, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { encoded_len: u64, width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var encoded_len: usize = 0;
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_photo(engineFromHandle(engine), sessionFromHandle(session), @ptrCast(data), @intCast(data_capacity), &encoded_len, &width, &height);
    info.encoded_len = encoded_len;
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptureStill(env: *JniEnv, cls: jobject, engine: i64, session: i64, width: i32, height: i32, supersample: i32, format: i32, quality: i32, color_space: i32, bit_depth: i32, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { encoded_len: u64, width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var config: abi.CaptureConfig = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .supersample = @intCast(@max(supersample, 0)),
        .format = @intCast(@max(format, 0)),
        .quality = @intCast(@max(quality, 0)),
        .color_space = @intCast(@max(color_space, 0)),
        .bit_depth = @intCast(@max(bit_depth, 0)),
    };
    var encoded_len: usize = 0;
    var out_width: u32 = 0;
    var out_height: u32 = 0;
    const status = abi.goss_engine_capture_still(engineFromHandle(engine), sessionFromHandle(session), &config, @ptrCast(data), @intCast(data_capacity), &encoded_len, &out_width, &out_height);
    info.encoded_len = encoded_len;
    info.width = out_width;
    info.height = out_height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeCaptureLiveFrame(env: *JniEnv, cls: jobject, engine: i64, session: i64, format: i32, data_buffer: jobject, data_capacity: i64, info_buffer: jobject) i32 {
    _ = cls;
    const info_bytes = getDirectBufferAddress(env, info_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const info: *extern struct { width: u32, height: u32 } = @ptrCast(@alignCast(info_bytes));
    const data = getDirectBufferAddress(env, data_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    var width: u32 = 0;
    var height: u32 = 0;
    const status = abi.goss_engine_capture_live_frame(engineFromHandle(engine), sessionFromHandle(session), @intCast(@max(format, 0)), @ptrCast(data), @intCast(data_capacity), &width, &height);
    info.width = width;
    info.height = height;
    return @intFromEnum(status);
}

export fn Java_com_gosslens_Gosslens_nativeRecordingStart(env: *JniEnv, cls: jobject, engine: i64, session: i64, path_buffer: jobject, path_len: i32, width: i32, height: i32, bitrate: i32, codec: i32) i32 {
    _ = cls;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const config: abi.RecordingConfig = .{
        .width = @intCast(@max(width, 0)),
        .height = @intCast(@max(height, 0)),
        .bitrate_bps = @intCast(@max(bitrate, 0)),
        .codec = @intCast(@max(codec, 0)),
    };
    return @intFromEnum(abi.goss_engine_recording_start(engineFromHandle(engine), sessionFromHandle(session), @ptrCast(path), @intCast(path_len), &config));
}

export fn Java_com_gosslens_Gosslens_nativeSubmitAudio(env: *JniEnv, cls: jobject, session: i64, samples_buffer: jobject, frame_count: i32, sample_rate: i32, channels: i32, timestamp_us: i64) i32 {
    _ = cls;
    const samples = getDirectBufferAddress(env, samples_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_submit_audio(sessionFromHandle(session), @ptrCast(@alignCast(samples)), @intCast(@max(frame_count, 0)), @intCast(@max(sample_rate, 0)), @intCast(@max(channels, 0)), timestamp_us));
}

/// state_buffer packs goss_world_state; planes_buffer and
/// anchors_buffer pack their arrays; light_buffer the light estimate.
export fn Java_com_gosslens_Gosslens_nativeSubmitWorld(env: *JniEnv, cls: jobject, session: i64, state_buffer: jobject, planes_buffer: jobject, plane_count: i32, anchors_buffer: jobject, anchor_count: i32, light_buffer: jobject) i32 {
    _ = cls;
    const state = getDirectBufferAddress(env, state_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const planes: ?[*]const abi.WorldPlane = if (plane_count > 0)
        @ptrCast(@alignCast(getDirectBufferAddress(env, planes_buffer) orelse return @intFromEnum(abi.Status.invalid_argument)))
    else
        null;
    const anchors: ?[*]const abi.WorldAnchor = if (anchor_count > 0)
        @ptrCast(@alignCast(getDirectBufferAddress(env, anchors_buffer) orelse return @intFromEnum(abi.Status.invalid_argument)))
    else
        null;
    const light: ?*const abi.WorldLight = if (getDirectBufferAddress(env, light_buffer)) |raw| @ptrCast(@alignCast(raw)) else null;
    return @intFromEnum(abi.goss_session_submit_world(sessionFromHandle(session), @ptrCast(@alignCast(state)), planes, @intCast(@max(plane_count, 0)), anchors, @intCast(@max(anchor_count, 0)), light));
}

export fn Java_com_gosslens_Gosslens_nativeRecordingStop(env: *JniEnv, cls: jobject, engine: i64) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_engine_recording_stop(engineFromHandle(engine)));
}

export fn Java_com_gosslens_Gosslens_nativeEnableBeauty(env: *JniEnv, cls: jobject, session: i64, path_buffer: jobject, path_len: i32) i32 {
    _ = cls;
    _ = path_len;
    const path = getDirectBufferAddress(env, path_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_enable_beauty(sessionFromHandle(session), @ptrCast(path)));
}

export fn Java_com_gosslens_Gosslens_nativeDisableBeauty(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_disable_beauty(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeSetBeauty(env: *JniEnv, cls: jobject, session: i64, effect: i32, value: f32) i32 {
    _ = env;
    _ = cls;
    return @intFromEnum(abi.goss_session_set_beauty(sessionFromHandle(session), effect, value));
}

export fn Java_com_gosslens_Gosslens_nativeBeautifyFrame(
    env: *JniEnv,
    cls: jobject,
    session: i64,
    rgba_in: jobject,
    rgba_out: jobject,
    width: i32,
    height: i32,
) i32 {
    _ = cls;
    const source = getDirectBufferAddress(env, rgba_in) orelse return @intFromEnum(abi.Status.invalid_argument);
    const destination = getDirectBufferAddress(env, rgba_out) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_beautify_frame(sessionFromHandle(session), source, @intCast(width), @intCast(height), destination));
}

export fn Java_com_gosslens_Gosslens_nativeActivateLens(env: *JniEnv, cls: jobject, session: i64, manifest_buffer: jobject, manifest_len: i32) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, manifest_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    return @intFromEnum(abi.goss_session_activate_lens(sessionFromHandle(session), bytes, @intCast(manifest_len)));
}

export fn Java_com_gosslens_Gosslens_nativeDeactivateLens(env: *JniEnv, cls: jobject, session: i64) void {
    _ = env;
    _ = cls;
    abi.goss_session_deactivate_lens(sessionFromHandle(session));
}

export fn Java_com_gosslens_Gosslens_nativeTickLens(env: *JniEnv, cls: jobject, session: i64, dt_us: i32, signals_buffer: jobject) i32 {
    _ = cls;
    const bytes = getDirectBufferAddress(env, signals_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const signals: *const abi.LensSignals = @ptrCast(@alignCast(bytes));
    return @intFromEnum(abi.goss_session_tick_lens(sessionFromHandle(session), @intCast(dt_us), signals));
}

export fn Java_com_gosslens_Gosslens_nativeParameterValue(env: *JniEnv, cls: jobject, session: i64, name_buffer: jobject, name_len: i32, out_buffer: jobject) i32 {
    _ = cls;
    const name = getDirectBufferAddress(env, name_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: *f32 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_session_parameter_value(sessionFromHandle(session), name, @intCast(name_len), out));
}

export fn Java_com_gosslens_Gosslens_nativePullAudio(env: *JniEnv, cls: jobject, session: i64, out_buffer: jobject, frames: i32) i32 {
    _ = cls;
    const out_bytes = getDirectBufferAddress(env, out_buffer) orelse return @intFromEnum(abi.Status.invalid_argument);
    const out: [*]i16 = @ptrCast(@alignCast(out_bytes));
    return @intFromEnum(abi.goss_session_pull_audio(sessionFromHandle(session), out, @intCast(frames)));
}

export fn Java_com_gosslens_Gosslens_nativeReportFrame(env: *JniEnv, cls: jobject, session: i64, frame_time_us: i32, thermal: i32) i32 {
    _ = env;
    _ = cls;
    return abi.goss_session_report_frame(sessionFromHandle(session), @intCast(frame_time_us), thermal);
}
