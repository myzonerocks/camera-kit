//! The render backend node: the one binding over bgfx. Owns renderer
//! lifecycle, the preview pipeline, and shader assembly. Shells hand over a
//! native surface and zero-copy camera textures; everything after that
//! happens here. Frame-path work allocates nothing after the pipelines are
//! built: transient quad vertices come from bgfx's bounded pools.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("math");

pub const c = @cImport({
    @cInclude("bgfx/c99/bgfx.h");
});

pub const invalid_handle: u16 = std.math.maxInt(u16);

// Shader blobs in the exact binary layout bgfx parses: magic VSH/FSH
// version 11, in/out hashes, the uniform table, then platform shader source
// compiled by the driver at load. The lens shader toolchain replaces hand
// assembly when it lands; the format itself is what shaderc emits.
pub const ShaderUniform = struct {
    name: []const u8,
    kind: u8,
    num: u8,
    reg_index: u16,
    reg_count: u16,
};

pub fn buildShaderBlob(gpa: std.mem.Allocator, kind: u8, uniforms: []const ShaderUniform, source: []const u8) ![]u8 {
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

pub fn samplerUniformTriple(comptime name: []const u8) [3]ShaderUniform {
    return .{
        .{ .name = name ++ "Sampler", .kind = 0x11, .num = 1, .reg_index = 0xffff, .reg_count = 1 },
        .{ .name = name ++ "Texture", .kind = 0x11, .num = 1, .reg_index = 0xffff, .reg_count = 1 },
        .{ .name = name, .kind = 0x10, .num = 0, .reg_index = 0, .reg_count = 0 },
    };
}

const preview_vertex_essl =
    \\attribute highp vec3 a_position;
    \\attribute highp vec2 a_texcoord0;
    \\varying highp vec2 v_texcoord0;
    \\uniform highp mat4 u_modelViewProj;
    \\void main ()
    \\{
    \\  gl_Position = (u_modelViewProj * vec4(a_position, 1.0));
    \\  v_texcoord0 = a_texcoord0;
    \\}
    \\
;

const rgba_fragment_essl =
    \\varying highp vec2 v_texcoord0;
    \\uniform sampler2D s_texColor;
    \\void main ()
    \\{
    \\  gl_FragColor = texture2D(s_texColor, v_texcoord0);
    \\}
    \\
;

const nv12_fragment_essl =
    \\varying highp vec2 v_texcoord0;
    \\uniform sampler2D s_texY;
    \\uniform sampler2D s_texUV;
    \\uniform highp mat4 u_yuvTransform;
    \\void main ()
    \\{
    \\  highp float y = texture2D(s_texY, v_texcoord0).r;
    \\  highp vec2 uv = texture2D(s_texUV, v_texcoord0).rg;
    \\  highp vec3 rgb = (u_yuvTransform * vec4(y, uv.x, uv.y, 1.0)).rgb;
    \\  gl_FragColor = vec4(rgb, 1.0);
    \\}
    \\
;

const preview_vertex_msl =
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

const rgba_fragment_msl =
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

// Two-plane YCbCr sampled and converted with the exact affine map from the
// math module, passed as one homogeneous matrix: rgb = (M * float4(yuv, 1)).
const nv12_fragment_msl =
    \\#include <metal_stdlib>
    \\#include <simd/simd.h>
    \\
    \\using namespace metal;
    \\
    \\struct _Global
    \\{
    \\    float4x4 u_yuvTransform;
    \\};
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
    \\fragment xlatMtlMain_out xlatMtlMain(xlatMtlMain_in in [[stage_in]], constant _Global& _mtl_u [[buffer(0)]], texture2d<float> s_texY [[texture(0)]], sampler s_texYSampler [[sampler(0)]], texture2d<float> s_texUV [[texture(1)]], sampler s_texUVSampler [[sampler(1)]])
    \\{
    \\    xlatMtlMain_out out = {};
    \\    float y = s_texY.sample(s_texYSampler, in.v_texcoord0).r;
    \\    float2 uv = s_texUV.sample(s_texUVSampler, in.v_texcoord0).rg;
    \\    float3 rgb = (_mtl_u.u_yuvTransform * float4(y, uv.x, uv.y, 1.0)).rgb;
    \\    out.bgfx_FragData0 = float4(rgb, 1.0);
    \\    return out;
    \\}
    \\
;

/// The affine color conversion as one homogeneous matrix for the shader.
pub fn yuvTransform(conversion: math.color.Conversion) math.Mat4 {
    return conversion.homogeneous();
}

pub const InitOptions = struct {
    native_window_handle: ?*anyopaque,
    width: u32,
    height: u32,
    callback: ?*c.bgfx_callback_interface_t = null,
    vsync: bool = true,
};

pub const Nv12Textures = struct {
    y: c.bgfx_texture_handle_t,
    uv: c.bgfx_texture_handle_t,
};

const UploadCache = struct {
    y: c.bgfx_texture_handle_t,
    uv: c.bgfx_texture_handle_t,
    width: u16,
    height: u16,
};

pub const PreviewFrame = union(enum) {
    bgra: struct {
        texture: c.bgfx_texture_handle_t,
    },
    nv12: struct {
        y: c.bgfx_texture_handle_t,
        uv: c.bgfx_texture_handle_t,
        conversion: math.color.Conversion,
    },
};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    width: u32,
    height: u32,
    layout: c.bgfx_vertex_layout_t,
    rgba_program: c.bgfx_program_handle_t,
    nv12_program: c.bgfx_program_handle_t,
    tex_color: c.bgfx_uniform_handle_t,
    tex_y: c.bgfx_uniform_handle_t,
    tex_uv: c.bgfx_uniform_handle_t,
    yuv_uniform: c.bgfx_uniform_handle_t,
    upload_cache: ?UploadCache = null,

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) !Renderer {
        var bgfx_init: c.bgfx_init_t = undefined;
        c.bgfx_init_ctor(&bgfx_init);
        // Metal on apple targets. Android runs the GL backend until the
        // shader toolchain brings SPIR-V for Vulkan.
        bgfx_init.type = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
            c.BGFX_RENDERER_TYPE_METAL
        else if (builtin.os.tag == .linux and builtin.abi.isAndroid())
            c.BGFX_RENDERER_TYPE_OPENGLES
        else
            c.BGFX_RENDERER_TYPE_COUNT;
        bgfx_init.resolution.width = options.width;
        bgfx_init.resolution.height = options.height;
        bgfx_init.resolution.reset = if (options.vsync) c.BGFX_RESET_VSYNC else c.BGFX_RESET_NONE;
        bgfx_init.platformData.nwh = options.native_window_handle;
        bgfx_init.callback = options.callback;
        if (!c.bgfx_init(&bgfx_init)) return error.RendererInit;
        errdefer c.bgfx_shutdown();

        var layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_POSITION, 3, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        _ = c.bgfx_vertex_layout_add(&layout, c.BGFX_ATTRIB_TEXCOORD0, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&layout);

        const mvp_uniform = [_]ShaderUniform{
            .{ .name = "u_modelViewProj", .kind = 0x04, .num = 1, .reg_index = 0, .reg_count = 4 },
        };
        const backend = c.bgfx_get_renderer_type();
        const rgba_program, const nv12_program = switch (backend) {
            c.BGFX_RENDERER_TYPE_METAL => .{
                try makeProgram(gpa, &mvp_uniform, &samplerUniformTriple("s_texColor"), preview_vertex_msl, rgba_fragment_msl),
                try makeProgram(gpa, &mvp_uniform, &(.{
                    ShaderUniform{ .name = "u_yuvTransform", .kind = 0x14, .num = 1, .reg_index = 0, .reg_count = 4 },
                } ++ samplerUniformTriple("s_texY") ++ samplerUniformTriple("s_texUV")), preview_vertex_msl, nv12_fragment_msl),
            },
            c.BGFX_RENDERER_TYPE_OPENGLES => .{
                try makeProgram(gpa, &mvp_uniform, &.{
                    .{ .name = "s_texColor", .kind = 0x00, .num = 1, .reg_index = 0, .reg_count = 1 },
                }, preview_vertex_essl, rgba_fragment_essl),
                try makeProgram(gpa, &mvp_uniform, &.{
                    .{ .name = "u_yuvTransform", .kind = 0x14, .num = 1, .reg_index = 0, .reg_count = 4 },
                    .{ .name = "s_texY", .kind = 0x00, .num = 1, .reg_index = 0, .reg_count = 1 },
                    .{ .name = "s_texUV", .kind = 0x00, .num = 1, .reg_index = 1, .reg_count = 1 },
                }, preview_vertex_essl, nv12_fragment_essl),
            },
            else => return error.RendererUnsupported,
        };

        c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x000000ff, 1.0, 0);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(options.width), @intCast(options.height));

        return .{
            .gpa = gpa,
            .width = options.width,
            .height = options.height,
            .layout = layout,
            .rgba_program = rgba_program,
            .nv12_program = nv12_program,
            .tex_color = c.bgfx_create_uniform("s_texColor", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_y = c.bgfx_create_uniform("s_texY", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_uv = c.bgfx_create_uniform("s_texUV", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .yuv_uniform = c.bgfx_create_uniform("u_yuvTransform", c.BGFX_UNIFORM_TYPE_MAT4, 1),
        };
    }

    fn makeProgram(gpa: std.mem.Allocator, vs_uniforms: []const ShaderUniform, fs_uniforms: []const ShaderUniform, vertex_source: []const u8, fragment_source: []const u8) !c.bgfx_program_handle_t {
        const vs_blob = try buildShaderBlob(gpa, 'V', vs_uniforms, vertex_source);
        defer gpa.free(vs_blob);
        const fs_blob = try buildShaderBlob(gpa, 'F', fs_uniforms, fragment_source);
        defer gpa.free(fs_blob);
        const vsh = c.bgfx_create_shader(c.bgfx_copy(vs_blob.ptr, @intCast(vs_blob.len)));
        const fsh = c.bgfx_create_shader(c.bgfx_copy(fs_blob.ptr, @intCast(fs_blob.len)));
        const program = c.bgfx_create_program(vsh, fsh, true);
        if (program.idx == invalid_handle) return error.ProgramCreate;
        return program;
    }

    pub fn deinit(r: *Renderer) void {
        if (r.upload_cache) |cache| {
            c.bgfx_destroy_texture(cache.y);
            c.bgfx_destroy_texture(cache.uv);
        }
        c.bgfx_destroy_uniform(r.tex_color);
        c.bgfx_destroy_uniform(r.tex_y);
        c.bgfx_destroy_uniform(r.tex_uv);
        c.bgfx_destroy_uniform(r.yuv_uniform);
        c.bgfx_destroy_program(r.rgba_program);
        c.bgfx_destroy_program(r.nv12_program);
        c.bgfx_shutdown();
        r.* = undefined;
    }

    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        r.width = width;
        r.height = height;
        c.bgfx_reset(width, height, c.BGFX_RESET_VSYNC, c.BGFX_TEXTURE_FORMAT_COUNT);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(width), @intCast(height));
    }

    /// Wraps a platform texture (MTLTexture and friends) as a bgfx handle
    /// without copying pixels. The platform object must outlive the frame
    /// that samples it; the shell guarantees that by holding the buffer
    /// until the next frame completes.
    pub fn wrapExternalTexture(r: *Renderer, width: u16, height: u16, format: u32, native_ptr: usize) c.bgfx_texture_handle_t {
        _ = r;
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, format, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, null, 0);
        _ = c.bgfx_override_internal_texture_ptr(handle, native_ptr, 0);
        return handle;
    }

    pub fn destroyTexture(r: *Renderer, handle: c.bgfx_texture_handle_t) void {
        _ = r;
        if (handle.idx != invalid_handle) c.bgfx_destroy_texture(handle);
    }

    /// Draws the camera frame as the full-view preview. `rotation_degrees`
    /// spins the quad for sensor orientation; `mirror` flips horizontally
    /// for front cameras.
    pub fn submitPreview(r: *Renderer, preview: PreviewFrame, rotation_degrees: u32, mirror: bool) void {
        var tvb: c.bgfx_transient_vertex_buffer_t = undefined;
        var tib: c.bgfx_transient_index_buffer_t = undefined;
        if (c.bgfx_get_avail_transient_vertex_buffer(4, &r.layout) < 4) return;
        if (c.bgfx_get_avail_transient_index_buffer(6, false) < 6) return;
        c.bgfx_alloc_transient_vertex_buffer(&tvb, 4, &r.layout);
        c.bgfx_alloc_transient_index_buffer(&tib, 6, false);

        const verts: [*][5]f32 = @ptrCast(@alignCast(tvb.data));
        verts[0] = .{ -1.0, -1.0, 0.0, 0.0, 1.0 };
        verts[1] = .{ 1.0, -1.0, 0.0, 1.0, 1.0 };
        verts[2] = .{ 1.0, 1.0, 0.0, 1.0, 0.0 };
        verts[3] = .{ -1.0, 1.0, 0.0, 0.0, 0.0 };
        const idx: [*]u16 = @ptrCast(@alignCast(tib.data));
        for ([6]u16{ 0, 1, 2, 0, 2, 3 }, 0..) |v, i| idx[i] = v;

        const angle = math.scalar.radians(@floatFromInt(rotation_degrees));
        var mvp = math.Mat4.rotationZ(angle);
        if (mirror) {
            mvp = math.Mat4.mul(mvp, math.Mat4.scaling(.{ -1.0, 1.0, 1.0 }));
        }
        _ = c.bgfx_set_transform(&mvp.cols, 1);

        const view = math.Mat4.identity;
        const proj = math.Mat4.ortho(-1.0, 1.0, -1.0, 1.0, -1.0, 1.0, .zero_to_one);
        c.bgfx_set_view_transform(0, &view.cols, &proj.cols);

        c.bgfx_set_transient_vertex_buffer(0, &tvb, 0, 4);
        c.bgfx_set_transient_index_buffer(&tib, 0, 6);

        switch (preview) {
            .bgra => |f| {
                c.bgfx_set_texture(0, r.tex_color, f.texture, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(0, r.rgba_program, 0, c.BGFX_DISCARD_ALL);
            },
            .nv12 => |f| {
                const transform = yuvTransform(f.conversion);
                c.bgfx_set_uniform(r.yuv_uniform, &transform.cols, 1);
                c.bgfx_set_texture(0, r.tex_y, f.y, std.math.maxInt(u32));
                c.bgfx_set_texture(1, r.tex_uv, f.uv, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(0, r.nv12_program, 0, c.BGFX_DISCARD_ALL);
            },
        }
    }

    /// The stated CPU path: copies NV12 planes into two cached updatable
    /// textures, recreated only when the size changes. The row copies go
    /// through bgfx's frame allocator, freed after submission; the cache
    /// itself is two textures, bounded and freed at shutdown.
    pub fn uploadNv12(r: *Renderer, width: u16, height: u16, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) !Nv12Textures {
        if (r.upload_cache) |cache| {
            if (cache.width != width or cache.height != height) {
                c.bgfx_destroy_texture(cache.y);
                c.bgfx_destroy_texture(cache.uv);
                r.upload_cache = null;
            }
        }
        if (r.upload_cache == null) {
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
            r.upload_cache = .{
                .y = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_R8, flags, null, 0),
                .uv = c.bgfx_create_texture_2d(width / 2, height / 2, false, 1, c.BGFX_TEXTURE_FORMAT_RG8, flags, null, 0),
                .width = width,
                .height = height,
            };
        }
        const cache = r.upload_cache.?;

        const y_mem = c.bgfx_alloc(@as(u32, width) * height) orelse return error.OutOfMemory;
        const y_dst: [*]u8 = y_mem.*.data;
        for (0..height) |row| {
            @memcpy(y_dst[row * width ..][0..width], y[row * y_stride ..][0..width]);
        }
        c.bgfx_update_texture_2d(cache.y, 0, 0, 0, 0, width, height, y_mem, std.math.maxInt(u16));

        const uv_width: u32 = width;
        const uv_rows: u32 = height / 2;
        const uv_mem = c.bgfx_alloc(uv_width * uv_rows) orelse return error.OutOfMemory;
        const uv_dst: [*]u8 = uv_mem.*.data;
        for (0..uv_rows) |row| {
            @memcpy(uv_dst[row * uv_width ..][0..uv_width], uv[row * uv_stride ..][0..uv_width]);
        }
        c.bgfx_update_texture_2d(cache.uv, 0, 0, 0, 0, width / 2, height / 2, uv_mem, std.math.maxInt(u16));

        return .{ .y = cache.y, .uv = cache.uv };
    }

    pub fn touch(r: *Renderer) void {
        _ = r;
        c.bgfx_touch(0);
    }

    pub fn frame(r: *Renderer) u32 {
        _ = r;
        return c.bgfx_frame(0);
    }

    pub fn requestScreenshot(r: *Renderer, path: [*:0]const u8) void {
        _ = r;
        c.bgfx_request_screen_shot(.{ .idx = invalid_handle }, path);
    }
};

