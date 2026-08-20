//! Platform photo encoding behind the image adapter boundary: the
//! formats phones actually save, produced by the platform's own
//! encoders. PNG stays the portable deterministic path in core/media;
//! these are the lossy platform formats layered next to it.

/// Whether a real backend exists on this target.
pub const supported = true;

pub const Format = enum(u32) {
    jpeg = 1,
    heic = 2,
};

pub const Error = error{ EncodeFailed, BufferTooSmall, DecodeFailed };

extern fn goss_photo_encode(rgba: [*]const u8, width: u32, height: u32, format: u32, quality: u32, out_data: ?[*]u8, out_capacity: usize, out_len: *usize) i32;
extern fn goss_photo_decode(data: [*]const u8, data_len: usize, out_rgba: ?[*]u8, out_capacity: usize, out_width: ?*u32, out_height: ?*u32) i32;

/// Encodes tightly packed RGBA8 at quality percent (1..100, 0 picks
/// the backend default). out_len always receives the encoded size, so
/// BufferTooSmall tells the caller exactly what to retry with.
pub fn encode(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32, out: []u8, out_len: *usize) Error!void {
    return switch (goss_photo_encode(rgba.ptr, width, height, @intFromEnum(format), quality, out.ptr, out.len, out_len)) {
        0 => {},
        -2 => error.BufferTooSmall,
        else => error.EncodeFailed,
    };
}

/// Reports the encoded size without producing output.
pub fn encodedSize(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32) Error!usize {
    var needed: usize = 0;
    return switch (goss_photo_encode(rgba.ptr, width, height, @intFromEnum(format), quality, null, 0, &needed)) {
        -2 => needed,
        0 => needed,
        else => error.EncodeFailed,
    };
}

/// Decodes encoded photo bytes back to RGBA8 - the harness's
/// round-trip proof surface, not a production decoder.
pub fn decode(data: []const u8, out_rgba: []u8, out_width: *u32, out_height: *u32) Error!void {
    return switch (goss_photo_decode(data.ptr, data.len, out_rgba.ptr, out_rgba.len, out_width, out_height)) {
        0 => {},
        -2 => error.BufferTooSmall,
        else => error.DecodeFailed,
    };
}
