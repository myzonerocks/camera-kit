//! Generates lenses/reference/trigger-anim/assets/clip.glb: a flat-
//! colored quad with one rotation animation clip (three keyframes, 0
//! degrees to 360 around Z, linear interpolation). Run once with `zig
//! run tools/gen_trigger_anim_asset.zig` whenever the asset needs
//! regenerating; the output is committed, this generator is not run at
//! build time.

const std = @import("std");
const math = std.math;

pub fn main(init: std.process.Init) !u8 {
    const gpa = init.arena.allocator();

    const positions = [4][3]f32{
        .{ -0.5, -0.5, 0.0 },
        .{ 0.5, -0.5, 0.0 },
        .{ 0.5, 0.5, 0.0 },
        .{ -0.5, 0.5, 0.0 },
    };
    const indices = [6]u16{ 0, 1, 2, 0, 2, 3 };
    const times = [3]f32{ 0.0, 1.0, 2.0 };
    // Rotation about Z: 0, 180, 360 degrees, as quaternions (x,y,z,w).
    // 360 degrees is encoded as (0,0,0,-1) rather than back to
    // (0,0,0,1): quaternions double-cover rotations, and slerping to
    // the negated identity continues turning the same direction the
    // 0->180 leg already started, instead of snapping backward.
    const rotations = [3][4]f32{
        .{ 0.0, 0.0, 0.0, 1.0 },
        .{ 0.0, 0.0, 1.0, 0.0 },
        .{ 0.0, 0.0, 0.0, -1.0 },
    };

    var bin: std.ArrayList(u8) = .empty;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&positions)); // 0..48
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&indices)); // 48..60
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0); // pad to 60->60 (already aligned)
    const times_offset = bin.items.len;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&times)); // +12
    const rotations_offset = bin.items.len;
    try bin.appendSlice(gpa, std.mem.sliceAsBytes(&rotations)); // +48
    while (bin.items.len % 4 != 0) try bin.append(gpa, 0);

    const json = try std.fmt.allocPrint(gpa,
        \\{{"asset":{{"version":"2.0"}},
        \\"buffers":[{{"byteLength":{d}}}],
        \\"bufferViews":[
        \\{{"buffer":0,"byteOffset":0,"byteLength":48}},
        \\{{"buffer":0,"byteOffset":48,"byteLength":12}},
        \\{{"buffer":0,"byteOffset":{d},"byteLength":12}},
        \\{{"buffer":0,"byteOffset":{d},"byteLength":48}}],
        \\"accessors":[
        \\{{"bufferView":0,"componentType":5126,"count":4,"type":"VEC3","min":[-0.5,-0.5,0.0],"max":[0.5,0.5,0.0]}},
        \\{{"bufferView":1,"componentType":5123,"count":6,"type":"SCALAR"}},
        \\{{"bufferView":2,"componentType":5126,"count":3,"type":"SCALAR"}},
        \\{{"bufferView":3,"componentType":5126,"count":3,"type":"VEC4"}}],
        \\"materials":[{{"pbrMetallicRoughness":{{"baseColorFactor":[1.0,0.35,0.1,1.0]}}}}],
        \\"meshes":[{{"primitives":[{{"attributes":{{"POSITION":0}},"indices":1,"material":0}}]}}],
        \\"nodes":[{{"mesh":0,"name":"clip"}}],
        \\"animations":[{{"samplers":[{{"input":2,"output":3,"interpolation":"LINEAR"}}],
        \\"channels":[{{"sampler":0,"target":{{"node":0,"path":"rotation"}}}}]}}],
        \\"scenes":[{{"nodes":[0]}}],"scene":0}}
    , .{ bin.items.len, times_offset, rotations_offset });

    var json_padded: std.ArrayList(u8) = .empty;
    try json_padded.appendSlice(gpa, json);
    while (json_padded.items.len % 4 != 0) try json_padded.append(gpa, ' ');

    var glb: std.ArrayList(u8) = .empty;
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

    try std.Io.Dir.cwd().createDirPath(init.io, "lenses/reference/trigger-anim/assets");
    try std.Io.Dir.cwd().writeFile(init.io, .{
        .sub_path = "lenses/reference/trigger-anim/assets/clip.glb",
        .data = glb.items,
    });

    var out_buf: [256]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try stdout.interface.print("wrote lenses/reference/trigger-anim/assets/clip.glb ({d} bytes)\n", .{glb.items.len});
    try stdout.interface.flush();
    return 0;
}
