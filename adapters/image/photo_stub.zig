//! Platform photo encoding for targets whose backend has not landed:
//! same surface, the capability honestly absent.

pub const supported = false;

pub const Format = enum(u32) {
    jpeg = 1,
    heic = 2,
};

pub const Error = error{ EncodeFailed, BufferTooSmall, DecodeFailed };

pub fn encode(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32, out: []u8, out_len: *usize) Error!void {
    _ = rgba;
    _ = width;
    _ = height;
    _ = format;
    _ = quality;
    _ = out;
    _ = out_len;
    return error.EncodeFailed;
}

pub fn encodedSize(rgba: []const u8, width: u32, height: u32, format: Format, quality: u32) Error!usize {
    _ = rgba;
    _ = width;
    _ = height;
    _ = format;
    _ = quality;
    return error.EncodeFailed;
}

pub fn decode(data: []const u8, out_rgba: []u8, out_width: *u32, out_height: *u32) Error!void {
    _ = data;
    _ = out_rgba;
    _ = out_width;
    _ = out_height;
    return error.DecodeFailed;
}

pub const Metadata = struct {
    orientation: u32,
    software: [32]u8,
    software_len: usize,
};

pub fn probeMetadata(data: []const u8) Error!Metadata {
    _ = data;
    return error.DecodeFailed;
}
