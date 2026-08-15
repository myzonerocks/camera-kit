//! Samples model input tensors out of camera frames. The tracking models
//! take a square RGB float tensor cut from the frame around the subject,
//! possibly rotated to a canonical orientation. Each output pixel inverse
//! maps into the source and samples bilinearly, so the pass reads the
//! frame once, writes the tensor once, and allocates nothing.

const std = @import("std");

pub const Frame = struct {
    /// Tightly packed RGBA, one byte per channel.
    pixels: []const u8,
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

pub const Range = struct {
    scale: f32,
    offset: f32,

    /// Zero to one, the landmark models' input range.
    pub const unit: Range = .{ .scale = 1.0 / 255.0, .offset = 0.0 };
    /// Minus one to one, the detector's input range.
    pub const symmetric: Range = .{ .scale = 1.0 / 127.5, .offset = -1.0 };
};

/// Fills `out` with side*side RGB float pixels sampled from the region.
/// Samples falling outside the frame read as black, matching how the
/// models were trained on border padding.
pub fn sampleRegion(frame: Frame, region: Region, range: Range, side: u32, out: []f32) void {
    std.debug.assert(out.len == @as(usize, side) * side * 3);
    std.debug.assert(frame.pixels.len >= @as(usize, frame.width) * frame.height * 4);

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
            sampleBilinear(frame, x, y, range, out[write..][0..3]);
            write += 3;
            x += step * cos;
            y += step * sin;
        }
    }
}

fn sampleBilinear(frame: Frame, x: f32, y: f32, range: Range, out: *[3]f32) void {
    const fx = x - 0.5;
    const fy = y - 0.5;
    const x0 = @floor(fx);
    const y0 = @floor(fy);
    const wx = fx - x0;
    const wy = fy - y0;

    var accumulated = [3]f32{ 0, 0, 0 };
    const corners = [4]struct { dx: f32, dy: f32, weight: f32 }{
        .{ .dx = 0, .dy = 0, .weight = (1 - wx) * (1 - wy) },
        .{ .dx = 1, .dy = 0, .weight = wx * (1 - wy) },
        .{ .dx = 0, .dy = 1, .weight = (1 - wx) * wy },
        .{ .dx = 1, .dy = 1, .weight = wx * wy },
    };
    for (corners) |corner| {
        const sx = x0 + corner.dx;
        const sy = y0 + corner.dy;
        if (sx < 0 or sy < 0) continue;
        const ux: u32 = @intFromFloat(sx);
        const uy: u32 = @intFromFloat(sy);
        if (ux >= frame.width or uy >= frame.height) continue;
        const at = (@as(usize, uy) * frame.width + ux) * 4;
        accumulated[0] += @as(f32, @floatFromInt(frame.pixels[at])) * corner.weight;
        accumulated[1] += @as(f32, @floatFromInt(frame.pixels[at + 1])) * corner.weight;
        accumulated[2] += @as(f32, @floatFromInt(frame.pixels[at + 2])) * corner.weight;
    }
    out[0] = accumulated[0] * range.scale + range.offset;
    out[1] = accumulated[1] * range.scale + range.offset;
    out[2] = accumulated[2] * range.scale + range.offset;
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
    const frame: Frame = .{ .pixels = &pixels, .width = 8, .height = 8 };
    var out: [4 * 4 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 4, .center_y = 4, .side = 4, .rotation = 0 }, .unit, 4, &out);
    try t.expectApproxEqAbs(@as(f32, 1.0), out[0], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 128.0 / 255.0), out[1], 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.0), out[2], 1e-6);
}

test "symmetric range maps black to minus one" {
    const pixels = solidFrame(4, 4, .{ 0, 0, 0, 255 });
    const frame: Frame = .{ .pixels = &pixels, .width = 4, .height = 4 };
    var out: [2 * 2 * 3]f32 = undefined;
    sampleRegion(frame, .{ .center_x = 2, .center_y = 2, .side = 2, .rotation = 0 }, .symmetric, 2, &out);
    try t.expectApproxEqAbs(@as(f32, -1.0), out[0], 1e-6);
}

test "samples outside the frame read as black" {
    const pixels = solidFrame(4, 4, .{ 255, 255, 255, 255 });
    const frame: Frame = .{ .pixels = &pixels, .width = 4, .height = 4 };
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
    const frame: Frame = .{ .pixels = &pixels, .width = 8, .height = 8 };
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
