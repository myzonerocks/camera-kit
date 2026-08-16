//! The segmentation model's transposed-convolution-with-bias upsample,
//! as pure math with no adapter dependency - mirrors how face.zig holds
//! the face pipeline's own math independent of the inference runtime
//! that drives it. This is the same algorithm MediaPipe's own
//! Convolution2DTransposeBias custom TFLite op runs (mediapipe/util/
//! tflite/operations/transpose_conv_bias.cc): the bias is folded in by
//! initializing the output with it before accumulating, rather than as
//! a separate add; SAME padding is computed the same asymmetric-if-odd
//! way TensorFlow's own convolution ops do.

const std = @import("std");

pub const Padding = enum { same, valid };

pub const Params = struct {
    padding: Padding,
    stride_height: i32,
    stride_width: i32,
};

fn samePaddingTotal(filter: i32, in_size: i32, stride: i32) i32 {
    return @max(0, filter - @mod(in_size - 1, stride) - 1);
}

/// The output spatial size a call with these params produces - Prepare
/// stages call this to size the output tensor before compute() ever runs.
pub fn outputSize(filter: i32, in_size: i32, stride: i32, padding: Padding) i32 {
    const total = if (padding == .same) samePaddingTotal(filter, in_size, stride) else 0;
    return stride * (in_size - 1) + filter - total;
}

fn inputOffset(y: i32, x: i32, ch: i32, w: i32, depth: i32) usize {
    return @intCast((y * w + x) * depth + ch);
}

/// Weights are OHWI (output_channels, filter_height, filter_width,
/// input_channels) - a different axis order than the NHWC the input,
/// bias, and output all share.
fn filterOffset(oc: i32, fy: i32, fx: i32, ic: i32, filter_height: i32, filter_width: i32, in_depth: i32) usize {
    return @intCast(((oc * filter_height + fy) * filter_width + fx) * in_depth + ic);
}

/// One batch element's worth of transposed convolution, output already
/// sized by the caller via outputSize(). O(in_h * in_w * in_c * filter_h
/// * filter_w * out_c) - the same bound a direct (non-FFT) transposed
/// convolution always costs; nothing here allocates.
pub fn compute(
    input: []const f32,
    in_height: i32,
    in_width: i32,
    in_depth: i32,
    filter: []const f32,
    filter_height: i32,
    filter_width: i32,
    bias: []const f32,
    out_channels: i32,
    output: []f32,
    out_height: i32,
    out_width: i32,
    params: Params,
) void {
    std.debug.assert(input.len == @as(usize, @intCast(in_height * in_width * in_depth)));
    std.debug.assert(filter.len == @as(usize, @intCast(out_channels * filter_height * filter_width * in_depth)));
    std.debug.assert(bias.len == @as(usize, @intCast(out_channels)));
    std.debug.assert(output.len == @as(usize, @intCast(out_height * out_width * out_channels)));

    var pad_height: i32 = 0;
    var pad_width: i32 = 0;
    if (params.padding == .same) {
        pad_height = @divTrunc(samePaddingTotal(filter_height, in_height, params.stride_height), 2);
        pad_width = @divTrunc(samePaddingTotal(filter_width, in_width, params.stride_width), 2);
    }

    var out_y: i32 = 0;
    while (out_y < out_height) : (out_y += 1) {
        var out_x: i32 = 0;
        while (out_x < out_width) : (out_x += 1) {
            const base = inputOffset(out_y, out_x, 0, out_width, out_channels);
            @memcpy(output[base..][0..@intCast(out_channels)], bias);
        }
    }

    var in_y: i32 = 0;
    while (in_y < in_height) : (in_y += 1) {
        var in_x: i32 = 0;
        while (in_x < in_width) : (in_x += 1) {
            const out_x_origin = in_x * params.stride_width - pad_width;
            const out_y_origin = in_y * params.stride_height - pad_height;
            var ic: i32 = 0;
            while (ic < in_depth) : (ic += 1) {
                const input_value = input[inputOffset(in_y, in_x, ic, in_width, in_depth)];

                var fy: i32 = 0;
                while (fy < filter_height) : (fy += 1) {
                    const oy = out_y_origin + fy;
                    if (oy < 0 or oy >= out_height) continue;
                    var fx: i32 = 0;
                    while (fx < filter_width) : (fx += 1) {
                        const ox = out_x_origin + fx;
                        if (ox < 0 or ox >= out_width) continue;
                        const out_base = inputOffset(oy, ox, 0, out_width, out_channels);
                        var oc: i32 = 0;
                        while (oc < out_channels) : (oc += 1) {
                            const filter_value = filter[filterOffset(oc, fy, fx, ic, filter_height, filter_width, in_depth)];
                            output[out_base + @as(usize, @intCast(oc))] += input_value * filter_value;
                        }
                    }
                }
            }
        }
    }
}

