//! Color management for capture output: the primaries a still is tagged
//! with so viewers render wide gamut correctly. PNG carries lightweight
//! cHRM/gAMA/sRGB chunks; JPEG carries a matrix-shaper ICC profile built
//! here from first principles - no vendored profile blob to license.

const std = @import("std");

/// The color spaces a capture can be tagged with. srgb is the default
/// and needs no gamut tag beyond the sRGB marker.
pub const Space = enum(u32) {
    srgb = 0,
    display_p3 = 1,
    rec2020 = 2,

    pub fn fromInt(v: u32) Space {
        return switch (v) {
            1 => .display_p3,
            2 => .rec2020,
            else => .srgb,
        };
    }
};

// Primaries and D65 white as CIE xy, the numbers each standard fixes.
const Primaries = struct { rx: f64, ry: f64, gx: f64, gy: f64, bx: f64, by: f64, wx: f64, wy: f64 };
const srgb_primaries = Primaries{ .rx = 0.64, .ry = 0.33, .gx = 0.30, .gy = 0.60, .bx = 0.15, .by = 0.06, .wx = 0.3127, .wy = 0.3290 };
const p3_primaries = Primaries{ .rx = 0.680, .ry = 0.320, .gx = 0.265, .gy = 0.690, .bx = 0.150, .by = 0.060, .wx = 0.3127, .wy = 0.3290 };
const rec2020_primaries = Primaries{ .rx = 0.708, .ry = 0.292, .gx = 0.170, .gy = 0.797, .bx = 0.131, .by = 0.046, .wx = 0.3127, .wy = 0.3290 };

fn primariesOf(space: Space) Primaries {
    return switch (space) {
        .srgb => srgb_primaries,
        .display_p3 => p3_primaries,
        .rec2020 => rec2020_primaries,
    };
}

// --- PNG chunk helpers -----------------------------------------------

/// cHRM stores white and primary xy as u32 in units of 100000. Null for
/// sRGB, which the sRGB chunk covers on its own.
pub fn chromaticities(space: Space) ?[32]u8 {
    if (space == .srgb) return null;
    const p = primariesOf(space);
    var out: [32]u8 = undefined;
    const vals = [8]f64{ p.wx, p.wy, p.rx, p.ry, p.gx, p.gy, p.bx, p.by };
    for (vals, 0..) |v, i| {
        std.mem.writeInt(u32, out[i * 4 ..][0..4], @intFromFloat(@round(v * 100000.0)), .big);
    }
    return out;
}

/// gAMA stores the image's encoding gamma times 100000; the wide-gamut
/// spaces here all use the sRGB/Rec709 ~1/2.2 encoding.
pub fn gamma(space: Space) ?[4]u8 {
    if (space == .srgb) return null;
    var out: [4]u8 = undefined;
    std.mem.writeInt(u32, &out, 45455, .big);
    return out;
}

// --- ICC profile assembly --------------------------------------------

fn s15(x: f64) i32 {
    return @intFromFloat(@round(x * 65536.0));
}

const Mat3 = [9]f64;

fn matMul(a: Mat3, b: Mat3) Mat3 {
    var out: Mat3 = undefined;
    for (0..3) |r| {
        for (0..3) |c| {
            out[r * 3 + c] = a[r * 3 + 0] * b[0 * 3 + c] + a[r * 3 + 1] * b[1 * 3 + c] + a[r * 3 + 2] * b[2 * 3 + c];
        }
    }
    return out;
}

fn matVec(a: Mat3, v: [3]f64) [3]f64 {
    return .{
        a[0] * v[0] + a[1] * v[1] + a[2] * v[2],
        a[3] * v[0] + a[4] * v[1] + a[5] * v[2],
        a[6] * v[0] + a[7] * v[1] + a[8] * v[2],
    };
}

fn matInv(m: Mat3) Mat3 {
    const det = m[0] * (m[4] * m[8] - m[5] * m[7]) - m[1] * (m[3] * m[8] - m[5] * m[6]) + m[2] * (m[3] * m[7] - m[4] * m[6]);
    const id = 1.0 / det;
    return .{
        (m[4] * m[8] - m[5] * m[7]) * id, (m[2] * m[7] - m[1] * m[8]) * id, (m[1] * m[5] - m[2] * m[4]) * id,
        (m[5] * m[6] - m[3] * m[8]) * id, (m[0] * m[8] - m[2] * m[6]) * id, (m[2] * m[3] - m[0] * m[5]) * id,
        (m[3] * m[7] - m[4] * m[6]) * id, (m[1] * m[6] - m[0] * m[7]) * id, (m[0] * m[4] - m[1] * m[3]) * id,
    };
}

fn xyzFromXy(x: f64, y: f64) [3]f64 {
    return .{ x / y, 1.0, (1.0 - x - y) / y };
}

