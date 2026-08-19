//! Segmentation on platforms without the compiled inference stack: every
//! entry refuses. The export layer reports the refusal as its own status
//! so an SDK can tell "not built here" from "no result yet".

const std = @import("std");
const math = @import("math");

pub const supported = false;

pub const CreateError = error{ Unsupported, InvalidModel, OutOfMemory };

pub const mask_side = 256;
pub const mask_len = mask_side * mask_side;

pub const Segmentation = struct {};

pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) CreateError!*Segmentation {
    _ = gpa;
    _ = model_bytes;
    _ = threads;
    return error.Unsupported;
}

pub fn destroy(segmentation: *Segmentation) void {
    _ = segmentation;
}

pub fn submitNv12(
    segmentation: *Segmentation,
    width: u32,
    height: u32,
    timestamp_us: i64,
    conversion: math.color.Conversion,
    y: [*]const u8,
    y_stride: u32,
    uv: [*]const u8,
    uv_stride: u32,
) void {
    _ = segmentation;
    _ = width;
    _ = height;
    _ = timestamp_us;
    _ = conversion;
    _ = y;
    _ = y_stride;
    _ = uv;
    _ = uv_stride;
}

pub fn readMask(segmentation: *Segmentation, out: *[mask_len]f32) bool {
    _ = segmentation;
    _ = out;
    return false;
}

pub fn readClassMask(segmentation: *Segmentation, class_index: u32, out: *[mask_len]f32) bool {
    _ = segmentation;
    _ = class_index;
    _ = out;
    return false;
}

pub fn classCount(segmentation: *Segmentation) u32 {
    _ = segmentation;
    return 0;
}
