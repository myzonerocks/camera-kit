//! The segmentation worker: owns the selfie-segmenter engine and runs it
//! off the camera thread. Frames arrive as NV12 plane copies into a
//! latest-wins mailbox, the same shape tracking.zig's worker uses; the
//! mask leaves through a mutex-guarded buffer rather than graph.
//! ResultSlot's seqlock. ResultSlot copies its payload as atomic words
//! one at a time, which is fine for face.Result's few kilobytes but would
//! mean tens of thousands of individual atomic operations per mask at
//! frame rate - a mutex held only across a single memcpy is cheaper.

const std = @import("std");
const runtime = @import("runtime");
const sampler = @import("sampler");
const math = @import("math");
const transpose_conv_bias = @import("transpose_conv_bias");

pub const supported = true;

pub const CreateError = error{ Unsupported, InvalidModel, OutOfMemory };

pub const mask_side = 256;
pub const mask_len = mask_side * mask_side;
/// More classes than any pinned model carries; a bound, not a promise.
pub const max_classes = 8;

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

const MaskBuffer = struct {
    /// mask_len * class_count floats, interleaved per pixel the way the
    /// model emits them - one probability per class.
    values: []f32,
    timestamp_us: i64 = 0,
    published: bool = false,
};

pub const Segmentation = struct {
    gpa: std.mem.Allocator,
    model_bytes: []u8,
    engine: runtime.Engine,
    /// One for the selfie/hair segmenters, six for the multiclass
    /// model - read off the model's own output tensor at create.
    class_count: u32,
    input_tensor: [mask_len * 3]f32 = undefined,

    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,

    mask_mutex: std.Io.Mutex = .init,
    mask: MaskBuffer,

    thread: ?std.Thread = null,
};

/// Copies the model, stands the engine up (with the custom upsample op
/// the selfie and hair segmenters both need to load at all), and starts
/// the worker.
pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) CreateError!*Segmentation {
    const segmentation = gpa.create(Segmentation) catch return error.OutOfMemory;
    errdefer gpa.destroy(segmentation);

    const owned_bytes = gpa.dupe(u8, model_bytes) catch return error.OutOfMemory;
    errdefer gpa.free(owned_bytes);

    var engine = runtime.Engine.initWithCustomOps(owned_bytes, threads, &.{transpose_conv_bias.register}) catch
        return error.InvalidModel;
    errdefer engine.deinit();
    if (engine.inputCount() != 1 or engine.outputCount() != 1) return error.InvalidModel;

    // The model's own output size decides the class count; anything that
    // is not a whole number of mask planes is a model this worker does
    // not understand.
    const output_tensor = runtime.c.TfLiteInterpreterGetOutputTensor(engine.interpreter, 0) orelse
        return error.InvalidModel;
    const output_floats = runtime.c.TfLiteTensorByteSize(output_tensor) / @sizeOf(f32);
    if (output_floats == 0 or output_floats % mask_len != 0) return error.InvalidModel;
    const class_count: u32 = @intCast(output_floats / mask_len);
    if (class_count > max_classes) return error.InvalidModel;

    const values = gpa.alloc(f32, output_floats) catch return error.OutOfMemory;
    errdefer gpa.free(values);
    @memset(values, 0);

    segmentation.* = .{
        .gpa = gpa,
        .io_state = std.Io.Threaded.init(gpa, .{}),
        .model_bytes = owned_bytes,
        .engine = engine,
        .class_count = class_count,
        .mask = .{ .values = values },
    };

    segmentation.thread = std.Thread.spawn(.{}, workerMain, .{segmentation}) catch return error.OutOfMemory;
    return segmentation;
}

pub fn destroy(segmentation: *Segmentation) void {
    const io = segmentation.io_state.io();
    {
        segmentation.mutex.lockUncancelable(io);
        defer segmentation.mutex.unlock(io);
        segmentation.stop = true;
        segmentation.frame_ready.signal(io);
    }
    if (segmentation.thread) |thread| thread.join();

    const gpa = segmentation.gpa;
    segmentation.pending.y.deinit(gpa);
    segmentation.pending.uv.deinit(gpa);
    segmentation.engine.deinit();
    gpa.free(segmentation.mask.values);
    gpa.free(segmentation.model_bytes);
    segmentation.io_state.deinit();
    gpa.destroy(segmentation);
}

