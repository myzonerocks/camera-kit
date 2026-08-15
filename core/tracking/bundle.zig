//! Reader for tracking model bundles. A bundle is a zip archive whose
//! entries are the individual model files; the ones we pin store their
//! payloads uncompressed, so a lookup returns a slice into the bundle
//! bytes without copying. Deflated entries decompress through the standard
//! library so an unusual bundle still opens, at the cost of one allocation.

const std = @import("std");

pub const Error = error{
    MalformedBundle,
    EntryNotFound,
    UnsupportedCompression,
} || std.mem.Allocator.Error;

const eocd_signature = 0x0605_4b50;
const central_signature = 0x0201_4b50;
const local_signature = 0x0403_4b50;
const eocd_min_len = 22;
const central_min_len = 46;
const local_min_len = 30;

pub const Entry = struct {
    name: []const u8,
    method: u16,
    compressed_size: u32,
    uncompressed_size: u32,
    payload_offset: usize,
};

/// The payload of one entry. Stored entries borrow from the bundle bytes;
/// deflated entries own an allocation the caller frees.
pub const Payload = struct {
    bytes: []const u8,
    owned: bool,

    pub fn deinit(payload: Payload, gpa: std.mem.Allocator) void {
        if (payload.owned) gpa.free(@constCast(payload.bytes));
    }
};

pub const Bundle = struct {
    bytes: []const u8,
    central_offset: usize,
    entry_count: u16,

    pub fn open(bytes: []const u8) Error!Bundle {
        if (bytes.len < eocd_min_len) return error.MalformedBundle;

        // The end record sits at the tail, pushed forward by an optional
        // comment; scan back over at most one comment's worth of bytes.
        const scan_floor = bytes.len -| (eocd_min_len + std.math.maxInt(u16));
        var at = bytes.len - eocd_min_len;
        const eocd = while (true) : (at -= 1) {
            if (std.mem.readInt(u32, bytes[at..][0..4], .little) == eocd_signature) break bytes[at..];
            if (at == scan_floor) return error.MalformedBundle;
        };

        const entry_count = std.mem.readInt(u16, eocd[10..12], .little);
        const central_size = std.mem.readInt(u32, eocd[12..16], .little);
        const central_offset = std.mem.readInt(u32, eocd[16..20], .little);
        if (central_offset > bytes.len or bytes.len - central_offset < central_size) return error.MalformedBundle;

        return .{ .bytes = bytes, .central_offset = central_offset, .entry_count = entry_count };
    }

    pub fn iterator(bundle: *const Bundle) Iterator {
        return .{ .bundle = bundle, .offset = bundle.central_offset, .remaining = bundle.entry_count };
    }

    pub fn find(bundle: *const Bundle, name: []const u8) Error!Entry {
        var it = bundle.iterator();
        while (try it.next()) |entry| {
            if (std.mem.eql(u8, entry.name, name)) return entry;
        }
        return error.EntryNotFound;
    }

    pub fn payload(bundle: *const Bundle, gpa: std.mem.Allocator, entry: Entry) Error!Payload {
        const compressed = bundle.bytes[entry.payload_offset..][0..entry.compressed_size];
        switch (entry.method) {
            0 => {
                if (entry.compressed_size != entry.uncompressed_size) return error.MalformedBundle;
                return .{ .bytes = compressed, .owned = false };
            },
            8 => {
                const out = try gpa.alloc(u8, entry.uncompressed_size);
                errdefer gpa.free(out);
                var input: std.Io.Reader = .fixed(compressed);
                var window: [std.compress.flate.max_window_len]u8 = undefined;
                var decompress: std.compress.flate.Decompress = .init(&input, .raw, &window);
                decompress.reader.readSliceAll(out) catch return error.MalformedBundle;
                return .{ .bytes = out, .owned = true };
            },
            else => return error.UnsupportedCompression,
        }
    }
};

