//! Stub glTF decode types for targets with no real cgltf wiring (web):
//! provides the same shapes core/abi's model.gltf dispatch references
//! so it type-checks on every target, decode always fails closed.
//! Directory-based lens activation - the only path that could ever
//! reach a model loader - already refuses with the same has_file_io
//! gate before this would ever be reached.

const std = @import("std");
const math = @import("math");

pub const Error = error{ OutOfMemory, MalformedAsset, UnsupportedAsset, ExternalReference };

pub const DecodedAnimChannel = struct {
    path: enum { translation, rotation, scale },
    times: []f32,
    values: []f32,
};

pub const DecodedAnimation = struct {
    duration_seconds: f32,
    channels: []DecodedAnimChannel,

    pub fn sample(anim: *const DecodedAnimation, elapsed_seconds: f32) math.Mat4 {
        _ = anim;
        _ = elapsed_seconds;
        return math.Mat4.identity;
    }
};

pub const DecodedModel = struct {
    positions: [][3]f32,
    indices: []u32,
    base_color: [4]f32,
    animation: ?DecodedAnimation,
};

pub fn decodeModel(gpa: std.mem.Allocator, bytes: []const u8) Error!DecodedModel {
    _ = gpa;
    _ = bytes;
    return error.UnsupportedAsset;
}

pub fn freeDecodedModel(gpa: std.mem.Allocator, model: DecodedModel) void {
    _ = gpa;
    _ = model;
}

pub fn freeAnimation(gpa: std.mem.Allocator, anim: *const DecodedAnimation) void {
    _ = gpa;
    _ = anim;
}
