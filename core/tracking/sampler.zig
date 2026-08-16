//! Samples model input tensors out of camera frames. The tracking models
//! take a square RGB float tensor cut from the frame around the subject,
//! possibly rotated to a canonical orientation. Each output pixel inverse
//! maps into the source and samples bilinearly, so the pass reads the
//! frame once, writes the tensor once, and allocates nothing. Camera
//! frames arrive as NV12 planes on devices and as packed RGBA elsewhere;
//! both sample directly, NV12 through the exact color conversion for the
//! frame's standard and range.

const std = @import("std");
const math = @import("math");

pub const Nv12 = struct {
    y: []const u8,
    y_stride: u32,
    /// Interleaved half resolution chroma pairs, Cb then Cr.
    uv: []const u8,
    uv_stride: u32,
    conversion: math.color.Conversion,
};

pub const Pixels = union(enum) {
    /// Tightly packed RGBA, one byte per channel.
    rgba8: []const u8,
    nv12: Nv12,
};

pub const Frame = struct {
    pixels: Pixels,
    width: u32,
    height: u32,
};

pub const Region = struct {
    /// Center and side length in source pixels; rotation in radians,
    /// positive rotating the sampled content counterclockwise.
    center_x: f32,
    center_y: f32,
    side: f32,
    rotation: f32,
};

/// Output mapping applied to normalized rgb.
pub const Range = struct {
    gain: f32,
    bias: f32,

    /// Zero to one, the landmark models' input range.
    pub const unit: Range = .{ .gain = 1.0, .bias = 0.0 };
    /// Minus one to one, the detector's input range.
    pub const symmetric: Range = .{ .gain = 2.0, .bias = -1.0 };
};

/// The whole frame, centered and letterboxed to its longer side - every
/// model that runs over the full image rather than a cropped subject
/// (face detection's own first pass, segmentation) starts from this same
/// region.
pub fn frameSquare(width: u32, height: u32) Region {
    return .{
        .center_x = @as(f32, @floatFromInt(width)) * 0.5,
        .center_y = @as(f32, @floatFromInt(height)) * 0.5,
        .side = @floatFromInt(@max(width, height)),
        .rotation = 0,
    };
}

/// Fills `out` with side*side RGB float pixels sampled from the region.
/// Samples falling outside the frame read as black, matching how the
/// models were trained on border padding.
pub fn sampleRegion(frame: Frame, region: Region, range: Range, side: u32, out: []f32) void {
    std.debug.assert(out.len == @as(usize, side) * side * 3);
    switch (frame.pixels) {
        .rgba8 => |bytes| std.debug.assert(bytes.len >= @as(usize, frame.width) * frame.height * 4),
        .nv12 => |planes| {
            std.debug.assert(planes.y.len >= @as(usize, planes.y_stride) * frame.height);
            std.debug.assert(planes.uv.len >= @as(usize, planes.uv_stride) * ((frame.height + 1) / 2));
        },
    }

    const step = region.side / @as(f32, @floatFromInt(side));
    const cos = @cos(region.rotation);
    const sin = @sin(region.rotation);
    const half = @as(f32, @floatFromInt(side)) * 0.5;

    var write: usize = 0;
    for (0..side) |row| {
        // Walk the source along the rotated row axis incrementally: two
        // adds per pixel instead of a full transform.
        const v = (@as(f32, @floatFromInt(row)) + 0.5 - half) * step;
        var x = region.center_x + (-half + 0.5) * step * cos - v * sin;
        var y = region.center_y + (-half + 0.5) * step * sin + v * cos;
        for (0..side) |_| {
            const rgb = switch (frame.pixels) {
                .rgba8 => |bytes| sampleRgba(bytes, frame.width, frame.height, x, y),
                .nv12 => |planes| sampleNv12(planes, frame.width, frame.height, x, y),
            };
            out[write] = rgb[0] * range.gain + range.bias;
            out[write + 1] = rgb[1] * range.gain + range.bias;
            out[write + 2] = rgb[2] * range.gain + range.bias;
            write += 3;
            x += step * cos;
            y += step * sin;
        }
    }
}

const Weights = struct {
    x0: f32,
    y0: f32,
    wx: f32,
    wy: f32,
};

fn bilinearWeights(x: f32, y: f32) Weights {
    const fx = x - 0.5;
    const fy = y - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    return .{ .x0 = x0, .y0 = y0, .wx = fx - x0, .wy = fy - y0 };
}

