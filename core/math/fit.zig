//! Weighted similarity fitting: the rotation, uniform scale, and
//! translation carrying one weighted cloud onto another. Horn's
//! quaternion method over fixed-count Jacobi sweeps - deterministic,
//! allocation-free, no general SVD needed.

const std = @import("std");
const vec = @import("vec.zig");
const matrix = @import("matrix.zig");

pub const Vec3 = vec.Vec3;
pub const Mat4 = matrix.Mat4;

pub const WeightedPoint = struct {
    source: Vec3,
    target: Vec3,
    weight: f32,
};

/// Diagonalizes a symmetric 4x4 in place by cyclic Jacobi rotations and
/// returns the eigenvector of the largest eigenvalue. Twelve sweeps
/// drive every off-diagonal term to f32 noise for any input this module
/// sees; the count is fixed so the result is bit-deterministic.
fn largestEigenvector(n_in: [4][4]f32) [4]f32 {
    var n = n_in;
    var v = [4][4]f32{
        .{ 1, 0, 0, 0 },
        .{ 0, 1, 0, 0 },
        .{ 0, 0, 1, 0 },
        .{ 0, 0, 0, 1 },
    };
    var sweep: usize = 0;
    while (sweep < 12) : (sweep += 1) {
        var p: usize = 0;
        while (p < 3) : (p += 1) {
            var q = p + 1;
            while (q < 4) : (q += 1) {
                const apq = n[p][q];
                if (@abs(apq) < 1e-12) continue;
                const app = n[p][p];
                const aqq = n[q][q];
                const theta = (aqq - app) / (2.0 * apq);
                const tangent = std.math.sign(theta) / (@abs(theta) + @sqrt(theta * theta + 1.0));
                const cos = 1.0 / @sqrt(tangent * tangent + 1.0);
                const sin = tangent * cos;
                for (0..4) |k| {
                    const nkp = n[k][p];
                    const nkq = n[k][q];
                    n[k][p] = cos * nkp - sin * nkq;
                    n[k][q] = sin * nkp + cos * nkq;
                }
                for (0..4) |k| {
                    const npk = n[p][k];
                    const nqk = n[q][k];
                    n[p][k] = cos * npk - sin * nqk;
                    n[q][k] = sin * npk + cos * nqk;
                }
                for (0..4) |k| {
                    const vkp = v[k][p];
                    const vkq = v[k][q];
                    v[k][p] = cos * vkp - sin * vkq;
                    v[k][q] = sin * vkp + cos * vkq;
                }
            }
        }
    }
    var best: usize = 0;
    for (1..4) |k| {
        if (n[k][k] > n[best][best]) best = k;
    }
    return .{ v[0][best], v[1][best], v[2][best], v[3][best] };
}

