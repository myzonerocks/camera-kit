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

    // The authoritative gate suite runs locally: hosted runners are not
    // funded, so green here is the merge bar. One command, every gate.
    const ci_step = b.step("ci", "Run every gate locally: tests, source gate, abi, vendor check, provenance");
    {
        const ci_gate = b.addRunArtifact(gate_exe);
        ci_gate.setCwd(b.path("."));
        ci_gate.addArgs(&.{"--tree"});
        ci_step.dependOn(&ci_gate.step);
        const ci_log = b.addRunArtifact(gate_exe);
        ci_log.setCwd(b.path("."));
        ci_log.addArgs(&.{ "--log", "origin/main..HEAD" });
        ci_step.dependOn(&ci_log.step);
    }


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

    // The host export layer carries the render stub: unit tests cannot
    // exercise Metal, and the harness plus device demos are the executable
    // truth for the real backend. Platform libraries built by the ios step
    // link the real binding.
    const render_stub_module = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_module }},
    });

    const abi_module = b.createModule(.{
        .root_source_file = b.path("core/abi/abi.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_module },
            .{ .name = "math", .module = math_module },
            .{ .name = "render", .module = render_stub_module },
        },
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
    ci_step.dependOn(abi_step);

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

    const vendor_sync_module = b.createModule(.{
        .root_source_file = b.path("tools/vendor_sync.zig"),
        .target = target,
        .optimize = optimize,
    });
    const vendor_sync_exe = b.addExecutable(.{
        .name = "vendor_sync",
        .root_module = vendor_sync_module,
    });
    const run_vendor_sync = b.addRunArtifact(vendor_sync_exe);
    run_vendor_sync.setCwd(b.path("."));
    if (b.args) |args| run_vendor_sync.addArgs(args);
    const vendor_step = b.step("vendor-sync", "Fetch and verify vendored trees from third_party pins (-- --check to verify only)");
    vendor_step.dependOn(&run_vendor_sync.step);
    {
        const vendor_check = b.addRunArtifact(vendor_sync_exe);
        vendor_check.setCwd(b.path("."));
        vendor_check.addArgs(&.{"--check"});
        ci_step.dependOn(&vendor_check.step);
        const release_tests = b.addSystemCommand(&.{ b.graph.zig_exe, "build", "test", "-Doptimize=ReleaseFast" });
        release_tests.setCwd(b.path("."));
        ci_step.dependOn(&release_tests.step);
    }

    const fetch_models_module = b.createModule(.{
        .root_source_file = b.path("tools/fetch_models.zig"),
        .target = target,
        .optimize = optimize,
    });
    const fetch_models_exe = b.addExecutable(.{
        .name = "fetch_models",
        .root_module = fetch_models_module,
    });
    const run_fetch_models = b.addRunArtifact(fetch_models_exe);
    run_fetch_models.setCwd(b.path("."));
    if (b.args) |args| run_fetch_models.addArgs(args);
    const fetch_models_step = b.step("fetch-models", "Fetch and verify model files from third_party/models.lock (-- --check to verify only)");
    fetch_models_step.dependOn(&run_fetch_models.step);
    {
        const models_check = b.addRunArtifact(fetch_models_exe);
        models_check.setCwd(b.path("."));
        models_check.addArgs(&.{"--check"});
        ci_step.dependOn(&models_check.step);
    }

    const blob_module = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/blob.zig"),
        .target = target,
        .optimize = optimize,
    });

    const gate_tests = b.addTest(.{ .root_module = gate_module });
    const blob_tests = b.addTest(.{ .root_module = blob_module });
    const math_tests = b.addTest(.{ .root_module = math_module });
    const graph_tests = b.addTest(.{ .root_module = graph_module });
    const abi_tests = b.addTest(.{ .root_module = abi_module });
    const abi_dump_tests = b.addTest(.{ .root_module = abi_dump_module });
    const vendor_sync_tests = b.addTest(.{ .root_module = vendor_sync_module });
    const fetch_models_tests = b.addTest(.{ .root_module = fetch_models_module });
    const test_step = b.step("test", "Run all tests");
    ci_step.dependOn(test_step);
    test_step.dependOn(&b.addRunArtifact(gate_tests).step);
    test_step.dependOn(&b.addRunArtifact(blob_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(graph_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_dump_tests).step);
    test_step.dependOn(&b.addRunArtifact(vendor_sync_tests).step);
    test_step.dependOn(&b.addRunArtifact(fetch_models_tests).step);

    // Adapters compile against the vendored trees. Without them the rest of
    // the build still works, vendor-sync included; only the steps that need
    // a vendor fail, closed, naming the exact command.
    const have_cgltf = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/cgltf/cgltf.h", .{}) catch break :blk false;
        break :blk true;
    };
    const gltf_module: ?*std.Build.Module = if (have_cgltf) blk: {
        const m = b.createModule(.{
            .root_source_file = b.path("adapters/gltf/gltf.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "math", .module = math_module }},
        });
        m.addIncludePath(b.path(".vendor/cgltf"));
        m.addCSourceFile(.{
            .file = b.path("adapters/gltf/cgltf_impl.c"),
            .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
        });
        m.link_libc = true;
        const gltf_tests = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(gltf_tests).step);
        break :blk m;
    } else blk: {
        const missing = b.addFail("camera-kit: .vendor/cgltf missing, run zig build vendor-sync");
        test_step.dependOn(&missing.step);
        break :blk null;
    };

    // The desktop harness draws through the real render stack. It exists
    // only where its vendors are synced and the host is supported.
    const have_render_stack = blk: {
        for ([_][]const u8{ ".vendor/bx/src/amalgamated.cpp", ".vendor/bimg/src/image.cpp", ".vendor/bgfx/src/amalgamated.cpp", ".vendor/glfw/src/init.c" }) |probe| {
            b.build_root.handle.access(b.graph.io, probe, .{}) catch break :blk false;
        }
        break :blk true;
    };
    const shaderc_exe = addShadercTool(b, optimize);
    const flatc_exe = addFlatcTool(b);
    _ = flatc_exe;
    {
        const deps_step = b.step("inference-deps", "Build the inference runtime dependency libraries");
        deps_step.dependOn(&b.addInstallArtifact(buildAbseilLib(b, target, optimize), .{}).step);
        deps_step.dependOn(&b.addInstallArtifact(buildCpuinfoLib(b, target, optimize), .{}).step);
        deps_step.dependOn(&b.addInstallArtifact(buildPthreadpoolLib(b, target, optimize), .{}).step);
        deps_step.dependOn(&b.addInstallArtifact(buildRuyLib(b, target, optimize), .{}).step);
        deps_step.dependOn(&b.addInstallArtifact(buildFarmhashLib(b, target, optimize), .{}).step);
    }
    addIosStep(b, optimize, shaderc_exe);
    addAndroidStep(b, optimize, shaderc_exe);

    // The web core: the same export layer compiled to wasm32 with every ck_
    // symbol visible to the embedder.
    const wasm_step = b.step("wasm", "Build the camerakit core for the web");
    {
        const wasm_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .freestanding });
        const math_wasm = b.createModule(.{ .root_source_file = b.path("core/math/math.zig"), .target = wasm_target, .optimize = .ReleaseSmall });
        const graph_wasm = b.createModule(.{ .root_source_file = b.path("core/graph/graph.zig"), .target = wasm_target, .optimize = .ReleaseSmall });
        const render_wasm = b.createModule(.{
            .root_source_file = b.path("adapters/bgfx/render_stub.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "math", .module = math_wasm }},
        });
        const abi_wasm = b.createModule(.{
            .root_source_file = b.path("core/abi/abi.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "graph", .module = graph_wasm },
                .{ .name = "math", .module = math_wasm },
                .{ .name = "render", .module = render_wasm },
            },
        });
        const camerakit_wasm = b.addExecutable(.{ .name = "camerakit", .root_module = abi_wasm });
        camerakit_wasm.entry = .disabled;
        camerakit_wasm.rdynamic = true;
        wasm_step.dependOn(&b.addInstallArtifact(camerakit_wasm, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
    }

    const harness_step = b.step("harness", "Build and run the desktop harness (draws through the graph on screen)");
    if (have_render_stack and gltf_module != null and target.result.os.tag == .macos) {
        const bgfx_lib = buildBgfxLib(b, target, optimize);
        const glfw_lib = buildGlfwLib(b, target, optimize);
        const harness_module = b.createModule(.{
            .root_source_file = b.path("harness/desktop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "math", .module = math_module },
                .{ .name = "graph", .module = graph_module },
                .{ .name = "gltf", .module = gltf_module.? },
            },
        });
        harness_module.addIncludePath(b.path(".vendor/bgfx/include"));
        harness_module.addIncludePath(b.path(".vendor/bx/include"));
        harness_module.addIncludePath(b.path(".vendor/glfw/include"));
        harness_module.link_libc = true;
        if (shaderc_exe) |tool| {
            harness_module.addImport("shader_blobs", addShaderBlobs(b, tool, target, optimize));
        }
        harness_module.addIncludePath(b.path(".vendor/bimg/3rdparty/lodepng"));
        harness_module.addCSourceFile(.{
            .file = b.path("harness/lodepng_impl.c"),
            .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
        });
        const harness_exe = b.addExecutable(.{
            .name = "harness",
            .root_module = harness_module,
        });
        harness_module.linkLibrary(bgfx_lib);
        harness_module.linkLibrary(glfw_lib);
        for ([_][]const u8{ "Metal", "QuartzCore", "Cocoa", "IOKit", "CoreFoundation", "Foundation", "AppKit", "CoreMedia", "CoreVideo", "VideoToolbox" }) |framework| {
            harness_exe.root_module.linkFramework(framework, .{});
        }
        b.installArtifact(harness_exe);
        const run_harness = b.addRunArtifact(harness_exe);
        run_harness.setCwd(b.path("."));
        if (b.args) |args| run_harness.addArgs(args);
        harness_step.dependOn(&run_harness.step);
    } else {
        const missing = b.addFail("camera-kit: harness needs macos and synced render vendors, run zig build vendor-sync");
        harness_step.dependOn(&missing.step);
    }
}

// bx, bimg, and bgfx compile as one static library from their amalgamated
// sources; zig is the C++ and Objective-C++ compiler for every target,
// device targets included. Debug config follows the zig optimize mode.
fn ndkSysroot(b: *std.Build) ?[]const u8 {
    const home = b.graph.environ_map.get("HOME") orelse return null;
    const sysroot = b.pathJoin(&.{ home, "Library", "Android", "sdk", "ndk", "29.0.14206865", "toolchains", "llvm", "prebuilt", "darwin-x86_64", "sysroot" });
    b.build_root.handle.access(b.graph.io, sysroot, .{}) catch return null;
    return sysroot;
}

fn addNdkPaths(b: *std.Build, module: *std.Build.Module, sysroot: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include", "aarch64-linux-android" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android", "29" }) });
}

