const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    enforcePinnedZig(b);

    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const gate_module = b.createModule(.{
        .root_source_file = b.path("tools/gate.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gate_exe = b.addExecutable(.{
        .name = "gate",
        .root_module = gate_module,
    });

    const run_gate = b.addRunArtifact(gate_exe);
    run_gate.setCwd(b.path("."));
    if (b.args) |args| run_gate.addArgs(args);
    const gate_step = b.step("gate", "Run the source-tracked gate (-- --staged | --tree | --commit-msg <file> | --log <range>)");
    gate_step.dependOn(&run_gate.step);

    const math_module = b.createModule(.{
        .root_source_file = b.path("core/math/math.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gate_tests = b.addTest(.{ .root_module = gate_module });
    const math_tests = b.addTest(.{ .root_module = math_module });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(gate_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
}

// The pinned toolchain is the only toolchain: .zigversion is the single place
// the version is written, and a mismatching compiler fails closed here. The
// shadow lane (weekly build against Zig master) is the one sanctioned bypass,
// via CK_ALLOW_ZIG_MISMATCH=1.
fn enforcePinnedZig(b: *std.Build) void {
    const raw = b.build_root.handle.readFileAlloc(b.graph.io, ".zigversion", b.allocator, .limited(128)) catch |err|
        std.process.fatal("camera-kit: cannot read .zigversion: {t}", .{err});
    const pinned = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, pinned, builtin.zig_version_string)) return;
    if (b.graph.environ_map.get("CK_ALLOW_ZIG_MISMATCH") != null) {
        std.debug.print("camera-kit: shadow lane: building with Zig {s} against pin {s}\n", .{ builtin.zig_version_string, pinned });
        return;
    }
    std.process.fatal("camera-kit: expected Zig {s}, found {s}, run tools/toolchain-sync", .{ pinned, builtin.zig_version_string });
}
