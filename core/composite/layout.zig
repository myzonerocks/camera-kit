//! Multi-source composite layout: where each source draws in the output frame.
//! Pure, deterministic, allocation-free geometry behind Duet/Stitch and live
//! multi-guest grids. The engine composites frames it is handed into these
//! placements; who the sources are and how they arrive is the SDK's, not core's.
const std = @import("std");

/// A single layout node caps at this many sources (matches the frame graph's
/// per-node port ceiling). Larger grids chain layout nodes.
pub const max_sources = 8;

/// How a source's alpha is cut before it blends into the composite.
pub const KeyMode = enum(u8) {
    none = 0, // opaque, alpha from opacity alone
    segmentation = 1, // multiply alpha by a segmentation matte (green screen, AI)
    chroma = 2, // multiply alpha by a chroma-key test (physical green screen)
};

/// One source's placement in normalized output space [0,1], with its blend.
pub const Placement = extern struct {
    rect: [4]f32 = .{ 0, 0, 1, 1 }, // x, y, w, h
    opacity: f32 = 1,
    z: i16 = 0, // draw order; ties broken by registration index
    key: u8 = 0, // KeyMode
    pad: u8 = 0,
    chroma: [4]f32 = .{ 0, 0, 0, 0 }, // key rgb + similarity (chroma mode)
};

pub const Arrangement = enum(u8) {
    custom = 0,
    side_by_side = 1,
    top_bottom = 2,
    pip = 3,
    grid = 4,
};

pub const Layout = struct {
    placements: [max_sources]Placement = @splat(.{}),
    count: u8 = 0,

    fn clampCount(n: u8) u8 {
        return std.math.clamp(n, 1, max_sources);
    }

    /// n sources in equal vertical columns, left to right.
    pub fn sideBySide(n: u8) Layout {
        const c = clampCount(n);
        var out = Layout{ .count = c };
        const w = 1.0 / @as(f32, @floatFromInt(c));
        for (0..c) |i| {
            out.placements[i] = .{ .rect = .{ @as(f32, @floatFromInt(i)) * w, 0, w, 1 } };
        }
        return out;
    }

    /// n sources in equal horizontal rows, top to bottom.
    pub fn topBottom(n: u8) Layout {
        const c = clampCount(n);
        var out = Layout{ .count = c };
        const h = 1.0 / @as(f32, @floatFromInt(c));
        for (0..c) |i| {
            out.placements[i] = .{ .rect = .{ 0, @as(f32, @floatFromInt(i)) * h, 1, h } };
        }
        return out;
    }

    /// Source 0 fills the frame; source 1 sits in `inset` on top of it.
    pub fn pip(inset: [4]f32) Layout {
        return .{
            .count = 2,
            .placements = blk: {
                var p: [max_sources]Placement = @splat(.{});
                p[0] = .{ .rect = .{ 0, 0, 1, 1 }, .z = 0 };
                p[1] = .{ .rect = inset, .z = 1 };
                break :blk p;
            },
        };
    }

    /// n sources in the smallest square-ish grid that holds them, row-major.
    pub fn grid(n: u8) Layout {
        const c = clampCount(n);
        var cols: u8 = 1;
        while (@as(u16, cols) * cols < c) cols += 1;
        const rows: u8 = (c + cols - 1) / cols;
        var out = Layout{ .count = c };
        const cw = 1.0 / @as(f32, @floatFromInt(cols));
        const ch = 1.0 / @as(f32, @floatFromInt(rows));
        for (0..c) |i| {
            const col = @as(u8, @intCast(i)) % cols;
            const row = @as(u8, @intCast(i)) / cols;
            out.placements[i] = .{ .rect = .{ @as(f32, @floatFromInt(col)) * cw, @as(f32, @floatFromInt(row)) * ch, cw, ch } };
        }
        return out;
    }

    /// Fills `out` with source indices in draw order: ascending z, ties broken
    /// by registration index, so the result is a stable, deterministic order
    /// the render loop walks (never the source hashmap). Returns the count.
    pub fn drawOrder(self: *const Layout, out: *[max_sources]u8) u8 {
        const n = self.count;
        for (0..n) |i| out[i] = @intCast(i);
        // Insertion sort keyed on (z, index) - stable and tiny for n <= 8.
        var i: usize = 1;
        while (i < n) : (i += 1) {
            const key = out[i];
            const key_z = self.placements[key].z;
            var j: isize = @as(isize, @intCast(i)) - 1;
            while (j >= 0) : (j -= 1) {
                const cand = out[@intCast(j)];
                // Move cand right while it should sort after key.
                if (self.placements[cand].z > key_z or (self.placements[cand].z == key_z and cand > key)) {
                    out[@intCast(j + 1)] = cand;
                } else break;
            }
            out[@intCast(j + 1)] = key;
        }
        return n;
    }
};

