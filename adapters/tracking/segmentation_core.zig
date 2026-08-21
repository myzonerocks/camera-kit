//! The synchronous segmentation inference core, free of any threading:
//! build the engine, sample a frame, invoke, read the mask. The host and
//! android wrap it in a worker thread (segmentation.zig); the web tier
//! calls it directly on its single thread.

const std = @import("std");
const runtime = @import("runtime");
const sampler = @import("sampler");
const transpose_conv_bias = @import("transpose_conv_bias");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, OutOfMemory };

pub const mask_side = 256;
pub const mask_len = mask_side * mask_side;
/// More classes than any pinned model carries; a bound, not a promise.
pub const max_classes = 8;

/// compute() samples and invokes; publish() lifts the result into
/// `values`, kept separate so a worker holds its mask lock only across
/// the cheap publish, not the whole inference. Readers see zeros until
/// the first publish.
pub const Core = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: runtime.Engine,
    /// One for the selfie/hair segmenters, six for the multiclass
    /// model - read off the model's own output tensor at create.
    class_count: u32,
    input_tensor: [mask_len * 3]f32 = undefined,
    /// mask_len * class_count floats, interleaved per pixel the way the
    /// model emits them - one probability per class.
    values: []f32,
    published: bool = false,

    pub fn init(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) CreateError!*Core {
        const core = gpa.create(Core) catch return error.OutOfMemory;
        errdefer gpa.destroy(core);

        const owned_bytes = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
        errdefer gpa.free(owned_bytes);

        // The custom upsample op the selfie and hair segmenters both need
        // to load at all.
        var engine = runtime.Engine.initWithCustomOps(owned_bytes, threads, &.{transpose_conv_bias.register}) catch
            return error.InvalidModel;
        errdefer engine.deinit();
        if (engine.inputCount() != 1 or engine.outputCount() != 1) return error.InvalidModel;

        // The model's own output size decides the class count; anything
        // that is not a whole number of mask planes is a model this core
        // does not understand.
        const output_tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, 0) orelse
            return error.InvalidModel;
        const output_floats = runtime.c.TfLiteTensorByteSize(output_tensor) / @sizeOf(f32);
        if (output_floats == 0 or output_floats % mask_len != 0) return error.InvalidModel;
        const class_count: u32 = @intCast(output_floats / mask_len);
        if (class_count > max_classes) return error.InvalidModel;

        const values = gpa.alloc(f32, output_floats) catch return error.OutOfMemory;
        errdefer gpa.free(values);
        @memset(values, 0);

        core.* = .{
            .gpa = gpa,
            .model_bytes = owned_bytes,
            .engine = engine,
            .class_count = class_count,
            .values = values,
        };
        return core;
    }

    pub fn deinit(core: *Core) void {
        const gpa = core.gpa;
        core.engine.deinit();
        gpa.free(core.values);
        gpa.free(core.model_bytes);
        gpa.destroy(core);
    }

    /// Samples the frame square into the input tensor and invokes the
    /// model, leaving the mask in the engine's output for publish().
    pub fn compute(core: *Core, frame: sampler.Frame) bool {
        sampler.sampleRegion(frame, sampler.frameSquare(frame.width, frame.height), .unit, mask_side, &core.input_tensor);
        core.engine.writeInput(0, std.mem.sliceAsBytes(&core.input_tensor)) catch return false;
        core.engine.invoke() catch return false;
        return true;
    }

    /// Copies the engine output into `values`, softmaxing the multiclass
    /// model's per-pixel logits so every reader sees probabilities.
    pub fn publish(core: *Core) void {
        const mask = core.engine.outputFloats(0) catch return;
        if (mask.len != core.values.len) return;
        if (core.class_count == 1) {
            // The single-class segmenters bake their sigmoid into the model.
            @memcpy(core.values, mask);
        } else {
            const stride = core.class_count;
            var at: usize = 0;
            while (at < mask.len) : (at += stride) {
                const pixel = mask[at..][0..stride];
                var max_logit = pixel[0];
                for (pixel[1..]) |value| max_logit = @max(max_logit, value);
                var sum: f32 = 0;
                const out_pixel = core.values[at..][0..stride];
                for (pixel, out_pixel) |value, *out_value| {
                    out_value.* = @exp(value - max_logit);
                    sum += out_value.*;
                }
                for (out_pixel) |*out_value| out_value.* /= sum;
            }
        }
        core.published = true;
    }

    /// The subject mask: a single-class model's own output, or one minus
    /// the multiclass background class. False until the first publish.
    pub fn subjectMask(core: *const Core, out: *[mask_len]f32) bool {
        if (!core.published) return false;
        if (core.class_count == 1) {
            @memcpy(out, core.values[0..mask_len]);
            return true;
        }
        const stride = core.class_count;
        for (out, 0..) |*value, at| {
            value.* = 1.0 - core.values[at * stride];
        }
        return true;
    }

    /// One class's mask plane. False until the first publish, or for a
    /// class the model does not have.
    pub fn classMask(core: *const Core, class_index: u32, out: *[mask_len]f32) bool {
        if (!core.published) return false;
        if (class_index >= core.class_count) return false;
        const stride = core.class_count;
        for (out, 0..) |*value, at| {
            value.* = core.values[at * stride + class_index];
        }
        return true;
    }
};
