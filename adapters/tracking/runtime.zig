//! Binding to the inference runtime's C interface. One Engine owns a
//! loaded model, its interpreter, and the cpu delegate; callers feed input
//! tensors and read outputs as plain slices. The model bytes must outlive
//! the engine: the runtime maps them in place rather than copying.

const std = @import("std");

pub const c = @cImport({
    @cInclude("tflite/c/c_api.h");
    @cInclude("tflite/core/c/c_api_opaque.h");
    @cInclude("tflite/delegates/xnnpack/xnnpack_delegate.h");
});

pub const Error = error{
    ModelRejected,
    InterpreterUnavailable,
    AllocationFailed,
    InvokeFailed,
    TensorShapeMismatch,
    TensorMissing,
};

/// A model naming this many distinct custom ops has no real model on
/// this project's roadmap to justify a dynamic list for - every known
/// case (today, just Convolution2DTransposeBias) needs exactly one.
const max_custom_ops = 4;

pub const Engine = struct {
    model: *c.TfLiteModel,
    options: *c.TfLiteInterpreterOptions,
    delegate: *c.TfLiteDelegate,
    interpreter: *c.TfLiteInterpreter,
    /// Owned custom-op registrations, if any: TfLiteOperator's own docs
    /// require it outlive every interpreter built from the options it
    /// was added to, so the engine that owns the interpreter is exactly
    /// where its lifetime belongs too, not leaked onto every caller.
    custom_ops: [max_custom_ops]?*c.TfLiteOperator = @splat(null),

    /// Threads bound the delegate's worker pool. Camera inference wants a
    /// small fixed pool: enough to hit frame budget, never enough to
    /// starve the render thread.
    pub fn init(model_bytes: []const u8, threads: i32) Error!Engine {
        return initWithCustomOps(model_bytes, threads, &.{});
    }

    /// Like init, but registers every op in `custom_ops` (each a
    /// module's own register(options) -> *TfLiteOperator function)
    /// before the interpreter loads the model - the only way a model
    /// naming an op the stock resolver doesn't know can load at all.
    /// Empty for every model that doesn't need one, which is why init()
    /// stays the plain entry point.
    pub fn initWithCustomOps(model_bytes: []const u8, threads: i32, custom_ops: []const *const fn (*c.TfLiteInterpreterOptions) *c.TfLiteOperator) Error!Engine {
        std.debug.assert(custom_ops.len <= max_custom_ops);
        const model = c.TfLiteModelCreate(model_bytes.ptr, model_bytes.len) orelse
            return error.ModelRejected;
        errdefer c.TfLiteModelDelete(model);

        const options = c.TfLiteInterpreterOptionsCreate() orelse
            return error.InterpreterUnavailable;
        errdefer c.TfLiteInterpreterOptionsDelete(options);
        c.TfLiteInterpreterOptionsSetNumThreads(options, threads);

        var registered: [max_custom_ops]?*c.TfLiteOperator = @splat(null);
        errdefer for (registered) |maybe_op| {
            if (maybe_op) |op| c.TfLiteOperatorDelete(op);
        };
        for (custom_ops, 0..) |register, i| registered[i] = register(options);

        var delegate_options = c.TfLiteXNNPackDelegateOptionsDefault();
        delegate_options.num_threads = threads;
        const delegate = c.TfLiteXNNPackDelegateCreate(&delegate_options) orelse
            return error.InterpreterUnavailable;
        errdefer c.TfLiteXNNPackDelegateDelete(delegate);
        c.TfLiteInterpreterOptionsAddDelegate(options, delegate);

        const interpreter = c.TfLiteInterpreterCreate(model, options) orelse
            return error.InterpreterUnavailable;
        errdefer c.TfLiteInterpreterDelete(interpreter);

        if (c.TfLiteInterpreterAllocateTensors(interpreter) != c.kTfLiteOk) {
            return error.AllocationFailed;
        }

        return .{ .model = model, .options = options, .delegate = delegate, .interpreter = interpreter, .custom_ops = registered };
    }

    pub fn deinit(engine: *Engine) void {
        c.TfLiteInterpreterDelete(engine.interpreter);
        c.TfLiteInterpreterOptionsDelete(engine.options);
        c.TfLiteXNNPackDelegateDelete(engine.delegate);
        c.TfLiteModelDelete(engine.model);
        for (engine.custom_ops) |maybe_op| {
            if (maybe_op) |op| c.TfLiteOperatorDelete(op);
        }
        engine.* = undefined;
    }

    pub fn inputCount(engine: *const Engine) usize {
        return @intCast(c.TfLiteInterpreterGetInputTensorCount(engine.interpreter));
    }

    pub fn outputCount(engine: *const Engine) usize {
        return @intCast(c.TfLiteInterpreterGetOutputTensorCount(engine.interpreter));
    }

    /// Writes one input tensor. The slice length must match the tensor's
    /// byte size exactly; a mismatch means the caller's preprocessing and
    /// the model disagree, which must fail loudly rather than truncate.
    pub fn writeInput(engine: *Engine, index: usize, bytes: []const u8) Error!void {
        const tensor = c.TfLiteInterpreterGetInputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        if (c.TfLiteTensorByteSize(tensor) != bytes.len) return error.TensorShapeMismatch;
        if (c.TfLiteTensorCopyFromBuffer(tensor, bytes.ptr, bytes.len) != c.kTfLiteOk) {
            return error.TensorShapeMismatch;
        }
    }

    pub fn invoke(engine: *Engine) Error!void {
        if (c.TfLiteInterpreterInvoke(engine.interpreter) != c.kTfLiteOk) {
            return error.InvokeFailed;
        }
    }

    /// Reads one output tensor as raw bytes, valid until the next invoke.
    pub fn output(engine: *const Engine, index: usize) Error![]const u8 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        const data = c.TfLiteTensorData(tensor) orelse return error.TensorMissing;
        return @as([*]const u8, @ptrCast(data))[0..c.TfLiteTensorByteSize(tensor)];
    }

    /// Reads one output tensor as floats. Camera models emit float32
    /// landmarks and scores; a different element type is a wiring defect.
    pub fn outputFloats(engine: *const Engine, index: usize) Error![]const f32 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        if (c.TfLiteTensorType(tensor) != c.kTfLiteFloat32) return error.TensorShapeMismatch;
        const data = c.TfLiteTensorData(tensor) orelse return error.TensorMissing;
        const count = c.TfLiteTensorByteSize(tensor) / @sizeOf(f32);
        return @as([*]const f32, @alignCast(@ptrCast(data)))[0..count];
    }

    pub fn outputDims(engine: *const Engine, index: usize, dims: []i32) Error![]i32 {
        const tensor = c.TfLiteInterpreterGetOutputTensor(engine.interpreter, @intCast(index)) orelse
            return error.TensorMissing;
        const count: usize = @intCast(c.TfLiteTensorNumDims(tensor));
        if (count > dims.len) return error.TensorShapeMismatch;
        for (dims[0..count], 0..) |*dim, at| {
            dim.* = c.TfLiteTensorDim(tensor, @intCast(at));
        }
        return dims[0..count];
    }
};
