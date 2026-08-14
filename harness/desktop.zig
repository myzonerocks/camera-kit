//! Desktop harness: draws a textured glTF asset through the frame graph on
//! screen with the real render stack, and proves what it drew by reading the
//! pixels back. This is the acceptance surface for the render and asset
//! adapters; nothing merges on a promise here.

const std = @import("std");
const graph = @import("graph");
const math = @import("math");
const gltf = @import("gltf");

const c = @cImport({
    @cDefine("GLFW_INCLUDE_NONE", "1");
    @cInclude("GLFW/glfw3.h");
    @cInclude("bgfx/c99/bgfx.h");
    @cInclude("lodepng.h");
});

extern fn glfwGetCocoaWindow(window: ?*c.GLFWwindow) ?*anyopaque;

const width: u32 = 800;
const height: u32 = 600;
const screenshot_path = "zig-out/harness-frame.ppm";

var screenshot_written: bool = false;
var harness_io: std.Io = undefined;

// The checkerboard texture embedded in the generated glTF: 8x8 RGBA PNG,
// alternating 4x4 white and red squares.
const checker_png = [_]u8{
    0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0x00, 0x00, 0x00, 0x0d, 0x49, 0x48, 0x44, 0x52,
    0x00, 0x00, 0x00, 0x08, 0x00, 0x00, 0x00, 0x08, 0x08, 0x06, 0x00, 0x00, 0x00, 0xc4, 0x0f, 0xbe,
    0x8b, 0x00, 0x00, 0x00, 0x19, 0x49, 0x44, 0x41, 0x54, 0x78, 0xda, 0x63, 0xf8, 0x8f, 0x0e, 0x18,
    0x18, 0x50, 0x30, 0x03, 0x3d, 0x14, 0xa0, 0x09, 0x60, 0xa8, 0xa7, 0xbd, 0x02, 0x00, 0xa3, 0xc6,
    0xbf, 0x41, 0x50, 0xd7, 0xe9, 0x6c, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42,
    0x60, 0x82,
};

// Metal shader blobs in the exact binary layout bgfx parses: magic VSH/FSH
// version 11, in/out hashes, the uniform table, then MSL source the driver
// compiles at load. The lens shader toolchain replaces this hand assembly
// when it lands; the format itself is what shaderc emits.
const ShaderUniform = struct {
    name: []const u8,
    kind: u8,
    num: u8,
    reg_index: u16,
    reg_count: u16,
};

fn buildShaderBlob(gpa: std.mem.Allocator, kind: u8, uniforms: []const ShaderUniform, source: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ kind, 'S', 'H', 11 });
    try out.appendSlice(gpa, &(.{0} ** 8)); // input and output hashes
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u16, scratch[0..2], @intCast(uniforms.len), .little);
    try out.appendSlice(gpa, scratch[0..2]);
    for (uniforms) |u| {
        try out.append(gpa, @intCast(u.name.len));
        try out.appendSlice(gpa, u.name);
        try out.append(gpa, u.kind);
        try out.append(gpa, u.num);
        std.mem.writeInt(u16, scratch[0..2], u.reg_index, .little);
        try out.appendSlice(gpa, scratch[0..2]);
        std.mem.writeInt(u16, scratch[0..2], u.reg_count, .little);
        try out.appendSlice(gpa, scratch[0..2]);
        try out.appendSlice(gpa, &.{ 0, 0, 0, 0 }); // texInfo, texFormat
    }
    std.mem.writeInt(u32, &scratch, @intCast(source.len), .little);
    try out.appendSlice(gpa, &scratch);
    try out.appendSlice(gpa, source);
    try out.append(gpa, 0);
    return out.toOwnedSlice(gpa);
}

const vertex_msl =
    \\#include <metal_stdlib>
    \\#include <simd/simd.h>
    \\
    \\using namespace metal;
    \\
    \\struct _Global
    \\{
    \\    float4x4 u_modelViewProj;
    \\};
    \\
    \\struct xlatMtlMain_out
    \\{
    \\    float2 _entryPointOutput_v_texcoord0 [[user(locn0)]];
    \\    float4 gl_Position [[position]];
    \\};
    \\
    \\struct xlatMtlMain_in
    \\{
    \\    float3 a_position [[attribute(0)]];
    \\    float2 a_texcoord0 [[attribute(1)]];
    \\};
    \\
    \\vertex xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], constant _Global& _mtl_u [[buffer(0)]])
    \\{
    \\    xlatMtlMain_out out = {};
    \\    out.gl_Position = _mtl_u.u_modelViewProj * float4(in.a_position, 1.0);
    \\    out._entryPointOutput_v_texcoord0 = in.a_texcoord0;
    \\    return out;
    \\}
    \\