const t = std.testing;

test "outputSize matches the reference formula for a real model's real dims" {
    // selfie_segmenter.tflite's own segment/Kernel [1,2,2,16], stride
    // 2x2, SAME padding, input 128x128 - the exact case this whole
    // module exists for.
    try t.expectEqual(@as(i32, 256), outputSize(2, 128, 2, .same));
}

test "1x1 input, 1x1 filter, stride 1, no padding: pure scale plus bias" {
    // The smallest possible case: one input pixel, one filter tap, one
    // output pixel - output = input * filter + bias, hand-computed.
    const input = [_]f32{3.0};
    const filter = [_]f32{2.0}; // one output channel, 1x1 filter, one input channel
    const bias = [_]f32{1.0};
    var output = [_]f32{0.0};
    compute(&input, 1, 1, 1, &filter, 1, 1, &bias, 1, &output, 1, 1, .{ .padding = .valid, .stride_height = 1, .stride_width = 1 });
    try t.expectApproxEqAbs(@as(f32, 7.0), output[0], 1.0e-6);
}

test "2x2 input, 2x2 filter, stride 2, SAME padding: each input pixel scatters independently" {
    // Matches the real model's shape family (stride 2, 2x2 filter, SAME
    // padding computes to zero total padding here since in_size=2 is
    // even) - four input pixels each land in their own disjoint 2x2
    // output block since the filter exactly covers one stride step, so
    // every output pixel equals exactly one input times one filter tap
    // plus bias, hand-verifiable per pixel.
    const input = [_]f32{ 1.0, 2.0, 3.0, 4.0 }; // 2x2, 1 channel, row-major
    // One output channel, 2x2 filter, 1 input channel, OHWI layout.
    const filter = [_]f32{ 10.0, 20.0, 30.0, 40.0 };
    const bias = [_]f32{5.0};
    const out_h = outputSize(2, 2, 2, .same);
    const out_w = out_h;
    try t.expectEqual(@as(i32, 4), out_h);
    var output: [16]f32 = undefined;
    compute(&input, 2, 2, 1, &filter, 2, 2, &bias, 1, &output, out_h, out_w, .{ .padding = .same, .stride_height = 2, .stride_width = 2 });

    // Input (0,0)=1 scatters into output block rows 0-1, cols 0-1 via
    // the 2x2 filter: out[0,0] = 1*filter[0,0] + bias, out[0,1] =
    // 1*filter[0,1] + bias, out[1,0] = 1*filter[1,0] + bias, out[1,1] =
    // 1*filter[1,1] + bias.
    const at = struct {
        fn get(buf: []const f32, y: i32, x: i32, w: i32) f32 {
            return buf[@intCast(y * w + x)];
        }
    }.get;
    try t.expectApproxEqAbs(@as(f32, 1.0 * 10.0 + 5.0), at(&output, 0, 0, out_w), 1.0e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0 * 20.0 + 5.0), at(&output, 0, 1, out_w), 1.0e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0 * 30.0 + 5.0), at(&output, 1, 0, out_w), 1.0e-6);
    try t.expectApproxEqAbs(@as(f32, 1.0 * 40.0 + 5.0), at(&output, 1, 1, out_w), 1.0e-6);
    // Input (0,1)=2 scatters into the next output block over, cols 2-3.
    try t.expectApproxEqAbs(@as(f32, 2.0 * 10.0 + 5.0), at(&output, 0, 2, out_w), 1.0e-6);
    // Input (1,0)=3 scatters into rows 2-3, cols 0-1.
    try t.expectApproxEqAbs(@as(f32, 3.0 * 10.0 + 5.0), at(&output, 2, 0, out_w), 1.0e-6);
    // Input (1,1)=4 scatters into rows 2-3, cols 2-3, the last block.
    try t.expectApproxEqAbs(@as(f32, 4.0 * 40.0 + 5.0), at(&output, 3, 3, out_w), 1.0e-6);
}
