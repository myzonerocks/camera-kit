//! Off-thread loading for a lens's declared assets (section 7 of the
//! lens format: images and LUTs under a bundle's assets/ tree): a
//! background thread reads the file and decodes it, then publishes the
//! result through a single atomic pointer swap. The frame path polls
//! with a cheap acquire load and never blocks on disk IO or image
//! decode - the same reasoning the face tracking worker already applies
//! to a continuous stream, here for a one-shot load instead: exactly
//! one publish ever, so a full seqlock is more machinery than the job
//! needs.

const std = @import("std");
const image = @import("image");

pub const CreateError = error{OutOfMemory};

pub const Loader = struct {
    gpa: std.mem.Allocator,
    io_state: std.Io.Threaded,
    path: []u8,
    thread: ?std.Thread = null,
    result: std.atomic.Value(?*image.Image) = .init(null),
    failed: std.atomic.Value(bool) = .init(false),

    /// Spawns the background thread immediately. path is copied, so the
    /// caller's own buffer is free to go away as soon as this returns.
    pub fn start(gpa: std.mem.Allocator, path: []const u8) CreateError!*Loader {
        const loader = try gpa.create(Loader);
        errdefer gpa.destroy(loader);
        const owned_path = try gpa.dupe(u8, path);
        errdefer gpa.free(owned_path);
        loader.* = .{
            .gpa = gpa,
            .io_state = std.Io.Threaded.init(gpa, .{}),
            .path = owned_path,
        };
        loader.thread = std.Thread.spawn(.{}, run, .{loader}) catch return error.OutOfMemory;
        return loader;
    }

    fn run(loader: *Loader) void {
        const io = loader.io_state.io();
        // The format's own per-asset limit (SPEC 1.1): a loader never
        // reads past what a validated bundle could ever have shipped.
        const bytes = std.Io.Dir.cwd().readFileAlloc(io, loader.path, loader.gpa, .limited(32 * 1024 * 1024)) catch {
            loader.failed.store(true, .release);
            return;
        };
        defer loader.gpa.free(bytes);
        const decoded = image.decode(loader.gpa, bytes) catch {
            loader.failed.store(true, .release);
            return;
        };
        const boxed = loader.gpa.create(image.Image) catch {
            loader.gpa.free(decoded.rgba);
            loader.failed.store(true, .release);
            return;
        };
        boxed.* = decoded;
        loader.result.store(boxed, .release);
    }

    /// Any thread, cheap. Null until the decode completes; whichever
    /// call first observes it takes ownership - a second call sees
    /// null even though the first one already succeeded, which is
    /// exactly right for a one-shot asset a single caller consumes
    /// once and turns into a GPU texture.
    pub fn take(loader: *Loader) ?image.Image {
        const ptr = loader.result.swap(null, .acquire) orelse return null;
        defer loader.gpa.destroy(ptr);
        return ptr.*;
    }

    pub fn hasFailed(loader: *const Loader) bool {
        return loader.failed.load(.acquire);
    }

    /// Joins the background thread and frees anything take() never
    /// claimed - an asset that finished loading right as its lens
    /// deactivated is not a leak.
    pub fn deinit(loader: *Loader) void {
        if (loader.thread) |thread| thread.join();
        if (loader.result.swap(null, .acquire)) |ptr| {
            loader.gpa.free(ptr.rgba);
            loader.gpa.destroy(ptr);
        }
        loader.io_state.deinit();
        loader.gpa.free(loader.path);
        loader.gpa.destroy(loader);
    }
};

const t = std.testing;

const checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

fn tmpFilePath(tmp: std.testing.TmpDir, buf: []u8, name: []const u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}/{s}", .{ tmp.sub_path, name }) catch unreachable;
}

test "loads and decodes a real file off-thread, observed through take" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "lut.png", .data = &checker_png });

    var path_buf: [96]u8 = undefined;
    const path = tmpFilePath(tmp, &path_buf, "lut.png");

    const loader = try Loader.start(t.allocator, path);
    defer loader.deinit();

    var decoded: ?image.Image = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer t.allocator.free(got.rgba);

    try t.expectEqual(@as(u32, 8), got.width);
    try t.expectEqual(@as(u32, 8), got.height);
    try t.expect(!loader.hasFailed());

    // take() is one-shot: a second call after the first claimed the
    // result sees nothing, even though loading already succeeded.
    try t.expect(loader.take() == null);
}

test "a missing file surfaces as a failure, never a crash or a hang" {
    const loader = try Loader.start(t.allocator, ".zig-cache/tmp/does-not-exist/nope.png");
    defer loader.deinit();

    var saw_failure = false;
    var spins: u32 = 0;
    while (!saw_failure and spins < 1_000_000) : (spins += 1) {
        saw_failure = loader.hasFailed();
        if (!saw_failure) std.atomic.spinLoopHint();
    }
    try t.expect(saw_failure);
    try t.expect(loader.take() == null);
}
