//! Video recording on Android: AMediaCodec's input surface takes the
//! renderer's frames zero-copy and AMediaMuxer writes the MP4. All C
//! NDK APIs, bound directly; no vendor type escapes this file.

const std = @import("std");

const c = @cImport({
    @cInclude("media/NdkMediaCodec.h");
    @cInclude("media/NdkMediaMuxer.h");
    @cInclude("media/NdkMediaFormat.h");
});

/// How the vended native handle binds: a sampleable texture, or a
/// platform window the renderer presents into.
pub const NativeHandleKind = enum { texture, window };
pub const native_handle_kind: NativeHandleKind = .window;
/// Whether this backend muxes a submitted audio track.
pub const audio_supported = false;

/// Whether a real backend exists on this target.
pub const supported = true;

pub const Codec = enum(u32) {
    h264 = 0,
    hevc = 1,
};

pub const Config = struct {
    width: u32,
    height: u32,
    /// Zero lets the backend pick a rate fitting the dimensions.
    bitrate_bps: u32 = 0,
    codec: Codec = .h264,
};

pub const Error = error{
    OpenFailed,
    FrameFailed,
    FinishFailed,
};

/// One vended frame between begin and commit; on this backend every
/// frame shares the codec's single input surface.
pub const Frame = struct {
    token: *anyopaque,
    /// The ANativeWindow the renderer presents the composite into.
    native_texture: *anyopaque,
};

// The surface-input color format constant from MediaCodecInfo.
const color_format_surface: i32 = 0x7F000789;

