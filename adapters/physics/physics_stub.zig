//! Physics for targets whose backend has not landed: same surface,
//! the capability honestly absent.

const std = @import("std");

pub const supported = false;

pub const Shape = enum(u32) {
    box = 0,
    sphere = 1,
};

pub const Motion = enum(u32) {
    static = 0,
    dynamic = 1,
};

pub const invalid_body: u32 = std.math.maxInt(u32);

pub const World = struct {
    handle: *anyopaque,

    pub fn create(gravity_y: f32) !World {
        _ = gravity_y;
        return error.WorldCreateFailed;
    }

    pub fn destroy(world: World) void {
        _ = world;
    }

    pub fn addBody(world: World, shape: Shape, position: [3]f32, size: [3]f32, motion: Motion) !u32 {
        _ = world;
        _ = shape;
        _ = position;
        _ = size;
        _ = motion;
        return error.BodyAddFailed;
    }

    pub fn step(world: World, dt_seconds: f32) void {
        _ = world;
        _ = dt_seconds;
    }

    pub fn bodyPose(world: World, body: u32) ![16]f32 {
        _ = world;
        _ = body;
        return error.BodyPoseFailed;
    }
};
