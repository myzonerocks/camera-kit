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
