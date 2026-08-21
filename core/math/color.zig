//! YCbCr to RGB conversion, the first arithmetic every camera frame meets.
//! Conversions are affine maps over normalized 0..1 samples (8-bit values
//! divided by 255), built per standard and range. The GPU does the per-pixel
//! work; these matrices feed the shader uniforms, so they must be exact.

const std = @import("std");
const scalar = @import("scalar.zig");
const vec = @import("vec.zig");
const matrix = @import("matrix.zig");

const Vec3 = vec.Vec3;
const Mat3 = matrix.Mat3;

pub const Standard = enum { bt601, bt709, bt2020 };

/// Video range packs Y into codes 16..235 and chroma into 16..240 of the
/// 8-bit scale; full range uses all 256 codes. The range is a property of
/// the delivered buffer, reported by the platform per frame and carried in
/// the frame descriptor. The conversion must match it exactly: decoding
/// video range as full lifts black to code 16 and clips highlights.
pub const Range = enum { video, full };

/// An affine color map: out = matrix * in + offset.
pub const Conversion = struct {
    matrix: Mat3,
    offset: Vec3,

    pub fn apply(c: Conversion, in: Vec3) Vec3 {
        return c.matrix.mulVec(in) + c.offset;
    }

    /// The same map as one homogeneous matrix, the form shaders consume:
    /// out = (M * vec4(in, 1)).xyz.
    pub fn homogeneous(c: Conversion) matrix.Mat4 {
        var m = matrix.Mat4.identity;
        inline for (0..3) |col| {
            m.cols[col] = vec.vec4From3(c.matrix.cols[col], 0.0);
        }
        m.cols[3] = vec.vec4From3(c.offset, 1.0);
        return m;
    }
};

fn lumaCoefficients(standard: Standard) [2]f32 {
    // Kr and Kb; Kg is 1 - Kr - Kb.
    return switch (standard) {
        .bt601 => .{ 0.299, 0.114 },
        .bt709 => .{ 0.2126, 0.0722 },
        .bt2020 => .{ 0.2627, 0.0593 },
    };
}

pub fn yuvToRgb(standard: Standard, range: Range) Conversion {
    const k = lumaCoefficients(standard);
    const kr = k[0];
    const kb = k[1];
    const kg = 1.0 - kr - kb;

    // Contribution of unit y', cb, cr (chroma centered at zero) to r, g, b.
    const base: Mat3 = .{ .cols = .{
        .{ 1.0, 1.0, 1.0 },
        .{ 0.0, -2.0 * kb * (1.0 - kb) / kg, 2.0 * (1.0 - kb) },
        .{ 2.0 * (1.0 - kr), -2.0 * kr * (1.0 - kr) / kg, 0.0 },
    } };

    const y_scale: f32 = switch (range) {
        .video => 255.0 / 219.0,
        .full => 1.0,
    };
    const c_scale: f32 = switch (range) {
        .video => 255.0 / 224.0,
        .full => 1.0,
    };
    const y_offset: f32 = switch (range) {
        .video => 16.0 / 255.0,
        .full => 0.0,
    };
    const c_offset: f32 = 128.0 / 255.0;

    var m = base;
    inline for (0..3) |i| {
        m.cols[0][i] *= y_scale;
        m.cols[1][i] *= c_scale;
        m.cols[2][i] *= c_scale;
    }
    const pre_offset: Vec3 = .{ y_offset, c_offset, c_offset };
    return .{ .matrix = m, .offset = -m.mulVec(pre_offset) };
}

pub fn rgbToYuv(standard: Standard, range: Range) Conversion {
    const fwd = yuvToRgb(standard, range);
    // Exact inverse of an affine map; the matrix is never singular for any
    // supported standard and range.
    const inv = fwd.matrix.inverse().?;
    return .{ .matrix = inv, .offset = inv.mulVec(-fwd.offset) };
}

fn encodeSample(v: f32) u8 {
    return @intFromFloat(std.math.clamp(@round(v * 255.0), 0.0, 255.0));
}

/// Packs a tightly-strided RGBA8 image into NV12: a full-resolution Y plane
/// then an interleaved half-resolution Cb,Cr plane. The exact encode mirror
/// of sampler.sampleNv12 - same (w+1)/2 geometry, same Conversion - so a
/// round trip through the decoder reproduces the input. Chroma box-averages.
pub fn rgbaToNv12(rgba: []const u8, width: usize, height: usize, conv: Conversion, y_out: []u8, uv_out: []u8) void {
    const half_w = (width + 1) / 2;
    const half_h = (height + 1) / 2;
    for (0..height) |yy| {
        for (0..width) |xx| {
            const p = (yy * width + xx) * 4;
            const rgb: Vec3 = .{
                @as(f32, @floatFromInt(rgba[p])) / 255.0,
                @as(f32, @floatFromInt(rgba[p + 1])) / 255.0,
                @as(f32, @floatFromInt(rgba[p + 2])) / 255.0,
            };
            y_out[yy * width + xx] = encodeSample(conv.apply(rgb)[0]);
        }
    }
    for (0..half_h) |by| {
        for (0..half_w) |bx| {
            var acc: Vec3 = .{ 0, 0, 0 };
            var n: f32 = 0;
            for (0..2) |dy| {
                const sy = by * 2 + dy;
                if (sy >= height) continue;
                for (0..2) |dx| {
                    const sx = bx * 2 + dx;
                    if (sx >= width) continue;
                    const p = (sy * width + sx) * 4;
                    acc += Vec3{
                        @as(f32, @floatFromInt(rgba[p])) / 255.0,
                        @as(f32, @floatFromInt(rgba[p + 1])) / 255.0,
                        @as(f32, @floatFromInt(rgba[p + 2])) / 255.0,
                    };
                    n += 1;
                }
            }
            const yuv = conv.apply(acc / @as(Vec3, @splat(n)));
            const o = (by * half_w + bx) * 2;
            uv_out[o] = encodeSample(yuv[1]);
            uv_out[o + 1] = encodeSample(yuv[2]);
        }
    }
}

