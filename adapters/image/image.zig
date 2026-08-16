//! PNG decode for lens assets: a thin binding over the kit's own
//! vendored lodepng, the same decoder the desktop harness already
//! proves against with a real texture upload. Always decodes to
//! tightly packed RGBA8, since that is the one format every consumer
//! here wants - the kit's own texture creation paths already assume it.

const std = @import("std");

const c = @cImport({
    @cInclude("lodepng.h");
});

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
