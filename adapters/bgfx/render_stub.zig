//! Render backend stub for targets without a compiled render stack, such as
//! the CI host running unit tests. Mirrors the real module's surface;
//! every entry point reports the renderer as unavailable. The engine treats
//! that as a configuration the SDK must handle, never a crash.

const std = @import("std");
const math = @import("math");

pub const invalid_handle: u16 = std.math.maxInt(u16);

pub const TextureHandle = struct { idx: u16 = invalid_handle };
pub const VertexBufferHandle = struct { idx: u16 = invalid_handle };
pub const IndexBufferHandle = struct { idx: u16 = invalid_handle };

/// fs_beauty_reshape.sc's own u_facePoints packing - mirrored here so
/// abi.zig's contour slicing compiles identically against the stub.
pub const face_point_vec4_count = 53;

// Format constants mirrored so the export layer compiles identically
// against the stub and the real binding.
pub const c = struct {
    pub const BGFX_TEXTURE_FORMAT_R8: u32 = 0;
    pub const BGFX_TEXTURE_FORMAT_RG8: u32 = 1;
    pub const BGFX_TEXTURE_FORMAT_BGRA8: u32 = 2;
    pub const BGFX_TEXTURE_FORMAT_RGBA8: u32 = 3;
};

pub const InitOptions = struct {
    native_window_handle: ?*anyopaque,
    width: u32,
    height: u32,
    vsync: bool = true,
};

pub const Nv12Textures = struct {
    y: TextureHandle,
    uv: TextureHandle,
};

pub const PreviewFrame = union(enum) {
    bgra: struct {
        texture: TextureHandle,
    },
    nv12: struct {
        y: TextureHandle,
        uv: TextureHandle,
        conversion: math.color.Conversion,
    },
};