fn cornerWeight(w: Weights, dx: f32, dy: f32) f32 {
    const wx = if (dx == 0) 1 - w.wx else w.wx;
    const wy = if (dy == 0) 1 - w.wy else w.wy;
    return wx * wy;
}

const corner_offsets = [4][2]f32{ .{ 0, 0 }, .{ 1, 0 }, .{ 0, 1 }, .{ 1, 1 } };

fn sampleRgba(bytes: []const u8, width: u32, height: u32, x: f32, y: f32) [3]f32 {
    const w = bilinearWeights(x, y);
    var accumulated = [3]f32{ 0, 0, 0 };
    for (corner_offsets) |corner| {
        const sx = w.x0 + corner[0];
        const sy = w.y0 + corner[1];
        if (sx < 0 or sy < 0) continue;
        const ux: u32 = @intFromFloat(sx);
        const uy: u32 = @intFromFloat(sy);
        if (ux >= width or uy >= height) continue;
        const weight = cornerWeight(w, corner[0], corner[1]);
        const at = (@as(usize, uy) * width + ux) * 4;
        accumulated[0] += @as(f32, @floatFromInt(bytes[at])) * weight;
        accumulated[1] += @as(f32, @floatFromInt(bytes[at + 1])) * weight;
        accumulated[2] += @as(f32, @floatFromInt(bytes[at + 2])) * weight;
    }
    return .{ accumulated[0] / 255.0, accumulated[1] / 255.0, accumulated[2] / 255.0 };
}

fn samplePlane(plane: []const u8, stride: u32, width: u32, height: u32, channels: u32, channel: u32, x: f32, y: f32) f32 {
    const w = bilinearWeights(x, y);
    var accumulated: f32 = 0;
    for (corner_offsets) |corner| {
        const sx = w.x0 + corner[0];
        const sy = w.y0 + corner[1];
        if (sx < 0 or sy < 0) continue;
        const ux: u32 = @intFromFloat(sx);
        const uy: u32 = @intFromFloat(sy);
        if (ux >= width or uy >= height) continue;
        const at = @as(usize, uy) * stride + ux * channels + channel;
        accumulated += @as(f32, @floatFromInt(plane[at])) * cornerWeight(w, corner[0], corner[1]);
    }
    return accumulated / 255.0;
}

fn sampleNv12(planes: Nv12, width: u32, height: u32, x: f32, y: f32) [3]f32 {
    const luma = samplePlane(planes.y, planes.y_stride, width, height, 1, 0, x, y);
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const cb = samplePlane(planes.uv, planes.uv_stride, half_width, half_height, 2, 0, x * 0.5, y * 0.5);
    const cr = samplePlane(planes.uv, planes.uv_stride, half_width, half_height, 2, 1, x * 0.5, y * 0.5);
    const rgb = planes.conversion.apply(.{ luma, cb, cr });
    return .{
        std.math.clamp(rgb[0], 0.0, 1.0),
        std.math.clamp(rgb[1], 0.0, 1.0),
        std.math.clamp(rgb[2], 0.0, 1.0),
    };
}

const t = std.testing;

fn solidFrame(comptime width: u32, comptime height: u32, rgba: [4]u8) [width * height * 4]u8 {
    var pixels: [width * height * 4]u8 = undefined;
    for (0..width * height) |at| {
        pixels[at * 4 ..][0..4].* = rgba;
    }
    return pixels;
}

test "identity sampling reproduces pixel values in range" {
    const pixels = solidFrame(8, 8, .{ 255, 128, 0, 255 });
    const frame: Frame = .{ .pixels = .{ .rgba8 = &pixels }, .width = 8, .height = 8 };
    var out: [4 * 4 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 4, .center_y = 4, .side = 4, .rotation = 0 }, .unit, 4, &out);
    try t.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 128.0 / 255.0), out[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-6);
}

test "symmetric range maps black to minus one" {
    const pixels = solidFrame(4, 4, .{ 0, 0, 0, 255 });
    const frame: Frame = .{ .pixels = .{ .rgba8 = &pixels }, .width = 4, .height = 4 };
    var out: [2 * 2 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 2, .center_y = 2, .side = 2, .rotation = 0 }, .symmetric, 2, &out);
    try t.expectApproxEqAbs(@as(f32, -1.0), out[0], 1e-6);
}