;

const fragment_msl =
    \\#include <metal_stdlib>
    \\#include <simd/simd.h>
    \\
    \\using namespace metal;
    \\
    \\struct xlatMtlMain_out
    \\{
    \\    float4 bgfx_FragData0 [[color(0)]];
    \\};
    \\
    \\struct xlatMtlMain_in
    \\{
    \\    float2 v_texcoord0 [[user(locn0)]];
    \\};
    \\
    \\fragment xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], texture2d<float> s_texColor [[texture(0)]], sampler s_texColorSampler [[sampler(0)]])
    \\{
    \\    xlatMtlMain_out out = {};
    \\    out.bgfx_FragData0 = s_texColor.sample(s_texColorSampler, in.v_texcoord0);
    \\    return out;
    \\}
    \\
;

// A complete GLB built in memory: one quad with texcoords, indices, and the
// checkerboard PNG as its embedded base color texture. The same container
// path a lens asset takes.
fn buildTexturedQuadGlb(gpa: std.mem.Allocator) ![]u8 {
    const positions = [4][3]f32{
        .{ -0.5, -0.5, 0.0 },
        .{ 0.5, -0.5, 0.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ -0.5, 0.5, 0.0 },
    };
    const uvs = [4][2]f32{
        .{ 0.0, 1.0 },
        .{ 1.0, 1.0 },
        .{ 1.0, 0.0 },
        .{ 0.0, 0.0 },
    };
    const indices = [6]u16{ 0, 1, 2, 0, 2, 3 };

    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(gpa);
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions));
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&uvs));
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices));
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);
    const png_offset = bin.items.len;
    try bin.appendSlice(gpa, &checker_png);
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":48}},
        \\{{"buffer":0,"byteOffset":48,"byteLength":32}},
        \\{{"buffer":0,"byteOffset":80,"byteLength":12}},
        \\{{"buffer":0,"byteOffset":{d},"byteLength":{d}}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.5,-0.5,0],"max":[0.5,0.5,0]}},
        \\{{"bufferView":1,"componentType":5126,"count":4,"type":"VEC2"}},
        \\{{"bufferView":2,"componentType":5123,"count":6,"type":"SCALAR"}}],
        \\"images":[{{"bufferView":3,"mimeType":"image/png"}}],
        \\"samplers":[{{"magFilter":9728,"minFilter":9728}}],
        \\"textures":[{{"source":0,"sampler":0}}],
        \\"materials":[{{"pbrMetallicRoughness":{{"baseColorTexture":{{"index":0}}}}}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0,"TEXCOORD_0":1}},"indices":2,"material":0}}]}}],
        \\"nodes":[{{"mesh":0,"name":"quad"}}],
        \\"scenes":[{{"nodes":[0]}}],"scene":0}}
    , .{ bin.items.len, png_offset, checker_png.len });
    defer gpa.free(json);

    var json_padded: std.ArrayList(u8) = .empty;
    defer json_padded.deinit(gpa);
    try json_padded.appendSlice(gpa, json);
    while (json_padded.items.len % 4 != 0) try json_padded.append(gpa, ' ');

    var glb: std.ArrayList(u8) = .empty;
    errdefer glb.deinit(gpa);
    const total: u32 = @intCast(12 + 8 + json_padded.items.len + 8 + bin.items.len);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 0x46546C67, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 2, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, total, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, @intCast(json_padded.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x4E4F534A, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, json_padded.items);
    std.mem.writeInt(u32, &scratch, @intCast(bin.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x004E4942, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, bin.items);
    return glb.toOwnedSlice(gpa);
}

