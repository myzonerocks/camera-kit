//! Decode for single-shot face detection models. The model emits one raw
//! box regression and one raw score per anchor; anchors are a fixed grid
//! derived from the input size and the per-layer stride plan, so they are
//! generated once and reused every frame. Overlapping candidates merge by
//! score weight, which keeps boxes stable frame to frame where a hard
//! suppression would flicker between near-equal candidates.

const std = @import("std");

pub const keypoint_count = 6;

pub const Layer = struct {
    stride: u32,
    anchors_per_cell: u32,
};

pub const Anchor = struct {
    x: f32,
    y: f32,
};

/// Number of anchors a stride plan produces for a square input.
pub fn anchorCount(input_size: u32, layers: []const Layer) usize {
    var total: usize = 0;
    for (layers) |layer| {
        const cells = (input_size + layer.stride - 1) / layer.stride;
        total += @as(usize, cells) * cells * layer.anchors_per_cell;
    }
    return total;
}

/// Fills `out` with anchor centers in normalized coordinates, row major
/// per layer, matching the model's output ordering. `out.len` must equal
/// `anchorCount` for the same plan.
pub fn generateAnchors(input_size: u32, layers: []const Layer, out: []Anchor) void {
    var at: usize = 0;
    for (layers) |layer| {
        const cells = (input_size + layer.stride - 1) / layer.stride;
        for (0..cells) |row| {
            for (0..cells) |column| {
                const x = (@as(f32, @floatFromInt(column)) + 0.5) / @as(f32, @floatFromInt(cells));
                const y = (@as(f32, @floatFromInt(row)) + 0.5) / @as(f32, @floatFromInt(cells));
                for (0..layer.anchors_per_cell) |_| {
                    out[at] = .{ .x = x, .y = y };
                    at += 1;
                }
            }
        }
    }
    std.debug.assert(at == out.len);
}

pub const Detection = struct {
    score: f32,
    /// Box center and size, normalized to the model input square.
    x: f32,
    y: f32,
    width: f32,
    height: f32,
    keypoints: [keypoint_count][2]f32,

    fn overlap(a: *const Detection, b: *const Detection) f32 {
        const ax0 = a.x - a.width * 0.5;
        const ay0 = a.y - a.height * 0.5;
        const bx0 = b.x - b.width * 0.5;
        const by0 = b.y - b.height * 0.5;
        const x0 = @max(ax0, bx0);
        const y0 = @max(ay0, by0);
        const x1 = @min(ax0 + a.width, bx0 + b.width);
        const y1 = @min(ay0 + a.height, by0 + b.height);
        if (x1 <= x0 or y1 <= y0) return 0;
        const shared = (x1 - x0) * (y1 - y0);
        const total = a.width * a.height + b.width * b.height - shared;
        if (total <= 0) return 0;
        return shared / total;
    }
};

fn sigmoid(raw: f32) f32 {
    // The score threshold is applied in logit space by the caller via
    // scoreToLogit, so this only runs for candidates that pass.
    return 1.0 / (1.0 + @exp(-raw));
}

pub fn scoreToLogit(score: f32) f32 {
    return @log(score / (1.0 - score));
}

/// Decodes raw model output into `out`, returning the accepted slice.
/// `raw_boxes` holds 4 box values then 6 keypoint pairs per anchor, in
/// model input pixels; `raw_scores` holds one logit per anchor. Candidates
/// below `min_score` are dropped before any allocation-free merge work.
pub fn decode(
    raw_boxes: []const f32,
    raw_scores: []const f32,
    anchors: []const Anchor,
    input_size: f32,
    min_score: f32,
    out: []Detection,
) []Detection {
    std.debug.assert(raw_boxes.len == anchors.len * (4 + keypoint_count * 2));
    std.debug.assert(raw_scores.len == anchors.len);
    const min_logit = scoreToLogit(min_score);
    const values_per_anchor = 4 + keypoint_count * 2;

    var count: usize = 0;
    for (anchors, 0..) |anchor, at| {
        // Clamped comparison in logit space skips the transcendental for
        // the overwhelming majority of anchors.
        const logit = std.math.clamp(raw_scores[at], -100.0, 100.0);
        if (logit < min_logit) continue;
        if (count == out.len) break;

        const raw = raw_boxes[at * values_per_anchor ..][0..values_per_anchor];
        var detection: Detection = .{
            .score = sigmoid(logit),
            .x = anchor.x + raw[0] / input_size,
            .y = anchor.y + raw[1] / input_size,
            .width = raw[2] / input_size,
            .height = raw[3] / input_size,
            .keypoints = undefined,
        };
        for (0..keypoint_count) |keypoint| {
            detection.keypoints[keypoint] = .{
                anchor.x + raw[4 + keypoint * 2] / input_size,
                anchor.y + raw[4 + keypoint * 2 + 1] / input_size,
            };
        }
        out[count] = detection;
        count += 1;
    }
    return mergeOverlapping(out[0..count]);
}