test "samples outside the frame read as black" {
    const pixels = solidFrame(4, 4, .{ 255, 255, 255, 255 });
    const frame: Frame = .{ .pixels = .{ .rgba8 = &pixels }, .width = 4, .height = 4 };
    var out: [2 * 2 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 100, .center_y = 100, .side = 2, .rotation = 0 }, .unit, 2, &out);
    for (out) |value| try t.expectApproxEqAbs(@as(f32, 0.0), value, 1e-6);
}

test "quarter turn swaps the gradient axis" {
    // Left half black, right half white; after a quarter turn the split
    // runs horizontally in the sampled tensor.
    var pixels: [8 * 8 * 4]u8 = undefined;
    for (0..8) |row| {
        for (0..8) |column| {
            const value: u8 = if (column < 4) 0 else 255;
            pixels[(row * 8 + column) * 4 ..][0..4].* = .{ value, value, value, 255 };
        }
    }
    const frame: Frame = .{ .pixels = .{ .rgba8 = &pixels }, .width = 8, .height = 8 };
    var straight: [4 * 4 * 3]f32 = undefined;
    var turned: [4 * 4 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 4, .center_y = 4, .side = 4, .rotation = 0 }, .unit, 4, &straight);
    sampleRegion(frame, .{ .center_x = 4, .center_y = 4, .side = 4, .rotation = std.math.pi / 2.0 }, .unit, 4, &turned);
    // Straight: first row spans dark to bright. Turned: first row is
    // uniform bright, last row uniform dark.
    try t.expect(straight[0] < 0.1 and straight[(4 - 1) * 3] > 0.9);
    try t.expectApproxEqAbs(turned[0], turned[(4 - 1) * 3], 1e-5);
    try t.expect(turned[0] > 0.9 and turned[(4 * 3) * 3] < 0.1);
}

fn nv12Frame(comptime width: u32, comptime height: u32, luma: u8, cb: u8, cr: u8) struct {
    y: [width * height]u8,
    uv: [(width / 2) * (height / 2) * 2]u8,
} {
    var planes: @TypeOf(nv12Frame(width, height, 0, 0, 0)) = undefined;
    @memset(&planes.y, luma);
    var at: usize = 0;
    while (at < planes.uv.len) : (at += 2) {
        planes.uv[at] = cb;
        planes.uv[at + 1] = cr;
    }
    return planes;
}

test "nv12 sampling converts video range red through the exact matrix" {
    // Video range red in the classic standard: Y 82, Cb 90, Cr 240.
    const planes = nv12Frame(8, 8, 82, 90, 240);
    const frame: Frame = .{
        .pixels = .{ .nv12 = .{
            .y = &planes.y,
            .y_stride = 8,
            .uv = &planes.uv,
            .uv_stride = 8,
            .conversion = math.color.yuvToRgb(.bt601, .video),
        } },
        .width = 8,
        .height = 8,
    };
    var out: [2 * 2 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 4, .center_y = 4, .side = 4, .rotation = 0 }, .unit, 2, &out);
    try t.expectApproxEqAbs(@as(f32, 1.0), out[0], 0.02);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[1], 0.02);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[2], 0.02);
}

test "nv12 mid gray is neutral in both ranges" {
    const planes = nv12Frame(4, 4, 128, 128, 128);
    var frame: Frame = .{
        .pixels = .{ .nv12 = .{
            .y = &planes.y,
            .y_stride = 4,
            .uv = &planes.uv,
            .uv_stride = 4,
            .conversion = math.color.yuvToRgb(.bt709, .full),
        } },
        .width = 4,
        .height = 4,
    };
    var out: [1 * 1 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 2, .center_y = 2, .side = 2, .rotation = 0 }, .unit, 1, &out);
    try t.expectApproxEqAbs(@as(f32, 128.0 / 255.0), out[0], 0.01);
    try t.expectApproxEqAbs(out[0], out[1], 0.01);
    try t.expectApproxEqAbs(out[1], out[2], 0.01);

    frame.pixels.nv12.conversion = math.color.yuvToRgb(.bt601, .video);
    sampleRegion(frame, .{ .center_x = 2, .center_y = 2, .side = 2, .rotation = 0 }, .unit, 1, &out);
    try t.expectApproxEqAbs(out[0], out[1], 0.01);
    try t.expectApproxEqAbs(out[1], out[2], 0.01);
}
