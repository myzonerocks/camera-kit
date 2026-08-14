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

    const graph_module = b.createModule(.{
        .root_source_file = b.path("core/graph/graph.zig"),
        .target = target,
        .optimize = optimize,
    });

    const abi_module = b.createModule(.{
        .root_source_file = b.path("core/abi/abi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "graph", .module = graph_module }},
    });

    const camerakit_lib = b.addLibrary(.{
        .name = "camerakit",
        .linkage = .static,
        .root_module = abi_module,
    });
    b.installArtifact(camerakit_lib);

    const abi_dump_module = b.createModule(.{
        .root_source_file = b.path("tools/abi_dump.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "abi", .module = abi_module }},
    });
    const abi_dump_exe = b.addExecutable(.{
        .name = "abi_dump",
        .root_module = abi_dump_module,
    });
    b.installArtifact(abi_dump_exe);

    const abi_check = b.addRunArtifact(abi_dump_exe);
    abi_check.setCwd(b.path("."));
    if (b.args) |args| abi_check.addArgs(args) else abi_check.addArgs(&.{ "--check", "tools/abi-baseline.txt" });
    const abi_step = b.step("abi", "Check the ABI surface against the baseline (-- --print to regenerate)");
    abi_step.dependOn(&abi_check.step);

    // A bare header is not a translation unit, so the compile check goes
    // through a generated file that includes it. C99 proves the header stays
    // C99-clean; C11 activates the static asserts on the frozen layouts.
    const header_tu = b.addWriteFiles().add("camerakit_header_check.c", "#include <camerakit.h>\n");
    for ([_][]const u8{ "c99", "c11" }) |std_name| {
        const header_module = b.createModule(.{ .target = target, .optimize = optimize });
        header_module.addCSourceFile(.{
            .file = header_tu,
            .flags = &.{ b.fmt("-std={s}", .{std_name}), "-Werror" },
        });
        header_module.addIncludePath(b.path("include"));
        const header_object = b.addObject(.{
            .name = b.fmt("camerakit_header_{s}", .{std_name}),
            .root_module = header_module,
        });
        abi_step.dependOn(&header_object.step);
    }

    const gate_tests = b.addTest(.{ .root_module = gate_module });
    const math_tests = b.addTest(.{ .root_module = math_module });
    const graph_tests = b.addTest(.{ .root_module = graph_module });
    const abi_tests = b.addTest(.{ .root_module = abi_module });
    const abi_dump_tests = b.addTest(.{ .root_module = abi_dump_module });
    const test_step = b.step("test", "Run all tests");
    test_step.dependOn(&b.addRunArtifact(gate_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(graph_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_dump_tests).step);
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
