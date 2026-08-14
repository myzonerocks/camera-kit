//! Render backend stub for targets without a compiled render stack, such as
//! the CI host running unit tests. Mirrors the real module's surface;
//! every entry point reports the renderer as unavailable. The engine treats
//! that as a configuration the shell must handle, never a crash.

const std = @import("std");
const math = @import("math");

pub const invalid_handle: u16 = std.math.maxInt(u16);

pub const TextureHandle = struct { idx: u16 = invalid_handle };

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

    pub fn wrapExternalTexture(r: *Renderer, width: u16, height: u16, format: u32, native_ptr: usize) TextureHandle {
        _ = r;
        _ = width;
        _ = height;
        _ = format;
        _ = native_ptr;
        return .{};
    }

    pub fn destroyTexture(r: *Renderer, handle: TextureHandle) void {
        _ = r;
        _ = handle;
    }

    pub fn submitPreview(r: *Renderer, preview: PreviewFrame, rotation_degrees: u32, mirror: bool) void {
        _ = r;
        _ = preview;
        _ = rotation_degrees;
        _ = mirror;
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
};

test "stub renderer refuses to initialize" {
    try std.testing.expectError(error.RendererUnavailable, Renderer.init(std.testing.allocator, .{
        .native_window_handle = null,
        .width = 1,
        .height = 1,
    }));
}
