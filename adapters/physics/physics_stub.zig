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
    /// The engine drives its pose each step; chained bodies follow.
    kinematic = 2,
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

    pub fn constrainDistance(world: World, a: u32, b: u32, point_a: [3]f32, point_b: [3]f32, min: f32, max: f32) !void {
        _ = world;
        _ = a;
        _ = b;
        _ = point_a;
        _ = point_b;
        _ = min;
        _ = max;
        return error.WorldCreateFailed;
    }

    pub fn moveBody(world: World, body: u32, position: [3]f32, dt_seconds: f32) void {
        _ = world;
        _ = body;
        _ = position;
        _ = dt_seconds;
    }

    pub fn bodyPose(world: World, body: u32) ![16]f32 {
        _ = world;
        _ = body;
        return error.BodyPoseFailed;
    }
};