// RGB->XYZ for the primaries at their native D65 white.
fn rgbToXyz(p: Primaries) Mat3 {
    const r = xyzFromXy(p.rx, p.ry);
    const g = xyzFromXy(p.gx, p.gy);
    const b = xyzFromXy(p.bx, p.by);
    const small = Mat3{ r[0], g[0], b[0], r[1], g[1], b[1], r[2], g[2], b[2] };
    const w = xyzFromXy(p.wx, p.wy);
    const s = matVec(matInv(small), w);
    return .{
        r[0] * s[0], g[0] * s[1], b[0] * s[2],
        r[1] * s[0], g[1] * s[1], b[1] * s[2],
        r[2] * s[0], g[2] * s[1], b[2] * s[2],
    };
}

const d65 = [3]f64{ 0.95047, 1.0, 1.08883 };
const d50 = [3]f64{ 0.96422, 1.0, 0.82521 };
const bradford = Mat3{ 0.8951, 0.2664, -0.1614, -0.7502, 1.7135, 0.0367, 0.0389, -0.0685, 1.0296 };

// Bradford chromatic adaptation from D65 to the ICC's D50 PCS.
fn adaptD65toD50() Mat3 {
    const src = matVec(bradford, d65);
    const dst = matVec(bradford, d50);
    const diag = Mat3{ dst[0] / src[0], 0, 0, 0, dst[1] / src[1], 0, 0, 0, dst[2] / src[2] };
    return matMul(matInv(bradford), matMul(diag, bradford));
}

fn writeXyzTag(buf: []u8, xyz: [3]f64) void {
    @memcpy(buf[0..4], "XYZ ");
    @memset(buf[4..8], 0);
    std.mem.writeInt(i32, buf[8..12], s15(xyz[0]), .big);
    std.mem.writeInt(i32, buf[12..16], s15(xyz[1]), .big);
    std.mem.writeInt(i32, buf[16..20], s15(xyz[2]), .big);
}

const IccError = error{Unsupported};

// A matrix-shaper ICC (mntr/RGB/XYZ, v4) tagging the primaries adapted
// to D50, a gamma 2.2 TRC shared by the channels, and mluc desc/cprt.
// Structurally minimal but complete enough for viewers to color-manage.
fn buildIcc(space: Space, out: []u8) usize {
    const p = primariesOf(space);
    const to_d50 = matMul(adaptD65toD50(), rgbToXyz(p));
    const r_xyz = [3]f64{ to_d50[0], to_d50[3], to_d50[6] };
    const g_xyz = [3]f64{ to_d50[1], to_d50[4], to_d50[7] };
    const b_xyz = [3]f64{ to_d50[2], to_d50[5], to_d50[8] };

    const name = switch (space) {
        .display_p3 => "Display P3",
        .rec2020 => "Rec2020",
        .srgb => "sRGB",
    };

    // Tag payloads, each padded to a 4-byte boundary.
    var body: [1024]u8 = undefined;
    var bp: usize = 0;
    const Tag = struct { sig: *const [4]u8, off: usize, len: usize };
    var tags: [9]Tag = undefined;
    var tag_count: usize = 0;

    const addXyz = struct {
        fn f(b: *[1024]u8, cur: *usize, xyz: [3]f64) [2]usize {
            const start = cur.*;
            writeXyzTag(b[start..], xyz);
            cur.* += 20;
            return .{ start, 20 };
        }
    }.f;
    const addCurve = struct {
        fn f(b: *[1024]u8, cur: *usize) [2]usize {
            const start = cur.*;
            @memcpy(b[start..][0..4], "curv");
            @memset(b[start + 4 ..][0..4], 0);
            std.mem.writeInt(u32, b[start + 8 ..][0..4], 1, .big); // one gamma entry
            std.mem.writeInt(u16, b[start + 12 ..][0..2], 0x0233, .big); // gamma 2.2 as u8Fixed8
            cur.* += 14;
            while (cur.* % 4 != 0) : (cur.* += 1) b[cur.*] = 0;
            return .{ start, 14 };
        }
    }.f;
    const addText = struct {
        fn f(b: *[1024]u8, cur: *usize, text: []const u8) [2]usize {
            const start = cur.*;
            @memcpy(b[start..][0..4], "mluc");
            @memset(b[start + 4 ..][0..4], 0);
            std.mem.writeInt(u32, b[start + 8 ..][0..4], 1, .big); // one record
            std.mem.writeInt(u32, b[start + 12 ..][0..4], 12, .big); // record size
            @memcpy(b[start + 16 ..][0..2], "en");
            @memcpy(b[start + 18 ..][0..2], "US");
            const str_len = text.len * 2;
            std.mem.writeInt(u32, b[start + 20 ..][0..4], @intCast(str_len), .big);
            std.mem.writeInt(u32, b[start + 24 ..][0..4], 28, .big); // offset within the tag
            var i: usize = 0;
            while (i < text.len) : (i += 1) {
                b[start + 28 + i * 2] = 0;
                b[start + 28 + i * 2 + 1] = text[i];
            }
            cur.* = start + 28 + str_len;
            while (cur.* % 4 != 0) : (cur.* += 1) b[cur.*] = 0;
            return .{ start, 28 + str_len };
        }
    }.f;

    var d = addText(&body, &bp, name);
    tags[tag_count] = .{ .sig = "desc", .off = d[0], .len = d[1] };
    tag_count += 1;

    d = addXyz(&body, &bp, d50);
    tags[tag_count] = .{ .sig = "wtpt", .off = d[0], .len = d[1] };
    tag_count += 1;

    d = addXyz(&body, &bp, r_xyz);
    tags[tag_count] = .{ .sig = "rXYZ", .off = d[0], .len = d[1] };
    tag_count += 1;
    d = addXyz(&body, &bp, g_xyz);
    tags[tag_count] = .{ .sig = "gXYZ", .off = d[0], .len = d[1] };
    tag_count += 1;
    d = addXyz(&body, &bp, b_xyz);
    tags[tag_count] = .{ .sig = "bXYZ", .off = d[0], .len = d[1] };
    tag_count += 1;

    const curve = addCurve(&body, &bp);
    // The three channels share one TRC payload.
    tags[tag_count] = .{ .sig = "rTRC", .off = curve[0], .len = curve[1] };
    tag_count += 1;
    tags[tag_count] = .{ .sig = "gTRC", .off = curve[0], .len = curve[1] };
    tag_count += 1;
    tags[tag_count] = .{ .sig = "bTRC", .off = curve[0], .len = curve[1] };
    tag_count += 1;

    d = addText(&body, &bp, "gosslens");
    tags[tag_count] = .{ .sig = "cprt", .off = d[0], .len = d[1] };
    tag_count += 1;

    const header_size: usize = 128;
    const table_size: usize = 4 + tag_count * 12;
    const body_base = header_size + table_size;
    const total = body_base + bp;

    @memset(out[0..header_size], 0);
    std.mem.writeInt(u32, out[0..4], @intCast(total), .big);
    std.mem.writeInt(u32, out[8..12], 0x04300000, .big); // ICC v4.3
    @memcpy(out[12..16], "mntr");
    @memcpy(out[16..20], "RGB ");
    @memcpy(out[20..24], "XYZ ");
    @memcpy(out[36..40], "acsp");
    // PCS illuminant is fixed to D50 in the header.
    std.mem.writeInt(i32, out[68..72], s15(d50[0]), .big);
    std.mem.writeInt(i32, out[72..76], s15(d50[1]), .big);
    std.mem.writeInt(i32, out[76..80], s15(d50[2]), .big);

    std.mem.writeInt(u32, out[128..132], @intCast(tag_count), .big);
    var i: usize = 0;
    while (i < tag_count) : (i += 1) {
        const e = out[132 + i * 12 ..];
        @memcpy(e[0..4], tags[i].sig);
        std.mem.writeInt(u32, e[4..8], @intCast(body_base + tags[i].off), .big);
        std.mem.writeInt(u32, e[8..12], @intCast(tags[i].len), .big);
    }
    @memcpy(out[body_base .. body_base + bp], body[0..bp]);
    return total;
}

