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

    pub fn readTexcoords(p: Primitive, out: [][2]f32) Error!usize {
        const accessor = p.findAttribute(c.cgltf_attribute_type_texcoord) orelse return 0;
        const count = @min(accessor.*.count, out.len);
        const floats: [*]f32 = @ptrCast(out.ptr);
        const unpacked = c.cgltf_accessor_unpack_floats(accessor, floats, count * 2);
        if (unpacked != count * 2) return error.MalformedAsset;
        return count;
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

    pub fn materialIndex(p: Primitive, asset: *const Asset) ?usize {
        const mat = p.raw.material orelse return null;
        const base = asset.data.materials;
        return (@intFromPtr(mat) - @intFromPtr(base)) / @sizeOf(c.cgltf_material);
    }
};

/// A material's base-color texture only - the one map a flat-shaded
/// lens draw needs. Every other PBR channel (metallic/roughness,
/// normal, emissive) is out of scope until a node type actually reads
/// one.
pub const Material = struct {
    raw: *const c.cgltf_material,

    pub fn baseColorImageIndex(m: Material, asset: *const Asset) ?usize {
        if (m.raw.has_pbr_metallic_roughness == 0) return null;
        const texture = m.raw.pbr_metallic_roughness.base_color_texture.texture orelse return null;
        const image = texture.*.image orelse return null;
        const base = asset.data.images;
        return (@intFromPtr(image) - @intFromPtr(base)) / @sizeOf(c.cgltf_image);
    }
};

pub const AnimationPath = enum { translation, rotation, scale };
pub const Interpolation = enum { linear, step };

/// One glTF animation channel: a keyframe curve on one node's one
/// transform component (translation/rotation/scale). weights (morph
/// targets) is a real glTF path type this wrapper does not expose -
/// no node type reads a weights channel yet.
pub const AnimationChannel = struct {
    raw: *const c.cgltf_animation_channel,

    pub fn path(ch: AnimationChannel) ?AnimationPath {
        return switch (ch.raw.target_path) {
            c.cgltf_animation_path_type_translation => .translation,
            c.cgltf_animation_path_type_rotation => .rotation,
            c.cgltf_animation_path_type_scale => .scale,
            else => null,
        };
    }

    pub fn targetsNode(ch: AnimationChannel, node: Node) bool {
        return ch.raw.target_node == node.raw;
    }

    /// Values per keyframe for this channel's path: 3 for translation
    /// and scale, 4 for a rotation quaternion.
    pub fn componentsPerKeyframe(ch: AnimationChannel) usize {
        return if (ch.path() == .rotation) 4 else 3;
    }

    pub fn keyframeCount(ch: AnimationChannel) usize {
        const sampler = ch.raw.sampler orelse return 0;
        return sampler.*.input.*.count;
    }

    /// null for cubic_spline: it stores an in-tangent and out-tangent
    /// alongside every value (3x the plain keyframe count) - real
    /// glTF, just not sampled by readValues below, which assumes one
    /// value per keyframe. A channel using it reads as unsupported
    /// rather than silently sampling tangent data as if it were a
    /// value.
    pub fn interpolation(ch: AnimationChannel) ?Interpolation {
        const sampler = ch.raw.sampler orelse return null;
        return switch (sampler.*.interpolation) {
            c.cgltf_interpolation_type_linear => .linear,
            c.cgltf_interpolation_type_step => .step,
            else => null,
        };
    }

    /// Copies keyframe times (seconds, ascending) into out.
    pub fn readTimes(ch: AnimationChannel, out: []f32) Error!usize {
        const sampler = ch.raw.sampler orelse return 0;
        const accessor = sampler.*.input;
        const count = @min(accessor.*.count, out.len);
        const unpacked = c.cgltf_accessor_unpack_floats(accessor, out.ptr, count);
        if (unpacked != count) return error.MalformedAsset;
        return count;
    }

    /// Copies keyframe values into out, flattened componentsPerKeyframe
    /// floats at a time (translation/scale: x,y,z; rotation: x,y,z,w,
    /// matching Quat's own field order).
    pub fn readValues(ch: AnimationChannel, out: []f32) Error!usize {
        const sampler = ch.raw.sampler orelse return 0;
        const accessor = sampler.*.output;
        const components = ch.componentsPerKeyframe();
        const count = @min(accessor.*.count, out.len / components);
        const unpacked = c.cgltf_accessor_unpack_floats(accessor, out.ptr, count * components);
        if (unpacked != count * components) return error.MalformedAsset;
        return count;
    }
};

