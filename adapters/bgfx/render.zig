//! The render backend node: the one binding over bgfx. Owns renderer
//! lifecycle, the preview pipeline, and shader assembly. SDKs hand over a
//! native surface and zero-copy camera textures; everything after that
//! happens here. Frame-path work allocates nothing after the pipelines are
//! built: transient quad vertices come from bgfx's bounded pools.

const std = @import("std");
const builtin = @import("builtin");
const math = @import("math");
const blobs = @import("shader_blobs");
const makeup_mesh = @import("makeup_mesh");
const face_mesh_topology = @import("face_mesh_topology");

pub const android_vk = if (builtin.os.tag == .linux and builtin.abi.isAndroid())
    @import("android_vk.zig")
else
    struct {};

pub const c = @cImport({
    @cInclude("bgfx/c99/bgfx.h");
});

pub const invalid_handle: u16 = std.math.maxInt(u16);

/// fs_beauty_reshape.sc packs the 106-point base face contour two
/// points per vec4 uniform - thin_face/big_eye only ever index into
/// that base range, never the five derived hub points face106.zig
/// appends for lipstick/blush's own mesh.
pub const face_point_vec4_count = 53;

/// A named alias for bgfx's own texture handle, matching the stub
/// module's TextureHandle - lets callers that need to name the type
/// (a hashmap value type, say) write render.TextureHandle uniformly
/// against whichever module is actually linked in.
pub const TextureHandle = c.bgfx_texture_handle_t;

