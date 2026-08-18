//! Desktop harness: draws a textured glTF asset through the frame graph on
//! screen with the real render stack, and proves what it drew by reading the
//! pixels back. This is the acceptance surface for the render and asset
//! adapters; nothing merges on a promise here.

const std = @import("std");
const blobs = @import("shader_blobs");
const graph = @import("graph");
const math = @import("math");
const gltf = @import("gltf");
const render = @import("render");

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
const screenshot_path2 = "zig-out/harness-frame-chain.ppm";
const screenshot_path3 = "zig-out/harness-frame-lut.ppm";
const screenshot_path4 = "zig-out/harness-frame-blend.ppm";

var screenshot_written: bool = false;
var screenshot_written2: bool = false;
var screenshot_written3: bool = false;
var screenshot_written4: bool = false;
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
        const path_slice = std.mem.span(@as([*:0]const u8, @ptrCast(path)));
        writePpm(path_slice, shot_width, shot_height, pitch, @ptrCast(data.?), yflip) catch |err| {
            std.debug.print("harness: screenshot write failed: {t}\n", .{err});
            return;
        };
        if (std.mem.eql(u8, path_slice, screenshot_path)) {
            screenshot_written = true;
        } else if (std.mem.eql(u8, path_slice, screenshot_path2)) {
            screenshot_written2 = true;
        } else if (std.mem.eql(u8, path_slice, screenshot_path3)) {
            screenshot_written3 = true;
        } else {
            screenshot_written4 = true;
        }
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
    const window = c.glfwCreateWindow(@intCast(width), @intCast(height), "gosslens harness", null, null) orelse return error.WindowCreate;
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

    const vs_blob = blobs.vs_preview_metal;
    const fs_blob = blobs.fs_preview_rgba_metal;
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

    const ortho_view = math.Mat4.identity;
    const ortho_proj = math.Mat4.ortho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0, .zero_to_one);

    // The packaged tint reference lens, loaded here (not after the loop)
    // so the render loop below can draw a real, end-to-end shader.pass
    // chain every frame: the same quad scene captured into an offscreen
    // target, then a full-screen pass reading that target through this
    // program and writing the swap chain - the same sequence
    // goss_engine_render_frame drives for an active lens with shader
    // passes, proven here against a real Metal-backed renderer the
    // headless tracking harness cannot provide.
    const shader_tag = try render.Renderer.currentShaderProfileTag();
    const shader_bin_path = try std.fmt.allocPrint(gpa, ".lens-packages/shader-tint/shaders/tint.{s}.bin", .{shader_tag});
    defer gpa.free(shader_bin_path);
    const shader_bytes = try std.Io.Dir.cwd().readFileAlloc(harness_io, shader_bin_path, gpa, .limited(256 * 1024));
    defer gpa.free(shader_bytes);
    const shader_program = try render.Renderer.loadLensProgram(shader_bytes);
    defer render.Renderer.destroyProgram(shader_program);
    if (shader_program.idx == std.math.maxInt(u16)) {
        std.debug.print("harness: FAIL shader-pass program invalid\n", .{});
        return 1;
    }

    // A lut.pass node's asset loader hands the render thread decoded
    // RGBA bytes (adapters/asset, off the calling thread) and this is
    // the call that turns them into the real GPU texture
    // goss_engine_render_frame's own poll makes: reusing the checker
    // image already decoded above rather than a second asset, since
    // the point here is proving createStaticTexture itself, not the
    // decode path adapters/image already has its own tests for.
    // Not explicitly destroyed, matching the checker texture above -
    // bgfx_shutdown reclaims both when the harness exits.
    const static_texture_proof = render.Renderer.createStaticTexture(@intCast(tex_w), @intCast(tex_h), decoded[0 .. @as(usize, tex_w) * tex_h * 4]);
    if (static_texture_proof.idx == std.math.maxInt(u16)) {
        std.debug.print("harness: FAIL static texture invalid\n", .{});
        return 1;
    }
    std.debug.print("harness: PROOF static texture created from decoded bytes (idx {d})\n", .{static_texture_proof.idx});
    std.debug.print("harness: PROOF shader-pass program created from packaged bytecode (idx {d})\n", .{shader_program.idx});

    const chain_target = try render.Renderer.createOffscreenTarget(@intCast(width), @intCast(height));
    defer render.Renderer.destroyOffscreenTarget(chain_target);
    const capture_view: c.bgfx_view_id_t = 5;
    const tint_view: c.bgfx_view_id_t = 6;
    render.Renderer.setViewTarget(capture_view, chain_target, @intCast(width), @intCast(height));
    c.bgfx_set_view_clear(capture_view, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x202020ff, 1.0, 0);
    render.Renderer.setViewTarget(tint_view, null, @intCast(width), @intCast(height));

    // The lut.pass proof: a solid-magenta "LUT" rather than a real
    // gradient one, so the expected output has one unambiguous answer
    // regardless of strip-LUT addressing math - any input color sampled
    // against a uniformly magenta texture reads back magenta, which
    // isolates what this proof actually cares about (submitLutPass
    // binds the right texture on the right unit and the fixed program
    // runs), not whether the strip-LUT arithmetic itself is exact.
    const magenta = [_]u8{ 255, 0, 255, 255 } ** 4;
    const lut_texture = render.Renderer.createStaticTexture(2, 2, &magenta);
    const lut_sampler_uniform = c.bgfx_create_uniform("s_texLut", c.BGFX_UNIFORM_TYPE_SAMPLER, 1);
    const lut_program = try render.Renderer.loadLutProgram();
    const lut_view: c.bgfx_view_id_t = 7;
    render.Renderer.setViewTarget(lut_view, null, @intCast(width), @intCast(height));

    // The blend.pass proof: a solid-cyan background and an all-zero mask,
    // so mix(background, frame, mask) collapses to exactly background
    // regardless of the offscreen capture's real content - the same
    // "isolate the binding, not the arithmetic" trick the LUT proof
    // above uses, here proving submitBlendPass binds background on unit
    // 1 and mask on unit 2 correctly (unit 0, the frame, is provably
    // ignored since mask=0 everywhere).
    const cyan = [_]u8{ 0, 255, 255, 255 } ** 4;
    const blend_background_texture = render.Renderer.createStaticTexture(2, 2, &cyan);
    const zero_mask = [_]u8{0} ** 4;
    const blend_mask_texture = render.Renderer.createMaskTexture(2, 2, &zero_mask);
    const blend_background_uniform = c.bgfx_create_uniform("s_texBackground", c.BGFX_UNIFORM_TYPE_SAMPLER, 1);
    const blend_mask_uniform = c.bgfx_create_uniform("s_texMask", c.BGFX_UNIFORM_TYPE_SAMPLER, 1);
    const blend_program = try render.Renderer.loadBlendProgram();
    const blend_view: c.bgfx_view_id_t = 8;
    render.Renderer.setViewTarget(blend_view, null, @intCast(width), @intCast(height));

    var frame: u32 = 0;
    while (frame < 105 and c.glfwWindowShouldClose(window) == c.GLFW_FALSE) : (frame += 1) {
        c.glfwPollEvents();
        c.bgfx_touch(0);
        for (order) |node_index| {
            switch (payloads[node_index]) {
                .asset_source => {},
                .transform => {
                    c.bgfx_set_view_transform(0, &ortho_view.cols, &ortho_proj.cols);
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

        // The chain proof starts only once the plain-preview screenshot
        // above is captured: view 6 below is a full-screen opaque draw
        // over the same viewport as view 0, so submitting it any
        // earlier would overwrite view 0's own output before frame 60
        // reads it back.
        if (frame > 60) {
            // Same quad scene, captured into the offscreen target
            // instead of the swap chain.
            c.bgfx_set_view_transform(capture_view, &ortho_view.cols, &ortho_proj.cols);
            _ = c.bgfx_set_transform(&math.Mat4.identity.cols, 1);
            c.bgfx_set_vertex_buffer(0, scene.vertex_buffer, 0, 4);
            c.bgfx_set_index_buffer(scene.index_buffer, 0, scene.index_count);
            c.bgfx_set_texture(0, scene.sampler_uniform, scene.texture, std.math.maxInt(u32));
            c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
            c.bgfx_submit(capture_view, scene.program, 0, c.BGFX_DISCARD_ALL);

            // The tint pass: a full-screen quad sampling the capture,
            // drawn with the packaged program, presenting to the swap
            // chain.
            var chain_tvb: c.bgfx_transient_vertex_buffer_t = undefined;
            var chain_tib: c.bgfx_transient_index_buffer_t = undefined;
            if (c.bgfx_get_avail_transient_vertex_buffer(4, &layout) >= 4 and c.bgfx_get_avail_transient_index_buffer(6, false) >= 6) {
                c.bgfx_alloc_transient_vertex_buffer(&chain_tvb, 4, &layout);
                c.bgfx_alloc_transient_index_buffer(&chain_tib, 6, false);
                const chain_verts: [*][5]f32 = @ptrCast(@alignCast(chain_tvb.data));
                chain_verts[0] = .{ -1.0, -1.0, 0.0, 0.0, 1.0 };
                chain_verts[1] = .{ 1.0, -1.0, 0.0, 1.0, 1.0 };
                chain_verts[2] = .{ 1.0, 1.0, 0.0, 1.0, 0.0 };
                chain_verts[3] = .{ -1.0, 1.0, 0.0, 0.0, 0.0 };
                const chain_idx: [*]u16 = @ptrCast(@alignCast(chain_tib.data));
                for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, vi| chain_idx[vi] = v;
                c.bgfx_set_view_transform(tint_view, &ortho_view.cols, &ortho_proj.cols);
                _ = c.bgfx_set_transform(&math.Mat4.identity.cols, 1);
                c.bgfx_set_transient_vertex_buffer(0, &chain_tvb, 0, 4);
                c.bgfx_set_transient_index_buffer(&chain_tib, 0, 6);
                // chain_target.texture is render.zig's own @cImport'd
                // handle type - structurally identical to this file's,
                // but a distinct Zig type since each @cImport is its own
                // namespace. Same bgfx.h layout (one uint16_t), so a
                // bitcast is exact, not a reinterpretation of anything.
                c.bgfx_set_texture(0, scene.sampler_uniform, @bitCast(chain_target.texture), std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(tint_view, @bitCast(shader_program), 0, c.BGFX_DISCARD_ALL);
            }
        }

        if (frame == 75) {
            c.bgfx_request_screen_shot(.{ .idx = std.math.maxInt(u16) }, screenshot_path2);
        }

        // The lut.pass proof starts only once the chain screenshot
        // above is captured, for the same reason the chain proof
        // itself waited on the plain-preview one: view 7 is another
        // full-screen opaque draw over the same viewport.
        if (frame > 75) {
            var lut_tvb: c.bgfx_transient_vertex_buffer_t = undefined;
            var lut_tib: c.bgfx_transient_index_buffer_t = undefined;
            if (c.bgfx_get_avail_transient_vertex_buffer(4, &layout) >= 4 and c.bgfx_get_avail_transient_index_buffer(6, false) >= 6) {
                c.bgfx_alloc_transient_vertex_buffer(&lut_tvb, 4, &layout);
                c.bgfx_alloc_transient_index_buffer(&lut_tib, 6, false);
                const lut_verts: [*][5]f32 = @ptrCast(@alignCast(lut_tvb.data));
                lut_verts[0] = .{ -1.0, -1.0, 0.0, 0.0, 1.0 };
                lut_verts[1] = .{ 1.0, -1.0, 0.0, 1.0, 1.0 };
                lut_verts[2] = .{ 1.0, 1.0, 0.0, 1.0, 0.0 };
                lut_verts[3] = .{ -1.0, 1.0, 0.0, 0.0, 0.0 };
                const lut_idx: [*]u16 = @ptrCast(@alignCast(lut_tib.data));
                for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, vi| lut_idx[vi] = v;
                c.bgfx_set_view_transform(lut_view, &ortho_view.cols, &ortho_proj.cols);
                _ = c.bgfx_set_transform(&math.Mat4.identity.cols, 1);
                c.bgfx_set_transient_vertex_buffer(0, &lut_tvb, 0, 4);
                c.bgfx_set_transient_index_buffer(&lut_tib, 0, 6);
                // Input on unit 0 (the same offscreen capture the tint
                // pass already reads), the solid-magenta "LUT" on
                // unit 1 - submitLutPass's own binding layout.
                c.bgfx_set_texture(0, scene.sampler_uniform, @bitCast(chain_target.texture), std.math.maxInt(u32));
                c.bgfx_set_texture(1, lut_sampler_uniform, @bitCast(lut_texture), std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(lut_view, @bitCast(lut_program), 0, c.BGFX_DISCARD_ALL);
            }
        }

        if (frame == 88) {
            c.bgfx_request_screen_shot(.{ .idx = std.math.maxInt(u16) }, screenshot_path3);
        }

        // The blend.pass proof starts only once the LUT screenshot above
        // is captured, same reasoning as every earlier proof phase: view
        // 8 is another full-screen opaque draw over the same viewport.
        if (frame > 88) {
            var blend_tvb: c.bgfx_transient_vertex_buffer_t = undefined;
            var blend_tib: c.bgfx_transient_index_buffer_t = undefined;
            if (c.bgfx_get_avail_transient_vertex_buffer(4, &layout) >= 4 and c.bgfx_get_avail_transient_index_buffer(6, false) >= 6) {
                c.bgfx_alloc_transient_vertex_buffer(&blend_tvb, 4, &layout);
                c.bgfx_alloc_transient_index_buffer(&blend_tib, 6, false);
                const blend_verts: [*][5]f32 = @ptrCast(@alignCast(blend_tvb.data));
                blend_verts[0] = .{ -1.0, -1.0, 0.0, 0.0, 1.0 };
                blend_verts[1] = .{ 1.0, -1.0, 0.0, 1.0, 1.0 };
                blend_verts[2] = .{ 1.0, 1.0, 0.0, 1.0, 0.0 };
                blend_verts[3] = .{ -1.0, 1.0, 0.0, 0.0, 0.0 };
                const blend_idx: [*]u16 = @ptrCast(@alignCast(blend_tib.data));
                for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, vi| blend_idx[vi] = v;
                c.bgfx_set_view_transform(blend_view, &ortho_view.cols, &ortho_proj.cols);
                _ = c.bgfx_set_transform(&math.Mat4.identity.cols, 1);
                c.bgfx_set_transient_vertex_buffer(0, &blend_tvb, 0, 4);
                c.bgfx_set_transient_index_buffer(&blend_tib, 0, 6);
                // Input on unit 0 (ignored, since mask=0), solid-cyan
                // background on unit 1, all-zero mask on unit 2 -
                // submitBlendPass's own binding layout.
                c.bgfx_set_texture(0, scene.sampler_uniform, @bitCast(chain_target.texture), std.math.maxInt(u32));
                c.bgfx_set_texture(1, blend_background_uniform, @bitCast(blend_background_texture), std.math.maxInt(u32));
                c.bgfx_set_texture(2, blend_mask_uniform, @bitCast(blend_mask_texture), std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(blend_view, @bitCast(blend_program), 0, c.BGFX_DISCARD_ALL);
            }
        }

        if (frame == 101) {
            c.bgfx_request_screen_shot(.{ .idx = std.math.maxInt(u16) }, screenshot_path4);
        }
        _ = c.bgfx_frame(0);
    }

    if (!screenshot_written or !screenshot_written2 or !screenshot_written3 or !screenshot_written4) {
        std.debug.print("harness: FAIL a screenshot was not produced\n", .{});
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
    if (!(background_ok and white_ok and red_ok)) {
        std.debug.print("harness: FAIL unexpected pixels\n", .{});
        return 1;
    }
    std.debug.print("harness: PROOF textured gltf drawn through the graph and read back\n", .{});

    // The second capture: the same quad, but only reachable by way of
    // the offscreen target and tint pass above. If the chain is wired
    // correctly, whichever square was white in the untouched capture
    // now reads back warmed - red boosted, green and blue pulled down -
    // rather than pure white, proving the tint actually landed on the
    // swap chain and not just that a program handle was valid.
    const chain_shot = try std.Io.Dir.cwd().readFileAlloc(harness_io, screenshot_path2, gpa, .limited(32 << 20));
    defer gpa.free(chain_shot);
    const chain_pixels = std.mem.indexOf(u8, chain_shot, "255\n").? + 4;

    const tinted = struct {
        fn matches(p: [3]u8) bool {
            return p[0] > 200 and p[1] > 180 and p[1] < 250 and p[2] > 150 and p[2] < 220 and p[0] > p[1] and p[1] > p[2];
        }
    }.matches;

    // Sample both squares at both the original and a vertically mirrored
    // y - an offscreen target's texture space is free to run either way
    // relative to the swap chain, and the chain must prove itself either
    // way, not assume one.
    var chain_ok = false;
    for ([2]u32{ 220, 380 }) |y| {
        for ([2]u32{ 300, 500 }) |x| {
            if (tinted(sample.at(chain_shot, chain_pixels, x, y))) chain_ok = true;
        }
    }
    if (!chain_ok) {
        std.debug.print("harness: FAIL shader-pass chain did not composite onto the swap chain\n", .{});
        return 1;
    }
    std.debug.print("harness: PROOF shader-pass chain rendered camera into an offscreen target, then the tint pass into the swap chain\n", .{});

    // The third capture: the same offscreen quad, this time through
    // submitLutPass's own binding layout with a solid-magenta "LUT" -
    // every sampled point must read back exactly magenta regardless of
    // whether it was originally background, white, or red, since a
    // uniform LUT texture returns the same color for any input. Any
    // other result means the pass sampled the wrong texture, the wrong
    // unit, or ran the wrong program.
    const lut_shot = try std.Io.Dir.cwd().readFileAlloc(harness_io, screenshot_path3, gpa, .limited(32 << 20));
    defer gpa.free(lut_shot);
    const lut_pixels = std.mem.indexOf(u8, lut_shot, "255\n").? + 4;

    const is_magenta = struct {
        fn matches(p: [3]u8) bool {
            return p[0] > 240 and p[1] < 20 and p[2] > 240;
        }
    }.matches;

    var lut_ok = true;
    for ([3]u32{ 60, 220, 380 }) |y| {
        for ([3]u32{ 60, 300, 500 }) |x| {
            const px = sample.at(lut_shot, lut_pixels, x, y);
            if (!is_magenta(px)) {
                std.debug.print("harness: FAIL lut-pass pixel at ({d},{d}) was {any}, expected magenta\n", .{ x, y, px });
                lut_ok = false;
            }
        }
    }
    if (!lut_ok) return 1;
    std.debug.print("harness: PROOF lut-pass sampled the LUT texture on its own unit through the fixed program, landing on the swap chain\n", .{});

    // The fourth capture: the same offscreen quad through submitBlendPass's
    // own binding layout, background solid cyan and mask all zero - every
    // sampled point must read back exactly cyan regardless of the frame
    // underneath it, since mix(background, frame, 0.0) always yields
    // background. Any other result means the pass sampled the wrong
    // texture, the wrong unit, or ran the wrong program.
    const blend_shot = try std.Io.Dir.cwd().readFileAlloc(harness_io, screenshot_path4, gpa, .limited(32 << 20));
    defer gpa.free(blend_shot);
    const blend_pixels = std.mem.indexOf(u8, blend_shot, "255\n").? + 4;

    const is_cyan = struct {
        fn matches(p: [3]u8) bool {
            return p[0] < 20 and p[1] > 240 and p[2] > 240;
        }
    }.matches;

    var blend_ok = true;
    for ([3]u32{ 60, 220, 380 }) |y| {
        for ([3]u32{ 60, 300, 500 }) |x| {
            const px = sample.at(blend_shot, blend_pixels, x, y);
            if (!is_cyan(px)) {
                std.debug.print("harness: FAIL blend-pass pixel at ({d},{d}) was {any}, expected cyan\n", .{ x, y, px });
                blend_ok = false;
            }
        }
    }
    if (!blend_ok) return 1;
    std.debug.print("harness: PROOF blend-pass sampled the background and mask textures on their own units through the fixed program, landing on the swap chain\n", .{});
    return 0;
}