pub const Animation = struct {
    raw: *const c.cgltf_animation,

    pub fn channelCount(a: Animation) usize {
        return a.raw.channels_count;
    }

    pub fn channel(a: Animation, index: usize) AnimationChannel {
        return .{ .raw = @ptrCast(&a.raw.channels[index]) };
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

    pub fn imageCount(a: *const Asset) usize {
        return a.data.images_count;
    }

    /// Raw bytes of an embedded image (its buffer view), typically a PNG a
    /// texture decoder consumes. External image files are already refused
    /// at parse time, so an image either has embedded bytes or none.
    pub fn imageBytes(a: *const Asset, index: usize) ?[]const u8 {
        const image = &a.data.images[index];
        const view = image.buffer_view orelse return null;
        const buffer_data = view.*.buffer.*.data orelse return null;
        const base: [*]const u8 = @ptrCast(buffer_data);
        return base[view.*.offset .. view.*.offset + view.*.size];
    }

    pub fn node(a: *const Asset, index: usize) Node {
        return .{ .raw = @ptrCast(&a.data.nodes[index]) };
    }

    pub fn animationCount(a: *const Asset) usize {
        return a.data.animations_count;
    }

    pub fn animation(a: *const Asset, index: usize) Animation {
        return .{ .raw = @ptrCast(&a.data.animations[index]) };
    }

    pub fn materialCount(a: *const Asset) usize {
        return a.data.materials_count;
    }

    pub fn material(a: *const Asset, index: usize) Material {
        return .{ .raw = @ptrCast(&a.data.materials[index]) };
    }
};

/// One animation channel's raw keyframe curve, decoded to plain owned
/// arrays - no cgltf pointers survive past decodeModel's own Asset,
/// which is parsed and torn down entirely off-thread. values is flat,
/// componentsPerKeyframe() floats (3 or 4) per entry, matching
/// AnimationChannel.readValues' own layout.
pub const DecodedAnimChannel = struct {
    path: AnimationPath,
    times: []f32,
    values: []f32,
};

pub const DecodedAnimation = struct {
    duration_seconds: f32,
    channels: []DecodedAnimChannel,

    /// The node's local transform at elapsed_seconds, looping every
    /// duration_seconds - a missing path (no channel drives it) holds
    /// its identity value, matching how a static glTF node with only a
    /// rotation channel keeps its authored translation/scale fixed.
    pub fn sample(anim: *const DecodedAnimation, elapsed_seconds: f32) math.Mat4 {
        var translation: math.Vec3 = .{ 0, 0, 0 };
        var rotation = math.Quat.identity;
        var scale: math.Vec3 = .{ 1, 1, 1 };
        const t_seconds = if (anim.duration_seconds > 0) @mod(elapsed_seconds, anim.duration_seconds) else 0;
        for (anim.channels) |ch| {
            switch (ch.path) {
                .translation => translation = sampleVec3(ch, t_seconds),
                .scale => scale = sampleVec3(ch, t_seconds),
                .rotation => rotation = sampleQuat(ch, t_seconds),
            }
        }
        return math.Mat4.mul(math.Mat4.mul(math.Mat4.translation(translation), rotation.toMat4()), math.Mat4.scaling(scale));
    }
};

/// Finds the keyframe pair bracketing t and the interpolation factor
/// between them - shared by sampleVec3/sampleQuat below, both of which
/// only differ in how they combine the two bracketing values. Times
/// are ascending per the glTF spec; before the first or after the
/// last keyframe clamps to that keyframe's own value (factor 0 or 1
/// against itself).
fn bracket(ch: DecodedAnimChannel, t_seconds: f32) struct { lo: usize, hi: usize, factor: f32 } {
    const times = ch.times;
    if (times.len == 1 or t_seconds <= times[0]) return .{ .lo = 0, .hi = 0, .factor = 0 };
    if (t_seconds >= times[times.len - 1]) return .{ .lo = times.len - 1, .hi = times.len - 1, .factor = 0 };
    for (1..times.len) |i| {
        if (t_seconds <= times[i]) {
            const span = times[i] - times[i - 1];
            const factor = if (span > 0) (t_seconds - times[i - 1]) / span else 0;
            return .{ .lo = i - 1, .hi = i, .factor = factor };
        }
    }
    unreachable;
}

fn sampleVec3(ch: DecodedAnimChannel, t_seconds: f32) math.Vec3 {
    const br = bracket(ch, t_seconds);
    const lo: math.Vec3 = .{ ch.values[br.lo * 3], ch.values[br.lo * 3 + 1], ch.values[br.lo * 3 + 2] };
    if (br.lo == br.hi) return lo;
    const hi: math.Vec3 = .{ ch.values[br.hi * 3], ch.values[br.hi * 3 + 1], ch.values[br.hi * 3 + 2] };
    return math.vec.lerp(lo, hi, br.factor);
}

fn sampleQuat(ch: DecodedAnimChannel, t_seconds: f32) math.Quat {
    const br = bracket(ch, t_seconds);
    const lo = math.Quat.init(ch.values[br.lo * 4], ch.values[br.lo * 4 + 1], ch.values[br.lo * 4 + 2], ch.values[br.lo * 4 + 3]);
    if (br.lo == br.hi) return lo;
    const hi = math.Quat.init(ch.values[br.hi * 4], ch.values[br.hi * 4 + 1], ch.values[br.hi * 4 + 2], ch.values[br.hi * 4 + 3]);
    return math.Quat.slerp(lo, hi, br.factor);
}

pub const DecodedModel = struct {
    positions: [][3]f32,
    indices: []u32,
    /// The material's flat base_color_factor tint (default white/
    /// opaque with no material) - the one PBR channel a flat-shaded
    /// draw needs; a base color texture is real, tested (Material.
    /// baseColorImageIndex), and deliberately not consumed here yet -
    /// no node type samples one.
    base_color: [4]f32,
    animation: ?DecodedAnimation,
};

/// Parses a .glb/.gltf's bytes into a plain-data model: the first
/// mesh's first primitive's geometry, its material's flat tint, and -
/// if the first node referencing that mesh has one - the first
/// animation's channels driving that same node. Suitable for the same
/// off-thread decode step image.decode already runs for a lens's other
/// assets (see adapters/asset's generic Loader): no cgltf pointer
/// outlives this call, everything returned is independently owned.
pub fn decodeModel(gpa: std.mem.Allocator, bytes: []const u8) Error!DecodedModel {
    var asset = try Asset.parse(gpa, bytes);
    defer asset.deinit();
    if (asset.meshCount() == 0) return error.MalformedAsset;
    const prim = asset.mesh(0).primitive(0);
    const vertex_count = prim.vertexCount();
    const index_count = prim.indexCount();
    if (vertex_count == 0 or index_count == 0) return error.MalformedAsset;

    const positions = try gpa.alloc([3]f32, vertex_count);
    errdefer gpa.free(positions);
    if (try prim.readPositions(positions) != vertex_count) return error.MalformedAsset;

    const indices = try gpa.alloc(u32, index_count);
    errdefer gpa.free(indices);
    if (try prim.readIndices(indices) != index_count) return error.MalformedAsset;

    var base_color: [4]f32 = .{ 1, 1, 1, 1 };
    if (prim.materialIndex(&asset)) |mat_index| {
        const mat = asset.material(mat_index);
        if (mat.raw.has_pbr_metallic_roughness != 0) base_color = mat.raw.pbr_metallic_roughness.base_color_factor;
    }

    var target_node: ?Node = null;
    for (0..asset.nodeCount()) |i| {
        const n = asset.node(i);
        if (n.meshIndex(&asset) == 0) {
            target_node = n;
            break;
        }
    }

    var decoded_animation: ?DecodedAnimation = null;
    errdefer if (decoded_animation) |*anim| freeAnimation(gpa, anim);
    if (target_node) |tn| {
        if (asset.animationCount() > 0) decoded_animation = try decodeAnimation(gpa, asset.animation(0), tn);
    }

    return .{ .positions = positions, .indices = indices, .base_color = base_color, .animation = decoded_animation };
}

fn decodeAnimation(gpa: std.mem.Allocator, anim: Animation, node: Node) Error!DecodedAnimation {
    var channels: std.ArrayList(DecodedAnimChannel) = .empty;
    errdefer {
        for (channels.items) |ch| {
            gpa.free(ch.times);
            gpa.free(ch.values);
        }
        channels.deinit(gpa);
    }
    var duration_seconds: f32 = 0;
    for (0..anim.channelCount()) |i| {
        const ch = anim.channel(i);
        if (!ch.targetsNode(node)) continue;
        const path = ch.path() orelse continue; // weights (morph targets): no node type reads one
        if (ch.interpolation() == null) return error.UnsupportedAsset; // cubic_spline
        const keyframe_count = ch.keyframeCount();
        if (keyframe_count == 0) continue;

        const times = try gpa.alloc(f32, keyframe_count);
        errdefer gpa.free(times);
        if (try ch.readTimes(times) != keyframe_count) return error.MalformedAsset;

        const components = ch.componentsPerKeyframe();
        const values = try gpa.alloc(f32, keyframe_count * components);
        errdefer gpa.free(values);
        if (try ch.readValues(values) != keyframe_count) return error.MalformedAsset;

        duration_seconds = @max(duration_seconds, times[keyframe_count - 1]);
        try channels.append(gpa, .{ .path = path, .times = times, .values = values });
    }
    return .{ .duration_seconds = duration_seconds, .channels = try channels.toOwnedSlice(gpa) };
}

pub fn freeAnimation(gpa: std.mem.Allocator, anim: *const DecodedAnimation) void {
    for (anim.channels) |ch| {
        gpa.free(ch.times);
        gpa.free(ch.values);
    }
    gpa.free(anim.channels);
}

pub fn freeDecodedModel(gpa: std.mem.Allocator, model: DecodedModel) void {
    gpa.free(model.positions);
    gpa.free(model.indices);
    if (model.animation) |*anim| freeAnimation(gpa, anim);
}

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

// Builds a GLB with the same single triangle plus a 3-keyframe linear
// translation animation on its one node - exercises the real accessor
// layout an animation channel reads (a separate bufferView per stream,
// each aligned to its own component size).
fn buildAnimatedGlb(gpa: std.mem.Allocator) ![]u8 {
    const positions = [3][3]f32{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 1.0, 0.0 },
    };
    const indices = [3]u16{ 0, 1, 2 };
    const times = [3]f32{ 0.0, 1.0, 2.0 };
    const values = [3][3]f32{
        .{ 0.0, 0.0, 0.0 },
        .{ 1.0, 0.0, 0.0 },
        .{ 0.0, 2.0, 0.0 },
    };

    var bin: std.ArrayList(u8) = .empty;
    defer bin.deinit(gpa);
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions)); // 0..36
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices)); // 36..42
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0); // pad to 44
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&times)); // 44..56
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&values)); // 56..92
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":36}},
        \\{{"buffer":0,"byteOffset":36,"byteLength":6}},
        \\{{"buffer":0,"byteOffset":44,"byteLength":12}},
        \\{{"buffer":0,"byteOffset":56,"byteLength":36}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":3,"type":"VEC3","min":[0,0,0],"max":[1,1,0]}},
        \\{{"bufferView":1,"componentType":5123,"count":3,"type":"SCALAR"}},
        \\{{"bufferView":2,"componentType":5126,"count":3,"type":"SCALAR"}},
        \\{{"bufferView":3,"componentType":5126,"count":3,"type":"VEC3"}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1}}]}}],
        \\"nodes":[{{"mesh":0,"name":"tri"}}],
        \\"animations":[{{"samplers":[{{"input":2,"output":3,"interpolation":"LINEAR"}}],
        \\"channels":[{{"sampler":0,"target":{{"node":0,"path":"translation"}}}}]}}],
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