/// The affine color conversion as one homogeneous matrix for the shader.
fn yuvTransform(conversion: math.color.Conversion) math.Mat4 {
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

const RgbaUploadCache = struct {
    texture: c.bgfx_texture_handle_t,
    width: u16,
    height: u16,
    format: u32,
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

const is_android = builtin.os.tag == .linux and builtin.abi.isAndroid();

const VkZeroCopy = if (is_android) struct {
    converter: android_vk.Converter,
    textures: [android_vk.ring_depth]c.bgfx_texture_handle_t = @splat(.{ .idx = invalid_handle }),
    width: u32 = 0,
    height: u32 = 0,
    /// Beauty compositing's Vulkan-side imports: write side and read
    /// side.
    beauty_render_target: android_vk.BeautyRenderTarget = .{},
    beauty_import: android_vk.BeautyImport = .{},
} else struct {};

pub const Renderer = struct {
    gpa: std.mem.Allocator,
    zero_copy: ?VkZeroCopy = null,
    width: u32,
    height: u32,
    layout: c.bgfx_vertex_layout_t,
    rgba_program: c.bgfx_program_handle_t,
    nv12_program: c.bgfx_program_handle_t,
    lut_program: c.bgfx_program_handle_t,
    blend_program: c.bgfx_program_handle_t,
    blur_program: c.bgfx_program_handle_t,
    beauty_face_program: c.bgfx_program_handle_t,
    beauty_reshape_program: c.bgfx_program_handle_t,
    makeup_program: c.bgfx_program_handle_t,
    model_program: c.bgfx_program_handle_t,
    /// The 176-triangle face-makeup mesh's fixed index buffer -
    /// makeup_mesh.triangle_indices, uploaded once, never changes.
    makeup_index_buffer: c.bgfx_index_buffer_handle_t,
    /// The canonical 898-triangle face mesh: fixed indices and UVs
    /// uploaded once, live landmark positions streamed per draw.
    face_mesh_index_buffer: c.bgfx_index_buffer_handle_t,
    face_mesh_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    face_mesh_position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
    /// The live tracked 111-point contour, stream 0 of a makeup draw -
    /// dynamic (updated every frame submitMakeup runs), unlike every
    /// other buffer here.
    makeup_position_buffer: c.bgfx_dynamic_vertex_buffer_handle_t,
    /// Stream 1 of a makeup draw: makeup_mesh.canonical_uv scaled into
    /// each effect's own crop of the source image - static, computed
    /// once at init, never changes per-frame the way position does.
    makeup_lipstick_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    makeup_blush_uv_buffer: c.bgfx_vertex_buffer_handle_t,
    tex_color: c.bgfx_uniform_handle_t,
    tex_y: c.bgfx_uniform_handle_t,
    tex_uv: c.bgfx_uniform_handle_t,
    tex_lut: c.bgfx_uniform_handle_t,
    tex_background: c.bgfx_uniform_handle_t,
    tex_mask: c.bgfx_uniform_handle_t,
    tex_mean: c.bgfx_uniform_handle_t,
    tex_lookup_gray: c.bgfx_uniform_handle_t,
    tex_lookup_origin: c.bgfx_uniform_handle_t,
    tex_lookup_skin: c.bgfx_uniform_handle_t,
    tex_lookup_custom: c.bgfx_uniform_handle_t,
    tex_makeup: c.bgfx_uniform_handle_t,
    blur_step_uniform: c.bgfx_uniform_handle_t,
    beauty_params_uniform: c.bgfx_uniform_handle_t,
    reshape_params_uniform: c.bgfx_uniform_handle_t,
    makeup_params_uniform: c.bgfx_uniform_handle_t,
    /// 106 tracked face points, two per vec4 (xy, zw) - matching
    /// fs_beauty_reshape.sc's own u_facePoints packing.
    face_points_uniform: c.bgfx_uniform_handle_t,
    model_color_uniform: c.bgfx_uniform_handle_t,
    /// Solid white 1x1: blend.pass's mask input when segmentation is
    /// unavailable. A mask of 1.0 everywhere means "always foreground,"
    /// so binding this reproduces the SPEC's degradation rule exactly -
    /// the pass draws the frame through unblended rather than blocking
    /// the chain or sampling an unbound texture.
    default_mask_texture: c.bgfx_texture_handle_t,
    /// The absence-of-signal mask: a named mask channel with no live
    /// data samples zero so the effect draws nothing, never everywhere.
    zero_mask_texture: c.bgfx_texture_handle_t,
    yuv_uniform: c.bgfx_uniform_handle_t,
    upload_cache: ?UploadCache = null,
    rgba_upload_cache: ?RgbaUploadCache = null,

    /// Web/wasm renderer choice: WebGPU when this build has it compiled
    /// in, auto-select (OpenGLES/WebGL2) otherwise. Queries bgfx's own
    /// supported-renderers list rather than a build-time flag, since
    /// wasm-emscripten-webgpu and wasm-emscripten link different bgfx
    /// object files.
    fn preferredWebRenderer() c.bgfx_renderer_type_t {
        var supported: [16]c.bgfx_renderer_type_t = undefined;
        const count = c.bgfx_get_supported_renderers(supported.len, &supported);
        for (supported[0..count]) |renderer| {
            if (renderer == c.BGFX_RENDERER_TYPE_WEBGPU) return c.BGFX_RENDERER_TYPE_WEBGPU;
        }
        return c.BGFX_RENDERER_TYPE_COUNT;
    }

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) !Renderer {
        var bgfx_init: c.bgfx_init_t = undefined;
        c.bgfx_init_ctor(&bgfx_init);
        // Metal on apple targets. Android probes for the Vulkan
        // capabilities zero-copy import rests on, brings up the adapter's
        // own device, and takes the GL backend as the declared fallback
        // when either is missing.
        var vk_context: if (is_android) ?android_vk.Context else void = if (is_android) null else {};
        if (is_android) {
            if (@import("vulkan_probe.zig").vulkanReady()) {
                vk_context = android_vk.Context.init() catch null;
            }
        }
        // On any failure below, the adapter-owned device dies only after
        // bgfx (which adopted it) has shut down - errdefers run in
        // reverse declaration order, so this one runs last.
        errdefer if (is_android) {
            if (vk_context) |*ctx| ctx.deinit();
        };
        bgfx_init.type = if (builtin.os.tag == .macos or builtin.os.tag == .ios)
            c.BGFX_RENDERER_TYPE_METAL
        else if (is_android)
            (if (vk_context != null) c.BGFX_RENDERER_TYPE_VULKAN else c.BGFX_RENDERER_TYPE_OPENGLES)
        else
            preferredWebRenderer();
        if (is_android) {
            if (vk_context) |ctx| bgfx_init.platformData.context = ctx.rendererDevice();
        }
        bgfx_init.resolution.width = options.width;
        bgfx_init.resolution.height = options.height;
        bgfx_init.resolution.reset = if (options.vsync) c.BGFX_RESET_VSYNC else c.BGFX_RESET_NONE;
        bgfx_init.platformData.nwh = options.native_window_handle;
        bgfx_init.callback = options.callback;
        // Calling bgfx_render_frame once on this thread before bgfx_init
        // is bgfx's own documented opt-in to single-threaded mode: this
        // thread becomes both the API thread and the render thread,
        // instead of bgfx spawning a separate render thread it would
        // otherwise own. PersistentTexture.rebind's bgfx_override_
        // internal_texture_ptr (zero-copy camera ingress, and the beauty
        // compositing bridge) is documented "must be called only on
        // render thread" - every caller in this codebase runs it from
        // whatever thread submitted the frame, never from a thread bgfx
        // itself spawned, so single-threaded mode is what actually makes
        // that contract hold rather than racing bgfx's internal thread.
        _ = c.bgfx_render_frame(-1);
        if (!c.bgfx_init(&bgfx_init)) {
            // bgfx doesn't retry another backend on its own when a
            // specific type was requested - WebGPU falls back to
            // auto-select here instead of failing outright.
            if (bgfx_init.type == c.BGFX_RENDERER_TYPE_WEBGPU) {
                bgfx_init.type = c.BGFX_RENDERER_TYPE_COUNT;
                _ = c.bgfx_render_frame(-1);
                if (!c.bgfx_init(&bgfx_init)) return error.RendererInit;
            } else {
                return error.RendererInit;
            }
        }
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
            c.BGFX_RENDERER_TYPE_WEBGPU => .{
                try loadProgram(blobs.vs_preview_wgsl, blobs.fs_preview_rgba_wgsl),
                try loadProgram(blobs.vs_preview_wgsl, blobs.fs_preview_nv12_wgsl),
            },
            else => return error.RendererUnsupported,
        };
        const lut_program = try loadLutProgram();
        const blend_program = try loadBlendProgram();
        const blur_program = try loadBlurProgram();
        const beauty_face_program = try loadBeautyFaceProgram();
        const beauty_reshape_program = try loadBeautyReshapeProgram();
        const makeup_program = try loadMakeupProgram();
        const model_program = try loadModelProgram();

        var makeup_position_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&makeup_position_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&makeup_position_layout, c.BGFX_ATTRIB_POSITION, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&makeup_position_layout);
        var makeup_uv_layout: c.bgfx_vertex_layout_t = undefined;
        _ = c.bgfx_vertex_layout_begin(&makeup_uv_layout, c.BGFX_RENDERER_TYPE_NOOP);
        _ = c.bgfx_vertex_layout_add(&makeup_uv_layout, c.BGFX_ATTRIB_TEXCOORD1, 2, c.BGFX_ATTRIB_TYPE_FLOAT, false, false);
        c.bgfx_vertex_layout_end(&makeup_uv_layout);

        const makeup_index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(&makeup_mesh.triangle_indices, @sizeOf(@TypeOf(makeup_mesh.triangle_indices))), 0);
        const makeup_position_buffer = c.bgfx_create_dynamic_vertex_buffer(makeup_mesh.canonical_uv.len / 2, &makeup_position_layout, c.BGFX_BUFFER_ALLOW_RESIZE);
        var lipstick_uv: [makeup_mesh.canonical_uv.len]f32 = undefined;
        makeup_mesh.makeupUv(makeup_mesh.lipstick_bounds, &lipstick_uv);
        const makeup_lipstick_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&lipstick_uv, @sizeOf(@TypeOf(lipstick_uv))), &makeup_uv_layout, 0);
        var blush_uv: [makeup_mesh.canonical_uv.len]f32 = undefined;
        makeup_mesh.makeupUv(makeup_mesh.blush_bounds, &blush_uv);
        const makeup_blush_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&blush_uv, @sizeOf(@TypeOf(blush_uv))), &makeup_uv_layout, 0);

        const face_mesh_index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(&face_mesh_topology.triangle_indices, @sizeOf(@TypeOf(face_mesh_topology.triangle_indices))), 0);
        const face_mesh_uv_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(&face_mesh_topology.vertex_uvs, @sizeOf(@TypeOf(face_mesh_topology.vertex_uvs))), &makeup_uv_layout, 0);
        const face_mesh_position_buffer = c.bgfx_create_dynamic_vertex_buffer(face_mesh_topology.vertex_count, &makeup_position_layout, c.BGFX_BUFFER_ALLOW_RESIZE);

        c.bgfx_set_view_clear(0, c.BGFX_CLEAR_COLOR | c.BGFX_CLEAR_DEPTH, 0x000000ff, 1.0, 0);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(options.width), @intCast(options.height));

        var zero_copy: ?VkZeroCopy = null;
        if (is_android) {
            if (vk_context) |ctx| {
                if (android_vk.Converter.init(ctx)) |converter| {
                    zero_copy = .{ .converter = converter };
                } else |_| {
                    // The errdefer chain shuts bgfx down before the
                    // device it adopted dies - never inline here.
                    return error.RendererInit;
                }
            }
        }

        return .{
            .gpa = gpa,
            .zero_copy = zero_copy,
            .width = options.width,
            .height = options.height,
            .layout = layout,
            .rgba_program = rgba_program,
            .nv12_program = nv12_program,
            .lut_program = lut_program,
            .blend_program = blend_program,
            .blur_program = blur_program,
            .beauty_face_program = beauty_face_program,
            .beauty_reshape_program = beauty_reshape_program,
            .makeup_program = makeup_program,
            .model_program = model_program,
            .makeup_index_buffer = makeup_index_buffer,
            .face_mesh_index_buffer = face_mesh_index_buffer,
            .face_mesh_uv_buffer = face_mesh_uv_buffer,
            .face_mesh_position_buffer = face_mesh_position_buffer,
            .makeup_position_buffer = makeup_position_buffer,
            .makeup_lipstick_uv_buffer = makeup_lipstick_uv_buffer,
            .makeup_blush_uv_buffer = makeup_blush_uv_buffer,
            .tex_color = c.bgfx_create_uniform("s_texColor", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_y = c.bgfx_create_uniform("s_texY", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_uv = c.bgfx_create_uniform("s_texUV", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lut = c.bgfx_create_uniform("s_texLut", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_background = c.bgfx_create_uniform("s_texBackground", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_mask = c.bgfx_create_uniform("s_texMask", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_mean = c.bgfx_create_uniform("s_texMean", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_gray = c.bgfx_create_uniform("s_texLookupGray", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_origin = c.bgfx_create_uniform("s_texLookupOrigin", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_skin = c.bgfx_create_uniform("s_texLookupSkin", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_lookup_custom = c.bgfx_create_uniform("s_texLookupCustom", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .tex_makeup = c.bgfx_create_uniform("s_texMakeup", c.BGFX_UNIFORM_TYPE_SAMPLER, 1),
            .blur_step_uniform = c.bgfx_create_uniform("u_blurStep", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .beauty_params_uniform = c.bgfx_create_uniform("u_beautyParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .reshape_params_uniform = c.bgfx_create_uniform("u_reshapeParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .makeup_params_uniform = c.bgfx_create_uniform("u_makeupParams", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .face_points_uniform = c.bgfx_create_uniform("u_facePoints", c.BGFX_UNIFORM_TYPE_VEC4, face_point_vec4_count),
            .model_color_uniform = c.bgfx_create_uniform("u_modelColor", c.BGFX_UNIFORM_TYPE_VEC4, 1),
            .default_mask_texture = createMaskTexture(1, 1, &[_]u8{255}),
            .zero_mask_texture = createMaskTexture(1, 1, &[_]u8{0}),
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

    /// The compiled bytecode file suffix matching bgfx's currently
    /// active backend - the one source of truth for which
    /// packaged shader variant a lens shader pass needs, shared between
    /// loadLensProgram below and whatever reads the bytes off disk.
    pub fn currentShaderProfileTag() ![]const u8 {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => "metal",
            c.BGFX_RENDERER_TYPE_VULKAN => "spirv",
            c.BGFX_RENDERER_TYPE_OPENGLES => "essl",
            c.BGFX_RENDERER_TYPE_WEBGPU => "wgsl",
            else => error.RendererUnsupported,
        };
    }

    /// Pairs a lens's compiled fragment shader with the one fixed vertex
    /// shader every lens shader pass shares (lenses/shaders/vs_lens_pass.sc),
    /// picking the vertex blob matching the same backend fs_bytes was
    /// compiled for - the caller is responsible for having read the
    /// right profile's .bin file (currentShaderProfileTag tells it which).
    pub fn loadLensProgram(fs_bytes: []const u8) !c.bgfx_program_handle_t {
        const vs_blob = switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => blobs.vs_lens_pass_metal,
            c.BGFX_RENDERER_TYPE_VULKAN => blobs.vs_lens_pass_spirv,
            c.BGFX_RENDERER_TYPE_OPENGLES => blobs.vs_lens_pass_essl,
            c.BGFX_RENDERER_TYPE_WEBGPU => blobs.vs_lens_pass_wgsl,
            else => return error.RendererUnsupported,
        };
        return loadProgram(vs_blob, fs_bytes);
    }

    /// The one fixed lut.pass program every lens shares - kit-authored,
    /// so unlike loadLensProgram this takes no bytes; there is nothing
    /// per-lens to compile for this node type. A real Renderer instance
    /// builds this once at init and keeps it in lut_program; this
    /// static form exists so a caller without an instance (a proof, a
    /// test) can still get the exact same program.
    pub fn loadLutProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_lut_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_lut_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_lut_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_lut_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed blend.pass program every lens shares - kit-authored
    /// like lut_program, same reasoning.
    pub fn loadBlendProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_blend_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_blend_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_blend_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_blend_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// beauty.face's smooth effect blur input - one program, run twice
    /// (horizontal then vertical) with a different u_blurStep each time.
    pub fn loadBlurProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_blur_pass_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_blur_pass_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_blur_pass_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_blur_pass_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.face program every lens shares - kit-authored
    /// like lut_program, same reasoning.
    pub fn loadBeautyFaceProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_beauty_face_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_beauty_face_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_beauty_face_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_beauty_face_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.reshape program every lens shares -
    /// kit-authored like lut_program, same reasoning.
    pub fn loadBeautyReshapeProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_beauty_reshape_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_beauty_reshape_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_beauty_reshape_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_beauty_reshape_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed beauty.lipstick/beauty.blusher program every lens
    /// shares - its own vertex stage (vs_makeup, not vs_lens_pass; the
    /// mesh needs two vertex attributes, not a full-screen quad).
    pub fn loadMakeupProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_makeup_metal, blobs.fs_makeup_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_makeup_spirv, blobs.fs_makeup_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_makeup_essl, blobs.fs_makeup_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_makeup_wgsl, blobs.fs_makeup_wgsl),
            else => error.RendererUnsupported,
        };
    }

    /// The one fixed model.gltf program every lens shares - reuses
    /// vs_lens_pass.sc (the mesh's vertex data is padded with a dummy
    /// texcoord so it fits the same interleaved POSITION+TEXCOORD0
    /// layout every full-screen-quad pass already uses), pairs it with
    /// its own fragment shader that outputs one flat uniform-driven
    /// color rather than sampling a texture.
    pub fn loadModelProgram() !c.bgfx_program_handle_t {
        return switch (c.bgfx_get_renderer_type()) {
            c.BGFX_RENDERER_TYPE_METAL => loadProgram(blobs.vs_lens_pass_metal, blobs.fs_model_metal),
            c.BGFX_RENDERER_TYPE_VULKAN => loadProgram(blobs.vs_lens_pass_spirv, blobs.fs_model_spirv),
            c.BGFX_RENDERER_TYPE_OPENGLES => loadProgram(blobs.vs_lens_pass_essl, blobs.fs_model_essl),
            c.BGFX_RENDERER_TYPE_WEBGPU => loadProgram(blobs.vs_lens_pass_wgsl, blobs.fs_model_wgsl),
            else => error.RendererUnsupported,
        };
    }

    pub fn destroyProgram(program: c.bgfx_program_handle_t) void {
        c.bgfx_destroy_program(program);
    }

    pub fn deinit(r: *Renderer) void {
        if (is_android) {
            if (r.zero_copy) |*zc| {
                for (zc.textures) |texture| {
                    if (texture.idx != invalid_handle) c.bgfx_destroy_texture(texture);
                }
                zc.beauty_render_target.deinit(zc.converter.ctx.device);
                zc.beauty_import.deinit(zc.converter.ctx.device);
                zc.converter.deinit();
            }
        }
        if (r.upload_cache) |cache| {
            c.bgfx_destroy_texture(cache.y);
            c.bgfx_destroy_texture(cache.uv);
        }
        if (r.rgba_upload_cache) |cache| {
            c.bgfx_destroy_texture(cache.texture);
        }
        c.bgfx_destroy_texture(r.default_mask_texture);
        c.bgfx_destroy_texture(r.zero_mask_texture);
        c.bgfx_destroy_uniform(r.tex_color);
        c.bgfx_destroy_uniform(r.tex_y);
        c.bgfx_destroy_uniform(r.tex_uv);
        c.bgfx_destroy_uniform(r.tex_lut);
        c.bgfx_destroy_uniform(r.tex_background);
        c.bgfx_destroy_uniform(r.tex_mask);
        c.bgfx_destroy_uniform(r.tex_mean);
        c.bgfx_destroy_uniform(r.tex_lookup_gray);
        c.bgfx_destroy_uniform(r.tex_lookup_origin);
        c.bgfx_destroy_uniform(r.tex_lookup_skin);
        c.bgfx_destroy_uniform(r.tex_lookup_custom);
        c.bgfx_destroy_uniform(r.tex_makeup);
        c.bgfx_destroy_uniform(r.blur_step_uniform);
        c.bgfx_destroy_uniform(r.beauty_params_uniform);
        c.bgfx_destroy_uniform(r.reshape_params_uniform);
        c.bgfx_destroy_uniform(r.makeup_params_uniform);
        c.bgfx_destroy_uniform(r.face_points_uniform);
        c.bgfx_destroy_uniform(r.model_color_uniform);
        c.bgfx_destroy_uniform(r.yuv_uniform);
        c.bgfx_destroy_program(r.rgba_program);
        c.bgfx_destroy_program(r.nv12_program);
        c.bgfx_destroy_program(r.lut_program);
        c.bgfx_destroy_program(r.blend_program);
        c.bgfx_destroy_program(r.blur_program);
        c.bgfx_destroy_program(r.beauty_face_program);
        c.bgfx_destroy_program(r.beauty_reshape_program);
        c.bgfx_destroy_program(r.makeup_program);
        c.bgfx_destroy_program(r.model_program);
        c.bgfx_destroy_index_buffer(r.makeup_index_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(r.makeup_position_buffer);
        c.bgfx_destroy_vertex_buffer(r.makeup_lipstick_uv_buffer);
        c.bgfx_destroy_vertex_buffer(r.makeup_blush_uv_buffer);
        c.bgfx_destroy_index_buffer(r.face_mesh_index_buffer);
        c.bgfx_destroy_vertex_buffer(r.face_mesh_uv_buffer);
        c.bgfx_destroy_dynamic_vertex_buffer(r.face_mesh_position_buffer);
        c.bgfx_shutdown();
        if (is_android) {
            if (r.zero_copy) |*zc| {
                var ctx = zc.converter.ctx;
                ctx.deinit();
            }
        }
        r.* = undefined;
    }

    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        r.width = width;
        r.height = height;
        c.bgfx_reset(width, height, c.BGFX_RESET_VSYNC, c.BGFX_TEXTURE_FORMAT_COUNT);
        c.bgfx_set_view_rect(0, 0, 0, @intCast(width), @intCast(height));
    }

    /// A bgfx texture handle a caller keeps across calls and repeatedly
    /// rebinds to new native pointers via PersistentTexture.rebind,
    /// instead of creating a fresh handle every time.
    pub const PersistentTexture = struct {
        handle: c.bgfx_texture_handle_t = .{ .idx = invalid_handle },
        width: u16 = 0,
        height: u16 = 0,

        /// A fresh handle every frame never survives long enough to
        /// clear bgfx's own override-timing contract (0 means not yet
        /// created from the main thread). Reusing the same handle,
        /// recreated only on a real size change, fixes that.
        pub fn rebind(self: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) c.bgfx_texture_handle_t {
            if (self.handle.idx == invalid_handle or self.width != width or self.height != height) {
                if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
                const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
                self.handle = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0);
                self.width = width;
                self.height = height;
            }
            _ = c.bgfx_override_internal_texture_ptr(self.handle, native_ptr, 0);
            return self.handle;
        }

        pub fn deinit(self: *PersistentTexture) void {
            if (self.handle.idx != invalid_handle) c.bgfx_destroy_texture(self.handle);
            self.* = .{};
        }
    };

    /// Verifies the override actually landed, keeping pt's handle alive
    /// across a still-pending resolve. The just-created frame never
    /// overrides at all: bgfx recycles handle indices, and a dying
    /// predecessor in the backend slot reads as a landed override.
    pub fn wrapExternalRenderTarget(r: *Renderer, pt: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) ?c.bgfx_texture_handle_t {
        _ = r;
        if (pt.handle.idx == invalid_handle or pt.width != width or pt.height != height) {
            if (pt.handle.idx != invalid_handle) c.bgfx_destroy_texture(pt.handle);
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP | c.BGFX_TEXTURE_RT;
            pt.handle = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0);
            pt.width = width;
            pt.height = height;
            return null;
        }
        const resolved = c.bgfx_override_internal_texture_ptr(pt.handle, native_ptr, 0);
        if (resolved == 0) return null;
        return pt.handle;
    }

    /// wrapExternalRenderTarget's Vulkan sibling: override is a no-op on
    /// that backend, so this creates the texture in one step via
    /// bgfx_create_texture_2d's own _external parameter instead. RGBA8,
    /// matching the AHardwareBuffer's real format.
    pub fn createAndroidBeautyRenderTarget(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?c.bgfx_texture_handle_t {
        if (!is_android) return null;
        const zc = if (r.zero_copy) |*z| z else return null;
        const vk_image = zc.beauty_render_target.importRenderTarget(&zc.converter.ctx, @ptrCast(@alignCast(hardware_buffer)), width, height) catch return null;
        const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP | c.BGFX_TEXTURE_RT;
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, flags, null, vk_image);
        if (handle.idx == invalid_handle) return null;
        return handle;
    }

    /// PersistentTexture.rebind's Vulkan sibling, same reason as
    /// createAndroidBeautyRenderTarget above.
    pub fn wrapAndroidBeautyOutput(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?c.bgfx_texture_handle_t {
        if (!is_android) return null;
        const zc = if (r.zero_copy) |*z| z else return null;
        const vk_image = zc.beauty_import.importRgba(&zc.converter.ctx, @ptrCast(@alignCast(hardware_buffer)), width, height) catch return null;
        const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, flags, null, vk_image);
        if (handle.idx == invalid_handle) return null;
        return handle;
    }

    pub fn destroyTexture(r: *Renderer, handle: c.bgfx_texture_handle_t) void {
        _ = r;
        if (handle.idx != invalid_handle) c.bgfx_destroy_texture(handle);
    }

    /// bgfx's own native device handle for the active backend - an
    /// MTL::Device on Metal, whose pointer value is the same underlying
    /// id<MTLDevice> object metal-cpp wraps with no extra indirection.
    /// What lets a platform adapter (the beauty compositing bridge)
    /// create native resources bgfx can wrap back in without owning any
    /// bgfx dependency itself - the same separation PersistentTexture.
    /// rebind's own native_ptr argument already keeps.
    pub fn nativeDevice(r: *Renderer) ?*anyopaque {
        _ = r;
        const data = c.bgfx_get_internal_data();
        if (data == null or data.*.context == null) return null;
        return data.*.context;
    }

    /// True only once Vulkan actually initialized, not just on Android -
    /// false on the GLES fallback.
    pub fn isAndroidVulkan(r: *const Renderer) bool {
        return is_android and r.zero_copy != null;
    }

    /// Uploads a decoded, immutable image (a lens's LUT, say) as a real
    /// GPU texture, copying rgba once at creation - unlike the
    /// override-based wraps, there is no live external buffer behind
    /// this one to keep alive frame over frame. No instance state to
    /// touch, so this needs no receiver, the same as loadLensProgram.
    pub fn createStaticTexture(width: u16, height: u16, rgba: []const u8) TextureHandle {
        return c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, c.bgfx_copy(rgba.ptr, @intCast(rgba.len)), 0);
    }

    /// Uploads a single-channel mask (a segmentation result, say) as a
    /// real GPU texture - the same immutable, copy-once shape as
    /// createStaticTexture, just one byte per pixel instead of four,
    /// since a mask has no color to carry.
    pub fn createMaskTexture(width: u16, height: u16, mask: []const u8) TextureHandle {
        return c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_R8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP, c.bgfx_copy(mask.ptr, @intCast(mask.len)), 0);
    }

    /// Full-screen quad geometry and the view's transform, shared by
    /// submitPreview and submitShaderPass - the two differ only in which
    /// program and textures they bind afterward.
    fn setupFullScreenQuad(r: *Renderer, view_id: c.bgfx_view_id_t, rotation_degrees: u32, mirror: bool) bool {
        var tvb: c.bgfx_transient_vertex_buffer_t = undefined;
        var tib: c.bgfx_transient_index_buffer_t = undefined;
        if (c.bgfx_get_avail_transient_vertex_buffer(4, &r.layout) < 4) return false;
        if (c.bgfx_get_avail_transient_index_buffer(6, false) < 6) return false;
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
        c.bgfx_set_view_transform(view_id, &view.cols, &proj.cols);

        c.bgfx_set_transient_vertex_buffer(0, &tvb, 0, 4);
        c.bgfx_set_transient_index_buffer(&tib, 0, 6);
        return true;
    }

    /// The trivial RGBA passthrough program submitPreview's own bgra
    /// branch already draws with - exposed so a caller outside this
    /// module (the beauty compositing bridge, blitting a plain texture
    /// into a platform-shared target through submitShaderPass) can reach
    /// it without touching Renderer's fields directly, the same
    /// boundary every other cross-module access in this file already
    /// keeps.
    pub fn passthroughProgram(r: *Renderer) c.bgfx_program_handle_t {
        return r.rgba_program;
    }

    /// Draws the camera frame as the full-view preview into view_id.
    /// `rotation_degrees` spins the quad for sensor orientation; `mirror`
    /// flips horizontally for front cameras.
    pub fn submitPreview(r: *Renderer, view_id: c.bgfx_view_id_t, preview: PreviewFrame, rotation_degrees: u32, mirror: bool) void {
        if (!r.setupFullScreenQuad(view_id, rotation_degrees, mirror)) return;
        switch (preview) {
            .bgra => |f| {
                c.bgfx_set_texture(0, r.tex_color, f.texture, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(view_id, r.rgba_program, 0, c.BGFX_DISCARD_ALL);
            },
            .nv12 => |f| {
                const transform = yuvTransform(f.conversion);
                c.bgfx_set_uniform(r.yuv_uniform, &transform.cols, 1);
                c.bgfx_set_texture(0, r.tex_y, f.y, std.math.maxInt(u32));
                c.bgfx_set_texture(1, r.tex_uv, f.uv, std.math.maxInt(u32));
                c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
                c.bgfx_submit(view_id, r.nv12_program, 0, c.BGFX_DISCARD_ALL);
            },
        }
    }

    /// An offscreen color target a shader pass can render into and a
    /// later pass (or the same pass's successor in a chain) can sample
    /// as input - what makes more than one lens shader pass composable
    /// without each one fighting the others for the swap chain.
    pub const OffscreenTarget = struct {
        framebuffer: c.bgfx_frame_buffer_handle_t,
        texture: c.bgfx_texture_handle_t,
    };

    pub fn createOffscreenTarget(width: u16, height: u16) !OffscreenTarget {
        const framebuffer = c.bgfx_create_frame_buffer(width, height, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP);
        if (framebuffer.idx == invalid_handle) return error.FrameBufferCreate;
        const texture = c.bgfx_get_texture(framebuffer, 0);
        return .{ .framebuffer = framebuffer, .texture = texture };
    }

    pub fn destroyOffscreenTarget(target: OffscreenTarget) void {
        if (target.framebuffer.idx != invalid_handle) c.bgfx_destroy_frame_buffer(target.framebuffer);
    }

    /// Wraps an existing texture handle (typically one wrapExternalRenderTarget
    /// just produced, over a platform-shared surface) as a render target
    /// bgfx can draw into via setViewTarget - what lets a shared surface
    /// receive a bgfx draw instead of only ever being sampled from. The
    /// texture's own lifecycle stays with whoever created it; destroying
    /// the returned target (destroyOffscreenTarget, same as any other
    /// OffscreenTarget) never touches it.
    pub fn createExternalTarget(handle: c.bgfx_texture_handle_t) !OffscreenTarget {
        const framebuffer = c.bgfx_create_frame_buffer_from_handles(1, &handle, false);
        if (framebuffer.idx == invalid_handle) return error.FrameBufferCreate;
        return .{ .framebuffer = framebuffer, .texture = handle };
    }

    /// Assigns view_id's render target: an offscreen target, or the
    /// swap chain itself when target is null (the last stage in a
    /// chain always presents to the swap chain). view_rect always
    /// matches the target's own size, offscreen or not.
    pub fn setViewTarget(view_id: c.bgfx_view_id_t, target: ?OffscreenTarget, width: u16, height: u16) void {
        c.bgfx_set_view_frame_buffer(view_id, if (target) |offscreen| offscreen.framebuffer else .{ .idx = invalid_handle });
        c.bgfx_set_view_rect(view_id, 0, 0, width, height);
    }

    /// Draws one lens shader.pass node as a full-screen pass into
    /// view_id: input_texture through the s_texColor sampler every lens
    /// fragment shader is authored against, and the node's named mask
    /// channel (or the all-foreground default) through s_texMask.
    pub fn submitShaderPass(r: *Renderer, view_id: c.bgfx_view_id_t, program: c.bgfx_program_handle_t, input_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens lut.pass node as a full-screen pass into view_id:
    /// the frame on unit 0, the lens's own LUT texture on unit 1, the
    /// one fixed lut_program every lut.pass node shares (there is
    /// nothing per-lens to compile here, unlike shader.pass).
    pub fn submitLutPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, lut_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_lut, lut_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.lut_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one lens blend.pass node as a full-screen pass into
    /// view_id: the frame on unit 0, the lens's own background image on
    /// unit 1, the session's current segmentation mask on unit 2, the
    /// one fixed blend_program every blend.pass node shares.
    pub fn submitBlendPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, background_texture: c.bgfx_texture_handle_t, mask_texture: c.bgfx_texture_handle_t) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_mask, mask_texture, std.math.maxInt(u32));
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.blend_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one pass of beauty.face's separable blur input into
    /// view_id - one call for the horizontal tap, one for the vertical,
    /// step carrying the per-tap UV offset for whichever direction this
    /// call is.
    pub fn submitBlurPass(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, step: [2]f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        const step_vec4 = [4]f32{ step[0], step[1], 0.0, 0.0 };
        c.bgfx_set_uniform(r.blur_step_uniform, &step_vec4, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.blur_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.face node (smooth+whiten) as a full-screen pass
    /// into view_id: the frame and its separable blur on units 0-1, the
    /// four whitening LUTs on units 2-5, matching gpupixel's own
    /// beauty_face_unit_filter.cc lookup set.
    pub fn submitBeautyFace(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mean_texture: c.bgfx_texture_handle_t, lookup_gray: c.bgfx_texture_handle_t, lookup_origin: c.bgfx_texture_handle_t, lookup_skin: c.bgfx_texture_handle_t, lookup_custom: c.bgfx_texture_handle_t, smooth_amount: f32, whiten_amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_mean, mean_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(2, r.tex_lookup_gray, lookup_gray, std.math.maxInt(u32));
        c.bgfx_set_texture(3, r.tex_lookup_origin, lookup_origin, std.math.maxInt(u32));
        c.bgfx_set_texture(4, r.tex_lookup_skin, lookup_skin, std.math.maxInt(u32));
        c.bgfx_set_texture(5, r.tex_lookup_custom, lookup_custom, std.math.maxInt(u32));
        const params = [4]f32{ smooth_amount, whiten_amount, 0.0, 0.0 };
        c.bgfx_set_uniform(r.beauty_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.beauty_face_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.reshape node (thin_face+big_eye) as a
    /// full-screen pass into view_id. face_points is the live tracked
    /// contour, 106 points as 212 floats (x0,y0,x1,y1,...) - the same
    /// flat layout core/tracking/face106.zig's base 106 points already
    /// fill, packed two points per vec4 with no repacking since that is
    /// already fs_beauty_reshape.sc's own u_facePoints layout.
    pub fn submitBeautyReshape(r: *Renderer, view_id: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, face_points: *const [face_point_vec4_count * 4]f32, aspect_ratio: f32, thin_face_amount: f32, big_eye_amount: f32) void {
        if (!r.setupFullScreenQuad(view_id, 0, false)) return;
        c.bgfx_set_texture(0, r.tex_color, input_texture, std.math.maxInt(u32));
        const params = [4]f32{ aspect_ratio, thin_face_amount, big_eye_amount, 0.0 };
        c.bgfx_set_uniform(r.reshape_params_uniform, &params, 1);
        c.bgfx_set_uniform(r.face_points_uniform, face_points, face_point_vec4_count);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.beauty_reshape_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws one beauty.lipstick or beauty.blusher node: the 176-triangle
    /// mesh over the live tracked contour, not a full-screen pass -
    /// uv_buffer picks which effect (makeupLipstickUvBuffer/
    /// makeupBlushUvBuffer), positions is this frame's own 111 tracked
    /// points in 0-1 UV space (both the mesh's vertex position and,
    /// unchanged, its background sample point - vs_makeup.sc's own
    /// trick for reading the frame at exactly the screen position each
    /// triangle draws over).
    pub fn submitMakeup(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, makeup_texture: c.bgfx_texture_handle_t, uv_buffer: c.bgfx_vertex_buffer_handle_t, positions: *const [makeup_mesh.canonical_uv.len]f32, intensity: f32) void {
        c.bgfx_update_dynamic_vertex_buffer(r.makeup_position_buffer, 0, c.bgfx_copy(positions, @sizeOf(@TypeOf(positions.*))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.makeup_position_buffer, 0, makeup_mesh.canonical_uv.len / 2);
        c.bgfx_set_vertex_buffer(1, uv_buffer, 0, makeup_mesh.canonical_uv.len / 2);
        c.bgfx_set_index_buffer(r.makeup_index_buffer, 0, makeup_mesh.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, makeup_texture, std.math.maxInt(u32));
        const params = [4]f32{ intensity, 0.0, 0.0, 0.0 };
        c.bgfx_set_uniform(r.makeup_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.makeup_program, 0, c.BGFX_DISCARD_ALL);
    }

    /// Draws the canonical face mesh over the frame: each vertex rides
    /// its tracked landmark (frame pixels in, zero-to-one frame UV out),
    /// canonical texture coordinates, the same program and blend the
    /// makeup mesh uses.
    pub fn submitFaceMesh(r: *Renderer, view_id: c.bgfx_view_id_t, background_texture: c.bgfx_texture_handle_t, mesh_texture: c.bgfx_texture_handle_t, landmarks: []const f32, frame_width: f32, frame_height: f32, intensity: f32) void {
        std.debug.assert(landmarks.len >= 468 * 3);
        var positions: [face_mesh_topology.vertex_count * 2]f32 = undefined;
        for (face_mesh_topology.vertex_landmarks, 0..) |landmark, at| {
            positions[at * 2] = landmarks[@as(usize, landmark) * 3] / frame_width;
            positions[at * 2 + 1] = landmarks[@as(usize, landmark) * 3 + 1] / frame_height;
        }
        c.bgfx_update_dynamic_vertex_buffer(r.face_mesh_position_buffer, 0, c.bgfx_copy(&positions, @sizeOf(@TypeOf(positions))));
        c.bgfx_set_dynamic_vertex_buffer(0, r.face_mesh_position_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_vertex_buffer(1, r.face_mesh_uv_buffer, 0, face_mesh_topology.vertex_count);
        c.bgfx_set_index_buffer(r.face_mesh_index_buffer, 0, face_mesh_topology.triangle_indices.len);
        c.bgfx_set_texture(0, r.tex_background, background_texture, std.math.maxInt(u32));
        c.bgfx_set_texture(1, r.tex_makeup, mesh_texture, std.math.maxInt(u32));
        const params = [4]f32{ intensity, 0.0, 0.0, 0.0 };
        c.bgfx_set_uniform(r.makeup_params_uniform, &params, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(view_id, r.makeup_program, 0, c.BGFX_DISCARD_ALL);
    }

    pub fn makeupLipstickUvBuffer(r: *const Renderer) c.bgfx_vertex_buffer_handle_t {
        return r.makeup_lipstick_uv_buffer;
    }

    pub fn makeupBlushUvBuffer(r: *const Renderer) c.bgfx_vertex_buffer_handle_t {
        return r.makeup_blush_uv_buffer;
    }

    /// A model.gltf node's geometry, uploaded once at load time - fixed
    /// topology, unlike the makeup mesh's per-frame-updated positions,
    /// so both buffers are static (not dynamic).
    pub const ModelMesh = struct {
        vertex_buffer: c.bgfx_vertex_buffer_handle_t,
        index_buffer: c.bgfx_index_buffer_handle_t,
        index_count: u32,
    };

    /// Builds a static mesh from positions and indices: real gpu-side
    /// geometry, uploaded once. Vertex data is interleaved into the
    /// same POSITION+TEXCOORD0 layout every full-screen-quad pass uses
    /// (r.layout), texcoord padded to zero since the model shader never
    /// samples one - this lets model draws reuse vs_lens_pass.sc rather
    /// than needing their own vertex stage.
    pub fn createModelMesh(r: *Renderer, positions: []const [3]f32, indices: []const u32) !ModelMesh {
        const interleaved = try r.gpa.alloc(f32, positions.len * 5);
        defer r.gpa.free(interleaved);
        for (positions, 0..) |p, i| {
            interleaved[i * 5 ..][0..5].* = .{ p[0], p[1], p[2], 0.0, 0.0 };
        }
        const vertex_buffer = c.bgfx_create_vertex_buffer(c.bgfx_copy(interleaved.ptr, @intCast(interleaved.len * @sizeOf(f32))), &r.layout, 0);
        const index_buffer = c.bgfx_create_index_buffer(c.bgfx_copy(indices.ptr, @intCast(indices.len * @sizeOf(u32))), c.BGFX_BUFFER_INDEX32);
        return .{ .vertex_buffer = vertex_buffer, .index_buffer = index_buffer, .index_count = @intCast(indices.len) };
    }

    pub fn destroyModelMesh(mesh: ModelMesh) void {
        c.bgfx_destroy_vertex_buffer(mesh.vertex_buffer);
        c.bgfx_destroy_index_buffer(mesh.index_buffer);
    }

    /// Draws one model.gltf node: blit_view first blits the current
    /// frame into the shared target so the mesh's own triangles are
    /// the only pixels this draw changes (same reasoning submitMakeup's
    /// own blit step already documents, here as a separate bgfx view
    /// rather than a second draw in the same one, since the mesh needs
    /// its own real 3D view/projection - bgfx's view transform is a
    /// per-view, not per-draw, state, and the blit needs the flat
    /// ortho every other pass shares). mesh_view runs after blit_view
    /// (bgfx executes views in ascending id order) into the same
    /// target, so the mesh composites on top with no blend state
    /// needed. No depth test: a single flat mesh has nothing to
    /// self-occlude against; a lens with multiple overlapping model
    /// nodes would need the offscreen target to grow a depth
    /// attachment, real future work this lens does not need.
    pub fn submitModel(r: *Renderer, blit_view: c.bgfx_view_id_t, mesh_view: c.bgfx_view_id_t, input_texture: c.bgfx_texture_handle_t, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, aspect_ratio: f32) void {
        r.submitShaderPass(blit_view, r.passthroughProgram(), input_texture, r.default_mask_texture);

        const eye: math.Vec3 = .{ 0.0, 0.0, 2.0 };
        const view = math.Mat4.lookAt(eye, .{ 0.0, 0.0, 0.0 }, .{ 0.0, 1.0, 0.0 });
        const proj = math.Mat4.perspective(math.scalar.radians(45.0), aspect_ratio, 0.1, 10.0, .zero_to_one);
        c.bgfx_set_view_transform(mesh_view, &view.cols, &proj.cols);
        _ = c.bgfx_set_transform(&model_matrix.cols, 1);
        c.bgfx_set_vertex_buffer(0, mesh.vertex_buffer, 0, std.math.maxInt(u32));
        c.bgfx_set_index_buffer(mesh.index_buffer, 0, mesh.index_count);
        c.bgfx_set_uniform(r.model_color_uniform, &base_color, 1);
        c.bgfx_set_state(c.BGFX_STATE_WRITE_RGB | c.BGFX_STATE_WRITE_A, 0);
        c.bgfx_submit(mesh_view, r.model_program, 0, c.BGFX_DISCARD_ALL);
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

    /// The CPU-copy path for a single-plane BGRA8/RGBA8 frame - a
    /// browser's own canvas/video frame byte buffer, say, with no
    /// native GPU handle behind it for the zero-copy override path
    /// to use. Same cached-and-updated shape as uploadNv12 above,
    /// not createStaticTexture's one-shot immutable upload - a live
    /// camera frame changes every call, the same texture reused rather
    /// than recreated each time.
    pub fn uploadRgba(r: *Renderer, width: u16, height: u16, format: u32, rgba: [*]const u8, stride: u32) !c.bgfx_texture_handle_t {
        if (r.rgba_upload_cache) |cache| {
            if (cache.width != width or cache.height != height or cache.format != format) {
                c.bgfx_destroy_texture(cache.texture);
                r.rgba_upload_cache = null;
            }
        }
        if (r.rgba_upload_cache == null) {
            const flags = c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP;
            r.rgba_upload_cache = .{
                .texture = c.bgfx_create_texture_2d(width, height, false, 1, format, flags, null, 0),
                .width = width,
                .height = height,
                .format = format,
            };
        }
        const cache = r.rgba_upload_cache.?;

        // Both axes reversed: bgfx's HTML5/WebGL2 backend samples (0,0)
        // as the last pixel of an uploaded 2D texture, not the first.
        const mem = c.bgfx_alloc(@as(u32, width) * height * 4) orelse return error.OutOfMemory;
        const dst: [*]u8 = mem.*.data;
        for (0..height) |row| {
            const src_row = rgba[(height - 1 - row) * stride ..];
            const dst_row = dst[row * width * 4 ..];
            for (0..width) |col| {
                const src_col = width - 1 - col;
                @memcpy(dst_row[col * 4 ..][0..4], src_row[src_col * 4 ..][0..4]);
            }
        }
        c.bgfx_update_texture_2d(cache.texture, 0, 0, 0, 0, width, height, mem, std.math.maxInt(u16));

        return cache.texture;
    }

    /// Zero-copy submission of a camera hardware buffer: the adapter
    /// converts on its own queue and the returned handle is the ring
    /// texture holding the rgba frame. Unsupported formats and devices
    /// surface as errors the caller counts onto the declared copy path.
    pub fn submitHardwareBuffer(r: *Renderer, hardware_buffer: *anyopaque, width: u32, height: u32, conversion: math.color.Conversion) !c.bgfx_texture_handle_t {
        if (!is_android) return error.Unsupported;
        const zc = if (r.zero_copy) |*z| z else return error.Unsupported;
        const m = conversion.homogeneous();
        var matrix: [16]f32 = undefined;
        var index: usize = 0;
        inline for (0..4) |col| {
            inline for (0..4) |row| {
                matrix[index] = m.cols[col][row];
                index += 1;
            }
        }
        zc.converter.setConversion(matrix);
        const slot = try zc.converter.convert(@ptrCast(hardware_buffer), width, height);
        if (zc.width != width or zc.height != height) {
            for (&zc.textures, 0..) |*texture, ring_slot| {
                if (texture.idx != invalid_handle) c.bgfx_destroy_texture(texture.*);
                texture.* = c.bgfx_create_texture_2d(
                    @intCast(width),
                    @intCast(height),
                    false,
                    1,
                    c.BGFX_TEXTURE_FORMAT_RGBA8,
                    c.BGFX_SAMPLER_U_CLAMP | c.BGFX_SAMPLER_V_CLAMP,
                    null,
                    zc.converter.targetImage(@intCast(ring_slot)),
                );
            }
            zc.width = width;
            zc.height = height;
        }
        return zc.textures[slot];
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

    /// Enqueues a pixel readback into `data` (sized to the texture's
    /// own width * height * 4); the texture must carry
    /// BGFX_TEXTURE_READ_BACK (createReadbackTexture). Returns the
    /// frame number the caller must reach via frame() before reading.
    pub fn readTexture(texture: TextureHandle, data: [*]u8) u32 {
        return c.bgfx_read_texture(texture, data, 0, 0);
    }

    /// A CPU-readable blit destination: render targets themselves are
    /// not readable on every backend, so readbacks blit into one of
    /// these first.
    pub fn createReadbackTexture(width: u16, height: u16) !TextureHandle {
        const handle = c.bgfx_create_texture_2d(width, height, false, 1, c.BGFX_TEXTURE_FORMAT_RGBA8, c.BGFX_TEXTURE_BLIT_DST | c.BGFX_TEXTURE_READ_BACK, null, 0);
        if (handle.idx == invalid_handle) return error.TextureCreate;
        return handle;
    }

    /// Enqueues a full-size copy of src into dst on view_id; blits run
    /// in view order, so a view id past every draw pass copies the
    /// finished frame.
    pub fn blitTexture(view_id: u8, dst: TextureHandle, src: TextureHandle, width: u16, height: u16) void {
        c.bgfx_blit(view_id, dst, 0, 0, 0, 0, src, 0, 0, 0, 0, width, height, 0);
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