fn addAndroidStep(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile) void {
    const android_step = b.step("android", "Build libcamerakit.so for android arm64-v8a");
    const shaderc_tool = shaderc_exe orelse {
        android_step.dependOn(&b.addFail("camera-kit: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    };
    const sysroot = ndkSysroot(b) orelse {
        const missing = b.addFail("camera-kit: ndk 29.0.14206865 not installed under ~/Library/Android/sdk/ndk");
        android_step.dependOn(&missing.step);
        return;
    };
    const android_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .linux,
        .abi = .android,
        .android_api_level = 29,
    });

    const math_android = b.createModule(.{ .root_source_file = b.path("core/math/math.zig"), .target = android_target, .optimize = optimize });
    const graph_android = b.createModule(.{ .root_source_file = b.path("core/graph/graph.zig"), .target = android_target, .optimize = optimize });
    const render_android = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_android }},
    });
    render_android.addIncludePath(b.path(".vendor/bgfx/include"));
    render_android.addIncludePath(b.path(".vendor/bx/include"));
    render_android.link_libc = true;
    addNdkPaths(b, render_android, sysroot);
    // Bionic annotates array parameters with nullability keywords that
    // translate-c rejects; neutralizing them costs only the annotations.
    render_android.addCMacro("_Nonnull", "");
    render_android.addCMacro("_Nullable", "");
    render_android.addImport("shader_blobs", addShaderBlobs(b, shaderc_tool, android_target, optimize));
    const abi_android = b.createModule(.{
        .root_source_file = b.path("core/abi/abi.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_android },
            .{ .name = "math", .module = math_android },
            .{ .name = "render", .module = render_android },
        },
    });
    const jni_module = b.createModule(.{
        .root_source_file = b.path("adapters/android/jni.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "abi", .module = abi_android }},
    });
    jni_module.link_libc = true;
    addNdkPaths(b, jni_module, sysroot);

    const libc_txt = b.addWriteFiles().add("android-libc.txt", b.fmt("include_dir={s}/usr/include\nsys_include_dir={s}/usr/include/aarch64-linux-android\ncrt_dir={s}/usr/lib/aarch64-linux-android/29\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", .{ sysroot, sysroot, sysroot }));

    const bgfx_android = buildBgfxAndroid(b, android_target, optimize, sysroot);
    bgfx_android.setLibCFile(libc_txt);
    const so = b.addLibrary(.{ .name = "camerakit", .linkage = .dynamic, .root_module = jni_module });
    so.setLibCFile(libc_txt);
    jni_module.linkLibrary(bgfx_android);
    for ([_][]const u8{ "android", "log", "EGL", "GLESv3", "vulkan" }) |lib| {
        jni_module.linkSystemLibrary(lib, .{});
    }

    android_step.dependOn(&b.addInstallArtifact(so, .{ .dest_dir = .{ .override = .{ .custom = "android/arm64-v8a" } } }).step);
}

