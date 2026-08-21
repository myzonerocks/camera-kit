//! Deterministic PNG encoding for capture output. Fixed filter choice
//! and fixed deflate options mean the same pixels always produce the
//! same bytes, so conformance can hash an encoded photo directly.

const std = @import("std");

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', '\r', '\n', 0x1a, '\n' };

fn writeChunk(out: *std.ArrayList(u8), gpa: std.mem.Allocator, kind: *const [4]u8, body: []const u8) !void {
    var length_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &length_bytes, @intCast(body.len), .big);
    try out.appendSlice(gpa, &length_bytes);
    try out.appendSlice(gpa, kind);
    try out.appendSlice(gpa, body);
    var crc = std.hash.Crc32.init();
    crc.update(kind);
    crc.update(body);
    var crc_bytes: [4]u8 = undefined;
    std.mem.writeInt(u32, &crc_bytes, crc.final(), .big);
    try out.appendSlice(gpa, &crc_bytes);
}

/// Color tagging the PNG carries: the sRGB marker, or explicit cHRM
/// primaries plus gAMA for wide-gamut output. All optional; none is the
/// untagged default.
pub const ColorTags = struct {
    srgb: bool = false,
    chrm: ?[32]u8 = null,
    gama: ?[4]u8 = null,
};

pub const EncodeOptions = struct {
    /// 8 or 16 bits per channel. 16 widens each 8-bit sample so the file
    /// is a genuine 16-bit container, ready for the HDR capture target.
    bit_depth: u8 = 8,
    color: ColorTags = .{},
};

/// Encodes tightly packed RGBA8 pixels as a PNG, appending to `out`.
/// Every scanline uses the up filter - cheap, effective on camera
/// frames, and one fixed choice keeps the output deterministic.
pub fn encodeRgba(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32) !void {
    return encodeRgbaOpts(gpa, out, pixels, width, height, .{});
}

/// The general path: bit depth and color tags on top of encodeRgba.
pub fn encodeRgbaOpts(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32, opts: EncodeOptions) !void {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (opts.bit_depth != 8 and opts.bit_depth != 16) return error.Unsupported;
    const src_row = @as(usize, width) * 4;
    if (pixels.len != src_row * height) return error.SizeMismatch;
    const bytes_per_sample: usize = if (opts.bit_depth == 16) 2 else 1;
    const row_bytes = src_row * bytes_per_sample;

    try out.appendSlice(gpa, &png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = opts.bit_depth;
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(out, gpa, "IHDR", &ihdr);

    // Color chunks sit between IHDR and IDAT. sRGB and cHRM/gAMA are
    // mutually exclusive by intent: sRGB for the default, the explicit
    // primaries for wide gamut.
    if (opts.color.srgb) {
        try writeChunk(out, gpa, "sRGB", &.{0}); // perceptual intent
    } else {
        if (opts.color.chrm) |chrm| try writeChunk(out, gpa, "cHRM", &chrm);
        if (opts.color.gama) |gama| try writeChunk(out, gpa, "gAMA", &gama);
    }

    // Filtered scanlines: one filter byte then the row minus the row
    // above (zero above the first row). At 16-bit each sample expands to
    // big-endian first, then the byte-wise filter runs the same way.
    const filtered = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(filtered);
    const widened: []u8 = if (opts.bit_depth == 16) try gpa.alloc(u8, row_bytes * height) else &.{};
    defer if (widened.len > 0) gpa.free(widened);
    const rows: []const u8 = if (opts.bit_depth == 16) blk: {
        for (0..pixels.len) |i| {
            widened[i * 2] = pixels[i];
            widened[i * 2 + 1] = pixels[i];
        }
        break :blk widened;
    } else pixels;
    for (0..height) |y| {
        const row = rows[y * row_bytes ..][0..row_bytes];
        const dst = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        dst[0] = 2; // up filter
        if (y == 0) {
            @memcpy(dst[1..], row);
        } else {
            const above = rows[(y - 1) * row_bytes ..][0..row_bytes];
            for (row, above, dst[1..]) |cur, up, *b| b.* = cur -% up;
        }
    }

    var compressed: std.Io.Writer.Allocating = try .initCapacity(gpa, 4096);
    defer compressed.deinit();
    const window = try gpa.alloc(u8, std.compress.flate.max_window_len);
    defer gpa.free(window);
    var compress = try std.compress.flate.Compress.init(&compressed.writer, window, .zlib, .level_6);
    try compress.writer.writeAll(filtered);
    try compress.finish();

    try writeChunk(out, gpa, "IDAT", compressed.written());
    try writeChunk(out, gpa, "IEND", &.{});
}

const t = std.testing;

test "a known 2x2 image round-trips through the std decoder-free checks" {
    // Without a decoder in std, assert the structural invariants: the
    // signature, chunk framing, IHDR fields, and determinism.
    const pixels = [16]u8{
        255, 0,   0,   255, 0, 255, 0, 255,
        0,   0,   255, 255, 9, 9,   9, 255,
    };
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(t.allocator);
    try encodeRgba(t.allocator, &a, &pixels, 2, 2);
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(t.allocator);
    try encodeRgba(t.allocator, &b, &pixels, 2, 2);
    try t.expectEqualSlices(u8, a.items, b.items);
    try t.expectEqualSlices(u8, &png_signature, a.items[0..8]);
    try t.expectEqualSlices(u8, "IHDR", a.items[12..16]);
    const w = std.mem.readInt(u32, a.items[16..20], .big);
    const h = std.mem.readInt(u32, a.items[20..24], .big);
    try t.expectEqual(@as(u32, 2), w);
    try t.expectEqual(@as(u32, 2), h);
    try t.expectEqualSlices(u8, "IEND", a.items[a.items.len - 8 ..][0..4]);
}

test "size mismatch and empty refuse" {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(t.allocator);
    const px = [4]u8{ 1, 2, 3, 4 };
    try t.expectError(error.SizeMismatch, encodeRgba(t.allocator, &out, &px, 2, 2));
    try t.expectError(error.EmptyImage, encodeRgba(t.allocator, &out, &px, 0, 1));
}
