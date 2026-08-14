//! Hand-off between asynchronous analysis and the render loop. Analysis
//! nodes publish timestamped results; render consumes the latest completed
//! one without ever blocking or allocating. A sequence-locked double buffer
//! carries the data. The payload crosses threads as atomic words: the
//! begin-write bump is a read-modify-write so the data stores cannot float
//! above it, the end-write store is a release so they cannot sink below it,
//! and the reader validates with a read-modify-write so its data loads
//! cannot sink past the check. A torn read is impossible; the reader
//! retries the rare in-flight overlap and never waits otherwise.

const std = @import("std");

pub fn ResultSlot(comptime T: type) type {
    return struct {
        const Self = @This();

        const Payload = struct {
            value: T,
            timestamp_us: i64,
        };

        const word_size = @sizeOf(usize);
        const word_count = (@sizeOf(Payload) + word_size - 1) / word_size;

        seq: std.atomic.Value(usize) = .init(0),
        slots: [2][word_count]std.atomic.Value(usize) = @splat(@splat(.init(0))),

        /// Single writer: the analysis executor. After the k-th publish the
        /// sequence is 2k and the data sits in slot k mod 2; an odd sequence
        /// marks a write in progress.
        pub fn publish(self: *Self, value: T, timestamp_us: i64) void {
            const payload: Payload = .{ .value = value, .timestamp_us = timestamp_us };
            var bytes: [word_count * word_size]u8 = @splat(0);
            @memcpy(bytes[0..@sizeOf(Payload)], std.mem.asBytes(&payload));

            const prev = self.seq.fetchAdd(1, .acq_rel);
            std.debug.assert(prev % 2 == 0);
            const publish_index = prev / 2 + 1;
            const slot = &self.slots[publish_index & 1];
            for (slot, 0..) |*word, i| {
                word.store(std.mem.bytesToValue(usize, bytes[i * word_size ..][0..word_size]), .monotonic);
            }
            self.seq.store(prev + 2, .release);
        }

        pub const Published = struct {
            value: T,
            timestamp_us: i64,
        };

        /// Any thread. Returns null until the first publish completes.
        pub fn latest(self: *Self) ?Published {
            while (true) {
                const seq = self.seq.load(.acquire);
                if (seq == 0) return null;
                if (seq % 2 != 0) {
                    std.atomic.spinLoopHint();
                    continue;
                }
                const slot = &self.slots[(seq / 2) & 1];
                var bytes: [word_count * word_size]u8 = undefined;
                for (slot, 0..) |*word, i| {
                    const value = word.load(.monotonic);
                    @memcpy(bytes[i * word_size ..][0..word_size], std.mem.asBytes(&value));
                }
                if (self.seq.fetchAdd(0, .acq_rel) == seq) {
                    const payload = std.mem.bytesToValue(Payload, bytes[0..@sizeOf(Payload)]);
                    return .{ .value = payload.value, .timestamp_us = payload.timestamp_us };
                }
            }
        }

        /// Age of the newest completed result relative to `now`, or null if
        /// nothing has been published. The degradation policy turns this
        /// into cadence decisions; the slot only measures.
        pub fn staleness(self: *Self, now_us: i64) ?i64 {
            const p = self.latest() orelse return null;
            return now_us - p.timestamp_us;
        }
    };
}

const t = std.testing;

const Landmarks = struct {
    points: [8]f32,
    confidence: f32,
};

test "latest is null before the first publish" {
    var slot: ResultSlot(Landmarks) = .{};
    try t.expect(slot.latest() == null);
    try t.expect(slot.staleness(1000) == null);
}

test "publish then consume round-trips value and timestamp" {
    var slot: ResultSlot(Landmarks) = .{};
    slot.publish(.{ .points = @splat(0.5), .confidence = 0.9 }, 16_000);
    const got = slot.latest().?;
    try t.expectEqual(@as(f32, 0.9), got.value.confidence);
    try t.expectEqual(@as(f32, 0.5), got.value.points[7]);
    try t.expectEqual(@as(i64, 16_000), got.timestamp_us);
    try t.expectEqual(@as(i64, 17_000 - 16_000), slot.staleness(17_000).?);
}

test "newer publish replaces older" {
    var slot: ResultSlot(Landmarks) = .{};
    slot.publish(.{ .points = @splat(0.1), .confidence = 0.1 }, 1_000);
    slot.publish(.{ .points = @splat(0.2), .confidence = 0.2 }, 2_000);
    slot.publish(.{ .points = @splat(0.3), .confidence = 0.3 }, 3_000);
    const got = slot.latest().?;
    try t.expectEqual(@as(f32, 0.3), got.value.confidence);
    try t.expectEqual(@as(i64, 3_000), got.timestamp_us);
}

test "concurrent writer and reader never tear" {
    var slot: ResultSlot(Landmarks) = .{};

    const writer = try std.Thread.spawn(.{}, struct {
        fn run(s: *ResultSlot(Landmarks)) void {
            var i: u32 = 1;
            while (i <= 10_000) : (i += 1) {
                const v: f32 = @floatFromInt(i);
                s.publish(.{ .points = @splat(v), .confidence = v }, @intCast(i));
            }
        }
    }.run, .{&slot});

    var torn: usize = 0;
    var reads: usize = 0;
    while (reads < 100_000) : (reads += 1) {
        if (slot.latest()) |got| {
            // Every field of a consumed result must come from one publish.
            for (got.value.points) |p| {
                if (p != got.value.confidence) torn += 1;
            }
            if (got.timestamp_us != @as(i64, @intFromFloat(got.value.confidence))) torn += 1;
        }
    }
    writer.join();

    try t.expectEqual(@as(usize, 0), torn);
    const final = slot.latest().?;
    try t.expectEqual(@as(f32, 10_000.0), final.value.confidence);
}
