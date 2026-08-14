//! Lens asset loading over vendored cgltf. Assets are untrusted content:
//! parsing happens fully in memory, external file references are refused,
//! and a malformed asset fails closed with an error, never a crash. All
//! cgltf allocations route through the caller's Zig allocator, so the leak
//! gates cover the C side too.

const std = @import("std");
const math = @import("math");
const c = @cImport({
    @cInclude("cgltf.h");
});

pub const Error = error{
    OutOfMemory,
    MalformedAsset,
    UnsupportedAsset,
    ExternalReference,
};

/// cgltf frees with only the pointer, so each allocation carries its length
/// in a max-aligned header the bridge reads back at free time.
const alloc_header = @sizeOf(usize) * 2;

fn bridgeAlloc(user: ?*anyopaque, size: c.cgltf_size) callconv(.c) ?*anyopaque {
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(user.?));
    const total = alloc_header + size;
    const raw = gpa.alignedAlloc(u8, .fromByteUnits(16), total) catch return null;
    std.mem.writeInt(usize, raw[0..@sizeOf(usize)], total, .little);
    return raw.ptr + alloc_header;
}

fn bridgeFree(user: ?*anyopaque, ptr: ?*anyopaque) callconv(.c) void {
    const p = ptr orelse return;
    const gpa: *const std.mem.Allocator = @ptrCast(@alignCast(user.?));
    const raw: [*]align(16) u8 = @alignCast(@as([*]u8, @ptrCast(p)) - alloc_header);
    const total = std.mem.readInt(usize, raw[0..@sizeOf(usize)], .little);
    gpa.free(raw[0..total]);
}

fn refuseFileRead(
    memory_options: [*c]const c.cgltf_memory_options,
    file_options: [*c]const c.cgltf_file_options,
    path: [*c]const u8,
    size: [*c]c.cgltf_size,
    data: [*c]?*anyopaque,
) callconv(.c) c.cgltf_result {
    _ = memory_options;
    _ = file_options;
    _ = path;
    _ = size;
    _ = data;
    return c.cgltf_result_file_not_found;
}

fn refuseFileRelease(
    memory_options: [*c]const c.cgltf_memory_options,
    file_options: [*c]const c.cgltf_file_options,
    data: ?*anyopaque,
    size: c.cgltf_size,
) callconv(.c) void {
    _ = memory_options;
    _ = file_options;
    _ = data;
    _ = size;
}

fn statusFromResult(result: c.cgltf_result) Error!void {
    return switch (result) {
        c.cgltf_result_success => {},
        c.cgltf_result_out_of_memory => error.OutOfMemory,
        c.cgltf_result_file_not_found => error.ExternalReference,
        c.cgltf_result_unknown_format, c.cgltf_result_legacy_gltf => error.UnsupportedAsset,
        else => error.MalformedAsset,
    };
}

pub const Primitive = struct {
    raw: *const c.cgltf_primitive,

    pub fn vertexCount(p: Primitive) usize {
        const positions = p.findAttribute(c.cgltf_attribute_type_position) orelse return 0;
        return positions.count;
    }

    pub fn indexCount(p: Primitive) usize {
        const accessor = p.raw.indices orelse return 0;
        return accessor.*.count;
    }

    fn findAttribute(p: Primitive, kind: c.cgltf_attribute_type) ?*const c.cgltf_accessor {
        for (p.raw.attributes[0..p.raw.attributes_count]) |attr| {
            if (attr.type == kind) return attr.data;
        }
        return null;
    }

    fn readVec3Attribute(p: Primitive, kind: c.cgltf_attribute_type, out: [][3]f32) Error!usize {
        const accessor = p.findAttribute(kind) orelse return 0;
        const count = @min(accessor.*.count, out.len);
        const floats: [*]f32 = @ptrCast(out.ptr);
        const unpacked = c.cgltf_accessor_unpack_floats(accessor, floats, count * 3);
        if (unpacked != count * 3) return error.MalformedAsset;
        return count;
    }

    /// Copies positions into `out`, returning how many vertices were read.
    pub fn readPositions(p: Primitive, out: [][3]f32) Error!usize {
        return p.readVec3Attribute(c.cgltf_attribute_type_position, out);
    }

    pub fn readNormals(p: Primitive, out: [][3]f32) Error!usize {
        return p.readVec3Attribute(c.cgltf_attribute_type_normal, out);
    }

    pub fn readIndices(p: Primitive, out: []u32) Error!usize {
        const accessor = p.raw.indices orelse return 0;
        const count = @min(accessor.*.count, out.len);
        for (out[0..count], 0..) |*index, i| {
            index.* = @intCast(c.cgltf_accessor_read_index(accessor, i));
        }
        return count;
    }
};

