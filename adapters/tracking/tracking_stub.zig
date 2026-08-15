//! Tracking on platforms without the compiled inference stack: every
//! entry refuses. The export layer reports the refusal as its own status
//! so a shell can tell "not built here" from "no result yet".

const std = @import("std");
const face = @import("face");
const math = @import("math");

pub const supported = false;

pub const CreateError = error{ Unsupported, InvalidBundle, OutOfMemory };

pub const Tracking = struct {};

pub fn create(gpa: std.mem.Allocator, task_bytes: []const u8, threads: i32) CreateError!*Tracking {
    _ = gpa;
    _ = task_bytes;
    _ = threads;
    return error.Unsupported;
}

pub fn destroy(tracking: *Tracking) void {
    _ = tracking;
}

pub fn submitNv12(
    tracking: *Tracking,
    width: u32,
    height: u32,
    timestamp_us: i64,
    conversion: math.color.Conversion,
    y: [*]const u8,
    y_stride: u32,
    uv: [*]const u8,
    uv_stride: u32,
) void {
    _ = tracking;
    _ = width;
    _ = height;
    _ = timestamp_us;
    _ = conversion;
    _ = y;
    _ = y_stride;
    _ = uv;
    _ = uv_stride;
}

pub fn readResult(tracking: *Tracking, out: *face.Result) bool {
    _ = tracking;
    _ = out;
    return false;
}