// The profiles are fixed per space, so build them once at comptime and
// hand out slices. sRGB captures carry no ICC (the sRGB assumption).
const p3_icc = blk: {
    @setEvalBranchQuota(200000);
    var buf: [1152]u8 = undefined;
    const n = buildIcc(.display_p3, &buf);
    break :blk buf[0..n].*;
};
const rec2020_icc = blk: {
    @setEvalBranchQuota(200000);
    var buf: [1152]u8 = undefined;
    const n = buildIcc(.rec2020, &buf);
    break :blk buf[0..n].*;
};

/// The ICC profile bytes a JPEG should carry for the given space, or
/// null for sRGB.
pub fn iccProfile(space_int: u32) ?[]const u8 {
    return switch (Space.fromInt(space_int)) {
        .srgb => null,
        .display_p3 => &p3_icc,
        .rec2020 => &rec2020_icc,
    };
}

const t = std.testing;

test "wide-gamut spaces carry a plausible ICC and sRGB carries none" {
    try t.expect(iccProfile(0) == null);
    const p3 = iccProfile(1).?;
    try t.expect(p3.len > 128);
    // Size field matches, signature present, tag count is nine.
    try t.expectEqual(@as(u32, @intCast(p3.len)), std.mem.readInt(u32, p3[0..4], .big));
    try t.expectEqualSlices(u8, "acsp", p3[36..40]);
    try t.expectEqual(@as(u32, 9), std.mem.readInt(u32, p3[128..132], .big));
    try t.expect(iccProfile(2).?.len > 128);
}

test "PNG chroma and gamma helpers tag wide gamut, skip sRGB" {
    try t.expect(chromaticities(.srgb) == null);
    try t.expect(gamma(.srgb) == null);
    const chrm = chromaticities(.display_p3).?;
    // Red x of Display P3 is 0.680 -> 68000.
    try t.expectEqual(@as(u32, 68000), std.mem.readInt(u32, chrm[8..12], .big));
    try t.expectEqual(@as(u32, 45455), std.mem.readInt(u32, &gamma(.rec2020).?, .big));
}
