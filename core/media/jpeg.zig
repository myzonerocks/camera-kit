//! Baseline sequential JPEG encoding for capture output. Pure Zig with
//! the standard tables and fixed rounding, so the same pixels always
//! produce the same bytes and the engine owns lossy stills on every
//! target - no platform encoder to gate on. PNG stays the lossless path.

const std = @import("std");

pub const Error = error{ EmptyImage, SizeMismatch, OutOfMemory };

/// Encoder inputs the caller varies: JFIF quality, an EXIF orientation
/// to stamp, and an optional ICC profile for wide-gamut output.
pub const Options = struct {
    quality: u8 = 90,
    orientation: u8 = 1,
    icc_profile: ?[]const u8 = null,
};

// Natural (row-major) order of each coefficient as it appears walking
// the zigzag, so quant tables and the coefficient stream stay in sync.
const zigzag = [64]u8{
    0,  1,  8,  16, 9,  2,  3,  10,
    17, 24, 32, 25, 18, 11, 4,  5,
    12, 19, 26, 33, 40, 48, 41, 34,
    27, 20, 13, 6,  7,  14, 21, 28,
    35, 42, 49, 56, 57, 50, 43, 36,
    29, 22, 15, 23, 30, 37, 44, 51,
    58, 59, 52, 45, 38, 31, 39, 46,
    53, 60, 61, 54, 47, 55, 62, 63,
};

// The Annex K reference quantization tables, in natural order.
const luma_base = [64]u8{
    16, 11, 10, 16, 24,  40,  51,  61,
    12, 12, 14, 19, 26,  58,  60,  55,
    14, 13, 16, 24, 40,  57,  69,  56,
    14, 17, 22, 29, 51,  87,  80,  62,
    18, 22, 37, 56, 68,  109, 103, 77,
    24, 35, 55, 64, 81,  104, 113, 92,
    49, 64, 78, 87, 103, 121, 120, 101,
    72, 92, 95, 98, 112, 100, 103, 99,
};
const chroma_base = [64]u8{
    17, 18, 24, 47, 99, 99, 99, 99,
    18, 21, 26, 66, 99, 99, 99, 99,
    24, 26, 56, 99, 99, 99, 99, 99,
    47, 66, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
    99, 99, 99, 99, 99, 99, 99, 99,
};

// Standard Huffman specifications (Annex K.3): counts per code length
// then the symbols in canonical order.
const dc_luma_bits = [16]u8{ 0, 1, 5, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0, 0, 0 };
const dc_luma_vals = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const dc_chroma_bits = [16]u8{ 0, 3, 1, 1, 1, 1, 1, 1, 1, 1, 1, 0, 0, 0, 0, 0 };
const dc_chroma_vals = [_]u8{ 0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11 };
const ac_luma_bits = [16]u8{ 0, 2, 1, 3, 3, 2, 4, 3, 5, 5, 4, 4, 0, 0, 1, 0x7d };
const ac_luma_vals = [_]u8{
    0x01, 0x02, 0x03, 0x00, 0x04, 0x11, 0x05, 0x12, 0x21, 0x31, 0x41, 0x06, 0x13, 0x51, 0x61, 0x07,
    0x22, 0x71, 0x14, 0x32, 0x81, 0x91, 0xa1, 0x08, 0x23, 0x42, 0xb1, 0xc1, 0x15, 0x52, 0xd1, 0xf0,
    0x24, 0x33, 0x62, 0x72, 0x82, 0x09, 0x0a, 0x16, 0x17, 0x18, 0x19, 0x1a, 0x25, 0x26, 0x27, 0x28,
    0x29, 0x2a, 0x34, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48, 0x49,
    0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68, 0x69,
    0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x83, 0x84, 0x85, 0x86, 0x87, 0x88, 0x89,
    0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5, 0xa6, 0xa7,
    0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3, 0xc4, 0xc5,
    0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda, 0xe1, 0xe2,
    0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf1, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};
