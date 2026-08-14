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
