//! Parsing for compiled shader blobs. The compiler wraps its platform
//! payload in a small container: magic and version, input and output
//! hashes, the uniform table, then the payload the driver consumes. The
//! render node hands blobs to bgfx whole; the vulkan adapter needs the raw
//! spirv inside, plus the binding convention verified against the payload's
//! own decorations.

const std = @import("std");

pub const Error = error{MalformedBlob};

pub const Uniform = struct {
    name_buf: [64]u8,
    name_len: u8,
    kind: u8,
    num: u8,
    reg_index: u16,
    reg_count: u16,

    pub fn name(u: *const Uniform) []const u8 {
        return u.name_buf[0..u.name_len];
    }
};

pub const Parsed = struct {
    kind: u8,
    version: u8,
    uniforms: [8]Uniform,
    uniform_count: u8,
    payload: []const u8,
};

pub fn parse(blob: []const u8) Error!Parsed {
    if (blob.len < 18) return error.MalformedBlob;
    if (blob[1] != 'S' or blob[2] != 'H') return error.MalformedBlob;
    const kind = blob[0];
    if (kind != 'V' and kind != 'F' and kind != 'C') return error.MalformedBlob;

    var out: Parsed = .{
        .kind = kind,
        .version = blob[3],
        .uniforms = undefined,
        .uniform_count = 0,
        .payload = &.{},
    };

    var offset: usize = 12;
    const count = std.mem.readInt(u16, blob[offset..][0..2], .little);
    offset += 2;
    for (0..count) |_| {
        if (offset + 1 > blob.len) return error.MalformedBlob;
        const name_len = blob[offset];
        offset += 1;
        if (offset + name_len + 10 > blob.len) return error.MalformedBlob;
        if (out.uniform_count < out.uniforms.len) {
            var uniform: Uniform = .{
                .name_buf = undefined,
                .name_len = @min(name_len, 63),
                .kind = blob[offset + name_len],
                .num = blob[offset + name_len + 1],
                .reg_index = std.mem.readInt(u16, blob[offset + name_len + 2 ..][0..2], .little),
                .reg_count = std.mem.readInt(u16, blob[offset + name_len + 4 ..][0..2], .little),
            };
            @memcpy(uniform.name_buf[0..uniform.name_len], blob[offset .. offset + uniform.name_len]);
            out.uniforms[out.uniform_count] = uniform;
            out.uniform_count += 1;
        }
        offset += name_len + 2 + 8;
    }

    if (offset + 4 > blob.len) return error.MalformedBlob;
    const payload_len = std.mem.readInt(u32, blob[offset..][0..4], .little);
    offset += 4;
    if (offset + payload_len > blob.len) return error.MalformedBlob;
    out.payload = blob[offset .. offset + payload_len];
    return out;
}

const spirv_magic: u32 = 0x0723_0203;

/// True when the payload's decorations declare this binding on descriptor
/// set zero. The adapter builds its pipeline layout from the compiler's
/// fixed convention and asserts each expected binding against the payload,
/// so a convention change breaks loudly at startup, not as garbage frames.
pub fn spirvDeclaresBinding(payload: []const u8, binding: u32) bool {
    if (payload.len < 20) return false;
    if (std.mem.readInt(u32, payload[0..4], .little) != spirv_magic) return false;

    var target_bindings: [64]u32 = undefined;
    var found: usize = 0;

    var offset: usize = 20;
    while (offset + 4 <= payload.len) {
        const word = std.mem.readInt(u32, payload[offset..][0..4], .little);
        const word_count: usize = word >> 16;
        const opcode = word & 0xffff;
        if (word_count == 0) return false;
        if (opcode == 71 and offset + 16 <= payload.len) { // OpDecorate
            const target = std.mem.readInt(u32, payload[offset + 4 ..][0..4], .little);
            const decoration = std.mem.readInt(u32, payload[offset + 8 ..][0..4], .little);
            if (decoration == 33 and found < target_bindings.len) { // Binding
                _ = target;
                target_bindings[found] = std.mem.readInt(u32, payload[offset + 12 ..][0..4], .little);
                found += 1;
            }
        }
        offset += word_count * 4;
    }
    for (target_bindings[0..found]) |declared| {
        if (declared == binding) return true;
    }
    return false;
}

const t = std.testing;

fn testBlob(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, &.{ 'C', 'S', 'H', 11 });
    try out.appendSlice(gpa, &(.{0} ** 8));
    try out.appendSlice(gpa, &.{ 1, 0 }); // one uniform
    try out.append(gpa, 5);
    try out.appendSlice(gpa, "u_yuv");
    try out.appendSlice(gpa, &.{ 0x04, 1 });
    try out.appendSlice(gpa, &.{ 0, 0, 4, 0, 0, 0, 0, 0 });
    const payload = [_]u8{ 0x03, 0x02, 0x23, 0x07, 0, 0, 1, 0, 0, 0, 0, 0, 1, 0, 0, 0, 0, 0, 0, 0 };
    try out.appendSlice(gpa, &.{ payload.len, 0, 0, 0 });
    try out.appendSlice(gpa, &payload);
    return out.toOwnedSlice(gpa);
}

test "parses kind, uniforms, and payload bounds" {
    const blob = try testBlob(t.allocator);
    defer t.allocator.free(blob);
    const parsed = try parse(blob);
    try t.expectEqual(@as(u8, 'C'), parsed.kind);
    try t.expectEqual(@as(u8, 11), parsed.version);
    try t.expectEqual(@as(u8, 1), parsed.uniform_count);
    try t.expectEqualStrings("u_yuv", parsed.uniforms[0].name());
    try t.expectEqual(@as(u16, 4), parsed.uniforms[0].reg_count);
    try t.expectEqual(@as(usize, 20), parsed.payload.len);
}

test "rejects truncated and foreign blobs" {
    try t.expectError(error.MalformedBlob, parse("short"));
    try t.expectError(error.MalformedBlob, parse("XYH\x0b0000000000000000000000"));
    const blob = try testBlob(t.allocator);
    defer t.allocator.free(blob);
    try t.expectError(error.MalformedBlob, parse(blob[0 .. blob.len - 4]));
}

test "binding scan finds only declared bindings" {
    const blob = try testBlob(t.allocator);
    defer t.allocator.free(blob);
    const parsed = try parse(blob);
    try t.expect(!spirvDeclaresBinding(parsed.payload, 0));
    try t.expect(!spirvDeclaresBinding("not spirv", 0));
}