fn buildBgfxAndroid(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, sysroot: []const u8) *std.Build.Step.Compile {
    const lib = buildBgfxLib(b, target, optimize);
    lib.root_module.pic = true;
    addNdkPaths(b, lib.root_module, sysroot);
    // Bionic annotates array parameters with nullability keywords that
    // clang rejects in C++ translation units; neutralizing the keywords
    // costs only the annotations.
    lib.root_module.addCMacro("_Nonnull", "");
    lib.root_module.addCMacro("_Nullable", "");
    return lib;
}

// The schema compiler from the pinned flatbuffers tree, built for the host
// to generate the inference runtime's schema headers at build time.
fn listFilesRecursive(b: *std.Build, dir_path: []const u8, suffix: []const u8, exclude: []const []const u8, out: *std.ArrayList([]const u8)) void {
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    while (it.next(b.graph.io) catch return) |entry| {
        const child = b.fmt("{s}/{s}", .{ dir_path, entry.name });
        switch (entry.kind) {
            .directory => listFilesRecursive(b, child, suffix, exclude, out),
            .file => {
                if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
                var banned = false;
                for (exclude) |pattern| {
                    if (std.mem.indexOf(u8, entry.name, pattern) != null) {
                        banned = true;
                        break;
                    }
                }
                if (!banned) out.append(b.allocator, child) catch @panic("oom");
            },
            else => {},
        }
    }
}

// Abseil from the pinned tree: every runtime library source, tests and
// tooling excluded, one static archive.
fn buildAbseilLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    module.addIncludePath(b.path(".vendor/abseil"));
    var sources: std.ArrayList([]const u8) = .empty;
    listFilesRecursive(b, ".vendor/abseil/absl", ".cc", &.{
        "_test", "test_", "_benchmark", "benchmark", "_mock", "mock_", "matchers",
        "test_util", "print_hash_of", "gaussian_distribution_gentables", "pool_urbg_gentables",
        "_win.cc", "_emscripten.cc",
    }, &sources);
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const flags = [_][]const u8{ "-std=c++17", "-fno-sanitize=undefined", "-w" };
    for (sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "absl", .linkage = .static, .root_module = module });
}

