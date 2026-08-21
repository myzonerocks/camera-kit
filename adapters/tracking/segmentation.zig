//! The segmentation worker: runs a synchronous inference core off the
//! camera thread. Frames arrive NV12 into a latest-wins mailbox; the mask
//! leaves through a mutex-guarded read. The web tier skips this wrapper
//! and drives the core directly (segmentation_core.zig).

const std = @import("std");
const math = @import("math");
const sampler = @import("sampler");
const core_mod = @import("segmentation_core");

pub const supported = core_mod.supported;
pub const CreateError = core_mod.CreateError;
pub const mask_side = core_mod.mask_side;
pub const mask_len = core_mod.mask_len;
pub const max_classes = core_mod.max_classes;
pub const Core = core_mod.Core;

const PendingFrame = struct {
    width: u32 = 0,
    height: u32 = 0,
    timestamp_us: i64 = 0,
    conversion: math.color.Conversion = undefined,
    y: std.ArrayList(u8) = .empty,
    uv: std.ArrayList(u8) = .empty,
    fresh: bool = false,
};

pub const Segmentation = struct {
    gpa: std.mem.Allocator,
    core: *Core,

    io_state: std.Io.Threaded,
    mutex: std.Io.Mutex = .init,
    frame_ready: std.Io.Condition = .init,
    pending: PendingFrame = .{},
    stop: bool = false,

    mask_mutex: std.Io.Mutex = .init,

    thread: ?std.Thread = null,
};

/// Stands the core up and starts the worker.
pub fn create(gpa: std.mem.Allocator, model_bytes: []const u8, threads: i32) CreateError!*Segmentation {
    const segmentation = gpa.create(Segmentation) catch return error.OutOfMemory;
    errdefer gpa.destroy(segmentation);

    const core = try Core.init(gpa, model_bytes, threads);
    errdefer core.deinit();

    segmentation.* = .{
        .gpa = gpa,
        .core = core,
        .io_state = std.Io.Threaded.init(gpa, .{}),
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
    segmentation.core.deinit();
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

pub fn readMask(segmentation: *Segmentation, out: *[mask_len]f32) bool {
    const io = segmentation.io_state.io();
    segmentation.mask_mutex.lockUncancelable(io);
    defer segmentation.mask_mutex.unlock(io);
    return segmentation.core.subjectMask(out);
}

pub fn readClassMask(segmentation: *Segmentation, class_index: u32, out: *[mask_len]f32) bool {
    const io = segmentation.io_state.io();
    segmentation.mask_mutex.lockUncancelable(io);
    defer segmentation.mask_mutex.unlock(io);
    return segmentation.core.classMask(class_index, out);
}

pub fn classCount(segmentation: *Segmentation) u32 {
    return segmentation.core.class_count;
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
        // Invoke off the lock, then hold the mask lock only across the
        // publish so readers block for a copy, not an inference.
        if (!segmentation.core.compute(image)) continue;
        const io = segmentation.io_state.io();
        segmentation.mask_mutex.lockUncancelable(io);
        defer segmentation.mask_mutex.unlock(io);
        segmentation.core.publish();
    }
}