/// Score-weighted merge of overlapping detections, in place. Candidates
/// are sorted by score; each survivor absorbs every remaining candidate
/// that overlaps it past the threshold, averaging geometry by score.
fn mergeOverlapping(candidates: []Detection) []Detection {
    const min_overlap = 0.3;
    std.mem.sort(Detection, candidates, {}, struct {
        fn byScore(_: void, a: Detection, b: Detection) bool {
            return a.score > b.score;
        }
    }.byScore);

    var kept: usize = 0;
    var remaining = candidates.len;
    while (remaining > kept) {
        const anchor_box = candidates[kept];
        var merged = anchor_box;
        var weight = anchor_box.score;
        merged.x *= weight;
        merged.y *= weight;
        merged.width *= weight;
        merged.height *= weight;
        for (&merged.keypoints) |*keypoint| {
            keypoint[0] *= weight;
            keypoint[1] *= weight;
        }

        // Partition survivors ahead of the read cursor so the pass stays
        // linear in the candidate count for each kept detection.
        var write = kept + 1;
        for (candidates[kept + 1 .. remaining]) |candidate| {
            if (anchor_box.overlap(&candidate) >= min_overlap) {
                const w = candidate.score;
                merged.x += candidate.x * w;
                merged.y += candidate.y * w;
                merged.width += candidate.width * w;
                merged.height += candidate.height * w;
                for (&merged.keypoints, candidate.keypoints) |*keypoint, other| {
                    keypoint[0] += other[0] * w;
                    keypoint[1] += other[1] * w;
                }
                weight += w;
            } else {
                candidates[write] = candidate;
                write += 1;
            }
        }
        remaining = write;

        merged.x /= weight;
        merged.y /= weight;
        merged.width /= weight;
        merged.height /= weight;
        for (&merged.keypoints) |*keypoint| {
            keypoint[0] /= weight;
            keypoint[1] /= weight;
        }
        merged.score = anchor_box.score;
        candidates[kept] = merged;
        kept += 1;
    }
    return candidates[0..kept];
}

const t = std.testing;

const short_range_layers = [_]Layer{ .{ .stride = 8, .anchors_per_cell = 2 }, .{ .stride = 16, .anchors_per_cell = 6 } };
const full_range_layers = [_]Layer{.{ .stride = 4, .anchors_per_cell = 1 }};

test "anchor plans produce the model's anchor counts" {
    try t.expectEqual(@as(usize, 896), anchorCount(128, &short_range_layers));
    try t.expectEqual(@as(usize, 2304), anchorCount(192, &full_range_layers));
}

test "anchors cover the unit square from the first cell center" {
    var anchors: [896]Anchor = undefined;
    generateAnchors(128, &short_range_layers, &anchors);
    try t.expectApproxEqAbs(@as(f32, 0.5 / 16.0), anchors[0].x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 0.5 / 16.0), anchors[0].y, 1e-6);
    const last = anchors[anchors.len - 1];
    try t.expectApproxEqAbs(@as(f32, 7.5 / 8.0), last.x, 1e-6);
    try t.expectApproxEqAbs(@as(f32, 7.5 / 8.0), last.y, 1e-6);
}

test "decode drops weak anchors and merges duplicates" {
    const anchors = [_]Anchor{ .{ .x = 0.25, .y = 0.25 }, .{ .x = 0.26, .y = 0.25 }, .{ .x = 0.75, .y = 0.75 } };
    var raw_boxes = [_]f32{0} ** (3 * 16);
    for (0..3) |at| {
        raw_boxes[at * 16 + 2] = 32; // quarter of the input square
        raw_boxes[at * 16 + 3] = 32;
    }
    const raw_scores = [_]f32{ 2.0, 1.0, -9.0 };
    var out: [3]Detection = undefined;
    const detections = decode(&raw_boxes, &raw_scores, &anchors, 128, 0.5, &out);
    try t.expectEqual(@as(usize, 1), detections.len);
    try t.expect(detections[0].score > 0.8);
    // The merged center sits between the two overlapping anchors, pulled
    // toward the higher score.
    try t.expect(detections[0].x > 0.25 and detections[0].x < 0.26);
}

test "distant detections survive the merge separately" {
    const anchors = [_]Anchor{ .{ .x = 0.25, .y = 0.25 }, .{ .x = 0.75, .y = 0.75 } };
    var raw_boxes = [_]f32{0} ** (2 * 16);
    for (0..2) |at| {
        raw_boxes[at * 16 + 2] = 16;
        raw_boxes[at * 16 + 3] = 16;
    }
    const raw_scores = [_]f32{ 1.5, 1.5 };
    var out: [2]Detection = undefined;
    const detections = decode(&raw_boxes, &raw_scores, &anchors, 128, 0.5, &out);
    try t.expectEqual(@as(usize, 2), detections.len);
}