fn buildCpuinfoLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.addIncludePath(b.path(".vendor/cpuinfo/include"));
    module.addIncludePath(b.path(".vendor/cpuinfo/src"));
    const flags = [_][]const u8{ "-std=c99", "-fno-sanitize=undefined", "-w", "-D_GNU_SOURCE", "-DCPUINFO_LOG_LEVEL=2" };
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "api.c", "cache.c", "init.c", "log.c" }) |file| {
        files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
    }
    const os = target.result.os.tag;
    if (os == .macos or os == .ios) {
        for ([_][]const u8{ "mach/topology.c", "arm/cache.c", "arm/uarch.c", "arm/mach/init.c" }) |file| {
            files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
        }
    } else if (os == .linux) {
        for ([_][]const u8{
            "linux/cpulist.c",       "linux/multiline.c", "linux/processors.c", "linux/smallfile.c",
            "arm/cache.c",           "arm/uarch.c",       "arm/linux/chipset.c", "arm/linux/clusters.c",
            "arm/linux/cpuinfo.c",   "arm/linux/hwcap.c", "arm/linux/init.c",    "arm/linux/midr.c",
            "arm/linux/aarch64-isa.c",
        }) |file| {
            files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
        }
        if (target.result.abi.isAndroid()) {
            files.append(b.allocator, ".vendor/cpuinfo/src/arm/android/properties.c") catch @panic("oom");
        }
    }
    for (files.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "cpuinfo", .linkage = .static, .root_module = module });
}

fn buildPthreadpoolLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.addIncludePath(b.path(".vendor/pthreadpool/include"));
    module.addIncludePath(b.path(".vendor/pthreadpool/src"));
    module.addIncludePath(b.path(".vendor/fxdiv/include"));
    const flags = [_][]const u8{ "-std=gnu11", "-fno-sanitize=undefined", "-w", "-DPTHREADPOOL_USE_GCD=0", "-DPTHREADPOOL_USE_EVENT=0", "-DPTHREADPOOL_USE_FUTEX=0" };
    for ([_][]const u8{ "legacy-api.c", "portable-api.c", "memory.c", "pthreads.c" }) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/pthreadpool/src/{s}", .{file})), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "pthreadpool", .linkage = .static, .root_module = module });
}

fn buildRuyLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    module.addIncludePath(b.path(".vendor/ruy"));
    module.addIncludePath(b.path(".vendor/cpuinfo/include"));
    const flags = [_][]const u8{ "-std=c++17", "-fno-sanitize=undefined", "-w" };
    var sources: std.ArrayList([]const u8) = .empty;
    listFilesRecursive(b, ".vendor/ruy/ruy", ".cc", &.{
        "_test", "test_", "benchmark", "example", "gtest", "pmu", "_lib.cc", "test.cc",
    }, &sources);
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    for (sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "ruy", .linkage = .static, .root_module = module });
}

fn buildFarmhashLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    module.addIncludePath(b.path(".vendor/farmhash/src"));
    module.addCSourceFile(.{
        .file = b.path(".vendor/farmhash/src/farmhash.cc"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined", "-w", "-DNAMESPACE_FOR_HASH_FUNCTIONS=farmhash" },
    });
    return b.addLibrary(.{ .name = "farmhash", .linkage = .static, .root_module = module });
}

fn addFlatcTool(b: *std.Build) ?*std.Build.Step.Compile {
    b.build_root.handle.access(b.graph.io, ".vendor/flatbuffers/src/flatc_main.cpp", .{}) catch return null;
    const target = b.graph.host;
    const module = b.createModule(.{ .target = target, .optimize = .ReleaseFast });
    module.link_libcpp = true;
    module.addIncludePath(b.path(".vendor/flatbuffers/include"));
    module.addIncludePath(b.path(".vendor/flatbuffers"));
    module.addIncludePath(b.path(".vendor/flatbuffers/grpc"));
    const flags = [_][]const u8{ "-std=c++17", "-fno-sanitize=undefined", "-w" };
    const sources = [_][]const u8{
        "src/idl_parser.cpp",          "src/idl_gen_text.cpp",     "src/reflection.cpp",
        "src/util.cpp",                "src/idl_gen_binary.cpp",   "src/idl_gen_cpp.cpp",
        "src/idl_gen_csharp.cpp",      "src/idl_gen_dart.cpp",     "src/idl_gen_kotlin.cpp",
        "src/idl_gen_kotlin_kmp.cpp",  "src/idl_gen_go.cpp",       "src/idl_gen_java.cpp",
        "src/idl_gen_ts.cpp",          "src/idl_gen_php.cpp",      "src/idl_gen_python.cpp",
        "src/idl_gen_lobster.cpp",     "src/idl_gen_rust.cpp",     "src/idl_gen_fbs.cpp",
        "src/idl_gen_grpc.cpp",        "src/idl_gen_json_schema.cpp", "src/idl_gen_swift.cpp",
        "src/file_name_saving_file_manager.cpp", "src/file_binary_writer.cpp", "src/file_writer.cpp",
        "src/flatc.cpp",               "src/flatc_main.cpp",       "src/binary_annotator.cpp",
        "src/annotated_binary_text_gen.cpp", "src/bfbs_gen_lua.cpp", "src/bfbs_gen_nim.cpp",
        "src/code_generators.cpp",     "include/codegen/python.cc",
        "grpc/src/compiler/cpp_generator.cc", "grpc/src/compiler/go_generator.cc",
        "grpc/src/compiler/java_generator.cc", "grpc/src/compiler/python_generator.cc",
        "grpc/src/compiler/swift_generator.cc", "grpc/src/compiler/ts_generator.cc",
    };
    for (sources) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/flatbuffers/{s}", .{file})), .flags = &flags });
    }
    const exe = b.addExecutable(.{ .name = "flatc", .root_module = module });
    const step = b.step("flatc", "Build the schema compiler from the pinned flatbuffers tree");
    step.dependOn(&b.addInstallArtifact(exe, .{}).step);
    return exe;
}

