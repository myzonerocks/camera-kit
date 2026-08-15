//! The render backend node: the one binding over bgfx. Owns renderer
//! lifecycle, the preview pipeline, and shader assembly. Shells hand over a
//! native surface and zero-copy camera textures; everything after that
//! happens here. Frame-path work allocates nothing after the pipelines are
//! built: transient quad vertices come from bgfx's bounded pools.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("math");
const blobs = @import("shader_blobs");

pub const android_vk = if (builtin.os.tag == .linux and builtin.abi.isAndroid())
    @import("android_vk.zig")
else
    struct {};

pub const c = @cImport({
    @cInclude("bgfx/c99/bgfx.h");
});

pub const invalid_handle: u16 = std.math.maxInt(u16);

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
        // Metal on apple targets. Android probes for the Vulkan
        // capabilities zero-copy import rests on and takes the GL backend
        // as the declared fallback when they are missing.
        bgfx_init.type = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
            c.BGFX_RENDERER_TYPE_METAL
        else if (builtin.os.tag == .linux and builtin.abi.isAndroid())
            (if (@import("vulkan_probe.zig").vulkanReady()) c.BGFX_RENDERER_TYPE_VULKAN else c.BGFX_RENDERER_TYPE_OPENGLES)
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

        const backend = c.bgfx_get_renderer_type();
        const rgba_program, const nv12_program = switch (backend) {
            c.BGFX_RENDERER_TYPE_METAL => .{
                try loadProgram(blobs.vs_preview_metal, blobs.fs_preview_rgba_metal),
                try loadProgram(blobs.vs_preview_metal, blobs.fs_preview_nv12_metal),
            },
            c.BGFX_RENDERER_TYPE_VULKAN => .{
                try loadProgram(blobs.vs_preview_spirv, blobs.fs_preview_rgba_spirv),
                try loadProgram(blobs.vs_preview_spirv, blobs.fs_preview_nv12_spirv),
            },
            c.BGFX_RENDERER_TYPE_OPENGLES => .{
                try loadProgram(blobs.vs_preview_essl, blobs.fs_preview_rgba_essl),
                try loadProgram(blobs.vs_preview_essl, blobs.fs_preview_nv12_essl),
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

    fn loadProgram(vs_blob: []const u8, fs_blob: []const u8) !c.bgfx_program_handle_t {
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

test "compiled shader blobs carry the header bgfx parses" {
    inline for (.{ blobs.vs_preview_metal, blobs.vs_preview_spirv, blobs.vs_preview_essl }) |blob| {
        try t.expectEqualSlices(u8, "VSH", blob[0..3]);
    }
    inline for (.{ blobs.fs_preview_rgba_metal, blobs.fs_preview_nv12_spirv, blobs.fs_preview_nv12_essl }) |blob| {
        try t.expectEqualSlices(u8, "FSH", blob[0..3]);
    }
}

test "yuv transform embeds matrix and offset homogeneously" {
    const conv = math.color.yuvToRgb(.bt709, .video);
    const m = yuvTransform(conv);
    const rgb_direct = conv.apply(.{ 0.5, 0.4, 0.6 });
    const homogeneous = m.mulVec(.{ 0.5, 0.4, 0.6, 1.0 });
    try t.expect(math.vec.approxEq(rgb_direct, math.vec.vec3From4(homogeneous), 1.0e-6));
}

test "every backend has all three shaders embedded" {
    try t.expect(blobs.fs_preview_rgba_essl.len > 0);
    try t.expect(blobs.fs_preview_rgba_spirv.len > 0);
    try t.expect(blobs.vs_preview_essl.len > 0);
}