const ac_chroma_bits = [16]u8{ 0, 2, 1, 2, 4, 4, 3, 4, 7, 5, 4, 4, 0, 1, 2, 0x77 };
const ac_chroma_vals = [_]u8{
    0x00, 0x01, 0x02, 0x03, 0x11, 0x04, 0x05, 0x21, 0x31, 0x06, 0x12, 0x41, 0x51, 0x07, 0x61, 0x71,
    0x13, 0x22, 0x32, 0x81, 0x08, 0x14, 0x42, 0x91, 0xa1, 0xb1, 0xc1, 0x09, 0x23, 0x33, 0x52, 0xf0,
    0x15, 0x62, 0x72, 0xd1, 0x0a, 0x16, 0x24, 0x34, 0xe1, 0x25, 0xf1, 0x17, 0x18, 0x19, 0x1a, 0x26,
    0x27, 0x28, 0x29, 0x2a, 0x35, 0x36, 0x37, 0x38, 0x39, 0x3a, 0x43, 0x44, 0x45, 0x46, 0x47, 0x48,
    0x49, 0x4a, 0x53, 0x54, 0x55, 0x56, 0x57, 0x58, 0x59, 0x5a, 0x63, 0x64, 0x65, 0x66, 0x67, 0x68,
    0x69, 0x6a, 0x73, 0x74, 0x75, 0x76, 0x77, 0x78, 0x79, 0x7a, 0x82, 0x83, 0x84, 0x85, 0x86, 0x87,
    0x88, 0x89, 0x8a, 0x92, 0x93, 0x94, 0x95, 0x96, 0x97, 0x98, 0x99, 0x9a, 0xa2, 0xa3, 0xa4, 0xa5,
    0xa6, 0xa7, 0xa8, 0xa9, 0xaa, 0xb2, 0xb3, 0xb4, 0xb5, 0xb6, 0xb7, 0xb8, 0xb9, 0xba, 0xc2, 0xc3,
    0xc4, 0xc5, 0xc6, 0xc7, 0xc8, 0xc9, 0xca, 0xd2, 0xd3, 0xd4, 0xd5, 0xd6, 0xd7, 0xd8, 0xd9, 0xda,
    0xe2, 0xe3, 0xe4, 0xe5, 0xe6, 0xe7, 0xe8, 0xe9, 0xea, 0xf2, 0xf3, 0xf4, 0xf5, 0xf6, 0xf7, 0xf8,
    0xf9, 0xfa,
};

const Code = struct { bits: u16 = 0, size: u8 = 0 };

// Canonical Huffman assignment (Annex C): sizes flatten from the bit
// counts, codes increment within a size and shift up between sizes.
fn buildTable(bits: [16]u8, vals: []const u8) [256]Code {
    var table = [_]Code{.{}} ** 256;
    var code: u16 = 0;
    var k: usize = 0;
    var len: u8 = 1;
    while (len <= 16) : (len += 1) {
        var n: u8 = 0;
        while (n < bits[len - 1]) : (n += 1) {
            table[vals[k]] = .{ .bits = code, .size = len };
            code += 1;
            k += 1;
        }
        code <<= 1;
    }
    return table;
}

// Bits needed to hold |value| - the JPEG magnitude category. Zero is
// category 0 and carries no extra bits.
fn category(value: i32) u8 {
    const m: u32 = @abs(value);
    return @intCast(32 - @clz(m | 0));
}

const cos_table = blk: {
    @setEvalBranchQuota(20000);
    var table: [8][8]f32 = undefined;
    var u: usize = 0;
    while (u < 8) : (u += 1) {
        var x: usize = 0;
        while (x < 8) : (x += 1) {
            const cu: f32 = if (u == 0) 0.70710678118654752 else 1.0;
            const angle = (2.0 * @as(f32, @floatFromInt(x)) + 1.0) * @as(f32, @floatFromInt(u)) *
                std.math.pi / 16.0;
            table[u][x] = cu * @cos(angle);
        }
    }
    break :blk table;
};

// Separable 2D DCT-II with the 1/4 normalization folded in, level-shift
// already applied by the caller. Straightforward on purpose: fixed
// operations keep it byte-identical run to run.
fn fdct(block: *[64]f32) void {
    var tmp: [64]f32 = undefined;
    var y: usize = 0;
    while (y < 8) : (y += 1) {
        var u: usize = 0;
        while (u < 8) : (u += 1) {
            var sum: f32 = 0;
            var x: usize = 0;
            while (x < 8) : (x += 1) sum += block[y * 8 + x] * cos_table[u][x];
            tmp[y * 8 + u] = sum * 0.5;
        }
    }
    var u: usize = 0;
    while (u < 8) : (u += 1) {
        var v: usize = 0;
        while (v < 8) : (v += 1) {
            var sum: f32 = 0;
            y = 0;
            while (y < 8) : (y += 1) sum += tmp[y * 8 + u] * cos_table[v][y];
            block[v * 8 + u] = sum * 0.5;
        }
    }
}