pub const Mesh = struct {
    raw: *const c.cgltf_mesh,

    pub fn primitiveCount(m: Mesh) usize {
        return m.raw.primitives_count;
    }

    pub fn primitive(m: Mesh, index: usize) Primitive {
        return .{ .raw = @ptrCast(&m.raw.primitives[index]) };
    }
};

pub const Node = struct {
    raw: *const c.cgltf_node,

    pub fn name(n: Node) ?[]const u8 {
        const p = n.raw.name orelse return null;
        return std.mem.span(@as([*:0]const u8, @ptrCast(p)));
    }

    pub fn meshIndex(n: Node, asset: *const Asset) ?usize {
        const mesh = n.raw.mesh orelse return null;
        const base = asset.data.meshes;
        return (@intFromPtr(mesh) - @intFromPtr(base)) / @sizeOf(c.cgltf_mesh);
    }

    /// Local transform composed to a column-major matrix.
    pub fn localMatrix(n: Node) math.Mat4 {
        var raw: [16]f32 = undefined;
        c.cgltf_node_transform_local(n.raw, &raw);
        var m: math.Mat4 = undefined;
        for (0..4) |col| {
            m.cols[col] = .{ raw[col * 4], raw[col * 4 + 1], raw[col * 4 + 2], raw[col * 4 + 3] };
        }
        return m;
    }
};

/// A parsed glTF or GLB asset, fully resident in memory. The `gpa` pointer
/// must stay stable for the asset's lifetime, so it lives in the struct and
/// the cgltf options point back into it.
pub const Asset = struct {
    gpa_box: *std.mem.Allocator,
    data: *c.cgltf_data,

    pub fn parse(gpa: std.mem.Allocator, bytes: []const u8) Error!Asset {
        const gpa_box = try gpa.create(std.mem.Allocator);
        errdefer gpa.destroy(gpa_box);
        gpa_box.* = gpa;

        var options: c.cgltf_options = std.mem.zeroes(c.cgltf_options);
        options.memory = .{ .alloc_func = bridgeAlloc, .free_func = bridgeFree, .user_data = gpa_box };
        options.file = .{ .read = refuseFileRead, .release = refuseFileRelease, .user_data = null };

        var data: ?*c.cgltf_data = null;
        try statusFromResult(c.cgltf_parse(&options, bytes.ptr, bytes.len, &data));
        errdefer c.cgltf_free(data);

        // Resolves GLB binary chunks and data URIs only. The base path is
        // null and the file callbacks refuse, so once parsing has succeeded
        // the only way buffer loading reports an unknown format is a URI
        // that would leave the asset: an external reference.
        statusFromResult(c.cgltf_load_buffers(&options, data, null)) catch |err| switch (err) {
            error.UnsupportedAsset => return error.ExternalReference,
            else => return err,
        };
        try statusFromResult(c.cgltf_validate(data));

        return .{ .gpa_box = gpa_box, .data = data.? };
    }

    pub fn deinit(a: *Asset) void {
        const gpa = a.gpa_box.*;
        c.cgltf_free(a.data);
        gpa.destroy(a.gpa_box);
        a.* = undefined;
    }

    pub fn meshCount(a: *const Asset) usize {
        return a.data.meshes_count;
    }

    pub fn mesh(a: *const Asset, index: usize) Mesh {
        return .{ .raw = @ptrCast(&a.data.meshes[index]) };
    }

    pub fn nodeCount(a: *const Asset) usize {
        return a.data.nodes_count;
    }

    pub fn node(a: *const Asset, index: usize) Node {
        return .{ .raw = @ptrCast(&a.data.nodes[index]) };
    }
};

const t = std.testing;

