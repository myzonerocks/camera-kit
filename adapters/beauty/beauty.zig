//! Binding over the beauty chain's C boundary. One context per session,
//! six zero-to-one parameters, and a synchronous per-frame pass over RGBA
//! pixels on the caller's thread. The landmark-driven effects read the
//! tracked contour when one is provided.

const std = @import("std");
const builtin = @import("builtin");
const face = @import("face");
const face106 = @import("face106");

const is_android = builtin.os.tag == .linux and builtin.abi.isAndroid();

pub const supported = true;

pub const Effect = enum(i32) {
    smooth = 0,
    whiten = 1,
    thin_face = 2,
    big_eye = 3,
    lipstick = 4,
    blush = 5,
};

extern fn goss_beauty_create(resource_path: ?[*:0]const u8) ?*anyopaque;
extern fn goss_beauty_destroy(handle: ?*anyopaque) void;
extern fn goss_beauty_set(handle: ?*anyopaque, effect: i32, value: f32) void;
extern fn goss_beauty_process(handle: ?*anyopaque, rgba_in: [*]const u8, width: i32, height: i32, landmarks106: ?[*]const f32, rgba_out: [*]u8) i32;
extern fn goss_beauty_output_texture(handle: ?*anyopaque) u32;

extern fn goss_beauty_interop_create() ?*anyopaque;
extern fn goss_beauty_interop_destroy(handle: ?*anyopaque) void;
extern fn goss_beauty_interop_composite(handle: ?*anyopaque, source_texture: u32, width: i32, height: i32) ?*anyopaque;
// Apple only, no Android sibling - Android's composite() already returns
// an AHardwareBuffer wrapExternalTexture's Vulkan sibling imports directly.
extern fn goss_beauty_interop_native_texture(handle: ?*anyopaque, device: ?*anyopaque) ?*anyopaque;

const is_apple = builtin.os.tag == .macos or builtin.os.tag == .ios;

pub const Beauty = struct {
    handle: *anyopaque,
};

/// The GPU-side bridge from the beauty chain's own output texture into a
/// platform-shared surface bgfx reads zero-copy from. One instance per
/// session; independent of Beauty itself since it owns platform surface
/// state, not chain state.
pub const Interop = struct {
    handle: *anyopaque,
};

pub fn interopCreate(gpa: std.mem.Allocator) error{ Unsupported, OutOfMemory }!*Interop {
    const handle = goss_beauty_interop_create() orelse return error.Unsupported;
    const interop = gpa.create(Interop) catch {
        goss_beauty_interop_destroy(handle);
        return error.OutOfMemory;
    };
    interop.* = .{ .handle = handle };
    return interop;
}

pub fn interopDestroy(gpa: std.mem.Allocator, interop: *Interop) void {
    goss_beauty_interop_destroy(interop.handle);
    gpa.destroy(interop);
}

/// Blits the beauty chain's most recent output into the shared surface
/// and returns its native handle (a CVPixelBufferRef on Apple platforms),
/// unretained - valid until the next composite call on this Interop or
/// interopDestroy, never released by the caller. Call immediately after
/// process() on the same thread: the blit reads whatever GL context is
/// current rather than gpupixel's own (not exposed publicly), which is
/// only correct while gpupixel's context is still the one bound here.
pub fn composite(interop: *Interop, beauty: *Beauty, width: u32, height: u32) ?*anyopaque {
    const texture = goss_beauty_output_texture(beauty.handle);
    if (texture == 0) return null;
    return goss_beauty_interop_composite(interop.handle, texture, @intCast(width), @intCast(height));
}

/// bgfx's own Metal-side view of composite()'s most recent output -
/// composite() itself returns a CVPixelBufferRef (for CPU readback), not
/// something wrapExternalTexture can bind. Call right after composite();
/// device is render.Renderer.nativeDevice(). No-op off Apple.
pub fn interopNativeTexture(interop: *Interop, device: ?*anyopaque) ?*anyopaque {
    if (!is_apple) return null;
    return goss_beauty_interop_native_texture(interop.handle, device);
}

pub fn create(gpa: std.mem.Allocator, resource_path: [*:0]const u8) error{ Unsupported, OutOfMemory }!*Beauty {
    const handle = goss_beauty_create(resource_path) orelse return error.Unsupported;
    const beauty = gpa.create(Beauty) catch {
        goss_beauty_destroy(handle);
        return error.OutOfMemory;
    };
    beauty.* = .{ .handle = handle };
    return beauty;
}

pub fn destroy(gpa: std.mem.Allocator, beauty: *Beauty) void {
    goss_beauty_destroy(beauty.handle);
    gpa.destroy(beauty);
}

pub fn set(beauty: *Beauty, effect: Effect, value: f32) void {
    goss_beauty_set(beauty.handle, @intFromEnum(effect), std.math.clamp(value, 0.0, 1.0));
}

