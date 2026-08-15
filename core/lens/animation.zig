//! Parameter animation: the two curve primitives in lenses/SPEC.md 6.3.
//! Both integrate at a fixed simulation step, not wall-clock dt directly,
//! so the same real-world duration produces the same sequence of values
//! regardless of the device's actual frame rate - required for the
//! conformance harness to assert identical curve values across platforms
//! at fixed timestamps. advance() accepts the real elapsed time and steps
//! internally; a caller pausing (debugger, backgrounding) for a long
//! stretch cannot turn one advance() call into an unbounded catch-up
//! burst, since the number of fixed steps taken per call is capped.

const std = @import("std");

/// ~120hz. Fine enough that a spring never visibly steps, coarse enough
/// that a lens with many in-flight ramps stays cheap.
pub const fixed_step_us: u32 = 8_333;
const fixed_step_seconds: f32 = @as(f32, @floatFromInt(fixed_step_us)) / 1_000_000.0;
const max_steps_per_advance: u32 = 32;

const settle_distance: f32 = 1e-4;
const settle_velocity: f32 = 1e-3;

pub const Curve = enum { linear, spring };

pub const Ramp = struct {
    start: f32,
    value: f32,
    target: f32,
    curve: Curve,
    duration_us: u32 = 0,
    elapsed_us: u32 = 0,
    velocity: f32 = 0,
    stiffness: f32 = 0,
    damping: f32 = 0,
    accumulator_us: u32 = 0,
    done: bool = false,

    pub fn startLinear(current: f32, target: f32, duration_ms: u32) Ramp {
        var ramp = Ramp{
            .start = current,
            .value = current,
            .target = target,
            .curve = .linear,
            .duration_us = duration_ms * 1000,
        };
        if (ramp.duration_us == 0) {
            ramp.value = target;
            ramp.done = true;
        }
        return ramp;
    }

    pub fn startSpring(current: f32, target: f32, stiffness: f32, damping: f32) Ramp {
        return .{
            .start = current,
            .value = current,
            .target = target,
            .curve = .spring,
            .stiffness = stiffness,
            .damping = damping,
        };
    }

    /// Advances by real_dt_us of wall-clock time and returns the value
    /// after stepping. Calling this on an already-settled ramp is a cheap
    /// no-op, so callers do not need to track completion separately.
    pub fn advance(self: *Ramp, real_dt_us: u32) f32 {
        if (self.done) return self.value;
        self.accumulator_us += real_dt_us;
        var steps: u32 = 0;
        while (self.accumulator_us >= fixed_step_us and steps < max_steps_per_advance) {
            self.tick();
            self.accumulator_us -= fixed_step_us;
            steps += 1;
            if (self.done) break;
        }
        if (steps == max_steps_per_advance) self.accumulator_us = 0;
        return self.value;
    }

    fn tick(self: *Ramp) void {
        switch (self.curve) {
            .linear => {
                self.elapsed_us += fixed_step_us;
                if (self.elapsed_us >= self.duration_us) {
                    self.value = self.target;
                    self.done = true;
                    return;
                }
                const progress = @as(f32, @floatFromInt(self.elapsed_us)) / @as(f32, @floatFromInt(self.duration_us));
                self.value = self.start + (self.target - self.start) * progress;
            },
            .spring => {
                const accel = self.stiffness * (self.target - self.value) - self.damping * self.velocity;
                self.velocity += accel * fixed_step_seconds;
                self.value += self.velocity * fixed_step_seconds;
                if (@abs(self.target - self.value) < settle_distance and @abs(self.velocity) < settle_velocity) {
                    self.value = self.target;
                    self.velocity = 0;
                    self.done = true;
                }
            },
        }
    }
};

const t = std.testing;

test "a zero-duration linear ramp settles immediately" {
    const ramp = Ramp.startLinear(0, 1, 0);
    try t.expect(ramp.done);
    try t.expectEqual(@as(f32, 1), ramp.value);
}

test "a linear ramp reaches its target once its duration has elapsed" {
    // duration_us (200_000) is not an exact multiple of fixed_step_us, so
    // the ramp needs one fixed step past the nominal duration to cross
    // the threshold - expected fixed-timestep quantization, not a bug.
    var ramp = Ramp.startLinear(0, 10, 200);
    _ = ramp.advance(100_000);
    try t.expect(!ramp.done);
    try t.expectApproxEqAbs(@as(f32, 5), ramp.value, 0.1);
    _ = ramp.advance(100_000 + fixed_step_us);
    try t.expect(ramp.done);
    try t.expectEqual(@as(f32, 10), ramp.value);
}

test "a linear ramp is monotonic toward its target" {
    var ramp = Ramp.startLinear(0, 10, 500);
    var last: f32 = 0;
    for (0..20) |_| {
        const v = ramp.advance(25_000);
        try t.expect(v >= last);
        last = v;
    }
}

test "advancing a settled ramp is a no-op" {
    var ramp = Ramp.startLinear(0, 10, 100);
    _ = ramp.advance(200_000);
    try t.expect(ramp.done);
    const v = ramp.advance(1_000_000);
    try t.expectEqual(@as(f32, 10), v);
}

test "a spring converges to its target and stops" {
    var ramp = Ramp.startSpring(0, 1, 120.0, 14.0);
    var v: f32 = 0;
    for (0..600) |_| v = ramp.advance(fixed_step_us);
    try t.expectApproxEqAbs(@as(f32, 1.0), v, 0.01);
    try t.expect(ramp.done);
}

test "a stiffer spring settles no slower than a softer one" {
    var stiff = Ramp.startSpring(0, 1, 400.0, 40.0);
    var soft = Ramp.startSpring(0, 1, 40.0, 8.0);
    var stiff_ticks: u32 = 0;
    var soft_ticks: u32 = 0;
    while (!stiff.done and stiff_ticks < 10_000) : (stiff_ticks += 1) _ = stiff.advance(fixed_step_us);
    while (!soft.done and soft_ticks < 10_000) : (soft_ticks += 1) _ = soft.advance(fixed_step_us);
    try t.expect(stiff_ticks < soft_ticks);
}

test "one big advance matches many small ones for the same total time (frame rate independence)" {
    var coarse = Ramp.startSpring(0, 1, 150.0, 16.0);
    var fine = Ramp.startSpring(0, 1, 150.0, 16.0);
    const total_us: u32 = 300_000;
    var elapsed: u32 = 0;
    while (elapsed < total_us) : (elapsed += 16_667) _ = coarse.advance(16_667);
    elapsed = 0;
    while (elapsed < total_us) : (elapsed += 4_000) _ = fine.advance(4_000);
    try t.expectApproxEqAbs(fine.value, coarse.value, 0.02);
}

test "a long pause caps its catch-up burst instead of spiraling" {
    var ramp = Ramp.startSpring(0, 1, 120.0, 14.0);
    const v = ramp.advance(10_000_000);
    try t.expect(std.math.isFinite(v));
    try t.expect(v >= 0 and v <= 1.5);
}
