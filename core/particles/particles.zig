//! A deterministic CPU particle sim for lens VFX. Particles emit from the
//! origin with an index-spread velocity, integrate under gravity, and respawn
//! on lifetime - a steady fountain, no clock and no randomness, so the same
//! field and step count give the same positions. The host streams to a mesh.
const std = @import("std");

pub const Field = struct {
    count: u32,
    gravity: f32 = 9.8,
    speed: f32 = 2.0,
    lifetime: f32 = 2.0,
};

pub const Particle = struct {
    pos: [3]f32,
    vel: [3]f32,
    life: f32,
};

pub const System = struct {
    field: Field,
    particles: []Particle,
    gpa: std.mem.Allocator,

    pub fn init(gpa: std.mem.Allocator, field: Field) !System {
        const particles = try gpa.alloc(Particle, field.count);
        var sys = System{ .field = field, .particles = particles, .gpa = gpa };
        sys.emitAll();
        return sys;
    }

    pub fn deinit(self: *System) void {
        self.gpa.free(self.particles);
    }

    fn emitOne(field: Field, i: usize) Particle {
        const denom: f32 = @floatFromInt(@max(field.count, 1));
        const a = @as(f32, @floatFromInt(i)) / denom * std.math.tau;
        return .{
            .pos = .{ 0, 0, 0 },
            .vel = .{
                @cos(a) * field.speed,
                field.speed * 1.5 + @as(f32, @floatFromInt(i % 8)) * 0.1,
                @sin(a) * field.speed,
            },
            .life = field.lifetime,
        };
    }

    fn emitAll(self: *System) void {
        for (self.particles, 0..) |*p, i| p.* = emitOne(self.field, i);
    }

    /// Advances every particle by dt; an expired particle respawns from the
    /// emitter, so the system is a steady loop.
    pub fn step(self: *System, dt: f32) void {
        for (self.particles, 0..) |*p, i| {
            p.life -= dt;
            if (p.life <= 0) {
                p.* = emitOne(self.field, i);
                continue;
            }
            p.vel[1] -= self.field.gravity * dt;
            p.pos[0] += p.vel[0] * dt;
            p.pos[1] += p.vel[1] * dt;
            p.pos[2] += p.vel[2] * dt;
        }
    }

    /// Writes xyz of every particle into out (count * 3 floats) for the mesh.
    pub fn writePositions(self: *const System, out: []f32) void {
        for (self.particles, 0..) |p, i| {
            out[i * 3 + 0] = p.pos[0];
            out[i * 3 + 1] = p.pos[1];
            out[i * 3 + 2] = p.pos[2];
        }
    }
};

test "the particle system is deterministic and moves under gravity" {
    const field = Field{ .count = 128, .gravity = 9.8, .speed = 2.0, .lifetime = 2.0 };
    var a = try System.init(std.testing.allocator, field);
    defer a.deinit();
    var b = try System.init(std.testing.allocator, field);
    defer b.deinit();
    for (0..90) |_| {
        a.step(1.0 / 60.0);
        b.step(1.0 / 60.0);
    }
    for (a.particles, b.particles) |pa, pb| {
        try std.testing.expectEqual(pa.pos[0], pb.pos[0]);
        try std.testing.expectEqual(pa.pos[1], pb.pos[1]);
        try std.testing.expectEqual(pa.pos[2], pb.pos[2]);
    }
    try std.testing.expect(a.particles[0].pos[1] != 0);
}
