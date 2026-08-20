//! Audio analysis for lens triggers: a smoothed level envelope and an
//! energy-flux beat pulse, computed deterministically from submitted
//! PCM so the same samples always produce the same signal values.

const std = @import("std");

/// Analysis window: level and beat update once per hop of this many
/// samples, giving ~93 updates a second at 48 kHz - ample for triggers.
pub const hop_size = 512;

pub const Analysis = struct {
    /// Smoothed envelope in [0, 1]; attack rises fast, release decays
    /// slowly, matching how audio-reactive effects want to move.
    level: f32 = 0,
    /// True exactly on hops whose energy jumps well above the recent
    /// average - a beat-ish onset pulse for triggers.
    beat: bool = false,

    // Running energy history for the onset comparison.
    history: [43]f32 = @splat(0),
    history_at: usize = 0,
    history_filled: bool = false,
    carry: [hop_size]f32 = @splat(0),
    carry_len: usize = 0,

    const attack: f32 = 0.6;
    const release: f32 = 0.05;
    const onset_ratio: f32 = 1.6;

    /// Feeds interleaved f32 samples; channels are averaged to mono.
    /// Level and beat reflect the latest completed hop afterwards.
    pub fn feed(analysis: *Analysis, samples: []const f32, channels: u32) void {
        if (channels == 0) return;
        analysis.beat = false;
        var at: usize = 0;
        const frame_count = samples.len / channels;
        while (at < frame_count) : (at += 1) {
            var mono: f32 = 0;
            for (0..channels) |ch| mono += samples[at * channels + ch];
            mono /= @floatFromInt(channels);
            analysis.carry[analysis.carry_len] = mono;
            analysis.carry_len += 1;
            if (analysis.carry_len == hop_size) {
                analysis.completeHop();
                analysis.carry_len = 0;
            }
        }
    }

    fn completeHop(analysis: *Analysis) void {
        var energy: f32 = 0;
        for (analysis.carry) |sample| energy += sample * sample;
        energy /= hop_size;
        const rms = @sqrt(energy);

        const coefficient: f32 = if (rms > analysis.level) attack else release;
        analysis.level += (rms - analysis.level) * coefficient;
        analysis.level = std.math.clamp(analysis.level, 0.0, 1.0);

        // Onset: this hop's energy against the recent average, only
        // once the history holds real data and the signal is audible.
        var sum: f32 = 0;
        for (analysis.history) |past| sum += past;
        const average = sum / analysis.history.len;
        if (analysis.history_filled and energy > average * onset_ratio and rms > 0.02) {
            analysis.beat = true;
        }
        analysis.history[analysis.history_at] = energy;
        analysis.history_at = (analysis.history_at + 1) % analysis.history.len;
        if (analysis.history_at == 0) analysis.history_filled = true;
    }
};

const t = std.testing;

test "silence stays at zero with no beats" {
    var analysis: Analysis = .{};
    const silence: [hop_size * 4]f32 = @splat(0);
    analysis.feed(&silence, 1);
    try t.expectEqual(@as(f32, 0), analysis.level);
    try t.expect(!analysis.beat);
}

test "a loud burst after quiet raises the level and fires a beat" {
    var analysis: Analysis = .{};
    // Enough quiet hops to fill the history ring.
    var quiet: [hop_size]f32 = undefined;
    for (&quiet, 0..) |*sample, i| sample.* = 0.03 * @sin(@as(f32, @floatFromInt(i)) * 0.2);
    for (0..44) |_| analysis.feed(&quiet, 1);
    try t.expect(!analysis.beat);
    const level_before = analysis.level;

    var burst: [hop_size]f32 = undefined;
    for (&burst, 0..) |*sample, i| sample.* = 0.8 * @sin(@as(f32, @floatFromInt(i)) * 0.3);
    analysis.feed(&burst, 1);
    try t.expect(analysis.beat);
    try t.expect(analysis.level > level_before);
}

test "stereo averages to mono and determinism holds" {
    var first: Analysis = .{};
    var second: Analysis = .{};
    var stereo: [hop_size * 2]f32 = undefined;
    for (0..hop_size) |i| {
        stereo[i * 2] = 0.5 * @sin(@as(f32, @floatFromInt(i)) * 0.1);
        stereo[i * 2 + 1] = stereo[i * 2];
    }
    first.feed(&stereo, 2);
    second.feed(&stereo, 2);
    try t.expectEqual(first.level, second.level);
    try t.expectEqual(first.beat, second.beat);
    try t.expect(first.level > 0);
}