fn addAppleSdkPaths(b: *std.Build, module: *std.Build.Module) void {
    const sdk = b.sysroot orelse return;
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" }) });
}

fn buildBgfxLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    return buildBgfxLibFlags(b, target, optimize, &.{});
}

fn buildBgfxLibFlags(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, extra_flags: []const []const u8) *std.Build.Step.Compile {
    const debug_flag = if (optimize == .Debug) "-DBX_CONFIG_DEBUG=1" else "-DBX_CONFIG_DEBUG=0";

    const bgfx_module = b.createModule(.{ .target = target, .optimize = optimize });
    bgfx_module.link_libc = true;
    bgfx_module.link_libcpp = true;
    if (target.result.os.tag == .macos or target.result.os.tag == .ios) {
        bgfx_module.addIncludePath(b.path(".vendor/bx/include/compat/osx"));
    }
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, bgfx_module);
    for ([_][]const u8{
        ".vendor/bx/include",
        ".vendor/bx/3rdparty",
        ".vendor/bimg/include",
        ".vendor/bimg/3rdparty",
        ".vendor/bimg/3rdparty/astc-encoder/include",
        ".vendor/bimg/3rdparty/iqa/include",
        ".vendor/bimg/3rdparty/tinyexr/deps",
        ".vendor/bgfx/include",
        ".vendor/bgfx/3rdparty",
        ".vendor/bgfx/3rdparty/khronos",
    }) |dir| bgfx_module.addIncludePath(b.path(dir));
    const base_flags = [_][]const u8{ "-std=c++20", "-fno-strict-aliasing", "-fno-exceptions", "-fno-rtti", "-fno-sanitize=undefined", "-D__STDC_FORMAT_MACROS", "-Wno-date-time", "-DBIMG_CONFIG_PARSE_AVIF=0", "-DBIMG_CONFIG_PARSE_HEIF=0", "-DBIMG_CONFIG_PARSE_EXR=0", debug_flag };
    const cxx_flags = std.mem.concat(b.allocator, []const u8, &.{ &base_flags, extra_flags }) catch @panic("oom");
    bgfx_module.addCSourceFile(.{ .file = b.path(".vendor/bx/src/amalgamated.cpp"), .flags = cxx_flags });
    for ([_][]const u8{ "image.cpp", "image_cubemap_filter.cpp", "image_decode.cpp", "image_encode.cpp" }) |file| {
        bgfx_module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/bimg/src/{s}", .{file})), .flags = cxx_flags });
    }
    if (listFiles(b, ".vendor/bimg/3rdparty/astc-encoder/source", ".cpp")) |astc_files| {
        for (astc_files) |file| bgfx_module.addCSourceFile(.{ .file = b.path(file), .flags = cxx_flags });
    }
    bgfx_module.addIncludePath(b.path(".vendor/bgfx/src"));
    bgfx_module.addCSourceFile(.{
        .file = b.path("adapters/bgfx/bgfx_amalgamated.mm"),
        .flags = std.mem.concat(b.allocator, []const u8, &.{ cxx_flags, &.{"-fno-objc-arc"} }) catch @panic("oom"),
    });
    return b.addLibrary(.{ .name = "bgfx", .linkage = .static, .root_module = bgfx_module });
}

fn buildGlfwLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const glfw_module = b.createModule(.{ .target = target, .optimize = optimize });
    glfw_module.link_libc = true;
    glfw_module.addIncludePath(b.path(".vendor/glfw/include"));
    glfw_module.addIncludePath(b.path(".vendor/glfw/src"));
    const glfw_flags = [_][]const u8{"-D_GLFW_COCOA"};
    for ([_][]const u8{
        "context.c",      "egl_context.c",  "init.c",         "input.c",
        "monitor.c",      "null_init.c",    "null_joystick.c", "null_monitor.c",
        "null_window.c",  "osmesa_context.c", "platform.c",   "vulkan.c",
        "window.c",       "macos_time.c",   "posix_module.c", "posix_thread.c",
    }) |file| {
        glfw_module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/glfw/src/{s}", .{file})), .flags = &glfw_flags });
    }
    for ([_][]const u8{ "cocoa_init.m", "cocoa_joystick.m", "cocoa_monitor.m", "cocoa_window.m", "nsgl_context.m" }) |file| {
        glfw_module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/glfw/src/{s}", .{file})), .flags = &(glfw_flags ++ [_][]const u8{"-fno-objc-arc"}) });
    }
    return b.addLibrary(.{ .name = "glfw", .linkage = .static, .root_module = glfw_module });
}

fn listFiles(b: *std.Build, dir_path: []const u8, suffix: []const u8) ?[][]const u8 {
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return null;
    defer dir.close(b.graph.io);
    var files: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch return null) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.name, suffix)) continue;
        files.append(b.allocator, b.fmt("{s}/{s}", .{ dir_path, entry.name })) catch return null;
    }
    std.mem.sort([]const u8, files.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return files.items;
}