const t = std.testing;

test "side by side splits the width evenly" {
    const l = Layout.sideBySide(2);
    try t.expectEqual(@as(u8, 2), l.count);
    try t.expectEqual([4]f32{ 0, 0, 0.5, 1 }, l.placements[0].rect);
    try t.expectEqual([4]f32{ 0.5, 0, 0.5, 1 }, l.placements[1].rect);
}

test "top bottom splits the height evenly" {
    const l = Layout.topBottom(2);
    try t.expectEqual([4]f32{ 0, 0, 1, 0.5 }, l.placements[0].rect);
    try t.expectEqual([4]f32{ 0, 0.5, 1, 0.5 }, l.placements[1].rect);
}

test "grid picks the smallest square-ish arrangement" {
    const four = Layout.grid(4); // 2x2
    try t.expectEqual(@as(u8, 4), four.count);
    try t.expectEqual([4]f32{ 0, 0, 0.5, 0.5 }, four.placements[0].rect);
    try t.expectEqual([4]f32{ 0.5, 0, 0.5, 0.5 }, four.placements[1].rect);
    try t.expectEqual([4]f32{ 0, 0.5, 0.5, 0.5 }, four.placements[2].rect);
    try t.expectEqual([4]f32{ 0.5, 0.5, 0.5, 0.5 }, four.placements[3].rect);

    const three = Layout.grid(3); // 2 cols, 2 rows
    try t.expectEqual([4]f32{ 0, 0, 0.5, 0.5 }, three.placements[0].rect);
    try t.expectEqual([4]f32{ 0.5, 0, 0.5, 0.5 }, three.placements[1].rect);
    try t.expectEqual([4]f32{ 0, 0.5, 0.5, 0.5 }, three.placements[2].rect);
}

test "pip stacks source 1 over source 0" {
    const l = Layout.pip(.{ 0.6, 0.6, 0.35, 0.35 });
    try t.expectEqual(@as(u8, 2), l.count);
    try t.expectEqual([4]f32{ 0, 0, 1, 1 }, l.placements[0].rect);
    try t.expectEqual([4]f32{ 0.6, 0.6, 0.35, 0.35 }, l.placements[1].rect);
    var order: [max_sources]u8 = undefined;
    try t.expectEqual(@as(u8, 2), l.drawOrder(&order));
    try t.expectEqual(@as(u8, 0), order[0]); // base first
    try t.expectEqual(@as(u8, 1), order[1]); // inset on top
}

test "draw order sorts by z then registration index, stably" {
    var l = Layout{ .count = 3 };
    l.placements[0].z = 2;
    l.placements[1].z = 0;
    l.placements[2].z = 0;
    var order: [max_sources]u8 = undefined;
    try t.expectEqual(@as(u8, 3), l.drawOrder(&order));
    // z 0 first (indices 1,2 by registration), then z 2 (index 0).
    try t.expectEqual(@as(u8, 1), order[0]);
    try t.expectEqual(@as(u8, 2), order[1]);
    try t.expectEqual(@as(u8, 0), order[2]);
}

test "counts clamp into range" {
    try t.expectEqual(@as(u8, 1), Layout.sideBySide(0).count);
    try t.expectEqual(@as(u8, max_sources), Layout.grid(99).count);
}