/// Fits target = scale * R * source + translation in the weighted
/// least-squares sense and returns it as one column-vector transform.
/// Null when the weights vanish or the cloud is degenerate.
pub fn fitSimilarity(points: []const WeightedPoint) ?Mat4 {
    if (points.len < 3) return null;

    var weight_sum: f32 = 0;
    var source_center = Vec3{ 0, 0, 0 };
    var target_center = Vec3{ 0, 0, 0 };
    for (points) |point| {
        weight_sum += point.weight;
        source_center += point.source * vec.splat(Vec3, point.weight);
        target_center += point.target * vec.splat(Vec3, point.weight);
    }
    if (weight_sum <= 1e-9) return null;
    source_center = source_center * vec.splat(Vec3, 1.0 / weight_sum);
    target_center = target_center * vec.splat(Vec3, 1.0 / weight_sum);

    // The weighted covariance between centered clouds, plus the source
    // spread for the scale below.
    var s = [3][3]f32{ .{ 0, 0, 0 }, .{ 0, 0, 0 }, .{ 0, 0, 0 } };
    var source_spread: f32 = 0;
    for (points) |point| {
        const a = point.source - source_center;
        const b = point.target - target_center;
        source_spread += point.weight * vec.dot(a, a);
        const av = [3]f32{ a[0], a[1], a[2] };
        const bv = [3]f32{ b[0], b[1], b[2] };
        for (0..3) |row| {
            for (0..3) |col| {
                s[row][col] += point.weight * av[row] * bv[col];
            }
        }
    }
    if (source_spread <= 1e-9) return null;

    // Horn's N matrix from the covariance.
    const n = [4][4]f32{
        .{ s[0][0] + s[1][1] + s[2][2], s[1][2] - s[2][1], s[2][0] - s[0][2], s[0][1] - s[1][0] },
        .{ s[1][2] - s[2][1], s[0][0] - s[1][1] - s[2][2], s[0][1] + s[1][0], s[2][0] + s[0][2] },
        .{ s[2][0] - s[0][2], s[0][1] + s[1][0], s[1][1] - s[0][0] - s[2][2], s[1][2] + s[2][1] },
        .{ s[0][1] - s[1][0], s[2][0] + s[0][2], s[1][2] + s[2][1], s[2][2] - s[0][0] - s[1][1] },
    };
    const q = largestEigenvector(n);
    const w = q[0];
    const x = q[1];
    const y = q[2];
    const z = q[3];

    var rotation = [3][3]f32{
        .{ 1 - 2 * (y * y + z * z), 2 * (x * y - w * z), 2 * (x * z + w * y) },
        .{ 2 * (x * y + w * z), 1 - 2 * (x * x + z * z), 2 * (y * z - w * x) },
        .{ 2 * (x * z - w * y), 2 * (y * z + w * x), 1 - 2 * (x * x + y * y) },
    };

    // The similarity scale: rotated-source-to-target correlation over the
    // source spread, Umeyama's closed form for the Horn rotation.
    var correlation: f32 = 0;
    for (points) |point| {
        const a = point.source - source_center;
        const b = point.target - target_center;
        const rotated = Vec3{
            rotation[0][0] * a[0] + rotation[0][1] * a[1] + rotation[0][2] * a[2],
            rotation[1][0] * a[0] + rotation[1][1] * a[1] + rotation[1][2] * a[2],
            rotation[2][0] * a[0] + rotation[2][1] * a[1] + rotation[2][2] * a[2],
        };
        correlation += point.weight * vec.dot(rotated, b);
    }
    const fit_scale = correlation / source_spread;
    if (!(fit_scale > 0)) return null;

    for (0..3) |row| {
        for (0..3) |col| {
            rotation[row][col] *= fit_scale;
        }
    }
    const translation = target_center - Vec3{
        rotation[0][0] * source_center[0] + rotation[0][1] * source_center[1] + rotation[0][2] * source_center[2],
        rotation[1][0] * source_center[0] + rotation[1][1] * source_center[1] + rotation[1][2] * source_center[2],
        rotation[2][0] * source_center[0] + rotation[2][1] * source_center[1] + rotation[2][2] * source_center[2],
    };

    return .{ .cols = .{
        .{ rotation[0][0], rotation[1][0], rotation[2][0], 0 },
        .{ rotation[0][1], rotation[1][1], rotation[2][1], 0 },
        .{ rotation[0][2], rotation[1][2], rotation[2][2], 0 },
        .{ translation[0], translation[1], translation[2], 1 },
    } };
}

const t = std.testing;

fn applyKnown(m: Mat4, p: Vec3) Vec3 {
    return m.mulPoint(p);
}

test "recovers a known rotation, scale, and translation" {
    const angle: f32 = 0.6;
    const cos = @cos(angle);
    const sin = @sin(angle);
    const scale: f32 = 1.7;
    const translate = Vec3{ 3.0, -2.0, 5.0 };
    const cloud = [_]Vec3{
        .{ 0, 0, 0 }, .{ 1, 0, 0 }, .{ 0, 1, 0 }, .{ 0, 0, 1 },
        .{ 1, 1, 0 }, .{ 0.3, -0.7, 0.2 }, .{ -1, 0.5, 1.5 },
    };
    var points: [cloud.len]WeightedPoint = undefined;
    for (cloud, 0..) |p, i| {
        const rotated = Vec3{
            cos * p[0] - sin * p[1],
            sin * p[0] + cos * p[1],
            p[2],
        };
        points[i] = .{
            .source = p,
            .target = rotated * vec.splat(Vec3, scale) + translate,
            .weight = if (i % 2 == 0) 1.0 else 0.4,
        };
    }
    const fit = fitSimilarity(&points).?;
    for (points) |point| {
        const mapped = applyKnown(fit, point.source);
        try t.expectApproxEqAbs(point.target[0], mapped[0], 1e-3);
        try t.expectApproxEqAbs(point.target[1], mapped[1], 1e-3);
        try t.expectApproxEqAbs(point.target[2], mapped[2], 1e-3);
    }
}

test "degenerate input refuses" {
    const same = Vec3{ 1, 2, 3 };
    var points: [4]WeightedPoint = undefined;
    for (&points) |*p| p.* = .{ .source = same, .target = same, .weight = 1.0 };
    try t.expectEqual(@as(?Mat4, null), fitSimilarity(&points));
    try t.expectEqual(@as(?Mat4, null), fitSimilarity(points[0..2]));
}
