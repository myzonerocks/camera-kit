//! The degradation ladder. Effects degrade so capture never does: each step
//! is a named state, transitions are hysteresis-guarded so the pipeline does
//! not flap at a boundary, and every change is reported to the session for
//! logging. The controller is pure state plus measured inputs, so tests can
//! force any walk of the ladder.

const std = @import("std");

/// Ordered from full quality down. The camera itself never stops; the last
/// step still renders the plain preview.
pub const Level = enum(u8) {
    full,
    reduced_ml_cadence,
    segmentation_off,
    beauty_simplified,
    passthrough,

    pub fn moreDegraded(level: Level) ?Level {
        if (level == .passthrough) return null;
        return @enumFromInt(@intFromEnum(level) + 1);
    }

    pub fn lessDegraded(level: Level) ?Level {
        if (level == .full) return null;
        return @enumFromInt(@intFromEnum(level) - 1);
    }
};

pub const ThermalState = enum(u8) { nominal, fair, serious, critical };

pub const Inputs = struct {
    /// Measured whole-pipeline time for the last frame.
    frame_time_us: u32,
    /// Fed by the shell from the platform thermal API.
    thermal: ThermalState,
};

pub const Config = struct {
    /// The frame-time budget the session must hold.
    budget_us: u32,
    /// Fraction of budget above which pressure accumulates, in percent.
    degrade_pct: u32 = 100,
    /// Fraction of budget below which recovery accumulates, in percent.
    recover_pct: u32 = 70,
    /// Consecutive over-budget frames before stepping down.
    degrade_dwell: u32 = 12,
    /// Consecutive comfortable frames before stepping back up. Longer than
    /// the degrade dwell on purpose: recovery must be earned.
    recover_dwell: u32 = 120,
};

pub const Transition = struct {
    from: Level,
    to: Level,
};

pub const Controller = struct {
    config: Config,
    level: Level = .full,
    over_streak: u32 = 0,
    under_streak: u32 = 0,

    pub fn init(config: Config) Controller {
        std.debug.assert(config.recover_pct < config.degrade_pct);
        return .{ .config = config };
    }

    /// One call per frame with measured inputs; returns a transition when
    /// the level changes. Serious thermal pressure degrades immediately at
    /// full dwell speed; critical jumps straight to passthrough.
    pub fn step(c: *Controller, inputs: Inputs) ?Transition {
        if (inputs.thermal == .critical) {
            c.over_streak = 0;
            c.under_streak = 0;
            if (c.level != .passthrough) {
                const from = c.level;
                c.level = .passthrough;
                return .{ .from = from, .to = .passthrough };
            }
            return null;
        }

        const degrade_threshold = c.config.budget_us / 100 * c.config.degrade_pct;
        const recover_threshold = c.config.budget_us / 100 * c.config.recover_pct;
        const over = inputs.frame_time_us > degrade_threshold or inputs.thermal == .serious;
        const under = inputs.frame_time_us < recover_threshold and inputs.thermal == .nominal;

        if (over) {
            c.over_streak += 1;
            c.under_streak = 0;
        } else if (under) {
            c.under_streak += 1;
            c.over_streak = 0;
        } else {
            c.over_streak = 0;
            c.under_streak = 0;
        }

        if (c.over_streak >= c.config.degrade_dwell) {
            c.over_streak = 0;
            if (c.level.moreDegraded()) |next| {
                const from = c.level;
                c.level = next;
                return .{ .from = from, .to = next };
            }
        } else if (c.under_streak >= c.config.recover_dwell) {
            c.under_streak = 0;
            if (c.level.lessDegraded()) |next| {
                const from = c.level;
                c.level = next;
                return .{ .from = from, .to = next };
            }
        }
        return null;
    }
};

const t = std.testing;

const test_config: Config = .{
    .budget_us = 16_000,
    .degrade_dwell = 3,
    .recover_dwell = 6,
};

fn stepMany(c: *Controller, inputs: Inputs, frames: u32) ?Transition {
    var last: ?Transition = null;
    for (0..frames) |_| {
        if (c.step(inputs)) |tr| last = tr;
    }
    return last;
}

test "sustained overload steps down one level after the dwell" {
    var c = Controller.init(test_config);
    const slow: Inputs = .{ .frame_time_us = 20_000, .thermal = .nominal };
    try t.expect(c.step(slow) == null);
    try t.expect(c.step(slow) == null);
    const tr = c.step(slow).?;
    try t.expectEqual(Level.full, tr.from);
    try t.expectEqual(Level.reduced_ml_cadence, tr.to);
}

test "a single spike does not degrade" {
    var c = Controller.init(test_config);
    _ = c.step(.{ .frame_time_us = 30_000, .thermal = .nominal });
    _ = c.step(.{ .frame_time_us = 30_000, .thermal = .nominal });
    _ = c.step(.{ .frame_time_us = 8_000, .thermal = .nominal });
    try t.expect(stepMany(&c, .{ .frame_time_us = 15_000, .thermal = .nominal }, 10) == null);
    try t.expectEqual(Level.full, c.level);
}

test "recovery needs a longer streak than degradation" {
    var c = Controller.init(test_config);
    _ = stepMany(&c, .{ .frame_time_us = 20_000, .thermal = .nominal }, 3);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);

    const fast: Inputs = .{ .frame_time_us = 8_000, .thermal = .nominal };
    try t.expect(stepMany(&c, fast, 5) == null);
    const tr = c.step(fast).?;
    try t.expectEqual(Level.full, tr.to);
}

test "the band between thresholds holds the current level" {
    var c = Controller.init(test_config);
    _ = stepMany(&c, .{ .frame_time_us = 20_000, .thermal = .nominal }, 3);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);
    try t.expect(stepMany(&c, .{ .frame_time_us = 13_000, .thermal = .nominal }, 500) == null);
    try t.expectEqual(Level.reduced_ml_cadence, c.level);
}

test "critical thermal jumps straight to passthrough and recovery walks back" {
    var c = Controller.init(test_config);
    const tr = c.step(.{ .frame_time_us = 8_000, .thermal = .critical }).?;
    try t.expectEqual(Level.full, tr.from);
    try t.expectEqual(Level.passthrough, tr.to);

    const fast: Inputs = .{ .frame_time_us = 8_000, .thermal = .nominal };
    const up = stepMany(&c, fast, 6).?;
    try t.expectEqual(Level.beauty_simplified, up.to);
}

test "serious thermal degrades even under budget" {
    var c = Controller.init(test_config);
    const tr = stepMany(&c, .{ .frame_time_us = 8_000, .thermal = .serious }, 3).?;
    try t.expectEqual(Level.reduced_ml_cadence, tr.to);
}

test "the ladder walks all the way down and stops" {
    var c = Controller.init(test_config);
    const slow: Inputs = .{ .frame_time_us = 40_000, .thermal = .nominal };
    _ = stepMany(&c, slow, 100);
    try t.expectEqual(Level.passthrough, c.level);
    try t.expect(stepMany(&c, slow, 100) == null);
}