pub const Iterator = struct {
    bundle: *const Bundle,
    offset: usize,
    remaining: u16,

    pub fn next(it: *Iterator) Error!?Entry {
        if (it.remaining == 0) return null;
        const bytes = it.bundle.bytes;
        if (bytes.len - it.offset < central_min_len) return error.MalformedBundle;
        const record = bytes[it.offset..];
        if (std.mem.readInt(u32, record[0..4], .little) != central_signature) return error.MalformedBundle;

        const method = std.mem.readInt(u16, record[10..12], .little);
        const compressed_size = std.mem.readInt(u32, record[20..24], .little);
        const uncompressed_size = std.mem.readInt(u32, record[24..28], .little);
        const name_len = std.mem.readInt(u16, record[28..30], .little);
        const extra_len = std.mem.readInt(u16, record[30..32], .little);
        const comment_len = std.mem.readInt(u16, record[32..34], .little);
        const local_offset = std.mem.readInt(u32, record[42..46], .little);
        if (bytes.len - it.offset < central_min_len + @as(usize, name_len) + extra_len + comment_len) {
            return error.MalformedBundle;
        }
        const name = record[central_min_len..][0..name_len];

        // The local header repeats the name and carries its own extra
        // field length; the payload starts after both.
        if (bytes.len < local_min_len or local_offset > bytes.len - local_min_len) return error.MalformedBundle;
        const local = bytes[local_offset..];
        if (std.mem.readInt(u32, local[0..4], .little) != local_signature) return error.MalformedBundle;
        const local_name_len = std.mem.readInt(u16, local[26..28], .little);
        const local_extra_len = std.mem.readInt(u16, local[28..30], .little);
        const payload_offset = local_offset + local_min_len + @as(usize, local_name_len) + local_extra_len;
        if (payload_offset > bytes.len or bytes.len - payload_offset < compressed_size) return error.MalformedBundle;

        it.offset += central_min_len + @as(usize, name_len) + extra_len + comment_len;
        it.remaining -= 1;
        return .{
            .name = name,
            .method = method,
            .compressed_size = compressed_size,
            .uncompressed_size = uncompressed_size,
            .payload_offset = payload_offset,
        };
    }
};

const t = std.testing;

fn appendInt(out: *std.ArrayList(u8), gpa: std.mem.Allocator, comptime T: type, value: T) !void {
    var buf: [@sizeOf(T)]u8 = undefined;
    std.mem.writeInt(T, &buf, value, .little);
    try out.appendSlice(gpa, &buf);
}

fn testBundle(gpa: std.mem.Allocator) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);

    const name = "model.tflite";
    const body = "weights-bytes";
    try appendInt(&out, gpa, u32, local_signature);
    try out.appendSlice(gpa, &(.{0} ** 4));
    try appendInt(&out, gpa, u16, 0); // stored
    try out.appendSlice(gpa, &(.{0} ** 8));
    try appendInt(&out, gpa, u32, body.len);
    try appendInt(&out, gpa, u32, body.len);
    try appendInt(&out, gpa, u16, name.len);
    try appendInt(&out, gpa, u16, 0);
    try out.appendSlice(gpa, name);
    try out.appendSlice(gpa, body);

    const central_start: u32 = @intCast(out.items.len);
    try appendInt(&out, gpa, u32, central_signature);
    try out.appendSlice(gpa, &(.{0} ** 6));
    try appendInt(&out, gpa, u16, 0); // stored
    try out.appendSlice(gpa, &(.{0} ** 8));
    try appendInt(&out, gpa, u32, body.len);
    try appendInt(&out, gpa, u32, body.len);
    try appendInt(&out, gpa, u16, name.len);
    try appendInt(&out, gpa, u16, 0);
    try appendInt(&out, gpa, u16, 0);
    try out.appendSlice(gpa, &(.{0} ** 8));
    try appendInt(&out, gpa, u32, 0); // local header offset
    try out.appendSlice(gpa, name);
    const central_size: u32 = @intCast(out.items.len - central_start);

    try appendInt(&out, gpa, u32, eocd_signature);
    try out.appendSlice(gpa, &(.{0} ** 4));
    try appendInt(&out, gpa, u16, 1);
    try appendInt(&out, gpa, u16, 1);
    try appendInt(&out, gpa, u32, central_size);
    try appendInt(&out, gpa, u32, central_start);
    try appendInt(&out, gpa, u16, 0);

    return out.toOwnedSlice(gpa);
}

test "finds a stored entry and borrows its payload" {
    const bytes = try testBundle(t.allocator);
    defer t.allocator.free(bytes);
    const bundle = try Bundle.open(bytes);
    const entry = try bundle.find("model.tflite");
    try t.expectEqual(@as(u16, 0), entry.method);
    const body = try bundle.payload(t.allocator, entry);
    defer body.deinit(t.allocator);
    try t.expect(!body.owned);
    try t.expectEqualStrings("weights-bytes", body.bytes);
}

test "missing entries and truncated archives are refused" {
    const bytes = try testBundle(t.allocator);
    defer t.allocator.free(bytes);
    const bundle = try Bundle.open(bytes);
    try t.expectError(error.EntryNotFound, bundle.find("absent.tflite"));
    try t.expectError(error.MalformedBundle, Bundle.open(bytes[0 .. bytes.len - 3]));
    try t.expectError(error.MalformedBundle, Bundle.open("PK"));
}

test "central records past the entry count are not read" {
    const bytes = try testBundle(t.allocator);
    defer t.allocator.free(bytes);
    const bundle = try Bundle.open(bytes);
    var it = bundle.iterator();
    try t.expect((try it.next()) != null);
    try t.expectEqual(@as(?Entry, null), try it.next());
}
