//! PNG decode for lens assets: a thin binding over the kit's own
//! vendored lodepng, the same decoder the desktop harness already
//! proves against with a real texture upload. Always decodes to
//! tightly packed RGBA8, since that is the one format every consumer
//! here wants - the kit's own texture creation paths already assume it.

const std = @import("std");

const c = @cImport({
    @cInclude("lodepng.h");
});

// libyuv's own header drags in libc headers zig's C translator cannot
// digest on every target sysroot; these two are plain C signatures,
// declared directly against the linked library.
extern fn ABGRToJ420(src_abgr: [*]const u8, src_stride_abgr: c_int, dst_y: [*]u8, dst_stride_y: c_int, dst_u: [*]u8, dst_stride_u: c_int, dst_v: [*]u8, dst_stride_v: c_int, width: c_int, height: c_int) c_int;
extern fn I420ToNV12(src_y: [*]const u8, src_stride_y: c_int, src_u: [*]const u8, src_stride_u: c_int, src_v: [*]const u8, src_stride_v: c_int, dst_y: [*]u8, dst_stride_y: c_int, dst_uv: [*]u8, dst_stride_uv: c_int, width: c_int, height: c_int) c_int;

pub const Image = struct {
    width: u32,
    height: u32,
    /// width * height * 4 bytes, RGBA8, row-major, tightly packed.
    rgba: []u8,
};

pub const DecodeError = error{ OutOfMemory, InvalidPng };

/// Decodes one complete PNG file's bytes into RGBA8. The returned
/// image's rgba slice is gpa-owned; free it with gpa.free.
pub fn decode(gpa: std.mem.Allocator, png_bytes: []const u8) DecodeError!Image {
    var decoded: [*c]u8 = null;
    var width: c_uint = 0;
    var height: c_uint = 0;
    const err = c.lodepng_decode32(&decoded, &width, &height, png_bytes.ptr, png_bytes.len);
    if (err != 0) return error.InvalidPng;
    defer std.c.free(decoded);

    const byte_count = @as(usize, width) * height * 4;
    const owned = try gpa.alloc(u8, byte_count);
    @memcpy(owned, decoded[0..byte_count]);
    return .{ .width = width, .height = height, .rgba = owned };
}

pub const ConvertError = error{ OutOfMemory, ConversionFailed };

/// Converts tightly packed RGBA8 (libyuv's ABGR word order) to
/// full-range BT.601 NV12 through libyuv, the kit's one CPU
/// conversion authority. y_out holds width * height bytes, uv_out the
/// interleaved half-rounded-up chroma plane.
pub fn rgbaToNv12(gpa: std.mem.Allocator, rgba: []const u8, width: u32, height: u32, y_out: []u8, uv_out: []u8) ConvertError!void {
    const w: usize = width;
    const h: usize = height;
    const half_w = (w + 1) / 2;
    const half_h = (h + 1) / 2;
    if (rgba.len < w * h * 4 or y_out.len < w * h or uv_out.len < half_w * 2 * half_h) return error.ConversionFailed;

    const u_plane = try gpa.alloc(u8, half_w * half_h);
    defer gpa.free(u_plane);
    const v_plane = try gpa.alloc(u8, half_w * half_h);
    defer gpa.free(v_plane);

    if (ABGRToJ420(rgba.ptr, @intCast(w * 4), y_out.ptr, @intCast(w), u_plane.ptr, @intCast(half_w), v_plane.ptr, @intCast(half_w), @intCast(width), @intCast(height)) != 0) {
        return error.ConversionFailed;
    }
    if (I420ToNV12(y_out.ptr, @intCast(w), u_plane.ptr, @intCast(half_w), v_plane.ptr, @intCast(half_w), y_out.ptr, @intCast(w), uv_out.ptr, @intCast(half_w * 2), @intCast(width), @intCast(height)) != 0) {
        return error.ConversionFailed;
    }
}

const t = std.testing;

// The same 8x8 checker PNG the desktop harness already proves through a
// real texture upload: alternating 4x4 white and red squares, fully
// opaque.
const checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

test "decodes a real PNG to the expected dimensions and its two solid colors" {
    const image = try decode(t.allocator, &checker_png);
    defer t.allocator.free(image.rgba);
    try t.expectEqual(@as(u32, 8), image.width);
    try t.expectEqual(@as(u32, 8), image.height);
    try t.expectEqual(@as(usize, 8 * 8 * 4), image.rgba.len);

    var saw_white = false;
    var saw_red = false;
    for (0..8) |row| {
        for (0..8) |col| {
            const px = image.rgba[(row * 8 + col) * 4 ..][0..4];
            try t.expectEqual(@as(u8, 255), px[3]);
            if (px[0] == 255 and px[1] == 255 and px[2] == 255) saw_white = true;
            if (px[0] == 255 and px[1] == 0 and px[2] == 0) saw_red = true;
        }
    }
    try t.expect(saw_white);
    try t.expect(saw_red);
}

test "rejects bytes that are not a valid PNG" {
    try t.expectError(error.InvalidPng, decode(t.allocator, "not a png"));
}

test "a solid color survives the round trip to NV12" {
    // Pure white, full range: Y saturates at 255 and both chroma
    // channels sit at the 128 midpoint.
    const w = 4;
    const h = 4;
    var rgba: [w * h * 4]u8 = @splat(255);
    var y_plane: [w * h]u8 = undefined;
    var uv_plane: [(w / 2) * 2 * (h / 2)]u8 = undefined;
    try rgbaToNv12(t.allocator, &rgba, w, h, &y_plane, &uv_plane);
    for (y_plane) |value| try t.expectEqual(@as(u8, 255), value);
    for (uv_plane) |value| try t.expectEqual(@as(u8, 128), value);
}

test "undersized planes refuse" {
    var rgba: [16]u8 = @splat(0);
    var y_plane: [1]u8 = undefined;
    var uv_plane: [2]u8 = undefined;
    try t.expectError(error.ConversionFailed, rgbaToNv12(t.allocator, &rgba, 2, 2, &y_plane, &uv_plane));
}
