//! Beauty on platforms without the compiled effects engine: every entry
//! refuses, and the export layer reports the refusal as its own status.

const std = @import("std");
const face = @import("face");

pub const supported = false;

pub const Effect = enum(i32) {
    smooth = 0,
    whiten = 1,
    thin_face = 2,
    big_eye = 3,
    lipstick = 4,
    blush = 5,
};

pub const Beauty = struct {};

pub fn create(gpa: std.mem.Allocator, resource_path: [*:0]const u8) error{ Unsupported, OutOfMemory }!*Beauty {
    _ = gpa;
    _ = resource_path;
    return error.Unsupported;
}

pub fn destroy(gpa: std.mem.Allocator, beauty: *Beauty) void {
    _ = gpa;
    _ = beauty;
}

pub fn set(beauty: *Beauty, effect: Effect, value: f32) void {
    _ = beauty;
    _ = effect;
    _ = value;
}

pub fn process(
    beauty: *Beauty,
    rgba_in: [*]const u8,
    width: u32,
    height: u32,
    result: ?*const face.Result,
    rgba_out: [*]u8,
) error{ProcessRefused}!void {
    _ = beauty;
    _ = rgba_in;
    _ = width;
    _ = height;
    _ = result;
    _ = rgba_out;
    return error.ProcessRefused;
}