// The pinned toolchain is the only toolchain: .zigversion is the single place
// the version is written, and a mismatching compiler fails closed here. The
// shadow lane (weekly build against Zig master) is the one sanctioned bypass,
// via CK_ALLOW_ZIG_MISMATCH=1.
fn addIosStep(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile) void {
    const ios_step = b.step("ios", "Build camerakit and bgfx static libraries for iOS devices");
    const shaderc_tool = shaderc_exe orelse {
        ios_step.dependOn(&b.addFail("camera-kit: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    };
    if (b.sysroot == null) {
        const missing = b.addFail("camera-kit: run zig build ios --sysroot \"$(xcrun --sdk iphoneos --show-sdk-path)\"");
        ios_step.dependOn(&missing.step);
        return;
    }
    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = .none,
    });

    const math_ios = b.createModule(.{
        .root_source_file = b.path("core/math/math.zig"),
        .target = ios_target,
        .optimize = optimize,
    });
    const graph_ios = b.createModule(.{
        .root_source_file = b.path("core/graph/graph.zig"),
        .target = ios_target,
        .optimize = optimize,
    });
    const render_ios = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_ios }},
    });
    render_ios.addIncludePath(b.path(".vendor/bgfx/include"));
    render_ios.addIncludePath(b.path(".vendor/bx/include"));
    render_ios.link_libc = true;
    addAppleSdkPaths(b, render_ios);
    render_ios.addImport("shader_blobs", addShaderBlobs(b, shaderc_tool, ios_target, optimize));
    const abi_ios = b.createModule(.{
        .root_source_file = b.path("core/abi/abi.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_ios },
            .{ .name = "math", .module = math_ios },
            .{ .name = "render", .module = render_ios },
        },
    });
    const camerakit_ios = b.addLibrary(.{
        .name = "camerakit",
        .linkage = .static,
        .root_module = abi_ios,
    });
    const bgfx_ios = buildBgfxLib(b, ios_target, optimize);
    // Apple's linker requires 8-byte archive member alignment; the system
    // ranlib rewrites zig's archives into the accepted layout.
    for ([_]*std.Build.Step.Compile{ camerakit_ios, bgfx_ios }) |lib| {
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = "ios" } } });
        const fix = b.addSystemCommand(&.{ "ranlib", b.getInstallPath(.{ .custom = "ios" }, lib.out_filename) });
        fix.step.dependOn(&install.step);
        ios_step.dependOn(&fix.step);
    }
}

