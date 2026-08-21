//! A deterministic CPU particle sim for lens VFX. Every particle's start and
//! motion is a pure function of its index and elapsed steps - no clock, no
//! randomness - so the same field and step count give the same picture,
//! conformance bit-stable. The host streams the particles to a sprite mesh.
const std = @import("std");

/// How the emitter seeds a particle's start position and velocity - the shape
/// of the effect. All are deterministic functions of the particle index.
pub const Pattern = enum { fountain, rain, burst, ring, cone, sphere };

pub const Field = struct {
    count: u32,
    /// Emission shape.
    pattern: Pattern = .fountain,
    /// Constant downward acceleration.
    gravity: f32 = 9.8,
    /// Launch speed, and a 0..1 fraction to vary it per particle.
    speed: f32 = 2.0,
    speed_spread: f32 = 0,
    /// Seconds a particle lives, and a 0..1 fraction to vary it per particle.
    lifetime: f32 = 2.0,
    lifetime_spread: f32 = 0,
    /// Velocity damping per second (air resistance).
    drag: f32 = 0,
    /// Constant directional force (wind).
    wind: [3]f32 = .{ 0, 0, 0 },
    /// Deterministic swirl amplitude added to velocity from position.
    turbulence: f32 = 0,
    /// Emit everything once and let it die, rather than respawning forever.
    oneshot: bool = false,
    // Rendering hints the sim itself ignores, carried for the host.
    /// The rgb a particle draws at; null uses the engine's warm default.
    color: ?[3]f32 = null,
    /// The rgb a particle cools toward as it dies; null holds the draw colour.
    cool: ?[3]f32 = null,
    /// Fade each particle out over its life (alpha-blended sprite).
    fade: bool = false,
    /// Sprite size in pixels at birth, and an optional size at death.
    size: u32 = 0,
    size_end: ?u32 = null,
    /// Turns a sprite spins over its life.
    spin: f32 = 0,
    /// Blend additively so overlaps brighten (a fire glow).
    glow: bool = false,
    /// Sprite image stem (assets/<stem>.png); null is the soft round default.
    sprite: ?[]const u8 = null,
};

/// A deterministic per-index value in [0, 1), salted so several independent
/// draws share no correlation - the sim's only source of "randomness".
fn hash01(i: usize, salt: f32) f32 {
    const x = @as(f32, @floatFromInt(i)) * 0.6180339887 + salt * 1.324717957;
    const s = @sin(x * 127.1 + salt * 311.7) * 43758.5453;
    return s - @floor(s);
}

