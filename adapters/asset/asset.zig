//! Off-thread loading for a lens's declared assets (section 7 of the
//! lens format: images, LUTs, and glTF models under a bundle's assets/
//! tree): a background thread reads the file and decodes it, then
//! publishes the result through a single atomic pointer swap. The
//! frame path polls with a cheap acquire load and never blocks on disk
//! IO or decode - the same reasoning the face tracking worker already
//! applies to a continuous stream, here for a one-shot load instead:
//! exactly one publish ever, so a full seqlock is more machinery than
//! the job needs.

const std = @import("std");
const image = @import("image");
const gltf = @import("gltf");

pub const CreateError = error{OutOfMemory};

/// One off-thread loader for one decoded asset type - image.Image for
/// a PNG, gltf.DecodedModel for a .glb, parameterized so both share
/// this exact threading/atomic-publish machinery rather than each
/// hand-rolling its own copy of it. decodeFn turns raw file bytes into
/// Result off the calling thread; freeFn releases a Result deinit()
/// never got to hand to a caller (a load that finished right as its
/// lens deactivated is not a leak).
pub fn Loader(comptime Result: type, comptime decodeFn: fn (std.mem.Allocator, []const u8) anyerror!Result, comptime freeFn: fn (std.mem.Allocator, Result) void) type {
    return struct {
        const Self = @This();

        gpa: std.mem.Allocator,
        io_state: std.Io.Threaded,
        path: []u8,
        thread: ?std.Thread = null,
        result: std.atomic.Value(?*Result) = .init(null),
        failed: std.atomic.Value(bool) = .init(false),

        /// Spawns the background thread immediately. path is copied, so
        /// the caller's own buffer is free to go away as soon as this
        /// returns.
        pub fn start(gpa: std.mem.Allocator, path: []const u8) CreateError!*Self {
            const loader = try gpa.create(Self);
            errdefer gpa.destroy(loader);
            const owned_path = try gpa.dupe(u8, path);
            errdefer gpa.free(owned_path);
            loader.* = .{
                .gpa = gpa,
                // The single-threaded form, not the pooled one
                // tracking.zig's long-lived worker uses: this loader
                // already has its own dedicated OS thread and never
                // shares Io duties with another one, so there is
                // nothing for a second layer of internal threading to
                // coordinate - the same reasoning core/abi's own
                // defaultIo() already applies.
                .io_state = std.Io.Threaded.init_single_threaded,
                .path = owned_path,
            };
            errdefer loader.io_state.deinit();
            loader.thread = std.Thread.spawn(.{}, run, .{loader}) catch return error.OutOfMemory;
            return loader;
        }

        fn run(loader: *Self) void {
            const io = loader.io_state.io();
            // The format's own per-asset limit (SPEC 1.1): a loader
            // never reads past what a validated bundle could ever have
            // shipped.
            const bytes = std.Io.Dir.cwd().readFileAlloc(io, loader.path, loader.gpa, .limited(32 * 1024 * 1024)) catch {
                loader.failed.store(true, .release);
                return;
            };
            defer loader.gpa.free(bytes);
            const decoded = decodeFn(loader.gpa, bytes) catch {
                loader.failed.store(true, .release);
                return;
            };
            const boxed = loader.gpa.create(Result) catch {
                freeFn(loader.gpa, decoded);
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
        /// once and turns into a GPU resource.
        pub fn take(loader: *Self) ?Result {
            const ptr = loader.result.swap(null, .acquire) orelse return null;
            defer loader.gpa.destroy(ptr);
            return ptr.*;
        }

        pub fn hasFailed(loader: *const Self) bool {
            return loader.failed.load(.acquire);
        }

        /// Joins the background thread and frees anything take() never
        /// claimed - an asset that finished loading right as its lens
        /// deactivated is not a leak.
        pub fn deinit(loader: *Self) void {
            if (loader.thread) |thread| thread.join();
            if (loader.result.swap(null, .acquire)) |ptr| {
                freeFn(loader.gpa, ptr.*);
                loader.gpa.destroy(ptr);
            }
            loader.io_state.deinit();
            loader.gpa.free(loader.path);
            loader.gpa.destroy(loader);
        }
    };
}

fn freeImage(gpa: std.mem.Allocator, img: image.Image) void {
    gpa.free(img.rgba);
}

pub const ImageLoader = Loader(image.Image, image.decode, freeImage);
pub const ModelLoader = Loader(gltf.DecodedModel, gltf.decodeModel, gltf.freeDecodedModel);

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

    const loader = try ImageLoader.start(t.allocator, path);
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
    const loader = try ImageLoader.start(t.allocator, ".zig-cache/tmp/does-not-exist/nope.png");
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

test "ModelLoader shares the same machinery for a real glb, off-thread" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();

    // The same asset shape adapters/gltf/gltf.zig's own tests build,
    // written to a real file so this exercises the same file-read path
    // a lens bundle's assets/<id>.glb load actually takes.
    const positions = [3][3]f32{ .{ 0.0, 0.0, 0.0 }, .{ 1.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 } };
    const indices = [3]u16{ 0, 1, 2 };
    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(t.allocator);
    try bin.appendSlice(t.allocator, std.mem.sliceAsBytes(&positions));
    try bin.appendSlice(t.allocator, std.mem.sliceAsBytes(&indices));
    while (bin.items.len % 4 != 0) try bin.append(t.allocator, 0);
    const json = try std.fmt.allocPrint(t.allocator,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[{{"buffer":0,"byteOffset":0,"byteLength":36}},{{"buffer":0,"byteOffset":36,"byteLength":6}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}},
        \\{{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1}}]}}],
        \\"nodes":[{{"mesh":0,"name":"tri"}}],
        \\"scenes":[{{"nodes":[0]}}],"scene":0}}
    , .{bin.items.len});
    defer t.allocator.free(json);
    var json_padded: std.ArrayList(u8) = .empty;
    defer json_padded.deinit(t.allocator);
    try json_padded.appendSlice(t.allocator, json);
    while (json_padded.items.len % 4 != 0) try json_padded.append(t.allocator, ' ');
    var glb: std.ArrayList(u8) = .empty;
    defer glb.deinit(t.allocator);
    const total: u32 = @intCast(12 + 8 + json_padded.items.len + 8 + bin.items.len);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 0x46546C67, .little);
    try glb.appendSlice(t.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, 2, .little);
    try glb.appendSlice(t.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, total, .little);
    try glb.appendSlice(t.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, @intCast(json_padded.items.len), .little);
    try glb.appendSlice(t.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, 0x4E4F534A, .little);
    try glb.appendSlice(t.allocator, &scratch);
    try glb.appendSlice(t.allocator, json_padded.items);
    std.mem.writeInt(u32, &scratch, @intCast(bin.items.len), .little);
    try glb.appendSlice(t.allocator, &scratch);
    std.mem.writeInt(u32, &scratch, 0x004E4942, .little);
    try glb.appendSlice(t.allocator, &scratch);
    try glb.appendSlice(t.allocator, bin.items);

    var path_buf: [96]u8 = undefined;
    const path = tmpFilePath(tmp, &path_buf, "clip.glb");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "clip.glb", .data = glb.items });

    const loader = try ModelLoader.start(t.allocator, path);
    defer loader.deinit();

    var decoded: ?gltf.DecodedModel = null;
    var spins: u32 = 0;
    while (decoded == null and spins < 1_000_000) : (spins += 1) {
        decoded = loader.take();
        if (decoded == null) std.atomic.spinLoopHint();
    }
    const got = decoded orelse return error.TestUnexpectedResult;
    defer gltf.freeDecodedModel(t.allocator, got);
    try t.expectEqual(@as(usize, 3), got.positions.len);
    try t.expectEqual(@as(usize, 3), got.indices.len);
    try t.expect(!loader.hasFailed());
}