/// Fills contour from a tracked face result's landmarks, or returns
/// null while no usable face holds. Landmarks are raw sensor space; a
/// frame drawn with the preview blit's rotation/mirror needs the same
/// transform here - mirror first, then quarter turns, like the blit.
fn contourFromResult(result: ?*const face.Result, width: u32, height: u32, rotation_quarter_turns: u32, mirror: bool, contour: *[face106.point_count * 2]f32) ?[*]const f32 {
    const tracked = result orelse return null;
    if (tracked.landmark_count_out != face.landmark_count or tracked.presence < 0.5) return null;
    var landmarks: [face.landmark_count]face.Landmark = undefined;
    for (&landmarks, 0..) |*landmark, at| {
        landmark.* = .{
            .x = tracked.landmarks[at * 3],
            .y = tracked.landmarks[at * 3 + 1],
            .z = tracked.landmarks[at * 3 + 2],
        };
    }
    face106.fill(&landmarks, @floatFromInt(width), @floatFromInt(height), contour);
    if (mirror or rotation_quarter_turns % 4 != 0) {
        var at: usize = 0;
        while (at < face106.point_count) : (at += 1) {
            var x = contour[at * 2] * 2.0 - 1.0;
            const y = 1.0 - contour[at * 2 + 1] * 2.0;
            if (mirror) x = -x;
            const rotated: [2]f32 = switch (rotation_quarter_turns % 4) {
                0 => .{ x, y },
                1 => .{ -y, x },
                2 => .{ -x, -y },
                3 => .{ y, -x },
                else => unreachable,
            };
            contour[at * 2] = (rotated[0] + 1.0) * 0.5;
            contour[at * 2 + 1] = (1.0 - rotated[1]) * 0.5;
        }
    }
    return contour;
}

/// Runs the chain over one frame in place through a scratch copy the
/// caller provides, with the tracked contour when a face holds.
pub fn process(
    beauty: *Beauty,
    rgba_in: [*]const u8,
    width: u32,
    height: u32,
    result: ?*const face.Result,
    rgba_out: [*]u8,
) error{ProcessRefused}!void {
    var contour: [face106.point_count * 2]f32 = undefined;
    const contour_ptr = contourFromResult(result, width, height, 0, false, &contour);
    if (goss_beauty_process(beauty.handle, rgba_in, @intCast(width), @intCast(height), contour_ptr, rgba_out) != 0) {
        return error.ProcessRefused;
    }
}

extern fn goss_beauty_input_create() ?*anyopaque;
extern fn goss_beauty_input_destroy(handle: ?*anyopaque) void;
extern fn goss_beauty_input_surface(handle: ?*anyopaque, device: ?*anyopaque, width: i32, height: i32) ?*anyopaque;
extern fn goss_beauty_input_process(input_handle: ?*anyopaque, beauty_handle: ?*anyopaque, width: i32, height: i32, landmarks106: ?[*]const f32) i32;
// Android/Vulkan only, no Apple sibling.
extern fn goss_beauty_input_hardware_buffer(handle: ?*anyopaque, width: i32, height: i32) ?*anyopaque;

/// The reverse of Interop: a platform-shared surface bgfx writes the
/// live preview into zero-copy, that gpupixel then reads zero-copy on
/// its own thread - what lets the beauty chain run over the frame
/// actually reaching the screen instead of only ever the ABI's CPU
/// roundtrip. One instance per session, independent of Beauty and
/// Interop for the same reason Interop is: it owns platform surface
/// state, not chain state.
pub const InputSurface = struct {
    handle: *anyopaque,
};

pub fn inputSurfaceCreate(gpa: std.mem.Allocator) error{ Unsupported, OutOfMemory }!*InputSurface {
    const handle = goss_beauty_input_create() orelse return error.Unsupported;
    const surface = gpa.create(InputSurface) catch {
        goss_beauty_input_destroy(handle);
        return error.OutOfMemory;
    };
    surface.* = .{ .handle = handle };
    return surface;
}

pub fn inputSurfaceDestroy(gpa: std.mem.Allocator, surface: *InputSurface) void {
    goss_beauty_input_destroy(surface.handle);
    gpa.destroy(surface);
}

/// (Re)creates the shared surface against device (bgfx's own native
/// device handle, render.Renderer.nativeDevice) sized to width/height,
/// and returns bgfx's own view of it - a native texture pointer
/// wrapExternalTexture can bind with no copy. Unretained: valid until
/// the next call that actually resizes, or inputSurfaceDestroy.
pub fn inputSurfaceNativeTexture(surface: *InputSurface, device: ?*anyopaque, width: u32, height: u32) ?*anyopaque {
    return goss_beauty_input_surface(surface.handle, device, @intCast(width), @intCast(height));
}

/// Vulkan sibling of inputSurfaceNativeTexture: same surface, returns
/// the raw AHardwareBuffer* instead of a GLES texture id.
pub fn inputSurfaceHardwareBuffer(surface: *InputSurface, width: u32, height: u32) ?*anyopaque {
    if (!is_android) return null;
    return goss_beauty_input_hardware_buffer(surface.handle, @intCast(width), @intCast(height));
}

/// Runs the beauty chain over the frame bgfx just wrote into surface,
/// with the tracked contour when a face holds - the GPU-input mirror of
/// process(). Call after that write has been submitted for this frame;
/// composite() then reads the result back out, same as the CPU path.
/// rotation_quarter_turns and mirror must match the caller's own
/// preview blit, since that blit produced the frame in this surface.
pub fn processTexture(surface: *InputSurface, beauty: *Beauty, width: u32, height: u32, rotation_quarter_turns: u32, mirror: bool, result: ?*const face.Result) bool {
    var contour: [face106.point_count * 2]f32 = undefined;
    const contour_ptr = contourFromResult(result, width, height, rotation_quarter_turns, mirror, &contour);
    if (contour_ptr != null) {
        // The chain ingests the shared surface through a V-flipping blit
        // (GL's bottom-up framebuffer convention), so it works on a
        // vertically flipped image - the contour flips with it. The CPU
        // path feeds raw rows straight in and never needs this.
        var at: usize = 0;
        while (at < face106.point_count) : (at += 1) {
            contour[at * 2 + 1] = 1.0 - contour[at * 2 + 1];
        }
    }
    return goss_beauty_input_process(surface.handle, beauty.handle, @intCast(width), @intCast(height), contour_ptr) == 0;
}