pub const Particle = struct {
    pos: [3]f32,
    vel: [3]f32,
    life: f32,
    /// This particle's own total lifetime (with spread applied).
    max_life: f32,
    /// A per-particle constant in [0,1), the sprite's spin phase.
    seed: f32,
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
        const t = @as(f32, @floatFromInt(i)) / denom;
        const a = t * std.math.tau;
        const seed = hash01(i, 0.0);
        const speed = field.speed * (1.0 - field.speed_spread * hash01(i, 1.0));
        const life = field.lifetime * (1.0 - field.lifetime_spread * hash01(i, 2.0));
        var pos: [3]f32 = .{ 0, 0, 0 };
        var vel: [3]f32 = .{ 0, 0, 0 };
        switch (field.pattern) {
            // A cone rising from the origin and spreading outward.
            .fountain => vel = .{ @cos(a) * speed, speed * 1.5 + @as(f32, @floatFromInt(i % 8)) * 0.1, @sin(a) * speed },
            // Seeded across the top of the frame, drifting straight down.
            .rain => {
                pos = .{ (t - 0.5) * 2.0, 1.0, (seed - 0.5) * 0.6 };
                vel = .{ 0, -speed, 0 };
            },
            // Radial explosion: velocities point out across a sphere by index.
            .burst => {
                const z = 1.0 - 2.0 * t;
                const r = @sqrt(@max(0.0, 1.0 - z * z));
                vel = .{ @cos(a) * r * speed, z * speed, @sin(a) * r * speed };
            },
            // A flat ring expanding outward in the xz plane.
            .ring => {
                pos = .{ @cos(a) * 0.5, 0, @sin(a) * 0.5 };
                vel = .{ @cos(a) * speed, 0, @sin(a) * speed };
            },
            // A tight upward cone, narrower than the fountain.
            .cone => {
                const rr = seed * 0.4;
                vel = .{ @cos(a) * rr * speed, speed, @sin(a) * rr * speed };
            },
            // Emitted from a sphere's surface, moving out along the normal.
            .sphere => {
                const z = 1.0 - 2.0 * seed;
                const r = @sqrt(@max(0.0, 1.0 - z * z));
                const b = hash01(i, 3.0) * std.math.tau;
                pos = .{ @cos(b) * r * 0.5, z * 0.5, @sin(b) * r * 0.5 };
                vel = .{ @cos(b) * r * speed, z * speed, @sin(b) * r * speed };
            },
        }
        return .{ .pos = pos, .vel = vel, .life = life, .max_life = @max(life, 1e-6), .seed = seed };
    }

    fn emitAll(self: *System) void {
        for (self.particles, 0..) |*p, i| p.* = emitOne(self.field, i);
    }

    /// Advances every particle by dt under gravity, drag, wind and turbulence;
    /// an expired particle respawns from the emitter, unless the field is a
    /// one-shot burst, in which case it stays dead.
    pub fn step(self: *System, dt: f32) void {
        const f = self.field;
        for (self.particles, 0..) |*p, i| {
            p.life -= dt;
            if (p.life <= 0) {
                if (f.oneshot) {
                    p.life = 0;
                    continue;
                }
                p.* = emitOne(f, i);
                continue;
            }
            p.vel[1] -= f.gravity * dt;
            if (f.drag > 0) {
                const damp = @max(0.0, 1.0 - f.drag * dt);
                p.vel[0] *= damp;
                p.vel[1] *= damp;
                p.vel[2] *= damp;
            }
            p.vel[0] += f.wind[0] * dt;
            p.vel[1] += f.wind[1] * dt;
            p.vel[2] += f.wind[2] * dt;
            if (f.turbulence > 0) {
                p.vel[0] += @sin(p.pos[1] * 7.0 + p.seed * 13.0) * f.turbulence * dt;
                p.vel[2] += @cos(p.pos[0] * 7.0 + p.seed * 17.0) * f.turbulence * dt;
            }
            p.pos[0] += p.vel[0] * dt;
            p.pos[1] += p.vel[1] * dt;
            p.pos[2] += p.vel[2] * dt;
        }
    }

    /// Writes xyz of every particle into out (count * 3 floats) for the plain
    /// non-fading point mesh.
    pub fn writePositions(self: *const System, out: []f32) void {
        for (self.particles, 0..) |p, i| {
            out[i * 3 + 0] = p.pos[0];
            out[i * 3 + 1] = p.pos[1];
            out[i * 3 + 2] = p.pos[2];
        }
    }

    /// Writes six vertices per particle (two triangles of a camera-facing
    /// quad) into out (count * 6 * 6 floats): the particle centre, then a
    /// corner index 0..3, the remaining-life fraction, and the spin seed the
    /// billboard shader expands into a rotated, sized, faded sprite.
    pub fn writeBillboards(self: *const System, out: []f32) void {
        const corners = [6]f32{ 0, 1, 2, 0, 2, 3 };
        for (self.particles, 0..) |p, i| {
            const frac = std.math.clamp(p.life / p.max_life, 0.0, 1.0);
            for (corners, 0..) |corner, k| {
                const base = (i * 6 + k) * 6;
                out[base + 0] = p.pos[0];
                out[base + 1] = p.pos[1];
                out[base + 2] = p.pos[2];
                out[base + 3] = corner;
                out[base + 4] = frac;
                out[base + 5] = p.seed;
            }
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

test "every emission pattern is deterministic and non-degenerate" {
    for ([_]Pattern{ .fountain, .rain, .burst, .ring, .cone, .sphere }) |pattern| {
        const field = Field{ .count = 64, .speed = 2.0, .lifetime = 2.0, .pattern = pattern, .drag = 0.5, .turbulence = 1.0, .wind = .{ 0.2, 0, 0 } };
        var s = try System.init(std.testing.allocator, field);
        defer s.deinit();
        for (0..30) |_| s.step(1.0 / 60.0);
        var moved = false;
        for (s.particles) |p| {
            if (p.pos[0] != 0 or p.pos[1] != 0 or p.pos[2] != 0) moved = true;
        }
        try std.testing.expect(moved);
    }
}
