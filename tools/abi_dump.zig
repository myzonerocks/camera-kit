//! Prints the ABI surface as deterministic text and checks it against the
//! tracked baseline. The baseline commits with the code, so any change to an
//! exported layout or symbol shows up in review as a diff to
//! tools/abi-baseline.txt, and an unintended change fails the gate.
//!
//!   abi_dump --print            write the current surface to stdout
//!   abi_dump --check <baseline> exit 1 if the surface differs from the file

const std = @import("std");
const abi = @import("abi");

const abi_types = .{ abi.FrameDesc, abi.Landmarks, abi.EngineConfig, abi.SessionConfig, abi.RendererDesc, abi.FramePlanes, abi.FaceResult, abi.HandResult, abi.PoseResult, abi.LensSignals };

// Exported functions with their frozen C signatures. Kept next to the type
// manifest so a new export without a manifest entry is caught in review.
const abi_functions = [_][]const u8{
    "uint32_t goss_abi_version(void)",
    "void *goss_alloc(size_t size)",
    "void goss_free(void *ptr, size_t size)",
    "goss_status goss_engine_create(const goss_engine_config *config, goss_engine **out_engine)",
    "void goss_engine_destroy(goss_engine *engine)",
    "goss_status goss_session_create(goss_engine *engine, const goss_session_config *config, goss_session **out_session)",
    "void goss_session_destroy(goss_session *session)",
    "goss_status goss_engine_init_renderer(goss_engine *engine, const goss_renderer_desc *desc)",
    "void goss_engine_resize(goss_engine *engine, uint32_t width, uint32_t height)",
    "goss_status goss_engine_render_frame(goss_engine *engine, goss_session *session)",
    "goss_status goss_engine_request_screenshot(goss_engine *engine, const uint8_t *path, size_t path_len)",
    "goss_status goss_engine_capture_frame(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_capture_photo(goss_engine *engine, goss_session *session, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_capture_photo_as(goss_engine *engine, goss_session *session, uint32_t format, uint32_t quality, uint8_t *out_data, size_t out_capacity, size_t *out_len, uint32_t *out_width, uint32_t *out_height)",
    "goss_status goss_engine_recording_start(goss_engine *engine, goss_session *session, const uint8_t *path, size_t path_len, const goss_recording_config *config)",
    "goss_status goss_engine_recording_stop(goss_engine *engine)",
    "goss_status goss_session_submit_frame(goss_session *session, const goss_frame_desc *desc, const goss_frame_planes *planes)",
    "goss_status goss_session_submit_hardware_buffer(goss_session *session, const goss_frame_desc *desc, void *hardware_buffer)",
    "goss_status goss_session_submit_frame_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "goss_degrade_level goss_session_report_frame(goss_session *session, uint32_t frame_time_us, goss_thermal thermal)",
    "goss_degrade_level goss_session_degrade_level(const goss_session *session)",
    "goss_status goss_color_yuv_to_rgb(uint32_t color_standard, uint32_t color_range, float *out_matrix)",
    "goss_status goss_session_enable_face_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_face_tracking(goss_session *session)",
    "goss_status goss_session_enable_hand_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_hand_tracking(goss_session *session)",
    "goss_status goss_session_hand_result(goss_session *session, goss_hand_result *out_result)",
    "goss_status goss_session_enable_pose_tracking(goss_session *session, const uint8_t *task_bytes, size_t task_len, int32_t threads)",
    "void goss_session_disable_pose_tracking(goss_session *session)",
    "goss_status goss_session_pose_result(goss_session *session, goss_pose_result *out_result)",
    "goss_status goss_session_face_pose(goss_session *session, float *out_matrix)",
    "goss_status goss_session_enable_segmentation(goss_session *session, const uint8_t *model_bytes, size_t model_len, int32_t threads)",
    "void goss_session_disable_segmentation(goss_session *session)",
    "goss_status goss_session_track_frame(goss_session *session, const goss_frame_desc *desc, const uint8_t *y, uint32_t y_stride, const uint8_t *uv, uint32_t uv_stride)",
    "goss_status goss_session_face_result(goss_session *session, goss_face_result *out_result)",
    "goss_status goss_session_enable_beauty(goss_session *session, const char *resource_path)",
    "void goss_session_disable_beauty(goss_session *session)",
    "goss_status goss_session_set_beauty(goss_session *session, int32_t effect, float value)",
    "goss_status goss_session_set_beauty_lut(goss_session *session, int32_t slot, const uint8_t *rgba, uint32_t width, uint32_t height)",
    "goss_status goss_session_set_beauty_makeup_texture(goss_session *session, int32_t effect, const uint8_t *rgba, uint32_t width, uint32_t height)",
    "goss_status goss_session_set_face_landmarks(goss_session *session, const float *points, uint32_t point_count)",
    "goss_status goss_session_submit_frame_rgba_copy(goss_session *session, const goss_frame_desc *desc, const uint8_t *rgba, uint32_t stride)",
    "goss_status goss_session_beautify_frame(goss_session *session, const uint8_t *rgba_in, uint32_t width, uint32_t height, uint8_t *rgba_out)",
    "goss_status goss_session_activate_lens(goss_session *session, const uint8_t *manifest_json, size_t manifest_len)",
    "goss_status goss_session_activate_lens_from_directory(goss_session *session, const uint8_t *bundle_path, size_t bundle_path_len)",
    "void goss_session_deactivate_lens(goss_session *session)",
    "goss_status goss_session_tick_lens(goss_session *session, uint32_t dt_us, const goss_lens_signals *signals)",
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

const build_options = @import("build_options");
const header_text = build_options.gosslens_header;

// The manifest above is hand-maintained next to the frozen header on
// purpose (a symbol only in one of the two is a build break, not a silent
// drift); this test is the enforcement so an export never goes undeclared
// in the header an SDK actually compiles against.
fn functionName(signature: []const u8) []const u8 {
    const paren = std.mem.indexOfScalar(u8, signature, '(') orelse unreachable;
    var start = paren;
    while (start > 0 and (std.ascii.isAlphanumeric(signature[start - 1]) or signature[start - 1] == '_')) start -= 1;
    return signature[start..paren];
}

test "every exported function is declared in the frozen public header" {
    for (abi_functions) |f| {
        const name = functionName(f);
        if (std.mem.indexOf(u8, header_text, name) == null) {
            std.debug.print("abi_dump: {s} is exported but not declared in include/gosslens.h\n", .{name});
            return error.TestUnexpectedResult;
        }
    }
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
    try std.testing.expect(std.mem.indexOf(u8, first.writer.buffered(), "goss_abi_version") != null);
}