pub const Renderer = struct {
    default_mask_texture: TextureHandle = .{},
    zero_mask_texture: TextureHandle = .{},
    width: u32 = 0,
    height: u32 = 0,

    pub fn init(gpa: std.mem.Allocator, options: InitOptions) !Renderer {
        _ = gpa;
        _ = options;
        return error.RendererUnavailable;
    }

    pub fn deinit(r: *Renderer) void {
        _ = r;
    }

    pub fn resize(r: *Renderer, width: u32, height: u32) void {
        _ = r;
        _ = width;
        _ = height;
    }

    pub fn wrapExternalRenderTarget(r: *Renderer, pt: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) ?TextureHandle {
        _ = r;
        _ = pt;
        _ = width;
        _ = height;
        _ = format;
        _ = native_ptr;
        return null;
    }

    pub const PersistentTexture = struct {
        pub fn rebind(self: *PersistentTexture, width: u16, height: u16, format: u32, native_ptr: usize) TextureHandle {
            _ = self;
            _ = width;
            _ = height;
            _ = format;
            _ = native_ptr;
            return .{};
        }

        pub fn deinit(self: *PersistentTexture) void {
            _ = self;
        }
    };

    pub fn createAndroidBeautyRenderTarget(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?TextureHandle {
        _ = r;
        _ = width;
        _ = height;
        _ = hardware_buffer;
        return null;
    }

    pub fn wrapAndroidBeautyOutput(r: *Renderer, width: u16, height: u16, hardware_buffer: *anyopaque) ?TextureHandle {
        _ = r;
        _ = width;
        _ = height;
        _ = hardware_buffer;
        return null;
    }

    pub fn destroyTexture(r: *Renderer, handle: TextureHandle) void {
        _ = r;
        _ = handle;
    }

    pub fn nativeDevice(r: *Renderer) ?*anyopaque {
        _ = r;
        return null;
    }

    pub fn isAndroidVulkan(r: *const Renderer) bool {
        _ = r;
        return false;
    }

    pub fn createStaticTexture(width: u16, height: u16, rgba: []const u8) TextureHandle {
        _ = width;
        _ = height;
        _ = rgba;
        return .{};
    }

    pub fn createMaskTexture(width: u16, height: u16, mask: []const u8) TextureHandle {
        _ = width;
        _ = height;
        _ = mask;
        return .{};
    }

    pub fn passthroughProgram(r: *Renderer) ProgramHandle {
        _ = r;
        return .{};
    }

    pub fn submitPreview(r: *Renderer, view_id: u16, preview: PreviewFrame, rotation_degrees: u32, mirror: bool) void {
        _ = r;
        _ = view_id;
        _ = preview;
        _ = rotation_degrees;
        _ = mirror;
    }

    pub fn submitFaceMesh(r: *Renderer, view_id: u16, background_texture: TextureHandle, mesh_texture: TextureHandle, landmarks: []const f32, frame_width: f32, frame_height: f32, intensity: f32) void {
        _ = r;
        _ = view_id;
        _ = background_texture;
        _ = mesh_texture;
        _ = landmarks;
        _ = frame_width;
        _ = frame_height;
        _ = intensity;
    }

    pub fn submitShaderPass(r: *Renderer, view_id: u16, program: ProgramHandle, input_texture: TextureHandle, mask_texture: TextureHandle) void {
        _ = r;
        _ = view_id;
        _ = program;
        _ = input_texture;
        _ = mask_texture;
    }

    pub fn submitLutPass(r: *Renderer, view_id: u16, input_texture: TextureHandle, lut_texture: TextureHandle) void {
        _ = r;
        _ = view_id;
        _ = input_texture;
        _ = lut_texture;
    }

    pub fn submitBlendPass(r: *Renderer, view_id: u16, input_texture: TextureHandle, background_texture: TextureHandle, mask_texture: TextureHandle) void {
        _ = r;
        _ = view_id;
        _ = input_texture;
        _ = background_texture;
        _ = mask_texture;
    }

    pub fn submitBlurPass(r: *Renderer, view_id: u16, input_texture: TextureHandle, step: [2]f32) void {
        _ = r;
        _ = view_id;
        _ = input_texture;
        _ = step;
    }

    pub fn submitBeautyFace(r: *Renderer, view_id: u16, input_texture: TextureHandle, mean_texture: TextureHandle, lookup_gray: TextureHandle, lookup_origin: TextureHandle, lookup_skin: TextureHandle, lookup_custom: TextureHandle, smooth_amount: f32, whiten_amount: f32) void {
        _ = r;
        _ = view_id;
        _ = input_texture;
        _ = mean_texture;
        _ = lookup_gray;
        _ = lookup_origin;
        _ = lookup_skin;
        _ = lookup_custom;
        _ = smooth_amount;
        _ = whiten_amount;
    }

    pub fn submitBeautyReshape(r: *Renderer, view_id: u16, input_texture: TextureHandle, face_points: *const [face_point_vec4_count * 4]f32, aspect_ratio: f32, thin_face_amount: f32, big_eye_amount: f32) void {
        _ = r;
        _ = view_id;
        _ = input_texture;
        _ = face_points;
        _ = aspect_ratio;
        _ = thin_face_amount;
        _ = big_eye_amount;
    }

    // 111 tracked points, two floats each - makeup_mesh.canonical_uv.len
    // in the real module, mirrored as a literal here rather than
    // importing makeup_mesh into a stub that otherwise has zero
    // dependencies of its own.
    pub fn submitMakeup(r: *Renderer, view_id: u16, background_texture: TextureHandle, makeup_texture: TextureHandle, uv_buffer: VertexBufferHandle, positions: *const [222]f32, intensity: f32) void {
        _ = r;
        _ = view_id;
        _ = background_texture;
        _ = makeup_texture;
        _ = uv_buffer;
        _ = positions;
        _ = intensity;
    }

    pub fn makeupLipstickUvBuffer(r: *const Renderer) VertexBufferHandle {
        _ = r;
        return .{};
    }

    pub fn makeupBlushUvBuffer(r: *const Renderer) VertexBufferHandle {
        _ = r;
        return .{};
    }

    pub const ModelMesh = struct {
        vertex_buffer: VertexBufferHandle = .{},
        index_buffer: IndexBufferHandle = .{},
        index_count: u32 = 0,
    };

    pub fn createModelMesh(r: *Renderer, positions: []const [3]f32, indices: []const u32) !ModelMesh {
        _ = r;
        _ = positions;
        _ = indices;
        return error.RendererUnavailable;
    }

    pub fn destroyModelMesh(mesh: ModelMesh) void {
        _ = mesh;
    }

    pub fn submitModel(r: *Renderer, blit_view: u8, mesh_view: u8, input_texture: TextureHandle, mesh: ModelMesh, model_matrix: math.Mat4, base_color: [4]f32, aspect_ratio: f32) void {
        _ = r;
        _ = blit_view;
        _ = mesh_view;
        _ = input_texture;
        _ = mesh;
        _ = model_matrix;
        _ = base_color;
        _ = aspect_ratio;
    }

    pub fn uploadNv12(r: *Renderer, width: u16, height: u16, y: [*]const u8, y_stride: u32, uv: [*]const u8, uv_stride: u32) !Nv12Textures {
        _ = r;
        _ = width;
        _ = height;
        _ = y;
        _ = y_stride;
        _ = uv;
        _ = uv_stride;
        return error.RendererUnavailable;
    }

    pub fn uploadRgba(r: *Renderer, width: u16, height: u16, format: u32, rgba: [*]const u8, stride: u32) !TextureHandle {
        _ = r;
        _ = width;
        _ = height;
        _ = format;
        _ = rgba;
        _ = stride;
        return error.RendererUnavailable;
    }

    pub fn submitHardwareBuffer(r: *Renderer, hardware_buffer: *anyopaque, width: u32, height: u32, conversion: math.color.Conversion) !TextureHandle {
        _ = r;
        _ = hardware_buffer;
        _ = width;
        _ = height;
        _ = conversion;
        return error.Unsupported;
    }

    pub fn touch(r: *Renderer) void {
        _ = r;
    }

    pub fn frame(r: *Renderer) u32 {
        _ = r;
        return 0;
    }

    pub fn requestScreenshot(r: *Renderer, path: [*:0]const u8) void {
        _ = r;
        _ = path;
    }

    pub fn readTexture(texture: TextureHandle, data: [*]u8) u32 {
        _ = texture;
        _ = data;
        return 0;
    }

    pub const ClothMesh = struct {
        position_buffer: TextureHandle = .{},
        index_buffer: TextureHandle = .{},
        vertex_count: u32 = 0,
        index_count: u32 = 0,
    };

    pub fn createClothMesh(r: *Renderer, cols: u32, rows: u32) !ClothMesh {
        _ = r;
        _ = cols;
        _ = rows;
        return .{};
    }

    pub fn updateClothMesh(r: *Renderer, mesh: ClothMesh, positions: []const f32) void {
        _ = r;
        _ = mesh;
        _ = positions;
    }

    pub fn destroyClothMesh(mesh: ClothMesh) void {
        _ = mesh;
    }

    pub fn submitCloth(r: *Renderer, blit_view: u8, mesh_view: u8, input_texture: TextureHandle, mesh: ClothMesh, base_color: [4]f32, aspect_ratio: f32) void {
        _ = r;
        _ = blit_view;
        _ = mesh_view;
        _ = input_texture;
        _ = mesh;
        _ = base_color;
        _ = aspect_ratio;
    }

    pub fn submitModelWithCamera(r: *Renderer, blit_view: u8, mesh_view: u8, input_texture: TextureHandle, mesh: ModelMesh, model_matrix: math.Mat4, view: math.Mat4, projection: math.Mat4, base_color: [4]f32) void {
        _ = r;
        _ = blit_view;
        _ = mesh_view;
        _ = input_texture;
        _ = mesh;
        _ = model_matrix;
        _ = view;
        _ = projection;
        _ = base_color;
    }

    pub fn createWindowTarget(nwh: *anyopaque, width: u16, height: u16) !OffscreenTarget {
        _ = nwh;
        _ = width;
        _ = height;
        return error.FrameBufferCreate;
    }

    pub fn createReadbackTexture(width: u16, height: u16) !TextureHandle {
        _ = width;
        _ = height;
        return .{};
    }

    pub fn blitTexture(view_id: u8, dst: TextureHandle, src: TextureHandle, width: u16, height: u16) void {
        _ = view_id;
        _ = dst;
        _ = src;
        _ = width;
        _ = height;
    }

    pub fn currentShaderProfileTag() ![]const u8 {
        return error.RendererUnavailable;
    }

    pub fn loadLensProgram(fs_bytes: []const u8) !ProgramHandle {
        _ = fs_bytes;
        return error.RendererUnavailable;
    }

    pub fn loadLutProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadBlendProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadBlurProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadBeautyFaceProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadBeautyReshapeProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadMakeupProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn loadModelProgram() !ProgramHandle {
        return error.RendererUnavailable;
    }

    pub fn destroyProgram(program: ProgramHandle) void {
        _ = program;
    }

    pub const OffscreenTarget = struct { texture: TextureHandle = .{} };

    pub fn createOffscreenTarget(width: u16, height: u16) !OffscreenTarget {
        _ = width;
        _ = height;
        return error.RendererUnavailable;
    }

    pub fn destroyOffscreenTarget(target: OffscreenTarget) void {
        _ = target;
    }

    pub fn createExternalTarget(handle: TextureHandle) !OffscreenTarget {
        _ = handle;
        return error.RendererUnavailable;
    }

    pub fn setViewTarget(view_id: u16, target: ?OffscreenTarget, width: u16, height: u16) void {
        _ = view_id;
        _ = target;
        _ = width;
        _ = height;
    }
};

pub const ProgramHandle = struct { idx: u16 = invalid_handle };

test "stub renderer refuses to initialize" {
    try std.testing.expectError(error.RendererUnavailable, Renderer.init(std.testing.allocator, .{
        .native_window_handle = null,
        .width = 1,
        .height = 1,
    }));
}