fn scaleQuant(base: [64]u8, quality: u8) [64]u16 {
    const q: i32 = std.math.clamp(@as(i32, quality), 1, 100);
    const scale: i32 = if (q < 50) @divTrunc(5000, q) else 200 - 2 * q;
    var out: [64]u16 = undefined;
    for (base, 0..) |b, i| {
        const v = @divTrunc(@as(i32, b) * scale + 50, 100);
        out[i] = @intCast(std.math.clamp(v, 1, 255));
    }
    return out;
}

const Writer = struct {
    out: *std.ArrayList(u8),
    gpa: std.mem.Allocator,
    acc: u32 = 0,
    nbits: u5 = 0,

    fn marker(w: *Writer, code: u8) !void {
        try w.out.append(w.gpa, 0xFF);
        try w.out.append(w.gpa, code);
    }

    fn u16be(w: *Writer, v: u16) !void {
        try w.out.append(w.gpa, @intCast(v >> 8));
        try w.out.append(w.gpa, @intCast(v & 0xFF));
    }

    // Entropy bytes stuff a 0x00 after every 0xFF so the stream never
    // fakes a marker.
    fn putBits(w: *Writer, code: Code) !void {
        var n = code.size;
        while (n > 0) {
            n -= 1;
            w.acc = (w.acc << 1) | ((code.bits >> @intCast(n)) & 1);
            w.nbits += 1;
            if (w.nbits == 8) {
                const byte: u8 = @intCast(w.acc & 0xFF);
                try w.out.append(w.gpa, byte);
                if (byte == 0xFF) try w.out.append(w.gpa, 0x00);
                w.acc = 0;
                w.nbits = 0;
            }
        }
    }

    fn flushBits(w: *Writer) !void {
        if (w.nbits > 0) {
            const pad: u8 = @intCast(8 - w.nbits);
            const byte: u8 = @intCast((w.acc << @intCast(pad)) | ((@as(u32, 1) << @intCast(pad)) - 1));
            try w.out.append(w.gpa, byte);
            if (byte == 0xFF) try w.out.append(w.gpa, 0x00);
            w.acc = 0;
            w.nbits = 0;
        }
    }
};

fn valueBits(value: i32, size: u8) Code {
    if (size == 0) return .{ .bits = 0, .size = 0 };
    const v: u16 = @intCast(@as(u32, @bitCast(if (value < 0) value - 1 else value)) & ((@as(u32, 1) << @intCast(size)) - 1));
    return .{ .bits = v, .size = size };
}

// One 8x8 block: DC difference then run-length AC, both Huffman coded.
// Returns the DC value for the next block's prediction.
fn encodeBlock(w: *Writer, block: *[64]f32, quant: [64]u16, dc_tab: [256]Code, ac_tab: [256]Code, prev_dc: i32) !i32 {
    fdct(block);
    var coeff: [64]i32 = undefined;
    for (0..64) |i| {
        const q: f32 = @floatFromInt(quant[i]);
        coeff[i] = @intFromFloat(@round(block[i] / q));
    }

    const dc = coeff[0];
    const diff = dc - prev_dc;
    const dc_size = category(diff);
    try w.putBits(dc_tab[dc_size]);
    try w.putBits(valueBits(diff, dc_size));

    var run: u8 = 0;
    var k: usize = 1;
    while (k < 64) : (k += 1) {
        const v = coeff[zigzag[k]];
        if (v == 0) {
            run += 1;
            continue;
        }
        while (run > 15) : (run -= 16) try w.putBits(ac_tab[0xF0]);
        const size = category(v);
        try w.putBits(ac_tab[(@as(u8, run) << 4) | size]);
        try w.putBits(valueBits(v, size));
        run = 0;
    }
    if (run > 0) try w.putBits(ac_tab[0x00]);
    return dc;
}

