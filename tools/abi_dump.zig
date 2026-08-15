//! Prints the ABI surface as deterministic text and checks it against the
//! tracked baseline. The baseline commits with the code, so any change to an
//! exported layout or symbol shows up in review as a diff to
//! tools/abi-baseline.txt, and an unintended change fails the gate.
//!
//!   abi_dump --print            write the current surface to stdout
//!   abi_dump --check <baseline> exit 1 if the surface differs from the file

const std = @import("std");
const abi = @import("abi");

const abi_types = .{ abi.FrameDesc, abi.Landmarks, abi.EngineConfig, abi.SessionConfig, abi.RendererDesc, abi.FramePlanes, abi.FaceResult };

// Exported functions with their frozen C signatures. Kept next to the type
// manifest so a new export without a manifest entry is caught in review.
const abi_functions = [_][]const u8{
    "uint32_t ck_abi_version(void)",
    "void *ck_alloc(size_t size)",
    "void ck_free(void *ptr, size_t size)",
    "ck_status ck_engine_create(const ck_engine_config *config, ck_engine **out_engine)",
    "void ck_engine_destroy(ck_engine *engine)",
    "ck_status ck_session_create(ck_engine *engine, const ck_session_config *config, ck_session **out_session)",
    "void ck_session_destroy(ck_session *session)",
    "ck_status ck_engine_init_renderer(ck_engine *engine, const ck_renderer_desc *desc)",
    "void ck_engine_resize(ck_engine *engine, uint32_t width, uint32_t height)",
    "ck_status ck_engine_render_frame(ck_engine *engine, ck_session *session)",
    "ck_status ck_session_submit_frame(ck_session *session, const ck_frame_desc *desc, const ck_frame_planes *planes)",
    "ck_status ck_session_submit_hardware_buffer(ck_session *session, const ck_frame_desc *desc, void *hardware_buffer)",
    "ck_status ck_session_submit_frame_copy(ck_session *session, const ck_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "ck_degrade_level ck_session_report_frame(ck_session *session, uint32_t frame_time_us, ck_thermal thermal)",
    "ck_degrade_level ck_session_degrade_level(const ck_session *session)",
    "ck_status ck_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix)",
    "ck_status ck_session_enable_face_tracking(ck_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void ck_session_disable_face_tracking(ck_session *session)",
    "ck_status ck_session_track_frame(ck_session *session, const ck_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "ck_status ck_session_face_result(ck_session *session, ck_face_result *out_result)",
    "ck_status ck_session_enable_beauty(ck_session *session, const char *resource_path)",
    "void ck_session_disable_beauty(ck_session *session)",
    "ck_status ck_session_set_beauty(ck_session *session, int32_t effect, float value)",
    "ck_status ck_session_beautify_frame(ck_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out)",
};

fn writeSurface(w: anytype) !void {
    try w.print("abi {d}.{d}\n", .{ abi.abi_major, abi.abi_minor });
    inline for (abi_types) |T| {
        try w.print("type {s} size={d} align={d}\n", .{ @typeName(T), @sizeOf(T), @alignOf(T) });
        inline for (@typeInfo(T).@"struct".fields) |field| {
            try w.print("  field {s} offset={d} size={d}\n", .{ field.name, @offsetOf(T, field.name), @sizeOf(field.type) });
        }
    }
    for (abi_functions) |f| {
        try w.print("fn {s}\n", .{f});
    }
}

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();

    var surface: std.Io.Writer.Allocating = .init(arena);
    try writeSurface(&surface.writer);
    const current = surface.writer.buffered();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const mode = args.next() orelse "--print";

    if (std.mem.eql(u8, mode, "--print")) {
        var out_buf: [4096]u8 = undefined;
        var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
        try stdout.interface.writeAll(current);
        try stdout.interface.flush();
        return 0;
    }

    if (std.mem.eql(u8, mode, "--check")) {
        const path = args.next() orelse {
            std.debug.print("abi_dump: --check needs a baseline path\n", .{});
            return 2;
        };
        const baseline = std.Io.Dir.cwd().readFileAlloc(init.io, path, arena, .limited(1 << 20)) catch |err| {
            std.debug.print("abi_dump: cannot read {s}: {t}\n", .{ path, err });
            return 1;
        };
        if (!std.mem.eql(u8, baseline, current)) {
            std.debug.print("abi_dump: ABI surface differs from {s}\n", .{path});
            std.debug.print("---- current ----\n{s}", .{current});
            std.debug.print("---- baseline ----\n{s}", .{baseline});
            std.debug.print("An intended change must update the baseline in the same PR.\n", .{});
            return 1;
        }
        return 0;
    }

    std.debug.print("abi_dump: unknown mode '{s}'\n", .{mode});
    return 2;
}

test "surface text is deterministic and complete" {
    var first: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer first.deinit();
    try writeSurface(&first.writer);
    var second: std.Io.Writer.Allocating = .init(std.testing.allocator);
    defer second.deinit();
    try writeSurface(&second.writer);

    try std.testing.expectEqualStrings(first.writer.buffered(), second.writer.buffered());
    try std.testing.expect(std.mem.indexOf(u8, first.writer.buffered(), "type") != null);
    try std.testing.expect(std.mem.indexOf(u8, first.writer.buffered(), "ck_abi_version") != null);
}