const Callbacks = struct {
    var vtbl: c.bgfx_callback_vtbl_t = .{
        .fatal = fatal,
        .trace_vargs = traceVargs,
        .profiler_begin = profilerBegin,
        .profiler_begin_literal = profilerBeginLiteral,
        .profiler_end = profilerEnd,
        .cache_read_size = cacheReadSize,
        .cache_read = cacheRead,
        .cache_write = cacheWrite,
        .screen_shot = screenShot,
        .capture_begin = captureBegin,
        .capture_end = captureEnd,
        .capture_frame = captureFrame,
    };
    var iface: c.bgfx_callback_interface_t = .{ .vtbl = &vtbl };

    fn fatal(_: [*c]c.bgfx_callback_interface_t, file: [*c]const u8, line: u16, code: c.bgfx_fatal_t, message: [*c]const u8) callconv(.c) void {
        std.debug.print("harness: bgfx fatal {d} at {s}:{d}: {s}\n", .{ code, file, line, message });
        std.process.abort();
    }
    fn traceVargs(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u16, _: [*c]const u8, _: [*c]u8) callconv(.c) void {}
    fn profilerBegin(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u32, _: [*c]const u8, _: u16) callconv(.c) void {}
    fn profilerBeginLiteral(_: [*c]c.bgfx_callback_interface_t, _: [*c]const u8, _: u32, _: [*c]const u8, _: u16) callconv(.c) void {}
    fn profilerEnd(_: [*c]c.bgfx_callback_interface_t) callconv(.c) void {}
    fn cacheReadSize(_: [*c]c.bgfx_callback_interface_t, _: u64) callconv(.c) u32 {
        return 0;
    }
    fn cacheRead(_: [*c]c.bgfx_callback_interface_t, _: u64, _: ?*anyopaque, _: u32) callconv(.c) bool {
        return false;
    }
    fn cacheWrite(_: [*c]c.bgfx_callback_interface_t, _: u64, _: ?*const anyopaque, _: u32) callconv(.c) void {}
    fn captureBegin(_: [*c]c.bgfx_callback_interface_t, _: u32, _: u32, _: u32, _: c.bgfx_texture_format_t, _: bool) callconv(.c) void {}
    fn captureEnd(_: [*c]c.bgfx_callback_interface_t) callconv(.c) void {}
    fn captureFrame(_: [*c]c.bgfx_callback_interface_t, _: ?*const anyopaque, _: u32) callconv(.c) void {}

    fn screenShot(
        _: [*c]c.bgfx_callback_interface_t,
        path: [*c]const u8,
        shot_width: u32,
        shot_height: u32,
        pitch: u32,
        _: c_uint,
        data: ?*const anyopaque,
        _: u32,
        yflip: bool,
    ) callconv(.c) void {
        writePpm(std.mem.span(@as([*:0]const u8, @ptrCast(path))), shot_width, shot_height, pitch, @ptrCast(data.?), yflip) catch |err| {
            std.debug.print("harness: screenshot write failed: {t}\n", .{err});
            return;
        };
        screenshot_written = true;
    }
};

fn writePpm(path: []const u8, w: u32, h: u32, pitch: u32, bgra: [*]const u8, yflip: bool) !void {
    const gpa = std.heap.page_allocator;
    const body = try gpa.alloc(u8, 64 + w * h * 3);
    defer gpa.free(body);
    const header = try std.fmt.bufPrint(body[0..64], "P6\n{d} {d}\n255\n", .{ w, h });
    var len: usize = header.len;
    for (0..h) |row_index| {
        const source_row = if (yflip) h - 1 - row_index else row_index;
        const row = bgra[source_row * pitch ..][0 .. w * 4];
        for (0..w) |x| {
            body[len] = row[x * 4 + 2];
            body[len + 1] = row[x * 4 + 1];
            body[len + 2] = row[x * 4];
            len += 3;
        }
    }
    try std.Io.Dir.cwd().writeFile(harness_io, .{ .sub_path = path, .data = body[0..len] });
}

const Scene = struct {
    program: c.bgfx_program_handle_t,
    vertex_buffer: c.bgfx_vertex_buffer_handle_t,
    index_buffer: c.bgfx_index_buffer_handle_t,
    texture: c.bgfx_texture_handle_t,
    sampler_uniform: c.bgfx_uniform_handle_t,
    index_count: u32,
    mvp: math.Mat4,
};

// Node dispatch for the harness graph: the schedule orders asset upload,
// transform update, and submit; execution walks that order every frame.
const NodePayload = union(enum) {
    asset_source,
    transform,
    render_sink,
};