fn clampSample(pixels: []const u8, width: u32, height: u32, sx: i64, sy: i64) [3]u8 {
    const cx: u32 = @intCast(std.math.clamp(sx, 0, @as(i64, width) - 1));
    const cy: u32 = @intCast(std.math.clamp(sy, 0, @as(i64, height) - 1));
    const i = (@as(usize, cy) * width + cx) * 4;
    return .{ pixels[i], pixels[i + 1], pixels[i + 2] };
}

/// Encodes tightly packed RGBA8 as a baseline JPEG (4:2:0), appending to
/// `out`. Chroma is subsampled 2x2 over 16x16 MCUs; edge samples clamp.
pub fn encode(gpa: std.mem.Allocator, out: *std.ArrayList(u8), pixels: []const u8, width: u32, height: u32, opts: Options) Error!void {
    if (width == 0 or height == 0) return error.EmptyImage;
    if (pixels.len != @as(usize, width) * height * 4) return error.SizeMismatch;

    const luma_q = scaleQuant(luma_base, opts.quality);
    const chroma_q = scaleQuant(chroma_base, opts.quality);
    const dc_luma = buildTable(dc_luma_bits, &dc_luma_vals);
    const ac_luma = buildTable(ac_luma_bits, &ac_luma_vals);
    const dc_chroma = buildTable(dc_chroma_bits, &dc_chroma_vals);
    const ac_chroma = buildTable(ac_chroma_bits, &ac_chroma_vals);

    var w = Writer{ .out = out, .gpa = gpa };
    errdefer out.clearRetainingCapacity();

    try w.marker(0xD8); // SOI

    // APP0 JFIF.
    try w.marker(0xE0);
    try w.u16be(16);
    try out.appendSlice(gpa, "JFIF\x00");
    try out.appendSlice(gpa, &.{ 1, 1, 0 }); // version 1.1, no density units
    try out.appendSlice(gpa, &.{ 0, 1, 0, 1 }); // 1x1 density
    try out.appendSlice(gpa, &.{ 0, 0 }); // no thumbnail

    // APP1 EXIF carrying orientation and the software tag, so viewers
    // rotate correctly and the encoder is identifiable.
    try writeExif(&w, gpa, opts.orientation);

    // APP2 ICC profile for wide-gamut output, chunked at 65533 bytes.
    if (opts.icc_profile) |icc| try writeIccProfile(&w, gpa, icc);

    // DQT: luma then chroma, 8-bit precision, in zigzag order.
    try writeQuantTable(&w, gpa, 0, luma_q);
    try writeQuantTable(&w, gpa, 1, chroma_q);

    // SOF0: baseline, 3 components, Y at 2x2 sampling (4:2:0).
    try w.marker(0xC0);
    try w.u16be(17);
    try out.append(gpa, 8); // 8-bit samples
    try w.u16be(@intCast(height));
    try w.u16be(@intCast(width));
    try out.append(gpa, 3);
    try out.appendSlice(gpa, &.{ 1, 0x22, 0 }); // Y: 2x2, quant 0
    try out.appendSlice(gpa, &.{ 2, 0x11, 1 }); // Cb: 1x1, quant 1
    try out.appendSlice(gpa, &.{ 3, 0x11, 1 }); // Cr: 1x1, quant 1

    try writeHuffTable(&w, gpa, 0x00, dc_luma_bits, &dc_luma_vals);
    try writeHuffTable(&w, gpa, 0x10, ac_luma_bits, &ac_luma_vals);
    try writeHuffTable(&w, gpa, 0x01, dc_chroma_bits, &dc_chroma_vals);
    try writeHuffTable(&w, gpa, 0x11, ac_chroma_bits, &ac_chroma_vals);

    // SOS.
    try w.marker(0xDA);
    try w.u16be(12);
    try out.append(gpa, 3);
    try out.appendSlice(gpa, &.{ 1, 0x00 }); // Y uses DC/AC table 0
    try out.appendSlice(gpa, &.{ 2, 0x11 }); // Cb uses table 1
    try out.appendSlice(gpa, &.{ 3, 0x11 }); // Cr uses table 1
    try out.appendSlice(gpa, &.{ 0, 63, 0 }); // full spectral selection

    var dc_y: i32 = 0;
    var dc_cb: i32 = 0;
    var dc_cr: i32 = 0;
    const mcus_x = (width + 15) / 16;
    const mcus_y = (height + 15) / 16;

    var my: u32 = 0;
    while (my < mcus_y) : (my += 1) {
        var mx: u32 = 0;
        while (mx < mcus_x) : (mx += 1) {
            const base_x: i64 = @as(i64, mx) * 16;
            const base_y: i64 = @as(i64, my) * 16;
            var cb_block: [64]f32 = undefined;
            var cr_block: [64]f32 = undefined;

            // Four luma blocks in raster order within the MCU, chroma
            // averaged over each 2x2 luma quad as we go.
            var by: u32 = 0;
            while (by < 2) : (by += 1) {
                var bx: u32 = 0;
                while (bx < 2) : (bx += 1) {
                    var y_block: [64]f32 = undefined;
                    var row: u32 = 0;
                    while (row < 8) : (row += 1) {
                        var col: u32 = 0;
                        while (col < 8) : (col += 1) {
                            const sx = base_x + @as(i64, bx) * 8 + col;
                            const sy = base_y + @as(i64, by) * 8 + row;
                            const rgb = clampSample(pixels, width, height, sx, sy);
                            const yy = 0.299 * f(rgb[0]) + 0.587 * f(rgb[1]) + 0.114 * f(rgb[2]);
                            y_block[row * 8 + col] = yy - 128.0;
                        }
                    }
                    dc_y = try encodeBlock(&w, &y_block, luma_q, dc_luma, ac_luma, dc_y);
                }
            }

            var row: u32 = 0;
            while (row < 8) : (row += 1) {
                var col: u32 = 0;
                while (col < 8) : (col += 1) {
                    const sx = base_x + @as(i64, col) * 2;
                    const sy = base_y + @as(i64, row) * 2;
                    var cb_sum: f32 = 0;
                    var cr_sum: f32 = 0;
                    var dy: i64 = 0;
                    while (dy < 2) : (dy += 1) {
                        var dx: i64 = 0;
                        while (dx < 2) : (dx += 1) {
                            const rgb = clampSample(pixels, width, height, sx + dx, sy + dy);
                            cb_sum += -0.168736 * f(rgb[0]) - 0.331264 * f(rgb[1]) + 0.5 * f(rgb[2]);
                            cr_sum += 0.5 * f(rgb[0]) - 0.418688 * f(rgb[1]) - 0.081312 * f(rgb[2]);
                        }
                    }
                    cb_block[row * 8 + col] = cb_sum / 4.0;
                    cr_block[row * 8 + col] = cr_sum / 4.0;
                }
            }
            dc_cb = try encodeBlock(&w, &cb_block, chroma_q, dc_chroma, ac_chroma, dc_cb);
            dc_cr = try encodeBlock(&w, &cr_block, chroma_q, dc_chroma, ac_chroma, dc_cr);
        }
    }

    try w.flushBits();
    try w.marker(0xD9); // EOI
}