test "reads a real linear translation animation channel exactly" {
    const glb = try buildAnimatedGlb(t.allocator);
    defer t.allocator.free(glb);
    var asset = try Asset.parse(t.allocator, glb);
    defer asset.deinit();

    try t.expectEqual(@as(usize, 1), asset.animationCount());
    const anim = asset.animation(0);
    try t.expectEqual(@as(usize, 1), anim.channelCount());
    const ch = anim.channel(0);

    try t.expectEqual(AnimationPath.translation, ch.path().?);
    try t.expect(ch.targetsNode(asset.node(0)));
    try t.expectEqual(Interpolation.linear, ch.interpolation().?);
    try t.expectEqual(@as(usize, 3), ch.keyframeCount());
    try t.expectEqual(@as(usize, 3), ch.componentsPerKeyframe());

    var times: [3]f32 = undefined;
    try t.expectEqual(@as(usize, 3), try ch.readTimes(&times));
    try t.expectEqual([3]f32{ 0.0, 1.0, 2.0 }, times);

    var values: [9]f32 = undefined;
    try t.expectEqual(@as(usize, 3), try ch.readValues(&values));
    try t.expectEqual(@as(f32, 1.0), values[3]); // second keyframe, x
    try t.expectEqual(@as(f32, 2.0), values[7]); // third keyframe, y
}