pub fn main(init_args: std.process.Init) !u8 {
    harness_io = init_args.io;
    const gpa = init_args.gpa;

    // Parse the asset through the same adapter a lens bundle uses.
    const glb = try buildTexturedQuadGlb(gpa);
    defer gpa.free(glb);
    var asset = try gltf.Asset.parse(gpa, glb);
    defer asset.deinit();

    const prim = asset.mesh(0).primitive(0);
    var positions: [4][3]f32 = undefined;
    var uvs: [4][2]f32 = undefined;
    var indices16: [6]u16 = undefined;
    var indices32: [6]u32 = undefined;
    if (try prim.readPositions(&positions) != 4) return error.BadAsset;
    if (try prim.readTexcoords(&uvs) != 4) return error.BadAsset;
    if (try prim.readIndices(&indices32) != 6) return error.BadAsset;
    for (indices32, 0..) |index, i| indices16[i] = @intCast(index);

    const png = asset.imageBytes(0) orelse return error.BadAsset;
    var decoded: [*c]u8 = null;
    var tex_w: c_uint = 0;
    var tex_h: c_uint = 0;
    if (c.lodepng_decode32(&decoded, &tex_w, &tex_h, png.ptr, png.len) != 0) return error.BadPng;
    defer std.c.free(decoded);
    std.debug.print("harness: asset quad with {d}x{d} texture from embedded png\n", .{ tex_w, tex_h });

    if (c.glfwInit() == c.GLFW_FALSE) return error.GlfwInit;
    defer c.glfwTerminate();
    c.glfwWindowHint(c.GLFW_CLIENT_API, c.GLFW_NO_API);
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "camera-kit harness", null, null) orelse return error.WindowCreate;
    defer c.glfwDestroyWindow(window);

    var init: c.bgfx_init_t = undefined;
    c.bgfx_init_ctor(&init);
    init.type = c.BGFX_RENDERER_TYPE_METAL;
    init.resolution.width = width;
    init.resolution.height = height;
    init.resolution.reset = c.BGFX_RESET_VSYNC;
    init.platformData.nwh = glfwGetCocoaWindow(window);
    init.callback = &Callbacks.iface;
    if (!c.bgfx_init(&init)) return error.BgfxInit;
    defer c.bgfx_shutdown();
    std.debug.print("harness: renderer {s}\n", .{c.bgfx_get_renderer_name(c.bgfx_get_renderer_type())});

    // GPU resources for the scene.
    var layout: c.bgfx_vertex_layout_t = undefined;
    _ = c.bgfx_vertex_layout_begin(&layout, c.BGFX_RENDERER_TYPE_NOOP);
    _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_POSITION, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
    _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_TEXCOORD0, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
    c.bgfx_vertex_layout_end(&layout);

    var vertex_data: [4][5]f32 = undefined;
    for (0..4) |i| {
        vertex_data[i] = .{ positions[i][0], positions[i][1], positions[i][2], uvs[i][0], uvs[i][1] };
    }
    const vbh = c.bgfx_create_vertex_buffer(c.bgfx_copy(&vertex_data, @sizeOf(@TypeOf(vertex_data))), &layout, c.BGFX_BUFFER_NONE);
    const ibh = c.bgfx_create_index_buffer(c.bgfx_copy(&indices16, @sizeOf(@TypeOf(indices16))), c.BGFX_BUFFER_NONE);
    const texture = c.bgfx_create_texture_2d(
        @intCast(tex_w),
        @intCast(tex_h),
        false,
        1,
        c.BGFX_TEXTURE_FORMAT_RGBA8,
        c.BGFX_SAMPLER_MIN_POINT | c.BGFX_SAMPLER_MAG_POINT | c.BGFX_SAMPLER_MIP_POINT,
        c.bgfx_copy(decoded, tex_w * tex_h * 4),
        0,
    );
    const sampler_uniform = c.bgfx_create_uniform("s_texColor", c.BGFX_UNIFORM_TYPE_SAMPLER, 1);

    const vs_blob = try buildShaderBlob(gpa, 'V', &.{
        .{ .name = "u_modelViewProj", .kind = 0x04, .num = 1, .reg_index = 0, .reg_count = 4 },
    }, vertex_msl);
    defer gpa.free(vs_blob);
    const fs_blob = try buildShaderBlob(gpa, 'F', &.{
        .{ .name = "s_texColorSampler", .kind = 0x11, .num = 1, .reg_index = 0xffff, .reg_count = 1 },
        .{ .name = "s_texColorTexture", .kind = 0x11, .num = 1, .reg_index = 0xffff, .reg_count = 1 },
        .{ .name = "s_texColor", .kind = 0x10, .num = 0, .reg_index = 0, .reg_count = 0 },
    }, fragment_msl);
    defer gpa.free(fs_blob);
    const vsh = c.bgfx_create_shader(c.bgfx_copy(vs_blob.ptr, @intCast(vs_blob.len)));
    const fsh = c.bgfx_create_shader(c.bgfx_copy(fs_blob.ptr, @intCast(fs_blob.len)));
    const program = c.bgfx_create_program(vsh, fsh, true);
    if (program.idx == std.math.maxInt(u16)) return error.ProgramCreate;

    var scene: Scene = .{
        .program = program,
        .vertex_buffer = vbh,
        .index_buffer = ibh,
        .texture = texture,
        .sampler_uniform = sampler_uniform,
        .index_count = 6,
        .mvp = undefined,
    };

    // The frame graph orders the work: asset source feeds the transform,
    // the transform feeds the render sink.
    var frame_graph = graph.Graph.init(gpa);
    defer frame_graph.deinit();
    const source_node = try frame_graph.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .buffer }} });
    const transform_node = try frame_graph.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .buffer }}, .outputs = &.{.{ .kind = .buffer }} });
    const sink_node = try frame_graph.addNode(.{ .role = .sink, .inputs = &.{.{ .kind = .buffer }} });
    try frame_graph.connect(source_node, 0, transform_node, 0);
    try frame_graph.connect(transform_node, 0, sink_node, 0);
    var payloads = [_]NodePayload{ .asset_source, .transform, .render_sink };
    payloads[source_node] = .asset_source;
    payloads[transform_node] = .transform;
    payloads[sink_node] = .render_sink;
    const order = try frame_graph.executionOrder();
    std.debug.print("harness: graph schedule has {d} nodes\n", .{order.len});

    c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x202020ff, 1.0, 0);
    c.bgfx_set_view_rect(0, 0, 0, @intCast(width), @intCast(height));

    var frame: u32 = 0;
    while (frame < 90 and c.glfwWindowShouldClose(window) == c.GLFW_FALSE) : (frame += 1) {
        c.glfwPollEvents();
        c.bgfx_touch(0);
        for (order) |node_index| {
            switch (payloads[node_index]) {
                .asset_source => {},
                .transform => {
                    const view = math.Mat4.identity;
                    const proj = math.Mat4.ortho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0, .zero_to_one);
                    c.bgfx_set_view_transform(0, &view.cols, &proj.cols);
                    scene.mvp = math.Mat4.identity;
                },
                .render_sink => {
                    _ = c.bgfx_set_transform(&scene.mvp.cols, 1);
                    c.bgfx_set_vertex_buffer(0, scene.vertex_buffer, 0, 4);
                    c.bgfx_set_index_buffer(scene.index_buffer, 0, scene.index_count);
                    c.bgfx_set_texture(0, scene.sampler_uniform, scene.texture, std.math.maxInt(u32));
                    c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                    c.bgfx_submit(0, scene.program, 0, c.BGFX_DISCARD_ALL);
                },
            }
        }
        if (frame == 60) {
            c.bgfx_request_screen_shot(.{ .idx = std.math.maxInt(u16) }, screenshot_path);
        }
        _ = c.bgfx_frame(0);
    }

    if (!screenshot_written) {
        std.debug.print("harness: FAIL no screenshot was produced\n", .{});
        return 1;
    }

    const shot = try std.Io.Dir.cwd().readFileAlloc(harness_io, screenshot_path, gpa, .limited(32 << 20));
    defer gpa.free(shot);
    const pixels = std.mem.indexOf(u8, shot, "255\n").? + 4;

    const sample = struct {
        fn at(data: []const u8, base: usize, x: u32, y: u32) [3]u8 {
            const offset = base + (@as(usize, y) * width + x) * 3;
            return .{ data[offset], data[offset + 1], data[offset + 2] };
        }
    };
    // Quad spans 200..600 x 150..450; checker squares are 200x150 pixels.
    const background = sample.at(shot, pixels, 60, 60);
    const first_square = sample.at(shot, pixels, 300, 220);
    const second_square = sample.at(shot, pixels, 500, 220);
    std.debug.print("harness: background {any} first {any} second {any}\n", .{ background, first_square, second_square });

    const background_ok = background[0] < 60 and background[1] < 60 and background[2] < 60;
    const white_ok = (first_square[0] > 200 and first_square[1] > 200 and first_square[2] > 200) or
        (second_square[0] > 200 and second_square[1] > 200 and second_square[2] > 200);
    const red_ok = (first_square[0] > 200 and first_square[1] < 60 and first_square[2] < 60) or
        (second_square[0] > 200 and second_square[1] < 60 and second_square[2] < 60);
    if (background_ok and white_ok and red_ok) {
        std.debug.print("harness: PROOF textured gltf drawn through the graph and read back\n", .{});
        return 0;
    }
    std.debug.print("harness: FAIL pixels do not show the textured quad\n", .{});
    return 1;
}