// The shader toolchain: bgfx's shaderc compiled from the vendored tree for
// the host, emitting spirv, msl, essl, and glsl. WGSL support compiles out
// gracefully without tint, per the tool's own include guard.
fn addShadercTool(b: *std.Build, optimize: std.builtin.OptimizeMode) ?*std.Build.Step.Compile {
    _ = optimize;
    const step = b.step("shaderc", "Build the shader compiler from the vendored bgfx tree");
    b.build_root.handle.access(b.graph.io, ".vendor/bgfx/tools/shaderc/shaderc.cpp", .{}) catch {
        step.dependOn(&b.addFail("camera-kit: .vendor/bgfx missing, run zig build vendor-sync").step);
        return null;
    };
    const target = b.graph.host;
    const opt = .ReleaseFast;

    const bgfx_dir = ".vendor/bgfx";
    const spirv_tools = ".vendor/bgfx/3rdparty/spirv-tools";
    const spirv_headers = ".vendor/bgfx/3rdparty/spirv-headers";
    const glslang = ".vendor/bgfx/3rdparty/glslang";
    const glsl_optimizer = ".vendor/bgfx/3rdparty/glsl-optimizer";
    const fcpp_dir = ".vendor/bgfx/3rdparty/fcpp";
    const spirv_cross = ".vendor/bgfx/3rdparty/spirv-cross";

    const cxx17 = [_][]const u8{ "-std=c++20", "-fno-strict-aliasing", "-fno-sanitize=undefined", "-w", "-DBX_CONFIG_DEBUG=0", "-D__STDC_FORMAT_MACROS" };
    const c_flags = [_][]const u8{ "-fno-sanitize=undefined", "-w" };

    const spirv_opt_module = b.createModule(.{ .target = target, .optimize = opt });
    spirv_opt_module.link_libcpp = true;
    for ([_][]const u8{ spirv_tools, spirv_tools ++ "/include", spirv_tools ++ "/include/generated", spirv_tools ++ "/source", spirv_headers ++ "/include" }) |dir| {
        spirv_opt_module.addIncludePath(b.path(dir));
    }
    addCxxDir(b, spirv_opt_module, spirv_tools ++ "/source", &cxx17, &.{"mimalloc.cpp"});
    for ([_][]const u8{ "source/opt", "source/reduce", "source/val", "source/util" }) |dir| {
        addCxxDir(b, spirv_opt_module, b.fmt("{s}/{s}", .{ spirv_tools, dir }), &cxx17, &.{});
    }
    const spirv_opt_lib = b.addLibrary(.{ .name = "spirv-opt", .linkage = .static, .root_module = spirv_opt_module });

    const spirv_cross_module = b.createModule(.{ .target = target, .optimize = opt });
    spirv_cross_module.link_libcpp = true;
    spirv_cross_module.addCMacro("SPIRV_CROSS_EXCEPTIONS_TO_ASSERTIONS", "");
    spirv_cross_module.addIncludePath(b.path(spirv_cross ++ "/include"));
    for ([_][]const u8{ "spirv_cfg.cpp", "spirv_cpp.cpp", "spirv_cross.cpp", "spirv_cross_parsed_ir.cpp", "spirv_cross_util.cpp", "spirv_glsl.cpp", "spirv_hlsl.cpp", "spirv_msl.cpp", "spirv_parser.cpp", "spirv_reflect.cpp" }) |file| {
        spirv_cross_module.addCSourceFile(.{ .file = b.path(b.fmt("{s}/{s}", .{ spirv_cross, file })), .flags = &cxx17 });
    }
    const spirv_cross_lib = b.addLibrary(.{ .name = "spirv-cross", .linkage = .static, .root_module = spirv_cross_module });

    const glslang_module = b.createModule(.{ .target = target, .optimize = opt });
    glslang_module.link_libcpp = true;
    glslang_module.addCMacro("ENABLE_OPT", "1");
    glslang_module.addCMacro("ENABLE_HLSL", "1");
    for ([_][]const u8{ glslang, ".vendor/bgfx/3rdparty", spirv_tools ++ "/include", spirv_tools ++ "/source" }) |dir| {
        glslang_module.addIncludePath(b.path(dir));
    }
    for ([_][]const u8{ "glslang/MachineIndependent", "glslang/MachineIndependent/preprocessor", "glslang/GenericCodeGen", "glslang/ResourceLimits", "glslang/OSDependent/Unix", "glslang/HLSL", "SPIRV" }) |dir| {
        addCxxDir(b, glslang_module, b.fmt("{s}/{s}", .{ glslang, dir }), &cxx17, &.{});
    }
    const glslang_lib = b.addLibrary(.{ .name = "glslang", .linkage = .static, .root_module = glslang_module });

    const glslopt_module = b.createModule(.{ .target = target, .optimize = opt });
    glslopt_module.link_libcpp = true;
    for ([_][]const u8{ glsl_optimizer ++ "/src", glsl_optimizer ++ "/include", glsl_optimizer ++ "/src/mesa", glsl_optimizer ++ "/src/mapi", glsl_optimizer ++ "/src/glsl" }) |dir| {
        glslopt_module.addIncludePath(b.path(dir));
    }
    addCxxDir(b, glslopt_module, glsl_optimizer ++ "/src/glsl", &cxx17, &.{ "ir_set_program_inouts.cpp", "main.cpp", "builtin_stubs.cpp" });
    for ([_][]const u8{ "src/glsl/glcpp/glcpp-lex.c", "src/glsl/glcpp/glcpp-parse.c", "src/glsl/glcpp/pp.c", "src/glsl/strtod.c", "src/mesa/main/imports.c", "src/mesa/program/prog_hash_table.c", "src/mesa/program/symbol_table.c", "src/util/hash_table.c", "src/util/ralloc.c" }) |file| {
        glslopt_module.addCSourceFile(.{ .file = b.path(b.fmt("{s}/{s}", .{ glsl_optimizer, file })), .flags = &c_flags });
    }
    const glslopt_lib = b.addLibrary(.{ .name = "glsl-optimizer", .linkage = .static, .root_module = glslopt_module });

    const fcpp_module = b.createModule(.{ .target = target, .optimize = opt });
    fcpp_module.link_libc = true;
    fcpp_module.addCMacro("NINCLUDE", "64");
    fcpp_module.addCMacro("NWORK", "65536");
    fcpp_module.addCMacro("NBUFF", "65536");
    fcpp_module.addCMacro("OLD_PREPROCESSOR", "0");
    fcpp_module.addIncludePath(b.path(fcpp_dir));
    for ([_][]const u8{ "cpp1.c", "cpp2.c", "cpp3.c", "cpp4.c", "cpp5.c", "cpp6.c" }) |file| {
        fcpp_module.addCSourceFile(.{ .file = b.path(b.fmt("{s}/{s}", .{ fcpp_dir, file })), .flags = &c_flags });
    }
    const fcpp_lib = b.addLibrary(.{ .name = "fcpp", .linkage = .static, .root_module = fcpp_module });

    const shaderc_module = b.createModule(.{ .target = target, .optimize = opt });
    shaderc_module.link_libcpp = true;
    for ([_][]const u8{
        ".vendor/bimg/include",
        bgfx_dir ++ "/include",
        ".vendor/bx/include",
        bgfx_dir ++ "/3rdparty/directx-headers/include/directx",
        fcpp_dir,
        glslang ++ "/glslang/Public",
        glslang ++ "/glslang/Include",
        glslang,
        glsl_optimizer ++ "/include",
        glsl_optimizer ++ "/src/glsl",
        spirv_tools ++ "/include",
        spirv_cross,
        spirv_cross ++ "/include",
        spirv_headers ++ "/include",
    }) |dir| {
        shaderc_module.addIncludePath(b.path(dir));
    }
    if (target.result.os.tag == .macos) {
        shaderc_module.addIncludePath(b.path(".vendor/bx/include/compat/osx"));
    }
    addCxxDir(b, shaderc_module, bgfx_dir ++ "/tools/shaderc", &cxx17, &.{});
    shaderc_module.addCSourceFile(.{ .file = b.path(bgfx_dir ++ "/src/vertexlayout.cpp"), .flags = &cxx17 });
    shaderc_module.addCSourceFile(.{ .file = b.path(bgfx_dir ++ "/src/shader.cpp"), .flags = &cxx17 });
    shaderc_module.addCSourceFile(.{ .file = b.path(".vendor/bx/src/amalgamated.cpp"), .flags = &cxx17 });
    for ([_][]const u8{ "image.cpp", "image_cubemap_filter.cpp", "image_decode.cpp", "image_encode.cpp" }) |file| {
        shaderc_module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/bimg/src/{s}", .{file})), .flags = &cxx17 });
    }
    for ([_][]const u8{
        ".vendor/bimg/3rdparty",
        ".vendor/bimg/3rdparty/astc-encoder/include",
        ".vendor/bimg/3rdparty/iqa/include",
        ".vendor/bimg/3rdparty/tinyexr/deps",
    }) |dir| {
        shaderc_module.addIncludePath(b.path(dir));
    }
    if (listFiles(b, ".vendor/bimg/3rdparty/astc-encoder/source", ".cpp")) |astc_files| {
        for (astc_files) |file| shaderc_module.addCSourceFile(.{ .file = b.path(file), .flags = &cxx17 });
    }
    shaderc_module.addCMacro("BIMG_CONFIG_PARSE_AVIF", "0");
    shaderc_module.addCMacro("BIMG_CONFIG_PARSE_HEIF", "0");
    shaderc_module.addCMacro("BIMG_CONFIG_PARSE_EXR", "0");

    const shaderc_exe = b.addExecutable(.{ .name = "shaderc", .root_module = shaderc_module });
    shaderc_module.linkLibrary(fcpp_lib);
    shaderc_module.linkLibrary(glslang_lib);
    shaderc_module.linkLibrary(glslopt_lib);
    shaderc_module.linkLibrary(spirv_opt_lib);
    shaderc_module.linkLibrary(spirv_cross_lib);
    step.dependOn(&b.addInstallArtifact(shaderc_exe, .{}).step);
    return shaderc_exe;
}

