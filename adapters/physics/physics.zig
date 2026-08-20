//! The rigid-body world for lens content: Jolt behind a C shim, fixed
//! 60 Hz stepping for determinism, poses read back as column-major
//! transforms ready for the model draw path.

const std = @import("std");

/// Whether a real backend exists on this target.
pub const supported = true;

pub const Shape = enum(u32) {
    box = 0,
    sphere = 1,
};

pub const Motion = enum(u32) {
    static = 0,
    dynamic = 1,
};

pub const invalid_body: u32 = std.math.maxInt(u32);

extern fn goss_physics_world_create(gravity_y: f32) ?*anyopaque;
extern fn goss_physics_world_destroy(handle: *anyopaque) void;
extern fn goss_physics_body_add(handle: *anyopaque, shape: u32, px: f32, py: f32, pz: f32, sx: f32, sy: f32, sz: f32, motion: u32) u32;
extern fn goss_physics_step(handle: *anyopaque, dt_seconds: f32) void;
extern fn goss_physics_body_pose(handle: *anyopaque, body: u32, out: *[16]f32) i32;

pub const World = struct {
    handle: *anyopaque,

    pub fn create(gravity_y: f32) !World {
        return .{ .handle = goss_physics_world_create(gravity_y) orelse return error.WorldCreateFailed };
    }

    pub fn destroy(world: World) void {
        goss_physics_world_destroy(world.handle);
    }

    /// Half extents size a box; a sphere reads its radius from size[0].
    pub fn addBody(world: World, shape: Shape, position: [3]f32, size: [3]f32, motion: Motion) !u32 {
        const id = goss_physics_body_add(world.handle, @intFromEnum(shape), position[0], position[1], position[2], size[0], size[1], size[2], @intFromEnum(motion));
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Accumulates dt into fixed 60 Hz substeps - the determinism
    /// contract: the same dt sequence always lands the same poses.
    pub fn step(world: World, dt_seconds: f32) void {
        goss_physics_step(world.handle, dt_seconds);
    }

    /// The body's column-major world transform.
    pub fn bodyPose(world: World, body: u32) ![16]f32 {
        var out: [16]f32 = undefined;
        if (goss_physics_body_pose(world.handle, body, &out) != 0) return error.BodyPoseFailed;
        return out;
    }
};

const t = std.testing;

test "a dropped sphere comes to rest on the floor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    _ = try world.addBody(.box, .{ 0, -0.5, 0 }, .{ 10, 0.5, 10 }, .static);
    const ball = try world.addBody(.sphere, .{ 0, 3.0, 0 }, .{ 0.25, 0, 0 }, .dynamic);

    for (0..240) |_| world.step(1.0 / 60.0);
    const pose = try world.bodyPose(ball);
    // Resting height: floor top (0) plus the radius, less the solver's
    // documented penetration slop (0.02 by default).
    try t.expectApproxEqAbs(@as(f32, 0.25), pose[13], 0.03);
}

test "two identical worlds land bit-identical poses" {
    var poses: [2][16]f32 = undefined;
    for (0..2) |run| {
        const world = try World.create(-9.81);
        defer world.destroy();
        _ = try world.addBody(.box, .{ 0, -0.5, 0 }, .{ 10, 0.5, 10 }, .static);
        const ball = try world.addBody(.sphere, .{ 0.3, 2.0, -0.1 }, .{ 0.2, 0, 0 }, .dynamic);
        for (0..90) |_| world.step(1.0 / 60.0);
        poses[run] = try world.bodyPose(ball);
    }
    try t.expectEqualSlices(f32, &poses[0], &poses[1]);
}
