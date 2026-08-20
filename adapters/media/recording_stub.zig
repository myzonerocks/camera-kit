//! Recording for targets whose backend has not landed: same surface,
//! every operation reports the capability honestly absent.

/// How the vended native handle binds: a sampleable texture, or a
/// platform window the renderer presents into.
pub const NativeHandleKind = enum { texture, window };
pub const native_handle_kind: NativeHandleKind = .texture;

/// Whether a real backend exists on this target.
pub const supported = false;

pub const Codec = enum(u32) {
    h264 = 0,
    hevc = 1,
};

pub const Config = struct {
    width: u32,
    height: u32,
    bitrate_bps: u32 = 0,
    codec: Codec = .h264,
};

pub const Error = error{
    OpenFailed,
    FrameFailed,
    FinishFailed,
};

pub const Frame = struct {
    token: *anyopaque,
    native_texture: *anyopaque,
};

pub const Recording = struct {
    handle: *anyopaque,
    config: Config,
    committed: u32 = 0,

    pub fn start(path: []const u8, config: Config) Error!Recording {
        _ = path;
        _ = config;
        return error.OpenFailed;
    }

    pub fn beginFrame(recording: *Recording) Error!Frame {
        _ = recording;
        return error.FrameFailed;
    }

    pub fn commitFrame(recording: *Recording, frame: Frame, timestamp_us: i64) Error!void {
        _ = recording;
        _ = frame;
        _ = timestamp_us;
        return error.FrameFailed;
    }

    pub fn abortFrame(recording: *Recording, frame: Frame) void {
        _ = recording;
        _ = frame;
    }

    pub fn finish(recording: *Recording) Error!void {
        _ = recording;
        return error.FinishFailed;
    }
};

pub const Probe = struct {
    frames: u32,
    width: u32,
    height: u32,
    duration_us: i64,
};

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