pub const Recording = struct {
    handle: *anyopaque,
    config: Config,
    committed: u32 = 0,

    const State = struct {
        codec: *c.AMediaCodec,
        muxer: *c.AMediaMuxer,
        window: *anyopaque,
        fd: c_int,
        track: i32 = -1,
        muxing: bool = false,
        failed: bool = false,
    };

    pub fn start(path: []const u8, config: Config) Error!Recording {
        var path_buf: [1024]u8 = undefined;
        if (path.len >= path_buf.len) return error.OpenFailed;
        @memcpy(path_buf[0..path.len], path);
        path_buf[path.len] = 0;
        const path_z: [*:0]const u8 = path_buf[0..path.len :0];
        const open_rc = std.os.linux.open(path_z, .{ .ACCMODE = .RDWR, .CREAT = true, .TRUNC = true }, 0o644);
        if (open_rc > std.math.maxInt(i32)) return error.OpenFailed;
        const fd: c_int = @intCast(open_rc);
        if (fd < 0) return error.OpenFailed;
        errdefer _ = std.os.linux.close(fd);

        const mime: [:0]const u8 = if (config.codec == .hevc) "video/hevc" else "video/avc";
        const codec = c.AMediaCodec_createEncoderByType(mime.ptr) orelse return error.OpenFailed;
        errdefer _ = c.AMediaCodec_delete(codec);

        const format = c.AMediaFormat_new() orelse return error.OpenFailed;
        defer _ = c.AMediaFormat_delete(format);
        c.AMediaFormat_setString(format, c.AMEDIAFORMAT_KEY_MIME, mime.ptr);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_WIDTH, @intCast(config.width));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_HEIGHT, @intCast(config.height));
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_COLOR_FORMAT, color_format_surface);
        const bitrate: i32 = if (config.bitrate_bps == 0) 8_000_000 else @intCast(config.bitrate_bps);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_BIT_RATE, bitrate);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_FRAME_RATE, 30);
        c.AMediaFormat_setInt32(format, c.AMEDIAFORMAT_KEY_I_FRAME_INTERVAL, 1);
        if (c.AMediaCodec_configure(codec, format, null, null, c.AMEDIACODEC_CONFIGURE_FLAG_ENCODE) != c.AMEDIA_OK) {
            return error.OpenFailed;
        }
        var window: ?*c.ANativeWindow = null;
        if (c.AMediaCodec_createInputSurface(codec, &window) != c.AMEDIA_OK or window == null) {
            return error.OpenFailed;
        }
        if (c.AMediaCodec_start(codec) != c.AMEDIA_OK) return error.OpenFailed;

        const muxer = c.AMediaMuxer_new(fd, c.AMEDIAMUXER_OUTPUT_FORMAT_MPEG_4) orelse return error.OpenFailed;

        const gpa = std.heap.c_allocator;
        const state = gpa.create(State) catch return error.OpenFailed;
        state.* = .{ .codec = codec, .muxer = muxer, .window = @ptrCast(window.?), .fd = fd };
        return .{ .handle = state, .config = config };
    }

    /// Every frame rides the codec's one input surface; the token is
    /// the surface itself.
    pub fn beginFrame(recording: *Recording) Error!Frame {
        const state: *State = @ptrCast(@alignCast(recording.handle));
        if (state.failed) return error.FrameFailed;
        return .{ .token = recording.handle, .native_texture = state.window };
    }

    /// Drains whatever the encoder has ready into the muxer; the
    /// surface path stamps its own presentation times.
    pub fn commitFrame(recording: *Recording, frame: Frame, timestamp_us: i64) Error!void {
        _ = frame;
        _ = timestamp_us;
        const state: *State = @ptrCast(@alignCast(recording.handle));
        if (state.failed) return error.FrameFailed;
        try drain(state, false);
        recording.committed += 1;
    }

    pub fn submitAudio(recording: *Recording, samples: []const f32, frame_count: u32, sample_rate: u32, channels: u32, timestamp_us: i64) Error!void {
        _ = recording;
        _ = samples;
        _ = frame_count;
        _ = sample_rate;
        _ = channels;
        _ = timestamp_us;
        return error.FrameFailed;
    }

    pub fn abortFrame(recording: *Recording, frame: Frame) void {
        _ = recording;
        _ = frame;
    }

    pub fn finish(recording: *Recording) Error!void {
        const state: *State = @ptrCast(@alignCast(recording.handle));
        defer {
            _ = c.AMediaCodec_stop(state.codec);
            _ = c.AMediaCodec_delete(state.codec);
            _ = c.AMediaMuxer_delete(state.muxer);
            _ = std.os.linux.close(state.fd);
            std.heap.c_allocator.destroy(state);
        }
        if (state.failed) return error.FinishFailed;
        if (c.AMediaCodec_signalEndOfInputStream(state.codec) != c.AMEDIA_OK) return error.FinishFailed;
        try drain(state, true);
        if (state.muxing) {
            if (c.AMediaMuxer_stop(state.muxer) != c.AMEDIA_OK) return error.FinishFailed;
        }
    }

    fn drain(state: *State, until_eos: bool) Error!void {
        var info: c.AMediaCodecBufferInfo = undefined;
        while (true) {
            const index = c.AMediaCodec_dequeueOutputBuffer(state.codec, &info, if (until_eos) 10_000 else 0);
            if (index == c.AMEDIACODEC_INFO_OUTPUT_FORMAT_CHANGED) {
                const format = c.AMediaCodec_getOutputFormat(state.codec) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                defer _ = c.AMediaFormat_delete(format);
                state.track = @intCast(c.AMediaMuxer_addTrack(state.muxer, format));
                if (state.track < 0 or c.AMediaMuxer_start(state.muxer) != c.AMEDIA_OK) {
                    state.failed = true;
                    return error.FrameFailed;
                }
                state.muxing = true;
                continue;
            }
            if (index < 0) {
                if (until_eos) continue;
                return;
            }
            defer _ = c.AMediaCodec_releaseOutputBuffer(state.codec, @intCast(index), false);
            if (info.size > 0 and state.muxing) {
                var buffer_size: usize = 0;
                const buffer = c.AMediaCodec_getOutputBuffer(state.codec, @intCast(index), &buffer_size) orelse {
                    state.failed = true;
                    return error.FrameFailed;
                };
                if (c.AMediaMuxer_writeSampleData(state.muxer, @intCast(state.track), buffer, &info) != c.AMEDIA_OK) {
                    state.failed = true;
                    return error.FrameFailed;
                }
            }
            if (info.flags & c.AMEDIACODEC_BUFFER_FLAG_END_OF_STREAM != 0) return;
        }
    }
};

pub const Probe = struct {
    frames: u32,
    width: u32,
    height: u32,
    duration_us: i64,
};

/// Decode-back probing is a host-harness proof surface; on device the
/// host app owns playback verification.
pub fn probe(path: []const u8) Error!Probe {
    _ = path;
    return error.OpenFailed;
}

pub fn exportFrame(path: []const u8, frame_index: u32, out_bgra: []u8) Error!struct { width: u32, height: u32 } {
    _ = path;
    _ = frame_index;
    _ = out_bgra;
    return error.OpenFailed;
}

pub fn probeAudio(path: []const u8) Error!i64 {
    _ = path;
    return error.OpenFailed;
}