/// Copies one NV12 frame into the mailbox, replacing any frame the worker
/// has not picked up yet - segmentation always wants the newest frame,
/// never a backlog.
pub fn submitNv12(
    segmentation: *Segmentation,
    width: u32,
    height: u32,
    timestamp_us: i64,
    conversion: math.color.Conversion,
    y: [*]const u8,
    y_stride: u32,
    uv: [*]const u8,
    uv_stride: u32,
) void {
    const y_size = @as(usize, width) * height;
    const half_width = (width + 1) / 2;
    const half_height = (height + 1) / 2;
    const uv_size = @as(usize, half_width) * half_height * 2;

    const io = segmentation.io_state.io();
    segmentation.mutex.lockUncancelable(io);
    defer segmentation.mutex.unlock(io);
    if (segmentation.stop) return;

    segmentation.pending.y.resize(segmentation.gpa, y_size) catch return;
    segmentation.pending.uv.resize(segmentation.gpa, uv_size) catch return;
    for (0..height) |row| {
        const src = y[row * y_stride ..][0..width];
        @memcpy(segmentation.pending.y.items[row * width ..][0..width], src);
    }
    for (0..half_height) |row| {
        const src = uv[row * uv_stride ..][0 .. half_width * 2];
        @memcpy(segmentation.pending.uv.items[row * half_width * 2 ..][0 .. half_width * 2], src);
    }
    segmentation.pending.width = width;
    segmentation.pending.height = height;
    segmentation.pending.timestamp_us = timestamp_us;
    segmentation.pending.conversion = conversion;
    segmentation.pending.fresh = true;
    segmentation.frame_ready.signal(io);
}

/// Copies the latest subject mask into `out`: a single-class model's
/// own output, or one minus the multiclass background class - the
/// background-swap path runs unchanged on either. False until the
/// worker has produced its first mask.
pub fn readMask(segmentation: *Segmentation, out: *[mask_len]f32) bool {
    const io = segmentation.io_state.io();
    segmentation.mask_mutex.lockUncancelable(io);
    defer segmentation.mask_mutex.unlock(io);
    if (!segmentation.mask.published) return false;
    if (segmentation.class_count == 1) {
        @memcpy(out, segmentation.mask.values[0..mask_len]);
        return true;
    }
    const stride = segmentation.class_count;
    for (out, 0..) |*value, at| {
        value.* = 1.0 - segmentation.mask.values[at * stride];
    }
    return true;
}

/// Copies one class's mask plane out of a multiclass model's output.
/// False until the first mask, or for a class the model does not have.
pub fn readClassMask(segmentation: *Segmentation, class_index: u32, out: *[mask_len]f32) bool {
    const io = segmentation.io_state.io();
    segmentation.mask_mutex.lockUncancelable(io);
    defer segmentation.mask_mutex.unlock(io);
    if (!segmentation.mask.published) return false;
    if (class_index >= segmentation.class_count) return false;
    const stride = segmentation.class_count;
    for (out, 0..) |*value, at| {
        value.* = segmentation.mask.values[at * stride + class_index];
    }
    return true;
}

pub fn classCount(segmentation: *Segmentation) u32 {
    return segmentation.class_count;
}

fn workerMain(segmentation: *Segmentation) void {
    var frame: PendingFrame = .{};
    defer {
        frame.y.deinit(segmentation.gpa);
        frame.uv.deinit(segmentation.gpa);
    }

    while (true) {
        {
            const io = segmentation.io_state.io();
            segmentation.mutex.lockUncancelable(io);
            defer segmentation.mutex.unlock(io);
            while (!segmentation.pending.fresh and !segmentation.stop) {
                segmentation.frame_ready.waitUncancelable(io, &segmentation.mutex);
            }
            if (segmentation.stop) return;
            std.mem.swap(PendingFrame, &frame, &segmentation.pending);
            segmentation.pending.fresh = false;
        }
        processFrame(segmentation, &frame);
    }
}

fn processFrame(segmentation: *Segmentation, frame: *const PendingFrame) void {
    const image: sampler.Frame = .{
        .width = frame.width,
        .height = frame.height,
        .pixels = .{ .nv12 = .{
            .y = frame.y.items,
            .y_stride = frame.width,
            .uv = frame.uv.items,
            .uv_stride = ((frame.width + 1) / 2) * 2,
            .conversion = frame.conversion,
        } },
    };

    sampler.sampleRegion(image, sampler.frameSquare(image.width, image.height), .unit, mask_side, &segmentation.input_tensor);
    segmentation.engine.writeInput(0, std.mem.sliceAsBytes(&segmentation.input_tensor)) catch return;
    segmentation.engine.invoke() catch return;
    const mask = segmentation.engine.outputFloats(0) catch return;
    if (mask.len != segmentation.mask.values.len) return;

    const io = segmentation.io_state.io();
    segmentation.mask_mutex.lockUncancelable(io);
    defer segmentation.mask_mutex.unlock(io);
    if (segmentation.class_count == 1) {
        // The single-class segmenters bake their sigmoid into the model.
        @memcpy(segmentation.mask.values, mask);
    } else {
        // The multiclass model emits raw per-class logits; its declared
        // activation is a per-pixel softmax, applied once at publish so
        // every reader sees probabilities.
        const stride = segmentation.class_count;
        var at: usize = 0;
        while (at < mask.len) : (at += stride) {
            const pixel = mask[at..][0..stride];
            var max_logit = pixel[0];
            for (pixel[1..]) |value| max_logit = @max(max_logit, value);
            var sum: f32 = 0;
            const out_pixel = segmentation.mask.values[at..][0..stride];
            for (pixel, out_pixel) |value, *out_value| {
                out_value.* = @exp(value - max_logit);
                sum += out_value.*;
            }
            for (out_pixel) |*out_value| out_value.* /= sum;
        }
    }
    segmentation.mask.timestamp_us = frame.timestamp_us;
    segmentation.mask.published = true;
}