fn f(sample: u8) f32 {
    return @floatFromInt(sample);
}

fn writeQuantTable(w: *Writer, gpa: std.mem.Allocator, id: u8, table: [64]u16) !void {
    try w.marker(0xDB);
    try w.u16be(67);
    try w.out.append(gpa, id); // precision 0, table id
    for (0..64) |k| try w.out.append(gpa, @intCast(table[zigzag[k]]));
}

fn writeHuffTable(w: *Writer, gpa: std.mem.Allocator, id: u8, bits: [16]u8, vals: []const u8) !void {
    try w.marker(0xC4);
    try w.u16be(@intCast(19 + vals.len));
    try w.out.append(gpa, id);
    try w.out.appendSlice(gpa, &bits);
    try w.out.appendSlice(gpa, vals);
}

fn writeExif(w: *Writer, gpa: std.mem.Allocator, orientation: u8) !void {
    const o: u16 = if (orientation >= 1 and orientation <= 8) orientation else 1;
    const software = "gosslens\x00";
    // TIFF (big-endian) with two IFD entries: Orientation inline, and
    // Software pointing at its string past the IFD.
    var tiff: [47]u8 = undefined;
    @memcpy(tiff[0..4], "MM\x00\x2a");
    std.mem.writeInt(u32, tiff[4..8], 8, .big); // IFD offset
    std.mem.writeInt(u16, tiff[8..10], 2, .big); // entry count
    std.mem.writeInt(u16, tiff[10..12], 0x0112, .big); // Orientation tag
    std.mem.writeInt(u16, tiff[12..14], 3, .big); // SHORT
    std.mem.writeInt(u32, tiff[14..18], 1, .big); // count
    std.mem.writeInt(u16, tiff[18..20], o, .big); // value
    std.mem.writeInt(u16, tiff[20..22], 0, .big); // pad
    std.mem.writeInt(u16, tiff[22..24], 0x0131, .big); // Software tag
    std.mem.writeInt(u16, tiff[24..26], 2, .big); // ASCII
    std.mem.writeInt(u32, tiff[26..30], software.len, .big); // count
    std.mem.writeInt(u32, tiff[30..34], 38, .big); // offset to the string
    std.mem.writeInt(u32, tiff[34..38], 0, .big); // next IFD
    @memcpy(tiff[38..47], software);
    try w.marker(0xE1);
    try w.u16be(@intCast(2 + 6 + tiff.len));
    try w.out.appendSlice(gpa, "Exif\x00\x00");
    try w.out.appendSlice(gpa, &tiff);
}

