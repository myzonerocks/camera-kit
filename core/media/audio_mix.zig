//! Outgoing audio mix: fold a lens's 48 kHz mono sound into the caller's
//! call/live track at any rate and 1..8 channels - resample, convert the f32
//! mic to s16, sum with saturation. No allocation, device, or clock: a pure
//! function of the mic block and the lens samples, identical on every platform.
const std = @import("std");

/// The lens mixer's native rate. The resampler converts from this to whatever
/// the outgoing track asks for.
pub const source_rate: u32 = 48_000;

fn lerpS16(a: i16, b: i16, frac: f64) i16 {
    const v = @as(f64, @floatFromInt(a)) * (1.0 - frac) + @as(f64, @floatFromInt(b)) * frac;
    // a and b are in range, so any convex combination is too; round to nearest.
    return @intFromFloat(@round(v));
}

fn micToS16(x: f32) i16 {
    const scaled = @round(@as(f64, x) * 32767.0);
    return @intFromFloat(std.math.clamp(scaled, -32768.0, 32767.0));
}

/// Saturating sum of the mic sample and the lens sample - the standard mix a
/// custom audio source would do, clamped instead of wrapped so a loud lens
/// sound over a loud mic clips rather than glitches.
pub fn satAddS16(a: i16, b: i16) i16 {
    const s = @as(i32, a) + @as(i32, b);
    return @intCast(std.math.clamp(s, @as(i32, -32768), @as(i32, 32767)));
}

/// Linear resampler for a single mono stream, driven one output sample at a
/// time by pulling source samples on demand. Each source sample is pulled from
/// the mixer exactly once and in order (destructive-safe), so a block boundary
/// never drops or repeats a sample. Continuous across calls through `phase`.
pub const Resampler = struct {
    /// Fractional position in [0,1) of the next output between `hist` and `next`.
    phase: f64 = 0,
    hist: i16 = 0,
    next: i16 = 0,
    primed: bool = false,

    pub fn reset(self: *Resampler) void {
        self.* = .{};
    }

    /// Fills `out` mono samples at the caller's rate. `ratio` is
    /// source_rate/target_rate. `pull(ctx)` yields the next 48 kHz mono source
    /// sample; it is called once per source sample consumed, in order.
    pub fn process(
        self: *Resampler,
        ratio: f64,
        out: []i16,
        ctx: anytype,
        comptime pull: fn (@TypeOf(ctx)) i16,
    ) void {
        if (!self.primed) {
            self.hist = pull(ctx);
            self.next = pull(ctx);
            self.phase = 0;
            self.primed = true;
        }
        for (out) |*o| {
            // Advance the window until the read position sits within [hist,next).
            // ratio can exceed 1 (downsampling), so this may pull several.
            while (self.phase >= 1.0) {
                self.hist = self.next;
                self.next = pull(ctx);
                self.phase -= 1.0;
            }
            o.* = lerpS16(self.hist, self.next, self.phase);
            self.phase += ratio;
        }
    }
};

/// Combines `frame_count` resampled mono lens samples with the caller's
/// interleaved f32 `mic` (null for silence) into interleaved s16, `channels`
/// wide - the mono lens sample summed into every channel. `out` holds
/// frame_count*channels, `lens_mono` holds frame_count.
pub fn combine(lens_mono: []const i16, mic: ?[]const f32, out: []i16, frame_count: u32, channels: u32) void {
    var i: u32 = 0;
    while (i < frame_count) : (i += 1) {
        const lens = lens_mono[i];
        var c: u32 = 0;
        while (c < channels) : (c += 1) {
            const idx = i * channels + c;
            const mic_s16: i16 = if (mic) |m| micToS16(m[idx]) else 0;
            out[idx] = satAddS16(mic_s16, lens);
        }
    }
}

const t = std.testing;

const SliceSource = struct {
    data: []const i16,
    pos: usize = 0,
    fn pull(self: *SliceSource) i16 {
        if (self.pos >= self.data.len) return 0;
        const v = self.data[self.pos];
        self.pos += 1;
        return v;
    }
};

test "resample at the source rate is a pass-through" {
    const src = [_]i16{ 10, 20, 30, 40, 50, 60, 70, 80 };
    var s = SliceSource{ .data = &src };
    var r = Resampler{};
    var out: [8]i16 = undefined;
    r.process(1.0, &out, &s, SliceSource.pull);
    try t.expectEqualSlices(i16, &src, &out);
}

test "a ramp resamples to a ramp under linear interpolation" {
    // A linear ramp is reproduced exactly by linear interpolation at any rate.
    var src: [64]i16 = undefined;
    for (&src, 0..) |*v, i| v.* = @intCast(i * 100);
    var s = SliceSource{ .data = &src };
    var r = Resampler{};
    const ratio = 48000.0 / 44100.0; // downsample toward 44.1 kHz
    var out: [32]i16 = undefined;
    r.process(ratio, &out, &s, SliceSource.pull);
    // Each output equals its exact ramp value: 100 * position, rounded.
    for (out, 0..) |v, i| {
        const pos = @as(f64, @floatFromInt(i)) * ratio;
        const expected: i16 = @intFromFloat(@round(pos * 100.0));
        try t.expectEqual(expected, v);
    }
}

test "resampling stays continuous across two calls" {
    var src: [128]i16 = undefined;
    for (&src, 0..) |*v, i| v.* = @intCast(i * 10);
    const ratio = 48000.0 / 32000.0;

    // One long call.
    var s_all = SliceSource{ .data = &src };
    var r_all = Resampler{};
    var out_all: [48]i16 = undefined;
    r_all.process(ratio, &out_all, &s_all, SliceSource.pull);

    // Split into two calls sharing one resampler and one source cursor.
    var s_split = SliceSource{ .data = &src };
    var r_split = Resampler{};
    var out_a: [20]i16 = undefined;
    var out_b: [28]i16 = undefined;
    r_split.process(ratio, &out_a, &s_split, SliceSource.pull);
    r_split.process(ratio, &out_b, &s_split, SliceSource.pull);

    try t.expectEqualSlices(i16, out_all[0..20], &out_a);
    try t.expectEqualSlices(i16, out_all[20..48], &out_b);
}

test "combine sums mic and lens with saturation across channels" {
    const lens = [_]i16{ 1000, -1000, 32000 };
    const mic = [_]f32{ 0.5, 0.5, -0.5, -0.5, 1.0, 1.0 }; // 3 frames, 2 channels
    var out: [6]i16 = undefined;
    combine(&lens, &mic, &out, 3, 2);
    // frame 0: mic 0.5 -> 16384(-ish) + 1000 in both channels.
    const mic_half = micToS16(0.5);
    try t.expectEqual(satAddS16(mic_half, 1000), out[0]);
    try t.expectEqual(satAddS16(mic_half, 1000), out[1]);
    // frame 2: mic 1.0 -> 32767 + 32000 saturates at 32767.
    try t.expectEqual(@as(i16, 32767), out[4]);
    try t.expectEqual(@as(i16, 32767), out[5]);
}

test "combine with no mic returns the lens over silence" {
    const lens = [_]i16{ 5, 6, 7, 8 };
    var out: [8]i16 = undefined;
    combine(&lens, null, &out, 4, 2);
    for (0..4) |i| {
        try t.expectEqual(lens[i], out[i * 2]);
        try t.expectEqual(lens[i], out[i * 2 + 1]);
    }
}