test "video-range black and white anchor points" {
    inline for (.{ Standard.bt601, Standard.bt709, Standard.bt2020 }) |standard| {
        const conv = yuvToRgb(standard, .video);
        const black = conv.apply(.{ 16.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0 });
        try std.testing.expect(vec.approxEq(black, vec.splat(Vec3, 0.0), 1.0e-5));
        const white = conv.apply(.{ 235.0 / 255.0, 128.0 / 255.0, 128.0 / 255.0 });
        try std.testing.expect(vec.approxEq(white, vec.splat(Vec3, 1.0), 1.0e-5));
    }
}

test "full-range identity on gray" {
    const conv = yuvToRgb(.bt709, .full);
    const gray = conv.apply(.{ 0.5, 128.0 / 255.0, 128.0 / 255.0 });
    try std.testing.expect(vec.approxEq(gray, vec.splat(Vec3, 0.5), 1.0e-5));
}

test "bt601 video-range red matches the reference encoding" {
    // R'G'B' (1,0,0) encodes to Y=81, Cb=90, Cr=240 in 8-bit BT.601 video range.
    const conv = rgbToYuv(.bt601, .video);
    const yuv = conv.apply(.{ 1.0, 0.0, 0.0 });
    try std.testing.expect(scalar.approxEq(yuv[0] * 255.0, 81.481, 0.01));
    try std.testing.expect(scalar.approxEq(yuv[1] * 255.0, 90.203, 0.01));
    try std.testing.expect(scalar.approxEq(yuv[2] * 255.0, 240.0, 0.01));
}

test "round-trip through both directions is identity" {
    inline for (.{ Standard.bt601, Standard.bt709, Standard.bt2020 }) |standard| {
        inline for (.{ Range.video, Range.full }) |range| {
            const fwd = rgbToYuv(standard, range);
            const back = yuvToRgb(standard, range);
            const samples = [_]Vec3{
                .{ 0.0, 0.0, 0.0 },
                .{ 1.0, 1.0, 1.0 },
                .{ 1.0, 0.0, 0.0 },
                .{ 0.0, 1.0, 0.0 },
                .{ 0.0, 0.0, 1.0 },
                .{ 0.25, 0.6, 0.9 },
            };
            for (samples) |rgb| {
                const round = back.apply(fwd.apply(rgb));
                try std.testing.expect(vec.approxEq(round, rgb, 1.0e-4));
            }
        }
    }
}

test "rgbaToNv12 encodes bt709 video-range anchors" {
    const conv = rgbToYuv(.bt709, .video);
    var y: [4]u8 = undefined;
    var uv: [2]u8 = undefined;

    // Solid white: video-range luma 235, neutral chroma 128.
    const white = [_]u8{ 255, 255, 255, 255 } ** 4;
    rgbaToNv12(&white, 2, 2, conv, &y, &uv);
    for (y) |v| try std.testing.expectEqual(@as(u8, 235), v);
    try std.testing.expect(@abs(@as(i32, uv[0]) - 128) <= 1);
    try std.testing.expect(@abs(@as(i32, uv[1]) - 128) <= 1);

    // Solid red: BT.709 video range is roughly Y 63, Cb 102, Cr 240.
    const red = [_]u8{ 255, 0, 0, 255 } ** 4;
    rgbaToNv12(&red, 2, 2, conv, &y, &uv);
    try std.testing.expect(@abs(@as(i32, y[0]) - 63) <= 1);
    try std.testing.expect(@abs(@as(i32, uv[0]) - 102) <= 1);
    try std.testing.expect(@abs(@as(i32, uv[1]) - 240) <= 1);
}

test "rgbaToNv12 box-averages chroma across a 2x2 block" {
    const conv = rgbToYuv(.bt709, .video);
    // Two red pixels, two black - the averaged chroma sits between neutral
    // and full red, proving the 2x2 downsample rather than a corner sample.
    const px = [_]u8{
        255, 0, 0, 255, 0, 0, 0, 255,
        0, 0, 0, 255, 255, 0, 0, 255,
    };
    var y: [4]u8 = undefined;
    var uv: [2]u8 = undefined;
    rgbaToNv12(&px, 2, 2, conv, &y, &uv);
    try std.testing.expect(uv[1] > 128 and uv[1] < 240);
}