// Builds a complete single-triangle GLB in memory: one buffer holding three
// positions and three indices, one mesh, one node. Exercises the same
// container path a real lens asset takes.
fn buildTriangleGlb(gpa: std.mem.Allocator) ![]u8 {
    const positions = [3][3]f32{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const indices = [3]u16{ 0, 1, 2 };

    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(gpa);
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions));
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices));
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":36}},
        \\{{"buffer":0,"byteOffset":36,"byteLength":6}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}},
        \\{{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1}}]}}],
        \\"nodes":[{{"mesh":0,"name":"tri","translation":[2,0,0]}}],
        \\"scenes":[{{"nodes":[0]}}],"scene":0}}
    , .{bin.items.len});
    defer gpa.free(json);

    var json_padded: std.ArrayList(u8) = .empty;
    defer json_padded.deinit(gpa);
    try json_padded.appendSlice(gpa, json);
    while (json_padded.items.len % 4 != 0) try json_padded.append(gpa, ' ');

    var glb: std.ArrayList(u8) = .empty;
    errdefer glb.deinit(gpa);
    const total: u32 = @intCast(12 + 8 + json_padded.items.len + 8 + bin.items.len);
    var scratch: [4]u8 = undefined;
    std.mem.writeInt(u32, &scratch, 0x46546C67, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 2, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, total, .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, @intCast(json_padded.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x4E4F534A, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, json_padded.items);
    std.mem.writeInt(u32, &scratch, @intCast(bin.items.len), .little);
    try glb.appendSlice(gpa, &scratch);
    std.mem.writeInt(u32, &scratch, 0x004E4942, .little);
    try glb.appendSlice(gpa, &scratch);
    try glb.appendSlice(gpa, bin.items);
    return glb.toOwnedSlice(gpa);
}

test "parses a glb and reads geometry exactly" {
    const glb = try buildTriangleGlb(t.allocator);
    defer t.allocator.free(glb);

    var asset = try Asset.parse(t.allocator, glb);
    defer asset.deinit();

    try t.expectEqual(@as(usize, 1), asset.meshCount());
    const prim = asset.mesh(0).primitive(0);
    try t.expectEqual(@as(usize, 3), prim.vertexCount());
    try t.expectEqual(@as(usize, 3), prim.indexCount());

    var positions: [3][3]f32 = undefined;
    try t.expectEqual(@as(usize, 3), try prim.readPositions(&positions));
    try t.expectEqual(@as(f32, 1.0), positions[1][0]);
    try t.expectEqual(@as(f32, 1.0), positions[2][1]);

    var indices: [3]u32 = undefined;
    try t.expectEqual(@as(usize, 3), try prim.readIndices(&indices));
    try t.expectEqual([3]u32{ 0, 1, 2 }, indices);
}

test "node transform reaches the math types" {
    const glb = try buildTriangleGlb(t.allocator);
    defer t.allocator.free(glb);
    var asset = try Asset.parse(t.allocator, glb);
    defer asset.deinit();

    try t.expectEqual(@as(usize, 1), asset.nodeCount());
    const n = asset.node(0);
    try t.expectEqualStrings("tri", n.name().?);
    try t.expectEqual(@as(usize, 0), n.meshIndex(&asset).?);
    const m = n.localMatrix();
    try t.expectEqual(@as(f32, 2.0), m.cols[3][0]);
}

test "truncated glb fails closed" {
    const glb = try buildTriangleGlb(t.allocator);
    defer t.allocator.free(glb);
    for ([_]usize{ 4, 11, 20, glb.len / 2 }) |cut| {
        try t.expectError(error.MalformedAsset, Asset.parse(t.allocator, glb[0..cut]));
    }
}

test "external buffer references are refused" {
    const json =
        \\{"asset":{"version":"2.0"},
        \\"buffers":[{"uri":"secret.bin","byteLength":16}]}
    ;
    try t.expectError(error.ExternalReference, Asset.parse(t.allocator, json));
}

test "garbage bytes are not an asset" {
    const garbage = [_]u8{0xff} ** 64;
    const result = Asset.parse(t.allocator, &garbage);
    try t.expect(result == Error.MalformedAsset or result == Error.UnsupportedAsset);
}