test "a channel not targeting a given node reports false" {
    const glb = try buildAnimatedGlb(t.allocator);
    defer t.allocator.free(glb);
    var asset = try Asset.parse(t.allocator, glb);
    defer asset.deinit();

    // Only one node exists, so build a throwaway one on the stack to
    // prove targetsNode compares real node identity, not just "any node".
    var other: c.cgltf_node = std.mem.zeroes(c.cgltf_node);
    const other_wrapped = Node{ .raw = &other };
    try t.expect(!asset.animation(0).channel(0).targetsNode(other_wrapped));
}

test "the committed trigger-anim reference asset parses with real geometry, animation, and material" {
    const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, "lenses/reference/trigger-anim/assets/clip.glb", t.allocator, .limited(1 << 20));
    defer t.allocator.free(bytes);
    var asset = try Asset.parse(t.allocator, bytes);
    defer asset.deinit();
    try t.expectEqual(@as(usize, 1), asset.meshCount());
    try t.expectEqual(@as(usize, 1), asset.animationCount());
    try t.expectEqual(@as(usize, 1), asset.materialCount());
    const prim = asset.mesh(0).primitive(0);
    try t.expectEqual(@as(usize, 4), prim.vertexCount());
    try t.expectEqual(@as(usize, 6), prim.indexCount());
    const anim = asset.animation(0);
    const ch = anim.channel(0);
    try t.expectEqual(AnimationPath.rotation, ch.path().?);
    try t.expect(ch.targetsNode(asset.node(0)));
    var rots: [12]f32 = undefined;
    try t.expectEqual(@as(usize, 3), try ch.readValues(&rots));
    try t.expectEqual([12]f32{ 0, 0, 0, 1, 0, 0, 1, 0, 0, 0, 0, -1 }, rots);
    const mat_idx = prim.materialIndex(&asset).?;
    const mat = asset.material(mat_idx);
    try t.expectEqual([4]f32{ 1, 0.35, 0.1, 1 }, mat.raw.pbr_metallic_roughness.base_color_factor);
}

test "no animations is the common, valid case" {
    const glb = try buildTriangleGlb(t.allocator);
    defer t.allocator.free(glb);
    var asset = try Asset.parse(t.allocator, glb);
    defer asset.deinit();
    try t.expectEqual(@as(usize, 0), asset.animationCount());
    try t.expectEqual(@as(usize, 0), asset.materialCount());
}
