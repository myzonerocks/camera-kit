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
    /// The engine drives its pose each step; chained bodies follow.
    kinematic = 2,
};

pub const invalid_body: u32 = std.math.maxInt(u32);

extern fn goss_physics_world_create(gravity_y: f32) ?*anyopaque;
extern fn goss_physics_world_destroy(handle: *anyopaque) void;
extern fn goss_physics_body_add(handle: *anyopaque, shape: u32, px: f32, py: f32, pz: f32, sx: f32, sy: f32, sz: f32, motion: u32) u32;
extern fn goss_physics_step(handle: *anyopaque, dt_seconds: f32) void;
extern fn goss_physics_body_pose(handle: *anyopaque, body: u32, out: *[16]f32) i32;
extern fn goss_physics_constrain_distance(handle: *anyopaque, a: u32, b: u32, ax: f32, ay: f32, az: f32, bx: f32, by: f32, bz: f32, min: f32, max: f32) i32;
extern fn goss_physics_body_move(handle: *anyopaque, body: u32, px: f32, py: f32, pz: f32, dt: f32) void;
extern fn goss_physics_add_cloth(handle: *anyopaque, cols: u32, rows: u32, width: f32, height: f32, px: f32, py: f32, pz: f32) u32;
extern fn goss_physics_cloth_read(handle: *anyopaque, body: u32, out: [*]f32, max_vertices: u32) u32;
extern fn goss_physics_add_hair(handle: *anyopaque, strand_count: u32, verts: u32, length: f32) u32;
extern fn goss_physics_hair_update(handle: *anyopaque, hair_id: u32, head_transform: [*]const f32, dt: f32) void;
extern fn goss_physics_hair_read(handle: *anyopaque, hair_id: u32, out: [*]f32, max_vertices: u32) u32;

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

    /// Links two bodies with a distance constraint between local attach
    /// points - the chain link for content hanging off an anchor.
    pub fn constrainDistance(world: World, a: u32, b: u32, point_a: [3]f32, point_b: [3]f32, min: f32, max: f32) !void {
        if (goss_physics_constrain_distance(world.handle, a, b, point_a[0], point_a[1], point_a[2], point_b[0], point_b[1], point_b[2], min, max) != 0) return error.ConstraintFailed;
    }

    /// Drives a kinematic body toward a pose over dt; chained bodies
    /// swing after it.
    pub fn moveBody(world: World, body: u32, position: [3]f32, dt_seconds: f32) void {
        goss_physics_body_move(world.handle, body, position[0], position[1], position[2], dt_seconds);
    }

    /// Adds a pinned-top cloth grid; its deformed vertices drive a mesh.
    pub fn addCloth(world: World, cols: u32, rows: u32, width: f32, height: f32, position: [3]f32) !u32 {
        const id = goss_physics_add_cloth(world.handle, cols, rows, width, height, position[0], position[1], position[2]);
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Reads the cloth's deformed world-space vertices (3 floats each)
    /// into out; returns the vertex count.
    pub fn clothRead(world: World, body: u32, out: []f32) u32 {
        return goss_physics_cloth_read(world.handle, body, out.ptr, @intCast(out.len / 3));
    }

    /// Adds a clump of strand_count strands, each `verts` long and
    /// `length` metres, rooted near the head. Returns a hair id.
    pub fn addHair(world: World, strand_count: u32, verts: u32, length: f32) !u32 {
        const id = goss_physics_add_hair(world.handle, strand_count, verts, length);
        if (id == invalid_body) return error.BodyAddFailed;
        return id;
    }

    /// Moves the hair with the head (translation from the 16-float
    /// column-major transform) and steps it; the tips swing.
    pub fn hairUpdate(world: World, hair_id: u32, head_transform: [16]f32, dt_seconds: f32) void {
        goss_physics_hair_update(world.handle, hair_id, &head_transform, dt_seconds);
    }

    /// Reads simulated strand vertices (3 floats each); returns count.
    pub fn hairRead(world: World, hair_id: u32, out: []f32) u32 {
        return goss_physics_hair_read(world.handle, hair_id, out.ptr, @intCast(out.len / 3));
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

test "a chained pendant follows a moved kinematic anchor" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const anchor = try world.addBody(.sphere, .{ 0, 1.0, 0 }, .{ 0.02, 0, 0 }, .kinematic);
    const pendant = try world.addBody(.sphere, .{ 0, 0.9, 0 }, .{ 0.03, 0, 0 }, .dynamic);
    try world.constrainDistance(anchor, pendant, .{ 0, 0, 0 }, .{ 0, 0, 0 }, 0.0, 0.1);
    var i: usize = 0;
    while (i < 120) : (i += 1) {
        const x = 0.3 * @sin(@as(f32, @floatFromInt(i)) * 0.08);
        world.moveBody(anchor, .{ x, 1.0, 0 }, 1.0 / 60.0);
        world.step(1.0 / 60.0);
    }
    const anchor_pose = try world.bodyPose(anchor);
    const pendant_pose = try world.bodyPose(pendant);
    // The pendant hangs below the anchor within the chain length.
    try t.expect(pendant_pose[13] <= anchor_pose[13]);
    const dx = pendant_pose[12] - anchor_pose[12];
    const dy = pendant_pose[13] - anchor_pose[13];
    try t.expect(@sqrt(dx * dx + dy * dy) <= 0.16);
}

test "a pinned cloth grid drapes and reads back deformed vertices" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const cloth = try world.addCloth(6, 6, 1.0, 1.0, .{ 0, 0, 0 });
    var i: usize = 0;
    while (i < 180) : (i += 1) world.step(1.0 / 60.0);
    var verts: [36 * 3]f32 = undefined;
    const n = world.clothRead(cloth, &verts);
    try t.expectEqual(@as(u32, 36), n);
    // Top-row centre stays high, bottom-row centre has draped below.
    const top_y = verts[(30 + 3) * 3 + 1];
    const bottom_y = verts[(0 + 3) * 3 + 1];
    try t.expect(top_y - bottom_y > 0.3);
}

test "a hair clump hangs and reads back strand vertices" {
    const world = try World.create(-9.81);
    defer world.destroy();
    const hair = try world.addHair(2, 16, 0.5);
    var i: usize = 0;
    const identity = [16]f32{ 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1, 0, 0, 0, 0, 1 };
    while (i < 60) : (i += 1) world.hairUpdate(hair, identity, 1.0 / 60.0);
    var verts: [128 * 3]f32 = undefined;
    const n = world.hairRead(hair, &verts);
    try t.expect(n > 0);
    // Some tip vertex hangs below the pinned root region.
    var min_y: f32 = 1e9;
    for (0..n) |v| min_y = @min(min_y, verts[v * 3 + 1]);
    try t.expect(min_y < 0.4);
}