// Compiles the kit's shaders with the vendored compiler at build time and
// exposes the blobs as one embedded module, per backend profile.
fn addShaderBlobs(b: *std.Build, shaderc_exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const wf = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    const shaders = [_]struct { name: []const u8, kind: []const u8 }{
        .{ .name = "vs_preview", .kind = "vertex" },
        .{ .name = "fs_preview_rgba", .kind = "fragment" },
        .{ .name = "fs_preview_nv12", .kind = "fragment" },
    };
    const profiles = [_]struct { profile: []const u8, platform: []const u8, tag: []const u8 }{
        .{ .profile = "metal", .platform = "ios", .tag = "metal" },
        .{ .profile = "spirv", .platform = "android", .tag = "spirv" },
        .{ .profile = "300_es", .platform = "android", .tag = "essl" },
    };
    const computes = [_][]const u8{"cs_nv12_to_rgba"};
    for (computes) |compute_name| {
        const run = b.addRunArtifact(shaderc_exe);
        run.addArg("-f");
        run.addFileArg(b.path(b.fmt("adapters/bgfx/shaders/{s}.sc", .{compute_name})));
        run.addArg("-o");
        const out_name = b.fmt("{s}.spirv.bin", .{compute_name});
        const out = run.addOutputFileArg(out_name);
        run.addArgs(&.{ "--type", "compute", "--platform", "android", "-p", "spirv" });
        run.addArg("-i");
        run.addDirectoryArg(b.path(".vendor/bgfx/src"));
        _ = wf.addCopyFile(out, out_name);
        source.appendSlice(b.allocator, b.fmt("pub const {s}_spirv = @embedFile(\"{s}\");\n", .{ compute_name, out_name })) catch @panic("oom");
    }
    for (shaders) |shader| {
        for (profiles) |profile| {
            const run = b.addRunArtifact(shaderc_exe);
            run.addArg("-f");
            run.addFileArg(b.path(b.fmt("adapters/bgfx/shaders/{s}.sc", .{shader.name})));
            run.addArg("-o");
            const out_name = b.fmt("{s}.{s}.bin", .{ shader.name, profile.tag });
            const out = run.addOutputFileArg(out_name);
            run.addArgs(&.{ "--type", shader.kind, "--platform", profile.platform, "-p", profile.profile, "--varyingdef" });
            run.addFileArg(b.path("adapters/bgfx/shaders/varying.def.sc"));
            run.addArg("-i");
            run.addDirectoryArg(b.path(".vendor/bgfx/src"));
            _ = wf.addCopyFile(out, out_name);
            source.appendSlice(b.allocator, b.fmt("pub const {s}_{s} = @embedFile(\"{s}\");\n", .{ shader.name, profile.tag, out_name })) catch @panic("oom");
        }
    }
    const root = wf.add("shader_blobs.zig", source.items);
    return b.createModule(.{ .root_source_file = root, .target = target, .optimize = optimize });
}

fn addCxxDir(b: *std.Build, module: *std.Build.Module, dir: []const u8, flags: []const []const u8, exclude: []const []const u8) void {
    const files = listFiles(b, dir, ".cpp") orelse return;
    outer: for (files) |file| {
        for (exclude) |bad| {
            if (std.mem.endsWith(u8, file, bad)) continue :outer;
        }
        module.addCSourceFile(.{ .file = b.path(file), .flags = flags });
    }
}

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
