//! Binding over the beauty chain's C boundary. One context per session,
//! six zero-to-one parameters, and a synchronous per-frame pass over RGBA
//! pixels on the caller's thread. The landmark-driven effects read the
//! tracked contour when one is provided.

const std = @import("std");
const face = @import("face");
const face106 = @import("face106");

pub const supported = true;

pub const Effect = enum(i32) {
    smooth = 0,
    whiten = 1,
    thin_face = 2,
    big_eye = 3,
    lipstick = 4,
    blush = 5,
};

extern fn ck_beauty_create(resource_path: ?[*:0]const u8) ?*anyopaque;
extern fn ck_beauty_destroy(handle: ?*anyopaque) void;
extern fn ck_beauty_set(handle: ?*anyopaque, effect: i32, value: f32) void;
extern fn ck_beauty_process(handle: ?*anyopaque, rgba_in: [*]const u8, width: i32, height: i32, landmarks106: ?[*]const f32, rgba_out: [*]u8) i32;
extern fn ck_beauty_output_texture(handle: ?*anyopaque) u32;

extern fn ck_beauty_interop_create() ?*anyopaque;
extern fn ck_beauty_interop_destroy(handle: ?*anyopaque) void;
extern fn ck_beauty_interop_composite(handle: ?*anyopaque, source_texture: u32, width: i32, height: i32) ?*anyopaque;

pub const Beauty = struct {
    handle: *anyopaque,
};

/// The GPU-side bridge from the beauty chain's own output texture into a
/// platform-shared surface bgfx reads zero-copy from, per
/// docs/private/DECISIONS.md's 2026-08-15 entry. One instance per
/// session; independent of Beauty itself since it owns platform surface
/// state, not chain state.
pub const Interop = struct {
    handle: *anyopaque,
};

pub fn interopCreate(gpa: std.mem.Allocator) error{ Unsupported, OutOfMemory }!*Interop {
    const handle = ck_beauty_interop_create() orelse return error.Unsupported;
    const interop = gpa.create(Interop) catch {
        ck_beauty_interop_destroy(handle);
        return error.OutOfMemory;
    };
    interop.* = .{ .handle = handle };
    return interop;
}

pub fn interopDestroy(gpa: std.mem.Allocator, interop: *Interop) void {
    ck_beauty_interop_destroy(interop.handle);
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
    const texture = ck_beauty_output_texture(beauty.handle);
    if (texture == 0) return null;
    return ck_beauty_interop_composite(interop.handle, texture, @intCast(width), @intCast(height));
}

pub fn create(gpa: std.mem.Allocator, resource_path: [*:0]const u8) error{ Unsupported, OutOfMemory }!*Beauty {
    const handle = ck_beauty_create(resource_path) orelse return error.Unsupported;
    const beauty = gpa.create(Beauty) catch {
        ck_beauty_destroy(handle);
        return error.OutOfMemory;
    };
    beauty.* = .{ .handle = handle };
    return beauty;
}

pub fn destroy(gpa: std.mem.Allocator, beauty: *Beauty) void {
    ck_beauty_destroy(beauty.handle);
    gpa.destroy(beauty);
}

pub fn set(beauty: *Beauty, effect: Effect, value: f32) void {
    ck_beauty_set(beauty.handle, @intFromEnum(effect), std.math.clamp(value, 0.0, 1.0));
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
    var contour_ptr: ?[*]const f32 = null;
    if (result) |tracked| {
        if (tracked.landmark_count_out == face.landmark_count and tracked.presence >= 0.5) {
            var landmarks: [face.landmark_count]face.Landmark = undefined;
            for (&landmarks, 0..) |*landmark, at| {
                landmark.* = .{
                    .x = tracked.landmarks[at * 3],
                    .y = tracked.landmarks[at * 3 + 1],
                    .z = tracked.landmarks[at * 3 + 2],
                };
            }
            face106.fill(&landmarks, @floatFromInt(width), @floatFromInt(height), &contour);
            contour_ptr = &contour;
        }
    }
    if (ck_beauty_process(beauty.handle, rgba_in, @intCast(width), @intCast(height), contour_ptr, rgba_out) != 0) {
        return error.ProcessRefused;
    }
}