fn writeIccProfile(w: *Writer, gpa: std.mem.Allocator, icc: []const u8) !void {
    const chunk_max: usize = 65533 - 14;
    const total = (icc.len + chunk_max - 1) / chunk_max;
    if (total == 0 or total > 255) return;
    var index: usize = 0;
    var offset: usize = 0;
    while (index < total) : (index += 1) {
        const len = @min(chunk_max, icc.len - offset);
        try w.marker(0xE2);
        try w.u16be(@intCast(2 + 12 + 2 + len));
        try w.out.appendSlice(gpa, "ICC_PROFILE\x00");
        try w.out.append(gpa, @intCast(index + 1));
        try w.out.append(gpa, @intCast(total));
        try w.out.appendSlice(gpa, icc[offset .. offset + len]);
        offset += len;
    }
}

const t = std.testing;

test "encodes a valid baseline stream, deterministically" {
    const w: u32 = 24;
    const h: u32 = 16;
    var pixels: [24 * 16 * 4]u8 = undefined;
    for (0..h) |y| {
        for (0..w) |x| {
            const i = (y * w + x) * 4;
            pixels[i] = @intCast((x * 10) & 0xFF);
            pixels[i + 1] = @intCast((y * 15) & 0xFF);
            pixels[i + 2] = @intCast((x + y) & 0xFF);
            pixels[i + 3] = 255;
        }
    }
    var a: std.ArrayList(u8) = .empty;
    defer a.deinit(t.allocator);
    try encode(t.allocator, &a, &pixels, w, h, .{ .quality = 85 });
    var b: std.ArrayList(u8) = .empty;
    defer b.deinit(t.allocator);
    try encode(t.allocator, &b, &pixels, w, h, .{ .quality = 85 });
    try t.expectEqualSlices(u8, a.items, b.items);
    // SOI, an APP0 JFIF, and EOI frame a real baseline file.
    try t.expectEqualSlices(u8, &.{ 0xFF, 0xD8 }, a.items[0..2]);
    try t.expectEqualSlices(u8, &.{ 0xFF, 0xE0 }, a.items[2..4]);
    try t.expectEqualSlices(u8, "JFIF\x00", a.items[6..11]);
    try t.expectEqualSlices(u8, &.{ 0xFF, 0xD9 }, a.items[a.items.len - 2 ..][0..2]);
    try t.expect(a.items.len > 100);
}

test "quality changes the encoded size and rejects bad input" {
    var pixels: [16 * 16 * 4]u8 = undefined;
    for (&pixels, 0..) |*p, i| p.* = @intCast(i & 0xFF);
    var low: std.ArrayList(u8) = .empty;
    defer low.deinit(t.allocator);
    var high: std.ArrayList(u8) = .empty;
    defer high.deinit(t.allocator);
    try encode(t.allocator, &low, &pixels, 16, 16, .{ .quality = 20 });
    try encode(t.allocator, &high, &pixels, 16, 16, .{ .quality = 98 });
    try t.expect(high.items.len > low.items.len);
    var bad: std.ArrayList(u8) = .empty;
    defer bad.deinit(t.allocator);
    try t.expectError(error.SizeMismatch, encode(t.allocator, &bad, &pixels, 8, 8, .{}));
    try t.expectError(error.EmptyImage, encode(t.allocator, &bad, &pixels, 0, 8, .{}));
}
