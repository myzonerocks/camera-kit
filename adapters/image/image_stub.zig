//! PNG decode on targets without libc/lodepng compiled in (wasm32-
//! freestanding has neither): decode always refuses. Nothing here ever
//! reads the bytes it's handed.

const std = @import("std");

pub const Image = struct {
    width: u32,
    height: u32,
    rgba: []u8,
};

pub const DecodeError = error{Unsupported};

pub fn decode(gpa: std.mem.Allocator, png_bytes: []const u8) DecodeError!Image {
    _ = gpa;
    _ = png_bytes;
    return error.Unsupported;
}

pub const ConvertError = error{ OutOfMemory, ConversionFailed };

pub fn downsampleBox(src: []const u8, src_width: u32, src_height: u32, dst: []u8, dst_width: u32, dst_height: u32) ConvertError!void {
    _ = src;
    _ = src_width;
    _ = src_height;
    _ = dst;
    _ = dst_width;
    _ = dst_height;
    return error.ConversionFailed;
}
