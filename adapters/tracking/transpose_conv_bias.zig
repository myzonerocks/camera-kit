//! Binds core/tracking/segment.zig's transposed-convolution-with-bias
//! math to TFLite's custom-op extension API, so an interpreter can load
//! a model using MediaPipe's Convolution2DTransposeBias op. This file
//! only ever adapts tensors and dimensions from TFLite's opaque C types
//! into that pure function's call shape - the algorithm itself lives
//! there, not here.

const runtime = @import("runtime");
const segment = @import("segment");
const c = runtime.c;

/// Only the fields MediaPipe's model actually serializes into
/// custom_options (TfLiteTransposeConvParams' version-1 fields) - the
/// struct has more fields upstream, but the flatbuffer only ever wrote
/// these three ints for this op, so reading past them would be reading
/// bytes the model never sent.
const Params = extern struct {
    padding: i32,
    stride_width: i32,
    stride_height: i32,
};

const padding_same: i32 = 1;

const data_input_index: i32 = 0;
const weights_index: i32 = 1;
const bias_index: i32 = 2;
const output_index: i32 = 0;

fn dim(tensor: *const c.TfLiteOpaqueTensor, index: i32) i32 {
    return c.TfLiteOpaqueTensorDim(tensor, index);
}

fn readParams(node: *c.TfLiteOpaqueNode) ?*const Params {
    var raw: ?*const anyopaque = null;
    var size: c_int = 0;
    if (c.TfLiteOpaqueNodeGetCustomInitialData(node, &raw, &size) != c.kTfLiteOk) return null;
    if (size < @sizeOf(Params)) return null;
    return @ptrCast(@alignCast(raw.?));
}

fn toPadding(value: i32) segment.Padding {
    return if (value == padding_same) .same else .valid;
}

fn prepare(user_data: ?*anyopaque, context: ?*c.TfLiteOpaqueContext, node: ?*c.TfLiteOpaqueNode) callconv(.c) c.TfLiteStatus {
    _ = user_data;
    const ctx = context.?;
    const n = node.?;

    const weights = c.TfLiteOpaqueNodeGetInput(ctx, n, weights_index) orelse return c.kTfLiteError;
    const input = c.TfLiteOpaqueNodeGetInput(ctx, n, data_input_index) orelse return c.kTfLiteError;
    const output = c.TfLiteOpaqueNodeGetOutput(ctx, n, output_index) orelse return c.kTfLiteError;
    const params = readParams(n) orelse return c.kTfLiteError;
    const padding = toPadding(params.padding);

    const new_size = c.TfLiteIntArrayCreate(4);
    new_size.*.data()[0] = dim(input, 0);
    new_size.*.data()[1] = segment.outputSize(dim(weights, 1), dim(input, 1), params.stride_height, padding);
    new_size.*.data()[2] = segment.outputSize(dim(weights, 2), dim(input, 2), params.stride_width, padding);
    new_size.*.data()[3] = dim(weights, 0);
    return c.TfLiteOpaqueContextResizeTensor(ctx, output, new_size);
}

fn tensorFloats(tensor: anytype) []f32 {
    if (c.TfLiteOpaqueTensorType(tensor) != c.kTfLiteFloat32) unreachable;
    const bytes = c.TfLiteOpaqueTensorData(tensor).?;
    const floats: [*]f32 = @alignCast(@ptrCast(bytes));
    const count = c.TfLiteOpaqueTensorByteSize(tensor) / @sizeOf(f32);
    return floats[0..count];
}

fn invoke(user_data: ?*anyopaque, context: ?*c.TfLiteOpaqueContext, node: ?*c.TfLiteOpaqueNode) callconv(.c) c.TfLiteStatus {
    _ = user_data;
    const ctx = context.?;
    const n = node.?;

    const weights = c.TfLiteOpaqueNodeGetInput(ctx, n, weights_index) orelse return c.kTfLiteError;
    const bias = c.TfLiteOpaqueNodeGetInput(ctx, n, bias_index) orelse return c.kTfLiteError;
    const input = c.TfLiteOpaqueNodeGetInput(ctx, n, data_input_index) orelse return c.kTfLiteError;
    const output = c.TfLiteOpaqueNodeGetOutput(ctx, n, output_index) orelse return c.kTfLiteError;
    const params = readParams(n) orelse return c.kTfLiteError;

    // One batch at a time: segment.compute operates on a single image's
    // worth of NHWC data, matching every other tensor here since this
    // op only ever runs with batch size 1 in a live camera pipeline.
    const batches = dim(input, 0);
    const in_height = dim(input, 1);
    const in_width = dim(input, 2);
    const in_depth = dim(input, 3);
    const filter_height = dim(weights, 1);
    const filter_width = dim(weights, 2);
    const out_channels = dim(weights, 0);
    const out_height = dim(output, 1);
    const out_width = dim(output, 2);

    const input_data = tensorFloats(@as(*const c.TfLiteOpaqueTensor, input));
    const filter_data = tensorFloats(@as(*const c.TfLiteOpaqueTensor, weights));
    const bias_data = tensorFloats(@as(*const c.TfLiteOpaqueTensor, bias));
    const output_data = tensorFloats(@as(*c.TfLiteOpaqueTensor, output));

    const in_batch_size: usize = @intCast(in_height * in_width * in_depth);
    const out_batch_size: usize = @intCast(out_height * out_width * out_channels);

    var batch: usize = 0;
    while (batch < @as(usize, @intCast(batches))) : (batch += 1) {
        segment.compute(
            input_data[batch * in_batch_size ..][0..in_batch_size],
            in_height,
            in_width,
            in_depth,
            filter_data,
            filter_height,
            filter_width,
            bias_data,
            out_channels,
            output_data[batch * out_batch_size ..][0..out_batch_size],
            out_height,
            out_width,
            .{ .padding = toPadding(params.padding), .stride_height = params.stride_height, .stride_width = params.stride_width },
        );
    }

    return c.kTfLiteOk;
}

/// Registers the op with `options` so an interpreter created from it can
/// load a model using Convolution2DTransposeBias. The returned
/// TfLiteOperator must outlive every interpreter built from `options` -
/// pass this function itself to Engine.initWithCustomOps, which takes
/// care of that lifetime rather than leaving it to the caller.
pub fn register(options: *c.TfLiteInterpreterOptions) *c.TfLiteOperator {
    const op = c.TfLiteOperatorCreate(c.kTfLiteBuiltinCustom, "Convolution2DTransposeBias", 1, null).?;
    _ = c.TfLiteOperatorSetPrepareWithData(op, prepare);
    _ = c.TfLiteOperatorSetInvokeWithData(op, invoke);
    c.TfLiteInterpreterOptionsAddOperator(options, op);
    return op;
}
