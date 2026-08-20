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

/// Encodes tightly packed RGBA8 pixels as a PNG, appending to `out`.
/// Every scanline uses the up filter - cheap, effective on camera
/// frames, and one fixed choice keeps the output deterministic.
pub fn encodeRgba(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32) !void {
    if (width == 0 or height == 0) return error.EmptyImage;
    const row_bytes = @as(usize, width) * 4;
    if (pixels.len != row_bytes * height) return error.SizeMismatch;

    try out.appendSlice(gpa, &png_signature);

    var ihdr: [13]u8 = undefined;
    std.mem.writeInt(u32, ihdr[0..4], width, .big);
    std.mem.writeInt(u32, ihdr[4..8], height, .big);
    ihdr[8] = 8; // bit depth
    ihdr[9] = 6; // color type: RGBA
    ihdr[10] = 0; // deflate
    ihdr[11] = 0; // adaptive filtering
    ihdr[12] = 0; // no interlace
    try writeChunk(out, gpa, "IHDR", &ihdr);

    // Filtered scanlines: one filter byte then the row minus the row
    // above (zero above the first row).
    const filtered = try gpa.alloc(u8, (row_bytes + 1) * height);
    defer gpa.free(filtered);
    for (0..height) |y| {
        const row = pixels[y * row_bytes ..][0..row_bytes];
        const dst = filtered[y * (row_bytes + 1) ..][0 .. row_bytes + 1];
        dst[0] = 2; // up filter
        if (y == 0) {
            @memcpy(dst[1..], row);
        } else {
            const above = pixels[(y - 1) * row_bytes ..][0..row_bytes];
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
