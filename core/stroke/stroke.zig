//! Brush strokes: the geometry behind the draw and AR-brush tools. Points are
//! pushed in normalized screen space, expanded into a per-segment ribbon of
//! triangles for the renderer. Bounded fixed storage with an undo/redo stack,
//! so a stroke allocates nothing and the frame path only reads finished vertices.
const std = @import("std");

pub const max_strokes = 64;
pub const max_points = 256;
pub const floats_per_vertex = 6; // x, y, r, g, b, a
/// Six vertices (two triangles) per segment, up to max_points-1 segments.
pub const max_vertices = max_strokes * (max_points - 1) * 6;

pub const Point = struct { x: f32, y: f32 };

pub const Stroke = struct {
    points: [max_points]Point = undefined,
    count: u16 = 0,
    color: [4]f32 = .{ 1, 1, 1, 1 },
    width: f32 = 0.01, // half-width in normalized units
};

/// A board of strokes with an undo/redo op-log. begin/point/end build the
/// current stroke; undo pops the last committed stroke onto the redo stack;
/// redo replays it; clear drops everything. All bounded, no allocation.
pub const Board = struct {
    strokes: [max_strokes]Stroke = undefined,
    count: u16 = 0,
    redo: [max_strokes]Stroke = undefined,
    redo_count: u16 = 0,
    drawing: bool = false,
    style_color: [4]f32 = .{ 1, 1, 1, 1 },
    style_width: f32 = 0.01,

    pub fn setStyle(self: *Board, color: [4]f32, width: f32) void {
        self.style_color = color;
        self.style_width = if (width > 0) width else 0.001;
    }

    /// Starts a new stroke with the current style. A fresh stroke invalidates
    /// the redo stack, the same as any editor.
    pub fn begin(self: *Board) void {
        if (self.count >= max_strokes) return;
        self.redo_count = 0;
        self.strokes[self.count] = .{ .color = self.style_color, .width = self.style_width };
        self.drawing = true;
    }

    pub fn point(self: *Board, x: f32, y: f32) void {
        if (!self.drawing or self.count >= max_strokes) return;
        const s = &self.strokes[self.count];
        if (s.count >= max_points) return;
        s.points[s.count] = .{ .x = x, .y = y };
        s.count += 1;
    }

    /// Commits the current stroke; a stroke of fewer than two points is dropped.
    pub fn end(self: *Board) void {
        if (!self.drawing) return;
        self.drawing = false;
        if (self.strokes[self.count].count >= 2) self.count += 1;
    }

    pub fn undo(self: *Board) void {
        if (self.count == 0) return;
        self.count -= 1;
        self.redo[self.redo_count] = self.strokes[self.count];
        self.redo_count += 1;
    }

    pub fn redoLast(self: *Board) void {
        if (self.redo_count == 0 or self.count >= max_strokes) return;
        self.redo_count -= 1;
        self.strokes[self.count] = self.redo[self.redo_count];
        self.count += 1;
    }

    pub fn clear(self: *Board) void {
        self.count = 0;
        self.redo_count = 0;
        self.drawing = false;
    }

    /// The float count buildVertices would write for the current strokes, so a
    /// caller can size its buffer before pulling the ribbon. Counts only
    /// segments long enough to survive the degenerate check.
    pub fn vertexFloatCount(self: *const Board) usize {
        var v: usize = 0;
        for (self.strokes[0..self.count]) |s| {
            if (s.count < 2) continue;
            var i: u16 = 0;
            while (i + 1 < s.count) : (i += 1) {
                const a = s.points[i];
                const b = s.points[i + 1];
                const dx = b.x - a.x;
                const dy = b.y - a.y;
                if (@sqrt(dx * dx + dy * dy) < 1e-6) continue;
                v += 6 * floats_per_vertex;
            }
        }
        return v;
    }

    /// Expands every committed stroke into a triangle ribbon in `out`
    /// (floats_per_vertex per vertex), returning the vertex count. Each segment
    /// becomes a quad whose thickness is the stroke's half-width offset
    /// perpendicular to the segment direction.
    pub fn buildVertices(self: *const Board, out: []f32) usize {
        var v: usize = 0;
        for (self.strokes[0..self.count]) |s| {
            if (s.count < 2) continue;
            var i: u16 = 0;
            while (i + 1 < s.count) : (i += 1) {
                const a = s.points[i];
                const b = s.points[i + 1];
                var dx = b.x - a.x;
                var dy = b.y - a.y;
                const len = @sqrt(dx * dx + dy * dy);
                if (len < 1e-6) continue;
                dx /= len;
                dy /= len;
                const nx = -dy * s.width; // perpendicular offset
                const ny = dx * s.width;
                const corners = [4][2]f32{
                    .{ a.x + nx, a.y + ny },
                    .{ a.x - nx, a.y - ny },
                    .{ b.x - nx, b.y - ny },
                    .{ b.x + nx, b.y + ny },
                };
                const tri = [6]usize{ 0, 1, 2, 0, 2, 3 };
                for (tri) |c| {
                    if (v + floats_per_vertex > out.len) return v;
                    out[v + 0] = corners[c][0];
                    out[v + 1] = corners[c][1];
                    out[v + 2] = s.color[0];
                    out[v + 3] = s.color[1];
                    out[v + 4] = s.color[2];
                    out[v + 5] = s.color[3];
                    v += floats_per_vertex;
                }
            }
        }
        return v;
    }
};

const t = std.testing;

test "a stroke commits only with two or more points" {
    var b = Board{};
    b.begin();
    b.point(0.1, 0.1);
    b.end();
    try t.expectEqual(@as(u16, 0), b.count); // one point is dropped
    b.begin();
    b.point(0.1, 0.1);
    b.point(0.5, 0.5);
    b.end();
    try t.expectEqual(@as(u16, 1), b.count);
}

test "undo and redo move the last stroke across the stacks" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 1);
    b.end();
    try t.expectEqual(@as(u16, 1), b.count);
    b.undo();
    try t.expectEqual(@as(u16, 0), b.count);
    b.redoLast();
    try t.expectEqual(@as(u16, 1), b.count);
    // A fresh stroke invalidates redo.
    b.undo();
    b.begin();
    b.point(0, 0);
    b.point(0.2, 0.2);
    b.end();
    try t.expectEqual(@as(u16, 0), b.redo_count);
}

test "buildVertices produces six vertices per segment" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 0); // one segment
    b.point(1, 1); // second segment
    b.end();
    var out: [max_vertices]f32 = undefined;
    const n = b.buildVertices(&out);
    // two segments * six vertices * six floats
    try t.expectEqual(@as(usize, 2 * 6 * floats_per_vertex), n);
    // the color rides every vertex
    try t.expectEqual(@as(f32, 1), out[2]);
}

test "clear drops everything" {
    var b = Board{};
    b.begin();
    b.point(0, 0);
    b.point(1, 1);
    b.end();
    b.clear();
    try t.expectEqual(@as(u16, 0), b.count);
    var out: [max_vertices]f32 = undefined;
    try t.expectEqual(@as(usize, 0), b.buildVertices(&out));
}