const t = std.testing;

test "shader blobs carry the exact header bgfx parses" {
    const blob = try buildShaderBlob(t.allocator, 'V', &.{
        .{ .name = "u_modelViewProj", .kind = 0x04, .num = 1, .reg_index = 0, .reg_count = 4 },
    }, "vertex source");
    defer t.allocator.free(blob);
    try t.expectEqualSlices(u8, &.{ 'V', 'S', 'H', 11 }, blob[0..4]);
    try t.expectEqual(@as(u16, 1), std.mem.readInt(u16, blob[12..14], .little));
    try t.expectEqual(@as(u8, 15), blob[14]);
    try t.expectEqualStrings("u_modelViewProj", blob[15..30]);
    const code_size_offset = 15 + 15 + 2 + 8;
    try t.expectEqual(@as(u32, "vertex source".len), std.mem.readInt(u32, blob[code_size_offset..][0..4], .little));
    try t.expectEqual(@as(u8, 0), blob[blob.len - 1]);
}

test "yuv transform embeds matrix and offset homogeneously" {
    const conv = math.color.yuvToRgb(.bt709, .video);
    const m = yuvTransform(conv);
    const rgb_direct = conv.apply(.{ 0.5, 0.4, 0.6 });
    const homogeneous = m.mulVec(.{ 0.5, 0.4, 0.6, 1.0 });
    try t.expect(math.vec.approxEq(rgb_direct, math.vec.vec3From4(homogeneous), 1.0e-6));
}

test "sampler triple matches the metal naming convention" {
    const triple = samplerUniformTriple("s_texY");
    try t.expectEqualStrings("s_texYSampler", triple[0].name);
    try t.expectEqualStrings("s_texYTexture", triple[1].name);
    try t.expectEqualStrings("s_texY", triple[2].name);
    try t.expectEqual(@as(u8, 0x11), triple[0].kind);
    try t.expectEqual(@as(u8, 0x10), triple[2].kind);
}
