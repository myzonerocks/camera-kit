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
    const gate_step = b.step("gate", "Run the source-tracked gate (-- --staged | --tree | --commit-msg <file> | --log <range> | --diff <range> | --pr-body <file>)");
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
        const ci_diff = b.addRunArtifact(gate_exe);
        ci_diff.setCwd(b.path("."));
        ci_diff.addArgs(&.{ "--diff", "origin/main...HEAD" });
        ci_step.dependOn(&ci_diff.step);
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

    const gosslens_lib = b.addLibrary(.{
        .name = "gosslens",
        .linkage = .static,
        .root_module = abi_module,
    });
    b.installArtifact(gosslens_lib);

    const abi_dump_module = b.createModule(.{
        .root_source_file = b.path("tools/abi_dump.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "abi", .module = abi_module }},
    });
    const gosslens_header_text = b.build_root.handle.readFileAlloc(b.graph.io, "include/gosslens.h", b.allocator, .limited(1 << 20)) catch @panic("include/gosslens.h unreadable");
    const abi_dump_options = b.addOptions();
    abi_dump_options.addOption([]const u8, "gosslens_header", gosslens_header_text);
    abi_dump_module.addOptions("build_options", abi_dump_options);
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
    const header_tu = b.addWriteFiles().add("gosslens_header_check.c", "#include <gosslens.h>\n");
    for ([_][]const u8{ "c99", "c11" }) |std_name| {
        const header_module = b.createModule(.{ .target = target, .optimize = optimize });
        header_module.addCSourceFile(.{
            .file = header_tu,
            .flags = &.{ b.fmt("-std={s}", .{std_name}), "-Werror" },
        });
        header_module.addIncludePath(b.path("include"));
        const header_object = b.addObject(.{
            .name = b.fmt("gosslens_header_{s}", .{std_name}),
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
    const tracking_cores = trackingCoreModules(b, target, optimize, math_module);
    const bundle_module = tracking_cores.bundle;
    const detector_module = tracking_cores.detector;
    const sampler_module = tracking_cores.sampler;
    const face_module = tracking_cores.face;
    const hand_core_module = tracking_cores.hand;
    const pose_core_module = tracking_cores.pose;
    const face_mesh_topology_module = tracking_cores.face_mesh_topology;
    const face_geometry_core_module = tracking_cores.face_geometry;
    const tracker_module = tracking_cores.tracker;
    const face106_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/face106.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "face", .module = face_module }},
    });
    const segment_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/segment.zig"),
        .target = target,
        .optimize = optimize,
    });
    abi_module.addImport("face", face_module);
    abi_module.addImport("hand", hand_core_module);
    abi_module.addImport("pose", pose_core_module);
    abi_module.addImport("face_geometry", face_geometry_core_module);
    abi_module.addImport("png", pngModule(b, target, optimize));
    abi_module.addImport("media_recording", recordingModule(b, target, optimize));
    abi_module.addImport("photo", photoModule(b, target, optimize));
    abi_module.addImport("audio_analysis", audioAnalysisModule(b, target, optimize));
    const have_jolt = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/jolt/Jolt/Jolt.h", .{}) catch break :blk false;
        break :blk true;
    };
    const have_quickjs = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/quickjs-ng/quickjs.h", .{}) catch break :blk false;
        break :blk true;
    };
    abi_module.addImport("physics", physicsModule(b, target, optimize, have_jolt));
    abi_module.addImport("tracking", trackingStubModule(b, target, optimize, face_module, hand_core_module, pose_core_module, math_module));
    abi_module.addImport("segmentation", segmentationStubModule(b, target, optimize, math_module));
    abi_module.addImport("beauty", beautyStubModule(b, target, optimize, face_module));

    const lens_manifest_module = b.createModule(.{
        .root_source_file = b.path("core/lens/manifest.zig"),
        .target = target,
        .optimize = optimize,
    });
    const lens_trigger_module = b.createModule(.{
        .root_source_file = b.path("core/lens/trigger.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "face", .module = face_module }},
    });
    const lens_animation_module = b.createModule(.{
        .root_source_file = b.path("core/lens/animation.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lens_runtime_module = b.createModule(.{
        .root_source_file = b.path("core/lens/runtime.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_module },
            .{ .name = "manifest", .module = lens_manifest_module },
            .{ .name = "trigger", .module = lens_trigger_module },
            .{ .name = "animation", .module = lens_animation_module },
            .{ .name = "face", .module = face_module },
        },
    });
    abi_module.addImport("manifest", lens_manifest_module);
    abi_module.addImport("trigger", lens_trigger_module);
    abi_module.addImport("runtime", lens_runtime_module);

    const lens_validator_module = b.createModule(.{
        .root_source_file = b.path("lenses/validator/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "manifest", .module = lens_manifest_module },
            .{ .name = "trigger", .module = lens_trigger_module },
        },
    });
    const lens_validator_exe = b.addExecutable(.{
        .name = "lens_validator",
        .root_module = lens_validator_module,
    });
    b.installArtifact(lens_validator_exe);
    const lens_validate_step = b.step("lens-validate", "Validate a .glens bundle (-- <bundle-path>)");
    const lens_validate_run = b.addRunArtifact(lens_validator_exe);
    lens_validate_run.setCwd(b.path("."));
    if (b.args) |args| lens_validate_run.addArgs(args);
    lens_validate_step.dependOn(&lens_validate_run.step);

    // The validator runs against every reference lens, in CI. One
    // bundle failing validation fails the build.
    // Deliberately NOT wired into ci_step: lens_validator_exe always
    // depends on a real shaderc (the CLI's whole point is giving a real
    // answer), and ci_step is the fast default path the "gates" job's
    // 15 minute budget assumes stays free of that cold C++ toolchain
    // build - the exact mistake that already broke this job once. The
    // "lens-shaders" hosted job, which already opts into shaderc's
    // build cost, runs this step explicitly instead.
    const lens_reference_step = b.step("lens-validate-reference", "Validate every bundle under lenses/reference/");
    for (listReferenceLenses(b)) |lens_dir| {
        const run = b.addRunArtifact(lens_validator_exe);
        run.setCwd(b.path("."));
        run.addArg(lens_dir);
        lens_reference_step.dependOn(&run.step);
    }

    // Packages every reference lens into .lens-packages/<name> (compiled
    // shader bytecode alongside the source) - the
    // tracking harness activates from there to prove shader.pass nodes
    // against a real packaged bundle, not a hand-built one.
    const lens_package_reference_step = b.step("lens-package-reference", "Package every bundle under lenses/reference/ into .lens-packages/");
    for (listReferenceLenses(b)) |lens_dir| {
        const run = b.addRunArtifact(lens_validator_exe);
        run.setCwd(b.path("."));
        run.addArg(lens_dir);
        run.addArg("--package");
        run.addArg(b.fmt(".lens-packages/{s}", .{std.fs.path.basename(lens_dir)}));
        lens_package_reference_step.dependOn(&run.step);
    }

    const gate_tests = b.addTest(.{ .root_module = gate_module });
    const bundle_tests = b.addTest(.{ .root_module = bundle_module });
    const detector_tests = b.addTest(.{ .root_module = detector_module });
    const sampler_tests = b.addTest(.{ .root_module = sampler_module });
    const face_tests = b.addTest(.{ .root_module = face_module });
    const pose_tests = b.addTest(.{ .root_module = pose_core_module });
    const face_mesh_topology_tests = b.addTest(.{ .root_module = face_mesh_topology_module });
    const face_geometry_tests = b.addTest(.{ .root_module = face_geometry_core_module });
    const tracker_tests = b.addTest(.{ .root_module = tracker_module });
    const face106_tests = b.addTest(.{ .root_module = face106_module });
    const segment_tests = b.addTest(.{ .root_module = segment_module });
    const blob_tests = b.addTest(.{ .root_module = blob_module });
    const math_tests = b.addTest(.{ .root_module = math_module });
    const fit_module = b.createModule(.{ .root_source_file = b.path("core/math/fit.zig"), .target = target, .optimize = optimize });
    const fit_tests = b.addTest(.{ .root_module = fit_module });
    const png_tests = b.addTest(.{ .root_module = pngModule(b, target, optimize) });
    const audio_analysis_tests = b.addTest(.{ .root_module = audioAnalysisModule(b, target, optimize) });
    const graph_tests = b.addTest(.{ .root_module = graph_module });
    const abi_tests = b.addTest(.{ .root_module = abi_module });
    const abi_dump_tests = b.addTest(.{ .root_module = abi_dump_module });
    const vendor_sync_tests = b.addTest(.{ .root_module = vendor_sync_module });
    const fetch_models_tests = b.addTest(.{ .root_module = fetch_models_module });
    const lens_manifest_tests = b.addTest(.{ .root_module = lens_manifest_module });
    const lens_trigger_tests = b.addTest(.{ .root_module = lens_trigger_module });
    const lens_animation_tests = b.addTest(.{ .root_module = lens_animation_module });
    const lens_runtime_tests = b.addTest(.{ .root_module = lens_runtime_module });
    const test_step = b.step("test", "Run all tests");
    ci_step.dependOn(test_step);
    test_step.dependOn(&b.addRunArtifact(gate_tests).step);
    test_step.dependOn(&b.addRunArtifact(bundle_tests).step);
    test_step.dependOn(&b.addRunArtifact(detector_tests).step);
    test_step.dependOn(&b.addRunArtifact(sampler_tests).step);
    test_step.dependOn(&b.addRunArtifact(face_tests).step);
    test_step.dependOn(&b.addRunArtifact(pose_tests).step);
    test_step.dependOn(&b.addRunArtifact(face_mesh_topology_tests).step);
    test_step.dependOn(&b.addRunArtifact(face_geometry_tests).step);
    test_step.dependOn(&b.addRunArtifact(tracker_tests).step);
    test_step.dependOn(&b.addRunArtifact(face106_tests).step);
    test_step.dependOn(&b.addRunArtifact(segment_tests).step);
    test_step.dependOn(&b.addRunArtifact(blob_tests).step);
    test_step.dependOn(&b.addRunArtifact(math_tests).step);
    test_step.dependOn(&b.addRunArtifact(fit_tests).step);
    test_step.dependOn(&b.addRunArtifact(png_tests).step);
    test_step.dependOn(&b.addRunArtifact(audio_analysis_tests).step);
    if (have_jolt) {
        const physics_tests = b.addTest(.{ .root_module = physicsModule(b, target, optimize, true) });
        test_step.dependOn(&b.addRunArtifact(physics_tests).step);
    }
    if (have_quickjs) {
        const script_tests = b.addTest(.{ .root_module = scriptModule(b, target, optimize, true) });
        test_step.dependOn(&b.addRunArtifact(script_tests).step);
    }
    test_step.dependOn(&b.addRunArtifact(graph_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_tests).step);
    test_step.dependOn(&b.addRunArtifact(abi_dump_tests).step);
    test_step.dependOn(&b.addRunArtifact(vendor_sync_tests).step);
    test_step.dependOn(&b.addRunArtifact(fetch_models_tests).step);
    test_step.dependOn(&b.addRunArtifact(lens_manifest_tests).step);
    test_step.dependOn(&b.addRunArtifact(lens_trigger_tests).step);
    test_step.dependOn(&b.addRunArtifact(lens_animation_tests).step);
    test_step.dependOn(&b.addRunArtifact(lens_runtime_tests).step);

    // Adapters compile against the vendored trees. Without them the rest of
    // the build still works, vendor-sync included; only the steps that need
    // a vendor fail, closed, naming the exact command.
    const have_cgltf = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/cgltf/cgltf.h", .{}) catch break :blk false;
        break :blk true;
    };
    const gltf_module: ?*std.Build.Module = if (have_cgltf)
        gltfModule(b, target, optimize, math_module)
    else blk: {
        const missing = b.addFail("gosslens: .vendor/cgltf missing, run zig build vendor-sync");
        test_step.dependOn(&missing.step);
        break :blk null;
    };
    if (gltf_module) |m| {
        const gltf_tests = b.addTest(.{ .root_module = m });
        test_step.dependOn(&b.addRunArtifact(gltf_tests).step);
    }

    // lodepng lives inside bimg's vendored tree (bgfx's own image
    // dependency); a lens asset decoder wants only this one file out of
    // it, not the rest of the render stack, so it gets its own probe
    // rather than riding on have_render_stack below. libyuv rides the
    // same probe because the image module is also the CPU conversion
    // authority.
    const have_image_stack = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/bimg/3rdparty/lodepng/lodepng.cpp", .{}) catch break :blk false;
        b.build_root.handle.access(b.graph.io, ".vendor/libyuv/include/libyuv.h", .{}) catch break :blk false;
        break :blk true;
    };
    const host_asset: ?AssetModules = if (have_image_stack) realAssetModules(b, target, optimize, gltf_module) else blk: {
        const missing = b.addFail("gosslens: .vendor/bimg or .vendor/libyuv missing, run zig build vendor-sync");
        test_step.dependOn(&missing.step);
        break :blk null;
    };
    if (host_asset) |am| {
        const image_tests = b.addTest(.{ .root_module = am.image });
        test_step.dependOn(&b.addRunArtifact(image_tests).step);
        const asset_tests = b.addTest(.{ .root_module = am.asset });
        test_step.dependOn(&b.addRunArtifact(asset_tests).step);

        lens_validator_module.addImport("image", am.image);
        lens_validator_module.link_libc = true;
        abi_module.addImport("image", am.image);
        abi_module.addImport("asset", am.asset);
        if (gltf_module) |gm| {
            lens_validator_module.addImport("gltf", gm);
            abi_module.addImport("gltf", gm);
        }
    }

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

    // The CLI always validates shaders for real - that is the point of
    // the tool - so it unconditionally depends on shaderc.
    const lens_validator_options = b.addOptions();
    if (shaderc_exe) |tool| {
        lens_validator_options.addOptionPath("shaderc_path", tool.getEmittedBin());
    } else {
        lens_validator_options.addOption([]const u8, "shaderc_path", "");
    }
    lens_validator_options.addOption([]const u8, "shader_include_dir", ".vendor/bgfx/src");
    lens_validator_options.addOption([]const u8, "varyingdef_path", "lenses/shaders/varying.def.sc");
    lens_validator_module.addOptions("build_options", lens_validator_options);

    // The test suite's shaderc dependency is opt-in: shaderc is a full
    // C++ toolchain (spirv-tools/glslang/glsl-optimizer/spirv-cross)
    // built from source, and forcing that build into the default fast
    // `zig build test`/`zig build ci` path (used by every quick local
    // check and the hosted gates job's 15-minute budget) is what left
    // this exact spot broken once already - a cold hosted runner never
    // finished the build in time. -Dlens-shaders=true opts a slower,
    // separately-timed job into full coverage; the default path's
    // shader-compile-stage tests skip cleanly instead of forcing a cold
    // multi-toolchain build no other test in this suite needs.
    const lens_shader_tests_enabled = b.option(
        bool,
        "lens-shaders",
        "Build shaderc and run the lens validator's shader-compile-stage tests (slow on a cold cache)",
    ) orelse false;
    const lens_validator_test_module = b.createModule(.{
        .root_source_file = b.path("lenses/validator/main.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "manifest", .module = lens_manifest_module },
            .{ .name = "trigger", .module = lens_trigger_module },
        },
    });
    const lens_test_options = b.addOptions();
    if (lens_shader_tests_enabled) {
        if (shaderc_exe) |tool| {
            lens_test_options.addOptionPath("shaderc_path", tool.getEmittedBin());
        } else {
            lens_test_options.addOption([]const u8, "shaderc_path", "");
        }
    } else {
        lens_test_options.addOption([]const u8, "shaderc_path", "");
    }
    lens_test_options.addOption([]const u8, "shader_include_dir", ".vendor/bgfx/src");
    lens_test_options.addOption([]const u8, "varyingdef_path", "lenses/shaders/varying.def.sc");
    lens_validator_test_module.addOptions("build_options", lens_test_options);
    if (host_asset) |am| {
        lens_validator_test_module.addImport("image", am.image);
        lens_validator_test_module.link_libc = true;
        if (gltf_module) |gm| lens_validator_test_module.addImport("gltf", gm);
    }
    const lens_validator_tests = b.addTest(.{ .root_module = lens_validator_test_module });
    test_step.dependOn(&b.addRunArtifact(lens_validator_tests).step);

    const have_inference_stack = blk: {
        for ([_][]const u8{
            ".vendor/litert/tflite/CMakeLists.txt", ".vendor/xnnpack/CMakeLists.txt",
            ".vendor/fft2d/fftsg2d.c",              ".vendor/abseil/absl/base/config.h",
        }) |probe| {
            b.build_root.handle.access(b.graph.io, probe, .{}) catch break :blk false;
        }
        break :blk true;
    };
    {
        const deps_step = b.step("inference-deps", "Build the inference runtime dependency libraries");
        if (have_inference_stack) {
            deps_step.dependOn(&b.addInstallArtifact(buildFft2dLib(b, target, optimize, null), .{}).step);
            if (flatc_exe) |flatc| {
                deps_step.dependOn(&b.addInstallArtifact(buildTfliteLib(b, target, optimize, flatc, null), .{}).step);
            }
            deps_step.dependOn(&b.addInstallArtifact(buildAbseilLib(b, target, optimize, null), .{}).step);
            deps_step.dependOn(&b.addInstallArtifact(buildCpuinfoLib(b, target, optimize, null), .{}).step);
            deps_step.dependOn(&b.addInstallArtifact(buildPthreadpoolLib(b, target, optimize, null), .{}).step);
            deps_step.dependOn(&b.addInstallArtifact(buildRuyLib(b, target, optimize, null), .{}).step);
            deps_step.dependOn(&b.addInstallArtifact(buildFarmhashLib(b, target, optimize, null), .{}).step);
        deps_step.dependOn(&b.addInstallArtifact(buildFlatbuffersLib(b, target, optimize, null), .{}).step);
            deps_step.dependOn(&b.addInstallArtifact(buildXnnpackLib(b, target, optimize, null, null), .{}).step);
        } else {
            deps_step.dependOn(&b.addFail("inference vendors are not synced; run: zig build vendor-sync").step);
        }
    }

    {
        const beauty_step = b.step("beauty-lib", "Build the beauty effects engine library");
        const gpupixel_present = blk: {
            b.build_root.handle.access(b.graph.io, ".vendor/gpupixel/src/CMakeLists.txt", .{}) catch break :blk false;
            break :blk true;
        };
        if (gpupixel_present) {
            beauty_step.dependOn(&b.addInstallArtifact(buildGpupixelLib(b, target, optimize, null), .{}).step);
            if (ndkSysroot(b)) |sysroot| {
                const android_target = b.resolveTargetQuery(.{
                    .cpu_arch = .aarch64,
                    .os_tag = .linux,
                    .abi = .android,
                    .android_api_level = 29,
                });
                const libc_txt = b.addWriteFiles().add("android-libc-beauty.txt", b.fmt("include_dir={s}/usr/include\nsys_include_dir={s}/usr/include/aarch64-linux-android\ncrt_dir={s}/usr/lib/aarch64-linux-android/29\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", .{ sysroot, sysroot, sysroot }));
                const beauty_android = buildGpupixelLib(b, android_target, optimize, libc_txt);
                addNdkPaths(b, beauty_android.root_module, sysroot);
                beauty_step.dependOn(&b.addInstallArtifact(beauty_android, .{ .dest_dir = .{ .override = .{ .custom = "android-beauty" } } }).step);
            }
        } else {
            beauty_step.dependOn(&b.addFail("beauty engine vendor is not synced; run: zig build vendor-sync").step);
        }
    }

    // The tracking harness stands the face pipeline up on the host: model
    // bundle in, engines interrogated, decode exercised end to end.
    const tracking_step = b.step("tracking-harness", "Build and run the tracking harness (face pipeline on host)");
    if (have_inference_stack and flatc_exe != null) {
        const runtime_module = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/runtime.zig"),
            .target = target,
            .optimize = optimize,
        });
        runtime_module.link_libc = true;
        runtime_module.addIncludePath(b.path(".vendor/litert"));
        // MediaPipe's segmentation models need a custom TFLite op the
        // stock interpreter can't resolve on its own (adapters/tracking/
        // transpose_conv_bias.zig) - built here rather than folded into
        // runtime.zig itself since it needs its own additional import
        // (segment.zig's pure math) runtime.zig has no reason to carry.
        const transpose_conv_bias_module = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/transpose_conv_bias.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_module },
                .{ .name = "segment", .module = segment_module },
            },
        });
        transpose_conv_bias_module.link_libc = true;
        transpose_conv_bias_module.addIncludePath(b.path(".vendor/litert"));
        // No standalone test artifact here: a zig test binary talks to the
        // build runner over its own stdin/stdout (--listen=-), and TFLite's
        // C-level logging writes straight to that same stdout, corrupting
        // the protocol the instant a real model loads. Every other real
        // Engine.init in this repo already lives in library code or the
        // tracking-harness executable for the same reason - this custom
        // op's own end-to-end proof against the real model belongs there
        // too, wired in below as tracking_module's "transpose_conv_bias"
        // import.
        // The export layer instance under real tracking: the harness drives
        // the same goss_ surface an SDK uses, worker thread and all.
        const tracking_real_module = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/tracking.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundle", .module = bundle_module },
                .{ .name = "runtime", .module = runtime_module },
                .{ .name = "detector", .module = detector_module },
                .{ .name = "sampler", .module = sampler_module },
                .{ .name = "face", .module = face_module },
                .{ .name = "hand", .module = hand_core_module },
                .{ .name = "pose", .module = pose_core_module },
                .{ .name = "face_geometry", .module = face_geometry_core_module },
                .{ .name = "tracker", .module = tracker_module },
                .{ .name = "graph", .module = graph_module },
                .{ .name = "math", .module = math_module },
            },
        });
        const segmentation_module = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/segmentation.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_module },
                .{ .name = "sampler", .module = sampler_module },
                .{ .name = "math", .module = math_module },
                .{ .name = "transpose_conv_bias", .module = transpose_conv_bias_module },
            },
        });
        const beauty_real_module = b.createModule(.{
            .root_source_file = b.path("adapters/beauty/beauty.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "face", .module = face_module },
                .{ .name = "face106", .module = face106_module },
            },
        });
        const abi_tracking_module = b.createModule(.{
            .root_source_file = b.path("core/abi/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_module },
                .{ .name = "math", .module = math_module },
                .{ .name = "render", .module = render_stub_module },
                .{ .name = "face", .module = face_module },
                .{ .name = "hand", .module = hand_core_module },
                .{ .name = "pose", .module = pose_core_module },
                .{ .name = "face_geometry", .module = face_geometry_core_module },
                .{ .name = "tracking", .module = tracking_real_module },
                .{ .name = "segmentation", .module = segmentation_module },
                .{ .name = "manifest", .module = lens_manifest_module },
                .{ .name = "trigger", .module = lens_trigger_module },
                .{ .name = "runtime", .module = lens_runtime_module },
            },
        });
        abi_tracking_module.addImport("png", pngModule(b, target, optimize));
        abi_tracking_module.addImport("media_recording", recordingModule(b, target, optimize));
        abi_tracking_module.addImport("photo", photoModule(b, target, optimize));
        abi_tracking_module.addImport("audio_analysis", audioAnalysisModule(b, target, optimize));
        abi_tracking_module.addImport("physics", physicsModule(b, target, optimize, have_jolt));
        if (target.result.os.tag == .macos) {
            abi_tracking_module.addImport("beauty", beauty_real_module);
        } else {
            abi_tracking_module.addImport("beauty", beautyStubModule(b, target, optimize, face_module));
        }
        if (host_asset) |am| {
            abi_tracking_module.addImport("image", am.image);
            abi_tracking_module.addImport("asset", am.asset);
            if (gltf_module) |gm| abi_tracking_module.addImport("gltf", gm);
        }
        const tracking_module = b.createModule(.{
            .root_source_file = b.path("harness/tracking.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundle", .module = bundle_module },
                .{ .name = "runtime", .module = runtime_module },
                .{ .name = "detector", .module = detector_module },
                .{ .name = "sampler", .module = sampler_module },
                .{ .name = "face", .module = face_module },
                .{ .name = "hand", .module = hand_core_module },
                .{ .name = "pose", .module = pose_core_module },
                .{ .name = "face_geometry", .module = face_geometry_core_module },
                .{ .name = "tracker", .module = tracker_module },
                .{ .name = "math", .module = math_module },
                .{ .name = "abi", .module = abi_tracking_module },
                .{ .name = "face106", .module = face106_module },
                .{ .name = "segmentation", .module = segmentation_module },
            },
        });
        if (host_asset) |am| tracking_module.addImport("image", am.image);
        if (target.result.os.tag == .macos) {
            tracking_module.linkLibrary(buildGpupixelLib(b, target, optimize, null));
            tracking_module.linkFramework("AppKit", .{});
            tracking_module.linkFramework("OpenGL", .{});
            tracking_module.linkFramework("CoreVideo", .{});
        } else {
            // The beauty archive carries the image loader implementation
            // where it links; elsewhere the harness compiles its own.
            tracking_module.addCSourceFile(.{
                .file = b.path("harness/stb_image_impl.c"),
                .flags = &.{ "-std=c99", "-fno-sanitize=undefined", "-w" },
            });
        }
        tracking_module.linkLibrary(buildTfliteLib(b, target, optimize, flatc_exe.?, null));
        tracking_module.linkLibrary(buildXnnpackLib(b, target, optimize, null, null));
        tracking_module.linkLibrary(buildAbseilLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildRuyLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildFarmhashLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildFlatbuffersLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildFft2dLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildCpuinfoLib(b, target, optimize, null));
        tracking_module.linkLibrary(buildPthreadpoolLib(b, target, optimize, null));
        // The image loader implementation arrives inside the beauty
        // archive; the harness only includes the declarations.
        tracking_module.addIncludePath(b.path(".vendor/gpupixel/third_party/stb/include/stb"));
        const tracking_exe = b.addExecutable(.{ .name = "tracking_harness", .root_module = tracking_module });
        const run_tracking = b.addRunArtifact(tracking_exe);
        run_tracking.setCwd(b.path("."));
        tracking_step.dependOn(&run_tracking.step);
    } else {
        tracking_step.dependOn(&b.addFail("inference vendors are not synced; run: zig build vendor-sync").step);
    }

    // The web tracking module: the same pipeline compiled to a wasi module
    // the TS SDK runs inside a worker, synchronous per frame.
    const tracking_wasm_step = b.step("tracking-wasm", "Build the web tracking module (wasm32-wasi)");
    if (have_inference_stack and flatc_exe != null) {
        // The pinned build enables both simd sets globally for wasm, and the
        // kernel configs select at compile time accordingly.
        const wasi_target = b.resolveTargetQuery(.{
            .cpu_arch = .wasm32,
            .os_tag = .wasi,
            .cpu_features_add = std.Target.wasm.featureSet(&.{ .simd128, .relaxed_simd }),
        });
        // Small mode: the web pays for bytes before it pays for cycles, and
        // the kernels keep their own inner-loop structure either way.
        const wasi_optimize: std.builtin.OptimizeMode = .ReleaseSmall;
        const cores_wasi = trackingCoreModules(b, wasi_target, wasi_optimize, b.createModule(.{
            .root_source_file = b.path("core/math/math.zig"),
            .target = wasi_target,
            .optimize = wasi_optimize,
        }));
        const runtime_wasi = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/runtime.zig"),
            .target = wasi_target,
            .optimize = wasi_optimize,
        });
        runtime_wasi.link_libc = true;
        runtime_wasi.addIncludePath(b.path(".vendor/litert"));
        const exports_wasi = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/wasm_exports.zig"),
            .target = wasi_target,
            .optimize = wasi_optimize,
            .imports = &.{
                .{ .name = "bundle", .module = cores_wasi.bundle },
                .{ .name = "runtime", .module = runtime_wasi },
                .{ .name = "detector", .module = cores_wasi.detector },
                .{ .name = "sampler", .module = cores_wasi.sampler },
                .{ .name = "face", .module = cores_wasi.face },
                .{ .name = "tracker", .module = cores_wasi.tracker },
            },
        });
        exports_wasi.linkLibrary(buildTfliteLib(b, wasi_target, wasi_optimize, flatc_exe.?, null));
        exports_wasi.linkLibrary(buildXnnpackLib(b, wasi_target, wasi_optimize, null, null));
        exports_wasi.linkLibrary(buildAbseilLib(b, wasi_target, wasi_optimize, null));
        exports_wasi.linkLibrary(buildRuyLib(b, wasi_target, wasi_optimize, null));
        exports_wasi.linkLibrary(buildFarmhashLib(b, wasi_target, wasi_optimize, null));
        exports_wasi.linkLibrary(buildFlatbuffersLib(b, wasi_target, wasi_optimize, null));
        exports_wasi.linkLibrary(buildFft2dLib(b, wasi_target, wasi_optimize, null));
        exports_wasi.linkLibrary(buildPthreadpoolLib(b, wasi_target, wasi_optimize, null));
        const tracking_wasm = b.addExecutable(.{ .name = "gosslens_tracking", .root_module = exports_wasi });
        tracking_wasm.entry = .disabled;
        tracking_wasm.rdynamic = true;
        tracking_wasm_step.dependOn(&b.addInstallArtifact(tracking_wasm, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
    } else {
        tracking_wasm_step.dependOn(&b.addFail("inference vendors are not synced; run: zig build vendor-sync").step);
    }
    addIosStep(b, optimize, shaderc_exe, flatc_exe);
    addIosSimulatorStep(b, optimize, shaderc_exe, flatc_exe);
    addAndroidStep(b, optimize, shaderc_exe, flatc_exe);

    // Separate from wasm_step: needs the opt-in emscripten vendors most builds never touch.
    const wasm_bgfx_smoke_step = b.step("wasm-bgfx-smoke", "Compile+link bgfx's real GL backend for wasm32-emscripten (needs emscripten vendors synced)");
    addWasmBgfxSmokeStep(b, wasm_bgfx_smoke_step);

    // Separate again from wasm-bgfx-smoke: a separate renderer backend
    // (BGFX_CONFIG_RENDERER_WEBGPU), kept off addBgfxWasmObjects's
    // shared cxx_flags/link args so the GLES-based production
    // wasm-emscripten step below can't regress if this one's own
    // recipe ever needs to change.
    const wasm_webgpu_smoke_step = b.step("wasm-webgpu-smoke", "Compile+link bgfx's real WebGPU backend for wasm32-emscripten (needs emscripten vendors synced)");
    addWasmWebgpuSmokeStep(b, wasm_webgpu_smoke_step);

    const wasm_emscripten_core_smoke_step = b.step("wasm-emscripten-core-smoke", "Compile+link render.zig itself for wasm32-emscripten against real bgfx (needs emscripten vendors synced)");
    addWasmEmscriptenCoreSmokeStep(b, wasm_emscripten_core_smoke_step, shaderc_exe, false);
    // The decisive end-to-end WGSL/WebGPU proof target: same render.zig,
    // same shader toolchain, bgfx compiled with WebGPU + Asyncify - real
    // composited draw through goss_core_smoke_render_frame, not just init.
    const wasm_emscripten_core_smoke_webgpu_step = b.step("wasm-emscripten-core-smoke-webgpu", "Compile+link render.zig for wasm32-emscripten against real bgfx WebGPU, render one real composited frame (needs emscripten vendors synced)");
    addWasmEmscriptenCoreSmokeStep(b, wasm_emscripten_core_smoke_webgpu_step, shaderc_exe, true);

    // The web core: the same export layer compiled to wasm32 with every goss_
    // symbol visible to the embedder.
    const wasm_step = b.step("wasm", "Build the gosslens core for the web");
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
        const tracking_cores_wasm = trackingCoreModules(b, wasm_target, .ReleaseSmall, math_wasm);
        abi_wasm.addImport("face", tracking_cores_wasm.face);
    abi_wasm.addImport("hand", tracking_cores_wasm.hand);
    abi_wasm.addImport("pose", tracking_cores_wasm.pose);
    abi_wasm.addImport("face_geometry", tracking_cores_wasm.face_geometry);
    abi_wasm.addImport("png", pngModule(b, wasm_target, .ReleaseSmall));
    abi_wasm.addImport("media_recording", recordingModule(b, wasm_target, .ReleaseSmall));
    abi_wasm.addImport("photo", photoModule(b, wasm_target, .ReleaseSmall));
    abi_wasm.addImport("audio_analysis", audioAnalysisModule(b, wasm_target, .ReleaseSmall));
    abi_wasm.addImport("physics", physicsModule(b, wasm_target, .ReleaseSmall, false));
        abi_wasm.addImport("tracking", trackingStubModule(b, wasm_target, .ReleaseSmall, tracking_cores_wasm.face, tracking_cores_wasm.hand, tracking_cores_wasm.pose, math_wasm));
        abi_wasm.addImport("segmentation", segmentationStubModule(b, wasm_target, .ReleaseSmall, math_wasm));
        abi_wasm.addImport("beauty", beautyStubModule(b, wasm_target, .ReleaseSmall, tracking_cores_wasm.face));
        const lens_manifest_wasm = b.createModule(.{
            .root_source_file = b.path("core/lens/manifest.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        const lens_trigger_wasm = b.createModule(.{
            .root_source_file = b.path("core/lens/trigger.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{.{ .name = "face", .module = tracking_cores_wasm.face }},
        });
        const lens_animation_wasm = b.createModule(.{
            .root_source_file = b.path("core/lens/animation.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
        });
        const lens_runtime_wasm = b.createModule(.{
            .root_source_file = b.path("core/lens/runtime.zig"),
            .target = wasm_target,
            .optimize = .ReleaseSmall,
            .imports = &.{
                .{ .name = "graph", .module = graph_wasm },
                .{ .name = "manifest", .module = lens_manifest_wasm },
                .{ .name = "trigger", .module = lens_trigger_wasm },
                .{ .name = "animation", .module = lens_animation_wasm },
                .{ .name = "face", .module = tracking_cores_wasm.face },
            },
        });
        abi_wasm.addImport("manifest", lens_manifest_wasm);
        abi_wasm.addImport("trigger", lens_trigger_wasm);
        abi_wasm.addImport("runtime", lens_runtime_wasm);
        // Neither libc nor real threads exist for wasm32-freestanding -
        // the same reason directory-based lens activation already
        // refuses there (defaultIo's std.Io.Threaded can't even be
        // typed for this target). An asset loader needs both, so it
        // gets the same stub treatment as tracking/beauty above.
        const image_wasm = imageStubModule(b, wasm_target, .ReleaseSmall);
        abi_wasm.addImport("image", image_wasm);
        const gltf_stub_wasm = gltfStubModule(b, wasm_target, .ReleaseSmall, math_wasm);
        abi_wasm.addImport("asset", assetStubModule(b, wasm_target, .ReleaseSmall, image_wasm, gltf_stub_wasm));
        abi_wasm.addImport("gltf", gltf_stub_wasm);
        const gosslens_wasm = b.addExecutable(.{ .name = "gosslens", .root_module = abi_wasm });
        gosslens_wasm.entry = .disabled;
        gosslens_wasm.rdynamic = true;
        wasm_step.dependOn(&b.addInstallArtifact(gosslens_wasm, .{ .dest_dir = .{ .override = .{ .custom = "wasm" } } }).step);
    }

    // The render-capable half of the web core, real bgfx underneath
    // instead of render_stub.zig - separate from wasm_step above (which
    // stays as-is until the TS SDK actually points at this one)
    // rather than replacing it outright. tracking/segmentation/beauty/
    // image/asset stay the same stubs wasm_step already uses - gpupixel
    // still isn't ported to web, and the effects this step renders
    // (beauty.face, beauty.reshape) need none of them.
    //
    // Two separate artifacts, not one build with a runtime toggle:
    // -sASYNCIFY=1 (required for WebGPU's async adapter/device request)
    // instruments the whole per-frame render/submit path, not just
    // init, so a WebGL2-only user shouldn't pay for it. wasm-emscripten
    // below is unchanged; wasm-emscripten-webgpu is the new artifact
    // the TS SDK fetches only after confirming a
    // real WebGPU adapter.
    const wasm_emscripten_step = b.step("wasm-emscripten", "Build the gosslens core for the web with a real bgfx renderer (needs emscripten vendors synced)");
    addWasmEmscriptenStep(b, wasm_emscripten_step, shaderc_exe, false);
    const wasm_emscripten_webgpu_step = b.step("wasm-emscripten-webgpu", "Build the gosslens core for the web with bgfx's real WebGPU renderer + Asyncify (needs emscripten vendors synced)");
    addWasmEmscriptenStep(b, wasm_emscripten_webgpu_step, shaderc_exe, true);

    const harness_step = b.step("harness", "Build and run the desktop harness (draws through the graph on screen)");
    const conformance_step = b.step("conformance", "Run a reference lens through the real ABI twice and prove bit-stable output");
    if (have_render_stack and gltf_module != null and target.result.os.tag == .macos) {
        const bgfx_lib = buildBgfxLib(b, target, optimize);
        const glfw_lib = buildGlfwLib(b, target, optimize);
        const shader_blobs_module = if (shaderc_exe) |tool| addShaderBlobs(b, tool, target, optimize) else null;

        // core/lens/runtime.zig's shader.pass proof needs the real
        // render.zig (loadLensProgram/currentShaderProfileTag), not
        // desktop.zig's own lower-level direct bgfx cImport - a second
        // module instance for the host target, sharing the same
        // shader_blobs the harness module below already builds.
        const makeup_mesh_module = b.createModule(.{ .root_source_file = b.path("core/tracking/makeup_mesh.zig"), .target = target, .optimize = optimize });
        const render_module = b.createModule(.{
            .root_source_file = b.path("adapters/bgfx/render.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "math", .module = math_module },
                .{ .name = "makeup_mesh", .module = makeup_mesh_module },
                .{ .name = "face_mesh_topology", .module = face_mesh_topology_module },
            },
        });
        render_module.addIncludePath(b.path(".vendor/bgfx/include"));
        render_module.addIncludePath(b.path(".vendor/bx/include"));
        render_module.link_libc = true;
        if (shader_blobs_module) |sb| render_module.addImport("shader_blobs", sb);

        const harness_module = b.createModule(.{
            .root_source_file = b.path("harness/desktop.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "math", .module = math_module },
                .{ .name = "graph", .module = graph_module },
                .{ .name = "gltf", .module = gltf_module.? },
                .{ .name = "render", .module = render_module },
            },
        });
        harness_module.addIncludePath(b.path(".vendor/bgfx/include"));
        harness_module.addIncludePath(b.path(".vendor/bx/include"));
        harness_module.addIncludePath(b.path(".vendor/glfw/include"));
        harness_module.link_libc = true;
        if (shader_blobs_module) |sb| harness_module.addImport("shader_blobs", sb);
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
        for ([_][]const u8{ "Metal", "QuartzCore", "Cocoa", "IOKit", "CoreFoundation", "Foundation", "AppKit", "CoreMedia", "CoreVideo", "VideoToolbox", "AVFoundation" }) |framework| {
            harness_exe.root_module.linkFramework(framework, .{});
        }
        b.installArtifact(harness_exe);
        const run_harness = b.addRunArtifact(harness_exe);
        run_harness.setCwd(b.path("."));
        run_harness.step.dependOn(lens_package_reference_step);
        if (b.args) |args| run_harness.addArgs(args);
        harness_step.dependOn(&run_harness.step);

        // The conformance harness drives a reference lens through the
        // real ABI end to end (activation, render frame, screenshot),
        // not desktop.zig's own lower-level direct bgfx calls - it needs
        // its own abi module instance for that, real render.zig instead
        // of the stub every other abi_module instance on this target
        // uses, since this is the one host consumer that actually opens
        // a window and renders for real.
        const abi_conformance_module = b.createModule(.{
            .root_source_file = b.path("core/abi/abi.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "graph", .module = graph_module },
                .{ .name = "math", .module = math_module },
                .{ .name = "render", .module = render_module },
                .{ .name = "face", .module = face_module },
                .{ .name = "hand", .module = hand_core_module },
                .{ .name = "pose", .module = pose_core_module },
                .{ .name = "face_geometry", .module = face_geometry_core_module },
                .{ .name = "manifest", .module = lens_manifest_module },
                .{ .name = "trigger", .module = lens_trigger_module },
                .{ .name = "runtime", .module = lens_runtime_module },
            },
        });
        const conformance_png_module = pngModule(b, target, optimize);
        abi_conformance_module.addImport("png", conformance_png_module);
        abi_conformance_module.addImport("media_recording", recordingModule(b, target, optimize));
        abi_conformance_module.addImport("photo", photoModule(b, target, optimize));
        abi_conformance_module.addImport("audio_analysis", audioAnalysisModule(b, target, optimize));
        abi_conformance_module.addImport("physics", physicsModule(b, target, optimize, have_jolt));
        if (host_asset) |am| {
            abi_conformance_module.addImport("image", am.image);
            abi_conformance_module.addImport("asset", am.asset);
            if (gltf_module) |gm| abi_conformance_module.addImport("gltf", gm);
        }
        // Real tracking/segmentation/beauty for this consumer specifically
        // - a conformance proof against a stub capability only ever
        // exercises a lens's own degradation path (see the conformance-
        // harness history below), never the real thing a device runs.
        // Own module instances, the same reason runtime_ios/runtime_
        // android need their own: a fresh consumer needs a fresh linked
        // instance, not a shared one.
        const conformance_inference = have_inference_stack and flatc_exe != null;
        if (conformance_inference) {
            const runtime_conformance = b.createModule(.{
                .root_source_file = b.path("adapters/tracking/runtime.zig"),
                .target = target,
                .optimize = optimize,
            });
            runtime_conformance.link_libc = true;
            runtime_conformance.addIncludePath(b.path(".vendor/litert"));
            const transpose_conv_bias_conformance = b.createModule(.{
                .root_source_file = b.path("adapters/tracking/transpose_conv_bias.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "runtime", .module = runtime_conformance },
                    .{ .name = "segment", .module = segment_module },
                },
            });
            transpose_conv_bias_conformance.link_libc = true;
            transpose_conv_bias_conformance.addIncludePath(b.path(".vendor/litert"));
            const tracking_conformance = b.createModule(.{
                .root_source_file = b.path("adapters/tracking/tracking.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "bundle", .module = bundle_module },
                    .{ .name = "runtime", .module = runtime_conformance },
                    .{ .name = "detector", .module = detector_module },
                    .{ .name = "sampler", .module = sampler_module },
                    .{ .name = "face", .module = face_module },
                    .{ .name = "hand", .module = hand_core_module },
                .{ .name = "pose", .module = pose_core_module },
                .{ .name = "face_geometry", .module = face_geometry_core_module },
                    .{ .name = "tracker", .module = tracker_module },
                    .{ .name = "graph", .module = graph_module },
                    .{ .name = "math", .module = math_module },
                },
            });
            const segmentation_conformance = b.createModule(.{
                .root_source_file = b.path("adapters/tracking/segmentation.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "runtime", .module = runtime_conformance },
                    .{ .name = "sampler", .module = sampler_module },
                    .{ .name = "math", .module = math_module },
                    .{ .name = "transpose_conv_bias", .module = transpose_conv_bias_conformance },
                },
            });
            const beauty_conformance = b.createModule(.{
                .root_source_file = b.path("adapters/beauty/beauty.zig"),
                .target = target,
                .optimize = optimize,
                .imports = &.{
                    .{ .name = "face", .module = face_module },
                    .{ .name = "face106", .module = face106_module },
                },
            });
            abi_conformance_module.addImport("tracking", tracking_conformance);
            abi_conformance_module.addImport("segmentation", segmentation_conformance);
            abi_conformance_module.addImport("beauty", beauty_conformance);
        } else {
            abi_conformance_module.addImport("tracking", trackingStubModule(b, target, optimize, face_module, hand_core_module, pose_core_module, math_module));
            abi_conformance_module.addImport("segmentation", segmentationStubModule(b, target, optimize, math_module));
            abi_conformance_module.addImport("beauty", beautyStubModule(b, target, optimize, face_module));
        }
        const conformance_module = b.createModule(.{
            .root_source_file = b.path("harness/conformance.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "abi", .module = abi_conformance_module },
                .{ .name = "sampler", .module = sampler_module },
                .{ .name = "math", .module = math_module },
            },
        });
        if (host_asset) |am| conformance_module.addImport("image", am.image);
        conformance_module.addImport("png", conformance_png_module);
        const world_replay_module = b.createModule(.{
            .root_source_file = b.path("harness/world_replay.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{.{ .name = "math", .module = math_module }},
        });
        conformance_module.addImport("world_replay", world_replay_module);
        test_step.dependOn(&b.addRunArtifact(b.addTest(.{ .root_module = world_replay_module })).step);
        conformance_module.addIncludePath(b.path(".vendor/glfw/include"));
        // Declarations only - the gpupixel archive already carries a
        // compiled stb_image implementation on this macOS-only target,
        // the same reason tracking_module's own include here needs no
        // paired stb_image_impl.c source file.
        conformance_module.addIncludePath(b.path(".vendor/gpupixel/third_party/stb/include/stb"));
        conformance_module.link_libc = true;
        const conformance_exe = b.addExecutable(.{
            .name = "conformance",
            .root_module = conformance_module,
        });
        conformance_module.linkLibrary(bgfx_lib);
        conformance_module.linkLibrary(glfw_lib);
        if (conformance_inference) {
            conformance_module.link_libcpp = true;
            conformance_module.linkLibrary(buildTfliteLib(b, target, optimize, flatc_exe.?, null));
            conformance_module.linkLibrary(buildXnnpackLib(b, target, optimize, null, null));
            conformance_module.linkLibrary(buildAbseilLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildRuyLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildFarmhashLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildFlatbuffersLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildFft2dLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildCpuinfoLib(b, target, optimize, null));
            conformance_module.linkLibrary(buildPthreadpoolLib(b, target, optimize, null));
            // beauty.zig's real implementation calls into the GPUPixel-
            // backed shim (adapters/beauty/beauty_shim_apple.mm) - this
            // target is already macOS-only (harness_step's own outer
            // condition), the same reason tracking_module links it
            // unconditionally too.
            conformance_module.linkLibrary(buildGpupixelLib(b, target, optimize, null));
            conformance_module.linkFramework("AppKit", .{});
            conformance_module.linkFramework("OpenGL", .{});
            conformance_module.linkFramework("CoreVideo", .{});
        }
        for ([_][]const u8{ "Metal", "QuartzCore", "Cocoa", "IOKit", "CoreFoundation", "Foundation", "AppKit", "CoreMedia", "CoreVideo", "VideoToolbox", "AVFoundation" }) |framework| {
            conformance_exe.root_module.linkFramework(framework, .{});
        }
        b.installArtifact(conformance_exe);
        const run_conformance = b.addRunArtifact(conformance_exe);
        run_conformance.setCwd(b.path("."));
        run_conformance.step.dependOn(lens_package_reference_step);
        if (b.args) |args| run_conformance.addArgs(args);
        conformance_step.dependOn(&run_conformance.step);
    } else {
        const missing = b.addFail("gosslens: harness needs macos and synced render vendors, run zig build vendor-sync");
        harness_step.dependOn(&missing.step);
        conformance_step.dependOn(&missing.step);
    }
}

// bx, bimg, and bgfx compile as one static library from their amalgamated
// sources; zig is the C++ and Objective-C++ compiler for every target,
// device targets included. Debug config follows the zig optimize mode.
fn ndkSysroot(b: *std.Build) ?[]const u8 {
    const prebuilt = if (@import("builtin").os.tag == .macos) "darwin-x86_64" else "linux-x86_64";
    // CI runners and other machines name the NDK through the standard
    // environment variables; the lab machine's fixed install is the
    // fallback.
    for ([_][]const u8{ "ANDROID_NDK_ROOT", "ANDROID_NDK_HOME", "ANDROID_NDK_LATEST_HOME" }) |name| {
        if (b.graph.environ_map.get(name)) |root| {
            const sysroot = b.pathJoin(&.{ root, "toolchains", "llvm", "prebuilt", prebuilt, "sysroot" });
            b.build_root.handle.access(b.graph.io, sysroot, .{}) catch continue;
            return sysroot;
        }
    }
    const home = b.graph.environ_map.get("HOME") orelse return null;
    const sysroot = b.pathJoin(&.{ home, "Library", "Android", "sdk", "ndk", "29.0.14206865", "toolchains", "llvm", "prebuilt", prebuilt, "sysroot" });
    b.build_root.handle.access(b.graph.io, sysroot, .{}) catch return null;
    return sysroot;
}

fn addNdkPaths(b: *std.Build, module: *std.Build.Module, sysroot: []const u8) void {
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include" }) });
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "include", "aarch64-linux-android" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sysroot, "usr", "lib", "aarch64-linux-android", "29" }) });
}

fn addAndroidStep(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile, flatc_exe: ?*std.Build.Step.Compile) void {
    const android_step = b.step("android", "Build libgosslens.so for android arm64-v8a");
    const shaderc_tool = shaderc_exe orelse {
        android_step.dependOn(&b.addFail("gosslens: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    };
    const sysroot = ndkSysroot(b) orelse {
        const missing = b.addFail("gosslens: ndk 29.0.14206865 not installed under ~/Library/Android/sdk/ndk");
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
    const makeup_mesh_android = b.createModule(.{ .root_source_file = b.path("core/tracking/makeup_mesh.zig"), .target = android_target, .optimize = optimize });
    const face_mesh_topology_android = b.createModule(.{ .root_source_file = b.path("core/tracking/face_mesh_topology.zig"), .target = android_target, .optimize = optimize });
    const render_android = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_android },
            .{ .name = "makeup_mesh", .module = makeup_mesh_android },
            .{ .name = "face_mesh_topology", .module = face_mesh_topology_android },
        },
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
    const libc_txt = b.addWriteFiles().add("android-libc.txt", b.fmt("include_dir={s}/usr/include\nsys_include_dir={s}/usr/include/aarch64-linux-android\ncrt_dir={s}/usr/lib/aarch64-linux-android/29\nmsvc_lib_dir=\nkernel32_lib_dir=\ngcc_dir=\n", .{ sysroot, sysroot, sysroot }));

    const tracking_cores_android = trackingCoreModules(b, android_target, optimize, math_android);
    abi_android.addImport("face", tracking_cores_android.face);
    abi_android.addImport("hand", tracking_cores_android.hand);
    abi_android.addImport("pose", tracking_cores_android.pose);
    abi_android.addImport("face_geometry", tracking_cores_android.face_geometry);
    abi_android.addImport("png", pngModule(b, android_target, optimize));
    abi_android.addImport("media_recording", recordingModule(b, android_target, optimize));
    abi_android.addImport("photo", photoModule(b, android_target, optimize));
    abi_android.addImport("audio_analysis", audioAnalysisModule(b, android_target, optimize));
    abi_android.addImport("physics", physicsModule(b, android_target, optimize, false));
    const lens_manifest_android = b.createModule(.{
        .root_source_file = b.path("core/lens/manifest.zig"),
        .target = android_target,
        .optimize = optimize,
    });
    const lens_trigger_android = b.createModule(.{
        .root_source_file = b.path("core/lens/trigger.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "face", .module = tracking_cores_android.face }},
    });
    const lens_animation_android = b.createModule(.{
        .root_source_file = b.path("core/lens/animation.zig"),
        .target = android_target,
        .optimize = optimize,
    });
    const lens_runtime_android = b.createModule(.{
        .root_source_file = b.path("core/lens/runtime.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_android },
            .{ .name = "manifest", .module = lens_manifest_android },
            .{ .name = "trigger", .module = lens_trigger_android },
            .{ .name = "animation", .module = lens_animation_android },
            .{ .name = "face", .module = tracking_cores_android.face },
        },
    });
    abi_android.addImport("manifest", lens_manifest_android);
    abi_android.addImport("trigger", lens_trigger_android);
    abi_android.addImport("runtime", lens_runtime_android);
    const have_inference_stack = blk: {
        for ([_][]const u8{ ".vendor/litert/tflite/CMakeLists.txt", ".vendor/xnnpack/CMakeLists.txt", ".vendor/fft2d/fftsg2d.c" }) |probe| {
            b.build_root.handle.access(b.graph.io, probe, .{}) catch break :blk false;
        }
        break :blk true;
    };
    const flatc_android = flatc_exe;
    const inference_android = have_inference_stack and flatc_android != null;
    if (inference_android) {
        const runtime_android = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/runtime.zig"),
            .target = android_target,
            .optimize = optimize,
        });
        runtime_android.link_libc = true;
        runtime_android.addIncludePath(b.path(".vendor/litert"));
        addNdkPaths(b, runtime_android, sysroot);
        runtime_android.addCMacro("_Nonnull", "");
        runtime_android.addCMacro("_Nullable", "");
        const tracking_android = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/tracking.zig"),
            .target = android_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundle", .module = tracking_cores_android.bundle },
                .{ .name = "runtime", .module = runtime_android },
                .{ .name = "detector", .module = tracking_cores_android.detector },
                .{ .name = "sampler", .module = tracking_cores_android.sampler },
                .{ .name = "face", .module = tracking_cores_android.face },
                .{ .name = "hand", .module = tracking_cores_android.hand },
                .{ .name = "pose", .module = tracking_cores_android.pose },
                .{ .name = "tracker", .module = tracking_cores_android.tracker },
                .{ .name = "graph", .module = graph_android },
                .{ .name = "math", .module = math_android },
            },
        });
        abi_android.addImport("tracking", tracking_android);
        const segment_android = b.createModule(.{
            .root_source_file = b.path("core/tracking/segment.zig"),
            .target = android_target,
            .optimize = optimize,
        });
        const transpose_conv_bias_android = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/transpose_conv_bias.zig"),
            .target = android_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_android },
                .{ .name = "segment", .module = segment_android },
            },
        });
        transpose_conv_bias_android.link_libc = true;
        transpose_conv_bias_android.addIncludePath(b.path(".vendor/litert"));
        const segmentation_android = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/segmentation.zig"),
            .target = android_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_android },
                .{ .name = "sampler", .module = tracking_cores_android.sampler },
                .{ .name = "math", .module = math_android },
                .{ .name = "transpose_conv_bias", .module = transpose_conv_bias_android },
            },
        });
        abi_android.addImport("segmentation", segmentation_android);
        const face106_android = b.createModule(.{
            .root_source_file = b.path("core/tracking/face106.zig"),
            .target = android_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "face", .module = tracking_cores_android.face }},
        });
        const beauty_android_module = b.createModule(.{
            .root_source_file = b.path("adapters/beauty/beauty.zig"),
            .target = android_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "face", .module = tracking_cores_android.face },
                .{ .name = "face106", .module = face106_android },
            },
        });
        abi_android.addImport("beauty", beauty_android_module);
    } else {
        abi_android.addImport("tracking", trackingStubModule(b, android_target, optimize, tracking_cores_android.face, tracking_cores_android.hand, tracking_cores_android.pose, math_android));
        abi_android.addImport("segmentation", segmentationStubModule(b, android_target, optimize, math_android));
        abi_android.addImport("beauty", beautyStubModule(b, android_target, optimize, tracking_cores_android.face));
    }
    const have_cgltf_android = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/cgltf/cgltf.h", .{}) catch break :blk false;
        break :blk true;
    };
    const gltf_android = if (have_cgltf_android) gltfModule(b, android_target, optimize, math_android) else null;
    const android_asset = realAssetModules(b, android_target, optimize, gltf_android);
    abi_android.addImport("image", android_asset.image);
    abi_android.addImport("asset", android_asset.asset);
    if (gltf_android) |gm| abi_android.addImport("gltf", gm);
    const jni_module = b.createModule(.{
        .root_source_file = b.path("adapters/android/jni.zig"),
        .target = android_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "abi", .module = abi_android }},
    });
    jni_module.link_libc = true;
    addNdkPaths(b, jni_module, sysroot);
    if (inference_android) {
        jni_module.link_libcpp = true;
        jni_module.linkLibrary(buildTfliteLib(b, android_target, optimize, flatc_android.?, libc_txt));
        jni_module.linkLibrary(buildXnnpackLib(b, android_target, optimize, libc_txt, null));
        jni_module.linkLibrary(buildAbseilLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildRuyLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildFarmhashLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildFlatbuffersLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildFft2dLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildCpuinfoLib(b, android_target, optimize, libc_txt));
        jni_module.linkLibrary(buildPthreadpoolLib(b, android_target, optimize, libc_txt));
        const beauty_archive = buildGpupixelLib(b, android_target, optimize, libc_txt);
        addNdkPaths(b, beauty_archive.root_module, sysroot);
        jni_module.linkLibrary(beauty_archive);
    }

    const bgfx_android = buildBgfxAndroid(b, android_target, optimize, sysroot);
    bgfx_android.setLibCFile(libc_txt);
    const so = b.addLibrary(.{ .name = "gosslens", .linkage = .dynamic, .root_module = jni_module });
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
const TrackingCoreModules = struct {
    bundle: *std.Build.Module,
    detector: *std.Build.Module,
    sampler: *std.Build.Module,
    face: *std.Build.Module,
    hand: *std.Build.Module,
    pose: *std.Build.Module,
    face_mesh_topology: *std.Build.Module,
    face_geometry: *std.Build.Module,
    tracker: *std.Build.Module,
};

// The pure tracking core for one target: geometry, decode, and sampling
// shared by the worker, the harness, and the export layer.
fn pngModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("core/media/png.zig"), .target = target, .optimize = optimize });
}

fn audioAnalysisModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{ .root_source_file = b.path("core/media/audio_analysis.zig"), .target = target, .optimize = optimize });
}

// The rigid-body world: Jolt and its shim on targets we build it for,
// the honest stub elsewhere. Host-only until the lens physics nodes
// bring the device targets with them.
fn physicsModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, real: bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(if (real) "adapters/physics/physics.zig" else "adapters/physics/physics_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (real) {
        module.link_libcpp = true;
        module.addIncludePath(b.path(".vendor/jolt"));
        module.addCSourceFile(.{
            .file = b.path("adapters/physics/jolt_shim.cpp"),
            .flags = &.{ "-std=c++17", "-fno-sanitize=undefined", "-DJPH_USE_CPU_COMPUTE" },
        });
        module.linkLibrary(buildJoltLib(b, target, optimize));
    }
    return module;
}

// QuickJS-ng's four-file minimal embed as a static library. No I/O layer
// (quickjs-libc.c) is compiled, so the interpreter has no way to touch the
// filesystem or network - the sandbox is by construction.
fn buildQuickjsLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const root = ".vendor/quickjs-ng";
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.addIncludePath(b.path(root));
    if (target.result.abi.isAndroid()) {
        module.pic = true;
        if (ndkSysroot(b)) |sysroot| addNdkPaths(b, module, sysroot);
    }
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    const flags = [_][]const u8{ "-std=c11", "-fno-sanitize=undefined", "-w" };
    const files = [_][]const u8{ "quickjs.c", "libregexp.c", "libunicode.c", "dtoa.c" };
    for (files) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt("{s}/{s}", .{ root, file })), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "quickjs", .linkage = .static, .root_module = module });
}

fn scriptModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, real: bool) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path(if (real) "adapters/script/script.zig" else "adapters/script/script_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (real) {
        module.link_libc = true;
        module.addIncludePath(b.path(".vendor/quickjs-ng"));
        module.addCSourceFile(.{
            .file = b.path("adapters/script/qjs_shim.c"),
            .flags = &.{ "-std=c11", "-fno-sanitize=undefined" },
        });
        module.linkLibrary(buildQuickjsLib(b, target, optimize));
    }
    return module;
}

// Platform photo encoding: the formats phones actually save, produced
// by the platform's own encoders; targets without a landed backend get
// the stub, which reports the capability honestly absent.
fn photoModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const module = b.createModule(.{
        .root_source_file = b.path(if (apple) "adapters/image/photo.zig" else "adapters/image/photo_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
    if (apple) {
        module.addCSourceFile(.{
            .file = b.path("adapters/image/photo_apple.mm"),
            .flags = &.{ "-std=c++17", "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        module.link_libcpp = true;
        module.linkFramework("CoreGraphics", .{});
        module.linkFramework("ImageIO", .{});
        module.linkFramework("Foundation", .{});
        if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    }
    return module;
}

// Video recording rides the platform's own encoder and muxer; targets
// without a landed backend get the stub, which reports the capability
// honestly absent rather than pretending.
fn recordingModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const apple = target.result.os.tag == .macos or target.result.os.tag == .ios;
    const android = target.result.abi.isAndroid();
    const root = if (apple)
        "adapters/media/recording.zig"
    else if (android)
        "adapters/media/recording_android.zig"
    else
        "adapters/media/recording_stub.zig";
    const module = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
    });
    if (android) {
        // Translation-only sysroot includes: link_libc here would mix
        // zig's bundled bionic headers with the sysroot's and conflict;
        // libc itself links at the shared-library level.
        if (ndkSysroot(b)) |sysroot| addNdkPaths(b, module, sysroot);
        module.linkSystemLibrary("mediandk", .{});
        module.linkSystemLibrary("android", .{});
    }
    if (apple) {
        module.addCSourceFile(.{
            .file = b.path("adapters/media/recording_apple.mm"),
            .flags = &.{ "-std=c++17", "-fobjc-arc", "-fno-sanitize=undefined" },
        });
        module.link_libcpp = true;
        module.linkFramework("AVFoundation", .{});
        module.linkFramework("CoreMedia", .{});
        module.linkFramework("CoreVideo", .{});
        module.linkFramework("Metal", .{});
        module.linkFramework("Foundation", .{});
        if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    }
    return module;
}

fn trackingCoreModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, math_module: *std.Build.Module) TrackingCoreModules {
    const bundle_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/bundle.zig"),
        .target = target,
        .optimize = optimize,
    });
    const detector_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/detector.zig"),
        .target = target,
        .optimize = optimize,
    });
    const sampler_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/sampler.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_module }},
    });
    const face_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/face.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sampler", .module = sampler_module },
            .{ .name = "detector", .module = detector_module },
        },
    });
    const hand_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/hand.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sampler", .module = sampler_module },
            .{ .name = "detector", .module = detector_module },
        },
    });
    const pose_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/pose.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sampler", .module = sampler_module },
            .{ .name = "detector", .module = detector_module },
        },
    });
    const face_mesh_topology_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/face_mesh_topology.zig"),
        .target = target,
        .optimize = optimize,
    });
    const face_geometry_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/face_geometry.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_module }},
    });
    const tracker_module = b.createModule(.{
        .root_source_file = b.path("core/tracking/tracker.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "sampler", .module = sampler_module },
            .{ .name = "face", .module = face_module },
        },
    });
    return .{
        .bundle = bundle_module,
        .detector = detector_module,
        .sampler = sampler_module,
        .face = face_module,
        .hand = hand_module,
        .pose = pose_module,
        .face_mesh_topology = face_mesh_topology_module,
        .face_geometry = face_geometry_module,
        .tracker = tracker_module,
    };
}

const AssetModules = struct {
    image: *std.Build.Module,
    asset: *std.Build.Module,
};

// cgltf compiles as C linked against a target's libc, the same reason
// lodepng below needs its own per-target instance rather than one
// shared module - math has no C dependency so the one shared
// math_module is fine to reuse across every target.
fn gltfModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, math_module: *std.Build.Module) *std.Build.Module {
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
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, m);
    return m;
}

// A real PNG decoder plus the off-thread loader built on it, for one
// target - each needs its own instance the same way the tracking core
// does, since lodepng (and, for the model loader, cgltf) compiles as C
// linked against that target's libc. gltf_module is optional only
// because a caller might not have vendor-synced cgltf yet; every real
// target passes one.
fn realAssetModules(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, gltf_module: ?*std.Build.Module) AssetModules {
    const image_module = b.createModule(.{
        .root_source_file = b.path("adapters/image/image.zig"),
        .target = target,
        .optimize = optimize,
    });
    image_module.addIncludePath(b.path(".vendor/bimg/3rdparty/lodepng"));
    image_module.addIncludePath(b.path(".vendor/libyuv/include"));
    image_module.addCSourceFile(.{
        .file = b.path("harness/lodepng_impl.c"),
        .flags = &.{ "-std=c99", "-fno-sanitize=undefined" },
    });
    image_module.link_libc = true;
    image_module.linkLibrary(buildLibyuvLib(b, target, optimize, null));
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, image_module);
    const asset_module = b.createModule(.{
        .root_source_file = b.path("adapters/asset/asset.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "image", .module = image_module }},
    });
    if (gltf_module) |gm| asset_module.addImport("gltf", gm);
    return .{ .image = image_module, .asset = asset_module };
}

fn imageStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/image/image_stub.zig"),
        .target = target,
        .optimize = optimize,
    });
}

fn assetStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, image_module: *std.Build.Module, gltf_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/asset/asset_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "image", .module = image_module },
            .{ .name = "gltf", .module = gltf_module },
        },
    });
}

fn gltfStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, math_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/gltf/gltf_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_module }},
    });
}

fn beautyStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, face_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/beauty/beauty_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "face", .module = face_module }},
    });
}

fn trackingStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, face_module: *std.Build.Module, hand_module: *std.Build.Module, pose_module: *std.Build.Module, math_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/tracking/tracking_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "face", .module = face_module },
            .{ .name = "hand", .module = hand_module },
            .{ .name = "pose", .module = pose_module },
            .{ .name = "math", .module = math_module },
        },
    });
}

fn segmentationStubModule(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, math_module: *std.Build.Module) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path("adapters/tracking/segmentation_stub.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "math", .module = math_module }},
    });
}

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
                    if (std.mem.indexOf(u8, child, pattern) != null) {
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
fn immintrinPath(b: *std.Build) []const u8 {
    const lib_dir = b.graph.zig_lib_directory.path orelse ".";
    return b.pathJoin(&.{ lib_dir, "include", "immintrin.h" });
}

fn buildAbseilLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    if (target.result.cpu.arch.isWasm()) module.addIncludePath(b.path("adapters/tracking/wasi_std"));
    module.addIncludePath(b.path(".vendor/abseil"));
    var sources: std.ArrayList([]const u8) = .empty;
    var absl_excludes: std.ArrayList([]const u8) = .empty;
    absl_excludes.appendSlice(b.allocator, &.{
        "_test", "test_", "_benchmark", "benchmark", "_mock", "mock_", "matchers",
        "test_util", "print_hash_of", "gaussian_distribution_gentables", "pool_urbg_gentables",
        "_win.cc", "_emscripten.cc",
    }) catch @panic("oom");
    // No signals to install a handler for on the web target.
    if (target.result.cpu.arch.isWasm()) {
        absl_excludes.append(b.allocator, "failure_signal_handler.cc") catch @panic("oom");
        module.addCMacro("_WASI_EMULATED_SIGNAL", "1");
        module.addCMacro("_WASI_EMULATED_MMAN", "1");
    }
    listFilesRecursive(b, ".vendor/abseil/absl", ".cc", absl_excludes.items, &sources);
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" }) catch @panic("oom");
    // Exception paths become traps on the web target; nothing catches in
    // this module.
    if (target.result.cpu.arch.isWasm()) flags.append(b.allocator, "-fno-exceptions") catch @panic("oom");
    // The container internals include the bmi2 intrinsics header directly,
    // which this compiler only accepts by way of immintrin.
    if (target.result.cpu.arch == .x86_64) {
        flags.appendSlice(b.allocator, &.{ "-include", immintrinPath(b) }) catch @panic("oom");
    }
    for (sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = flags.items });
    }
    const lib = b.addLibrary(.{ .name = "absl", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildCpuinfoLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    module.addIncludePath(b.path(".vendor/cpuinfo/include"));
    module.addIncludePath(b.path(".vendor/cpuinfo/src"));
    const flags = [_][]const u8{ "-std=c99", "-fno-sanitize=undefined", "-w", "-D_GNU_SOURCE", "-DCPUINFO_LOG_LEVEL=2" };
    var files: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "api.c", "cache.c", "init.c", "log.c" }) |file| {
        files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
    }
    const os = target.result.os.tag;
    const arch = target.result.cpu.arch;
    if (arch == .x86_64) {
        for ([_][]const u8{
            "x86/init.c",       "x86/info.c",              "x86/vendor.c",
            "x86/uarch.c",      "x86/name.c",              "x86/topology.c",
            "x86/isa.c",        "x86/cache/init.c",        "x86/cache/descriptor.c",
            "x86/cache/deterministic.c",
        }) |file| {
            files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
        }
        if (os == .linux) {
            for ([_][]const u8{
                "linux/cpulist.c", "linux/multiline.c", "linux/processors.c", "linux/smallfile.c",
                "x86/linux/init.c", "x86/linux/cpuinfo.c",
            }) |file| {
                files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
            }
        } else if (os == .macos) {
            for ([_][]const u8{ "mach/topology.c", "x86/mach/init.c" }) |file| {
                files.append(b.allocator, b.fmt(".vendor/cpuinfo/src/{s}", .{file})) catch @panic("oom");
            }
        }
    } else if (os == .macos or os == .ios) {
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
    const lib = b.addLibrary(.{ .name = "cpuinfo", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildPthreadpoolLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    module.addIncludePath(b.path(".vendor/pthreadpool/include"));
    module.addIncludePath(b.path(".vendor/pthreadpool/src"));
    module.addIncludePath(b.path(".vendor/fxdiv/include"));
    const flags = [_][]const u8{ "-std=gnu11", "-fno-sanitize=undefined", "-w", "-DPTHREADPOOL_USE_GCD=0", "-DPTHREADPOOL_USE_EVENT=0", "-DPTHREADPOOL_USE_FUTEX=0" };
    const sources: []const []const u8 = if (target.result.cpu.arch.isWasm())
        &.{ "legacy-api.c", "shim.c" }
    else
        &.{ "legacy-api.c", "portable-api.c", "memory.c", "pthreads.c" };
    for (sources) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/pthreadpool/src/{s}", .{file})), .flags = &flags });
    }
    const lib = b.addLibrary(.{ .name = "pthreadpool", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildRuyLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    if (target.result.cpu.arch.isWasm()) module.addIncludePath(b.path("adapters/tracking/wasi_std"));
    module.addIncludePath(b.path(".vendor/ruy"));
    module.addIncludePath(b.path(".vendor/cpuinfo/include"));
    var ruy_flags: std.ArrayList([]const u8) = .empty;
    ruy_flags.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" }) catch @panic("oom");
    if (target.result.cpu.arch.isWasm()) ruy_flags.append(b.allocator, "-fno-exceptions") catch @panic("oom");
    const flags = ruy_flags.items;
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
        module.addCSourceFile(.{ .file = b.path(file), .flags = flags });
    }
    const lib = b.addLibrary(.{ .name = "ruy", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

// The flatbuffers runtime pieces the schema code links against; the
// headers carry almost everything, this archive holds the rest.

// ANGLE's own EGL/GLES2-over-Metal backend, the fix for real iOS
// hardware where native EAGLContext creation fails outright. Scoped the
// way Tint was: libANGLE core, only the Metal renderer backend, the
// translator, libGLESv2, libEGL - compiled directly, no GN/Ninja.
fn buildAngleLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const angle_dir = ".vendor/angle";
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.link_libcpp = true;
    addAppleSdkPaths(b, module);

    for ([_][]const u8{
        angle_dir ++ "/include",
        angle_dir ++ "/src",
        angle_dir ++ "/src/common/base",
        angle_dir ++ "/src/common/third_party/xxhash",
        "adapters/angle",
    }) |dir| {
        module.addIncludePath(b.path(dir));
    }

    module.addCMacro("ANGLE_ENABLE_METAL", "1");
    module.addCMacro("ANGLE_ENABLE_ESSL", "1");
    module.addCMacro("ANGLE_ENABLE_GLSL", "1");
    module.addCMacro("GL_GLES_PROTOTYPES", "0");
    module.addCMacro("EGL_EGL_PROTOTYPES", "0");
    module.addCMacro("LIBANGLE_IMPLEMENTATION", "1");
    module.addCMacro("LIBGLESV2_IMPLEMENTATION", "1");
    module.addCMacro("LIBEGL_IMPLEMENTATION", "1");
    module.addCMacro("ANGLE_UTIL_EXPORT", "");
    module.addCMacro("ANGLE_CAPTURE_ENABLED", "0");

    const flags = [_][]const u8{ "-std=c++20", "-fno-sanitize=undefined", "-w", "-fno-objc-arc" };

    // Backends and features this scope has no use for: other GPU APIs
    // (D3D/Vulkan/WGPU/desktop-GL/null, plus the DXGI/SPIR-V/Vulkan
    // common code they alone pull in), OpenCL, the experimental Rust
    // translator, frame capture, and code for platforms that aren't us.
    const angle_excludes = [_][]const u8{
        "_unittest.cpp", "_test.cpp",    "_fuzzer.cpp",   "_unittest.mm", "_test.mm",
        "/fuzz/",        "/tests/",
        "/renderer/d3d/", "/renderer/vulkan/", "/renderer/wgpu/",
        "/renderer/null/", "/renderer/gl/",    "/renderer/cl/",
        "/dxgi_support_table", "/dxgi_format_map_autogen",
        "/CL",           "/cl_",         "_cl_",         "validationCL", "PackedCLEnums",
        "system_utils_linux", "system_utils_win",
        "/common/gl/",   "/common/serializer/", "/common/vulkan/", "/common/spirv/",
        "/compiler/translator/ir/", "/compiler/translator/hlsl/",
        "/compiler/translator/spirv/", "/compiler/translator/wgsl/",
        "/libANGLE/capture/",
        // The real ASTC decoder needs an external codec this project
        // doesn't vendor; AstcDecompressorNoOp.cpp is ANGLE's own
        // fallback for exactly that, same as angle_has_astc_encoder=false.
        "/image_util/AstcDecompressor.cpp",
        // gpu_info_util's real per-platform source list (src/libGLESv2.gni)
        // for iOS is exactly SystemInfo.cpp + SystemInfo_apple.mm +
        // SystemInfo_ios.cpp - every other SystemInfo_*.{cpp,mm} here is
        // a different platform's file.
        "SystemInfo_android", "SystemInfo_fuchsia", "SystemInfo_libpci",
        "SystemInfo_linux",   "SystemInfo_macos",   "SystemInfo_vulkan",
        "SystemInfo_win",     "SystemInfo_x11",
    };

    var sources: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{
        angle_dir ++ "/src/common",
        angle_dir ++ "/src/libANGLE",
        angle_dir ++ "/src/libGLESv2",
        angle_dir ++ "/src/libEGL",
        angle_dir ++ "/src/compiler",
        angle_dir ++ "/src/image_util",
        angle_dir ++ "/src/gpu_info_util",
    }) |dir| {
        listFilesRecursive(b, dir, ".cpp", &angle_excludes, &sources);
        listFilesRecursive(b, dir, ".mm", &angle_excludes, &sources);
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b_: []const u8) bool {
            return std.mem.lessThan(u8, a, b_);
        }
    }.lessThan);

    for (sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }
    module.addCSourceFile(.{ .file = b.path("adapters/angle/compression_utils_portable.cc"), .flags = &flags });
    // xxhash.h alone only declares the API; this is its implementation.
    // A plain C file, so it gets its own flags rather than -std=c++20.
    const xxhash_flags = [_][]const u8{ "-fno-sanitize=undefined", "-w" };
    module.addCSourceFile(.{
        .file = b.path(angle_dir ++ "/src/common/third_party/xxhash/xxhash.c"),
        .flags = &xxhash_flags,
    });
    // Core code calls into FrameCaptureShared unconditionally even with
    // capture disabled - ANGLE's own GN build hits the same real gap
    // and papers over it with exactly these two stub sources.
    for ([_][]const u8{
        angle_dir ++ "/src/libANGLE/capture/FrameCapture_mock.cpp",
        angle_dir ++ "/src/libANGLE/capture/serialize_mock.cpp",
    }) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }

    module.linkSystemLibrary("z", .{});
    module.linkFramework("Metal", .{});
    module.linkFramework("QuartzCore", .{});
    module.linkFramework("Foundation", .{});
    module.linkFramework("IOSurface", .{});

    return b.addLibrary(.{ .name = "angle", .linkage = .static, .root_module = module });
}

// The beauty effects engine from its pinned tree: the core graph, the
// filter set, raw data source and sinks, compiled per platform against the
// system gl it targets. The bundled face detector never builds; landmarks
// come from the tracking pipeline. Its color converter dependency builds
// from the sources the sink actually reaches for.
fn buildGpupixelLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    for ([_][]const u8{
        ".vendor/gpupixel/include",
        ".vendor/gpupixel/src",
        ".vendor/gpupixel/third_party/ghc",
        ".vendor/libyuv/include",
        ".vendor/gpupixel/third_party/stb/include",
    }) |dir| {
        module.addIncludePath(b.path(dir));
    }
    if (target.result.os.tag == .ios) {
        module.addIncludePath(b.path(".vendor/angle/include"));
    }
    const os = target.result.os.tag;
    const platform_define: []const u8 = switch (os) {
        .macos => "GPUPIXEL_MAC",
        .ios => "GPUPIXEL_IOS",
        else => if (target.result.abi.isAndroid()) "GPUPIXEL_ANDROID" else "GPUPIXEL_LINUX",
    };
    module.addCMacro(platform_define, "1");

    var flags: std.ArrayList([]const u8) = .empty;
    flags.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" }) catch @panic("oom");
    // The gl include header imports the apple ui frameworks, so every
    // translation unit on those targets is objective c++.
    if (os == .macos or os == .ios) {
        flags.appendSlice(b.allocator, &.{ "-std=gnu++17", "-fno-objc-arc" }) catch @panic("oom");
    }

    const sources = [_][]const u8{
        "core/gpupixel.cc",
        "core/gpupixel_context.cc",
        "core/gpupixel_program.cc",
        "core/gpupixel_framebuffer.cc",
        "core/gpupixel_framebuffer_factory.cc",
        "source/source.cc",
        "source/source_raw_data.cc",
        "source/source_image.cc",
        "sink/sink_raw_data.cc",
        "sink/sink_raw_data_yuv.cc",
        "sink/sink_render.cc",
        "sink/sink.cc",
        "utils/math_toolbox.cc",
        "utils/dispatch_queue.cc",
        "utils/util.cc",
        "filter/contrast_filter.cc",
        "filter/glass_sphere_filter.cc",
        "filter/brightness_filter.cc",
        "filter/ios_blur_filter.cc",
        "filter/hsb_filter.cc",
        "filter/sobel_edge_detection_filter.cc",
        "filter/sphere_refraction_filter.cc",
        "filter/directional_sobel_edge_detection_filter.cc",
        "filter/blusher_filter.cc",
        "filter/box_high_pass_filter.cc",
        "filter/luminance_range_filter.cc",
        "filter/box_blur_filter.cc",
        "filter/sketch_filter.cc",
        "filter/directional_non_maximum_suppression_filter.cc",
        "filter/toon_filter.cc",
        "filter/pixellation_filter.cc",
        "filter/beauty_face_unit_filter.cc",
        "filter/single_component_gaussian_blur_filter.cc",
        "filter/non_maximum_suppression_filter.cc",
        "filter/canny_edge_detection_filter.cc",
        "filter/filter.cc",
        "filter/bilateral_filter.cc",
        "filter/color_matrix_filter.cc",
        "filter/exposure_filter.cc",
        "filter/rgb_filter.cc",
        "filter/face_makeup_filter.cc",
        "filter/hue_filter.cc",
        "filter/nearby_sampling3x3_filter.cc",
        "filter/posterize_filter.cc",
        "filter/color_invert_filter.cc",
        "filter/single_component_gaussian_blur_mono_filter.cc",
        "filter/gaussian_blur_mono_filter.cc",
        "filter/convolution3x3_filter.cc",
        "filter/weak_pixel_inclusion_filter.cc",
        "filter/halftone_filter.cc",
        "filter/saturation_filter.cc",
        "filter/emboss_filter.cc",
        "filter/grayscale_filter.cc",
        "filter/lipstick_filter.cc",
        "filter/box_mono_blur_filter.cc",
        "filter/box_difference_filter.cc",
        "filter/crosshatch_filter.cc",
        "filter/filter_group.cc",
        "filter/gaussian_blur_filter.cc",
        "filter/beauty_face_filter.cc",
        "filter/face_reshape_filter.cc",
        "filter/white_balance_filter.cc",
        "filter/smooth_toon_filter.cc",
    };
    // The compiler picks the language from the extension, and these
    // sources import ui frameworks on the apple targets, so each compiles
    // through a generated objective c++ includer there.
    const apple = os == .macos or os == .ios;
    const wrappers = b.addWriteFiles();
    for (sources) |file| {
        if (apple) {
            const name = std.mem.trimEnd(u8, file[std.mem.lastIndexOfScalar(u8, file, '/').? + 1 ..], ".c");
            const real_path = b.fmt(".vendor/gpupixel/src/{s}", .{file});
            // The wrapper's own text never changes between builds, so a
            // vendor patch editing real_path's content alone leaves
            // zig's cache none the wiser. Forces the wrapper to change.
            const real_content = b.build_root.handle.readFileAlloc(b.graph.io, real_path, b.allocator, .limited(1 << 20)) catch @panic("gpupixel source unreadable");
            const fingerprint = std.hash.Wyhash.hash(0, real_content);
            const wrapper = wrappers.add(
                b.fmt("{s}.mm", .{name}),
                b.fmt("// fingerprint: {x}\n#include \"{s}\"\n", .{ fingerprint, b.pathFromRoot(real_path) }),
            );
            module.addCSourceFile(.{ .file = wrapper, .flags = flags.items });
        } else {
            module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/gpupixel/src/{s}", .{file})), .flags = flags.items });
        }
    }
    if (target.result.abi.isAndroid()) {
        module.addCSourceFile(.{ .file = b.path(".vendor/gpupixel/src/sink/sink_surface.cc"), .flags = flags.items });
    }

    module.linkLibrary(buildLibyuvLib(b, target, optimize, libc));

    // The engine's c boundary compiles into the same archive.
    if (apple) {
        module.addCSourceFile(.{ .file = b.path("adapters/beauty/beauty_shim_apple.mm"), .flags = flags.items });
        module.addCSourceFile(.{ .file = b.path("adapters/beauty/interop_apple.mm"), .flags = flags.items });
        module.linkFramework("CoreVideo", .{});
        if (os == .macos) module.linkFramework("OpenGL", .{});
        // Real OpenGL ES is gone on current iOS hardware; ANGLE's
        // EGL/GLES-over-Metal backend stands in (see buildAngleLib).
        if (os == .ios) module.linkLibrary(buildAngleLib(b, target, optimize));
    } else {
        module.addCSourceFile(.{ .file = b.path("adapters/beauty/beauty_shim.cc"), .flags = flags.items });
        if (target.result.abi.isAndroid()) {
            module.addCSourceFile(.{ .file = b.path("adapters/beauty/interop_android.cc"), .flags = flags.items });
        }
    }

    const lib = b.addLibrary(.{ .name = "gpupixel", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

// The color converter the beauty engine's raw sinks call into, from the
// engine's own tree. Its row kernels carry inline assembly for the newer
// vector instructions with runtime dispatch deciding what executes, so the
// module compiles with those features available; the scalable extensions
// stay out entirely.
// Jolt compiles from source under the one build orchestration - the
// samples and their proprietary Assets/ never enter the build (see the
// decisions record). Single-threaded determinism is the harness's own
// job-system choice at runtime, not a compile flag.
fn buildJoltLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.link_libcpp = true;
    module.addIncludePath(b.path(".vendor/jolt"));
    var sources: std.ArrayList([]const u8) = .empty;
    listFilesRecursive(b, ".vendor/jolt/Jolt", ".cpp", &.{}, &sources);
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const flags = [_][]const u8{ "-std=c++17", "-fno-sanitize=undefined", "-w", "-DJPH_USE_CPU_COMPUTE" };
    for (sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &flags });
    }
    return b.addLibrary(.{ .name = "jolt", .linkage = .static, .root_module = module });
}

fn buildLibyuvLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const root = ".vendor/libyuv";
    const yuv_target = if (target.result.cpu.arch == .aarch64) blk: {
        var query = target.query;
        query.cpu_model = .baseline;
        query.cpu_features_add = std.Target.aarch64.featureSet(&.{ .dotprod, .i8mm });
        break :blk b.resolveTargetQuery(query);
    } else target;
    const module = b.createModule(.{ .target = yuv_target, .optimize = optimize });
    module.link_libc = true;
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) {
        module.pic = true;
        // The pinned libyuv pulls libc headers gpupixel's older bundled
        // copy never did; like every other android C++ module, it needs
        // the NDK sysroot includes.
        if (ndkSysroot(b)) |sysroot| addNdkPaths(b, module, sysroot);
    }
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    module.addIncludePath(b.path(b.fmt("{s}/include", .{root})));
    var yuv_sources: std.ArrayList([]const u8) = .empty;
    listFilesRecursive(b, b.fmt("{s}/source", .{root}), ".cc", &.{
        "_test", "_unittest", "mjpeg",
    }, &yuv_sources);
    std.mem.sort([]const u8, yuv_sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const yuv_flags = [_][]const u8{
        "-std=c++17",           "-fno-sanitize=undefined", "-w",
        "-DLIBYUV_DISABLE_SVE", "-DLIBYUV_DISABLE_SME",
    };
    for (yuv_sources.items) |file| {
        module.addCSourceFile(.{ .file = b.path(file), .flags = &yuv_flags });
    }
    const lib = b.addLibrary(.{ .name = "yuv", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildFlatbuffersLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    if (target.result.cpu.arch.isWasm()) module.addIncludePath(b.path("adapters/tracking/wasi_std"));
    module.addIncludePath(b.path(".vendor/flatbuffers/include"));
    module.addCSourceFile(.{
        .file = b.path(".vendor/flatbuffers/src/util.cpp"),
        .flags = if (target.result.cpu.arch.isWasm())
            &.{ "-std=c++17", "-fno-sanitize=undefined", "-w", "-fno-exceptions" }
        else
            &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" },
    });
    const lib = b.addLibrary(.{ .name = "flatbuffers", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildFarmhashLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    module.addIncludePath(b.path(".vendor/farmhash/src"));
    module.addCSourceFile(.{
        .file = b.path(".vendor/farmhash/src/farmhash.cc"),
        .flags = &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" },
    });
    const lib = b.addLibrary(.{ .name = "farmhash", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

// Reads one SET(<name> ...) source list out of a cmake file in a pinned
// tree. The generated microkernel lists are the runtime's own source of
// truth for what compiles on each processor; parsing them keeps this build
// aligned with the pin instead of a hand-copied snapshot that would rot.
fn cmakeSourceList(b: *std.Build, root: []const u8, cmake_path: []const u8, var_name: []const u8, out: *std.ArrayList([]const u8)) void {
    const text = b.build_root.handle.readFileAlloc(b.graph.io, cmake_path, b.allocator, .limited(8 << 20)) catch
        std.debug.panic("unreadable cmake list {s}", .{cmake_path});
    const open = b.fmt("SET({s}", .{var_name});
    var search: usize = 0;
    const body_start = while (std.mem.indexOfPos(u8, text, search, open)) |at| {
        const after = at + open.len;
        if (after < text.len and std.ascii.isWhitespace(text[after])) break after;
        search = at + 1;
    } else std.debug.panic("{s} not found in {s}", .{ var_name, cmake_path });
    var tokens = std.mem.tokenizeAny(u8, text[body_start..], " \t\r\n");
    while (tokens.next()) |raw| {
        var token = raw;
        const closes = std.mem.endsWith(u8, token, ")");
        if (closes) token = token[0 .. token.len - 1];
        // Entries referencing cmake variables (the generated identifier
        // file) are produced by this build separately.
        if (token.len > 0 and std.mem.indexOfScalar(u8, token, '$') == null) {
            out.append(b.allocator, b.fmt("{s}/{s}", .{ root, token })) catch @panic("oom");
        }
        if (closes) return;
    }
    std.debug.panic("unterminated {s} in {s}", .{ var_name, cmake_path });
}

fn is_wasm_arch(target: std.Build.ResolvedTarget) bool {
    return target.result.cpu.arch.isWasm();
}

const XnnpackFamily = struct {
    list: []const u8,
    variable: []const u8,
    features: std.Target.Cpu.Feature.Set = std.Target.Cpu.Feature.Set.empty,
    exclude_contains: []const []const u8 = &.{},
};

// Production microkernel families per processor, each with the cpu features
// its sources require. Dispatch picks among them at runtime from detected
// features, so every family compiles into its own archive built for exactly
// that feature set; a family must never leak instructions into another.
const aarch64_feature = std.Target.aarch64.featureSet;
const xnnpack_aarch64_families = [_]XnnpackFamily{
    .{ .list = "scalar_microkernels.cmake", .variable = "PROD_SCALAR_MICROKERNEL_SRCS" },
    .{ .list = "neon_microkernels.cmake", .variable = "PROD_NEON_MICROKERNEL_SRCS" },
    .{ .list = "neonfp16_microkernels.cmake", .variable = "PROD_NEONFP16_MICROKERNEL_SRCS" },
    .{ .list = "neonfma_microkernels.cmake", .variable = "PROD_NEONFMA_MICROKERNEL_SRCS" },
    .{ .list = "neonv8_microkernels.cmake", .variable = "PROD_NEONV8_MICROKERNEL_SRCS" },
    .{ .list = "neon_aarch64_microkernels.cmake", .variable = "PROD_NEON_AARCH64_MICROKERNEL_SRCS" },
    .{ .list = "neonfma_aarch64_microkernels.cmake", .variable = "PROD_NEONFMA_AARCH64_MICROKERNEL_SRCS" },
    .{ .list = "fp16arith_microkernels.cmake", .variable = "PROD_FP16ARITH_MICROKERNEL_SRCS", .features = aarch64_feature(&.{.fullfp16}) },
    .{ .list = "neonfp16arith_microkernels.cmake", .variable = "PROD_NEONFP16ARITH_MICROKERNEL_SRCS", .features = aarch64_feature(&.{.fullfp16}) },
    .{ .list = "neonfp16arith_aarch64_microkernels.cmake", .variable = "PROD_NEONFP16ARITH_AARCH64_MICROKERNEL_SRCS", .features = aarch64_feature(&.{.fullfp16}) },
    .{ .list = "neondot_microkernels.cmake", .variable = "PROD_NEONDOT_MICROKERNEL_SRCS", .features = aarch64_feature(&.{.dotprod}) },
    .{ .list = "neondot_aarch64_microkernels.cmake", .variable = "PROD_NEONDOT_AARCH64_MICROKERNEL_SRCS", .features = aarch64_feature(&.{.dotprod}) },
    .{ .list = "neondotfp16arith_microkernels.cmake", .variable = "PROD_NEONDOTFP16ARITH_MICROKERNEL_SRCS", .features = aarch64_feature(&.{ .dotprod, .fullfp16 }) },
    .{ .list = "neoni8mm_microkernels.cmake", .variable = "PROD_NEONI8MM_MICROKERNEL_SRCS", .features = aarch64_feature(&.{ .i8mm, .fullfp16 }) },
    .{ .list = "aarch64_microkernels.cmake", .variable = "PROD_AARCH64_ASM_MICROKERNEL_SRCS", .features = aarch64_feature(&.{ .fullfp16, .dotprod }) },
};

const x86_feature = std.Target.x86.featureSet;
const x86_avx512_base = [_]std.Target.x86.Feature{ .f16c, .fma, .avx512f, .avx512cd, .avx512bw, .avx512dq, .avx512vl };
const xnnpack_x86_64_families = [_]XnnpackFamily{
    .{ .list = "scalar_microkernels.cmake", .variable = "PROD_SCALAR_MICROKERNEL_SRCS" },
    .{ .list = "sse_microkernels.cmake", .variable = "PROD_SSE_MICROKERNEL_SRCS" },
    .{ .list = "sse2_microkernels.cmake", .variable = "PROD_SSE2_MICROKERNEL_SRCS" },
    .{ .list = "sse2fma_microkernels.cmake", .variable = "PROD_SSE2FMA_MICROKERNEL_SRCS" },
    .{ .list = "ssse3_microkernels.cmake", .variable = "PROD_SSSE3_MICROKERNEL_SRCS", .features = x86_feature(&.{.ssse3}) },
    .{ .list = "sse41_microkernels.cmake", .variable = "PROD_SSE41_MICROKERNEL_SRCS", .features = x86_feature(&.{.sse4_1}) },
    .{ .list = "avx_microkernels.cmake", .variable = "PROD_AVX_MICROKERNEL_SRCS", .features = x86_feature(&.{.avx}) },
    .{ .list = "f16c_microkernels.cmake", .variable = "PROD_F16C_MICROKERNEL_SRCS", .features = x86_feature(&.{.f16c}) },
    .{ .list = "fma3_microkernels.cmake", .variable = "PROD_FMA3_MICROKERNEL_SRCS", .features = x86_feature(&.{ .f16c, .fma }) },
    .{ .list = "avx2_microkernels.cmake", .variable = "PROD_AVX2_MICROKERNEL_SRCS", .features = x86_feature(&.{ .f16c, .fma, .avx2 }) },
    .{ .list = "avx256skx_microkernels.cmake", .variable = "PROD_AVX256SKX_MICROKERNEL_SRCS", .features = x86_feature(&x86_avx512_base) },
    .{ .list = "avx256vnni_microkernels.cmake", .variable = "PROD_AVX256VNNI_MICROKERNEL_SRCS", .features = x86_feature(&(x86_avx512_base ++ [_]std.Target.x86.Feature{.avx512vnni})) },
    .{ .list = "avx512f_microkernels.cmake", .variable = "PROD_AVX512F_MICROKERNEL_SRCS", .features = x86_feature(&.{.avx512f}) },
    .{ .list = "avx512skx_microkernels.cmake", .variable = "PROD_AVX512SKX_MICROKERNEL_SRCS", .features = x86_feature(&x86_avx512_base) },
    .{ .list = "avx512vbmi_microkernels.cmake", .variable = "PROD_AVX512VBMI_MICROKERNEL_SRCS", .features = x86_feature(&(x86_avx512_base ++ [_]std.Target.x86.Feature{.avx512vbmi})) },
    .{ .list = "avx512vnni_microkernels.cmake", .variable = "PROD_AVX512VNNI_MICROKERNEL_SRCS", .features = x86_feature(&(x86_avx512_base ++ [_]std.Target.x86.Feature{.avx512vnni})) },
};

const wasm_feature = std.Target.wasm.featureSet;
const xnnpack_wasm_families = [_]XnnpackFamily{
    .{ .list = "scalar_microkernels.cmake", .variable = "PROD_SCALAR_MICROKERNEL_SRCS" },
    .{ .list = "wasmsimd_microkernels.cmake", .variable = "PROD_WASMSIMD_MICROKERNEL_SRCS", .features = wasm_feature(&.{.simd128}) },
    // The pure half precision math kernels use instructions browsers do
    // not validate yet; the ones converting to and from full precision
    // stay, and the config never selects the excluded ones while their
    // toggle is off.
    .{ .list = "wasmrelaxedsimd_microkernels.cmake", .variable = "PROD_WASMRELAXEDSIMD_MICROKERNEL_SRCS", .features = wasm_feature(&.{ .simd128, .relaxed_simd }), .exclude_contains = &.{"/gen/f16-v"} },
};

// The inference runtime's cpu backend as one static archive: the shared
// library groups from the runtime's build plus the production microkernels
// for the target processor. The build identifier the weight cache checks
// is derived from the vendor pin, so it changes exactly when the vendored
// revision does.
fn xnnpackConfigureModule(b: *std.Build, module: *std.Build.Module, target: std.Build.ResolvedTarget) void {
    module.link_libc = true;
    module.link_libcpp = true;
    if (target.result.cpu.arch.isWasm()) {
        module.addIncludePath(b.path("adapters/tracking/wasi_std"));
        // The web target maps memory through the engine, never a memory
        // mapping syscall.
        module.addCMacro("XNN_HAS_MMAP", "0");
    }
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    for ([_][]const u8{
        ".vendor/xnnpack",             ".vendor/xnnpack/include", ".vendor/xnnpack/src",
        ".vendor/pthreadpool/include",
        ".vendor/fxdiv/include",       ".vendor/fp16/include", ".vendor/cpuinfo/include",
    }) |dir| {
        module.addIncludePath(b.path(dir));
    }
    const arch = target.result.cpu.arch;
    const is_arm = arch == .aarch64;
    const is_x86 = arch == .x86_64;
    const toggles = [_]struct { name: []const u8, on: bool }{
        .{ .name = "XNN_ENABLE_ARM_FP16_VECTOR", .on = is_arm },
        .{ .name = "XNN_ENABLE_ARM_FP16_SCALAR", .on = is_arm },
        .{ .name = "XNN_ENABLE_ARM_BF16", .on = false },
        .{ .name = "XNN_ENABLE_ARM_DOTPROD", .on = is_arm },
        .{ .name = "XNN_ENABLE_ARM_I8MM", .on = is_arm },
        .{ .name = "XNN_ENABLE_ARM_SME", .on = false },
        .{ .name = "XNN_ENABLE_ARM_SME2", .on = false },
        .{ .name = "XNN_ENABLE_RISCV_VECTOR", .on = false },
        .{ .name = "XNN_ENABLE_RISCV_FP16_VECTOR", .on = false },
        .{ .name = "XNN_ENABLE_SSE", .on = is_x86 },
        .{ .name = "XNN_ENABLE_SSE2", .on = is_x86 },
        .{ .name = "XNN_ENABLE_SSSE3", .on = is_x86 },
        .{ .name = "XNN_ENABLE_SSE41", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX", .on = is_x86 },
        .{ .name = "XNN_ENABLE_F16C", .on = is_x86 },
        .{ .name = "XNN_ENABLE_FMA3", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX2", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVXVNNI", .on = false },
        .{ .name = "XNN_ENABLE_AVXVNNIINT8", .on = false },
        .{ .name = "XNN_ENABLE_AVX256SKX", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX256VNNI", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX256VNNIGFNI", .on = false },
        .{ .name = "XNN_ENABLE_AVX512F", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX512SKX", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX512VBMI", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX512VNNI", .on = is_x86 },
        .{ .name = "XNN_ENABLE_AVX512VNNIGFNI", .on = false },
        .{ .name = "XNN_ENABLE_AVX512AMX", .on = false },
        .{ .name = "XNN_ENABLE_AVX512FP16", .on = false },
        .{ .name = "XNN_ENABLE_AVX512BF16", .on = false },
        .{ .name = "XNN_ENABLE_WASMRELAXEDSIMDFP16", .on = false },
        .{ .name = "XNN_ENABLE_VSX", .on = false },
        .{ .name = "XNN_ENABLE_HVX", .on = false },
        .{ .name = "XNN_ENABLE_ASSEMBLY", .on = is_arm },
        .{ .name = "XNN_ENABLE_SPARSE", .on = true },
        .{ .name = "XNN_ENABLE_RNDNU16", .on = false },
        .{ .name = "XNN_ENABLE_KLEIDIAI", .on = false },
        .{ .name = "XNN_ENABLE_WASM_REVECTORIZE", .on = false },
        .{ .name = "XNN_ENABLE_CPUINFO", .on = !arch.isWasm() },
        .{ .name = "XNN_LOG_LEVEL", .on = false },
    };
    for (toggles) |toggle| {
        module.addCMacro(toggle.name, if (toggle.on) "1" else "0");
    }
    if (target.result.os.tag == .linux) module.addCMacro("_GNU_SOURCE", "1");
}

fn buildXnnpackLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath, family_sink: ?*std.ArrayList(*std.Build.Step.Compile)) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    xnnpackConfigureModule(b, module, target);
    const is_arm = target.result.cpu.arch == .aarch64;
    const is_x86 = target.result.cpu.arch == .x86_64;

    var shared: std.ArrayList([]const u8) = .empty;
    for ([_][]const u8{ "OPERATOR_SRCS", "REFERENCE_SRCS", "SUBGRAPH_SRCS", "LOGGING_SRCS", "XNNPACK_SRCS", "TABLE_SRCS" }) |group| {
        cmakeSourceList(b, ".vendor/xnnpack", ".vendor/xnnpack/CMakeLists.txt", group, &shared);
    }
    for ([_][]const u8{
        "src/sanitizers.c",       "src/configs/hardware-config.c",     "src/xnnpack/init-once.c",
        "src/indirection.c",      "src/microparams-init.c",            "src/normalization.c",
        "src/pack-lh.cc",         "src/reference/packing.cc",          "src/allocator.c",
        "src/cache.c",            "src/datatype.c",                    "src/operators/fingerprint_id.c",
        "src/operators/fingerprint_cache.c", "src/xnnpack/fingerprint_check.c", "src/memory.c",
        "src/microkernel-utils.c", "src/mutex.c",                      "src/operator-run.c",
        "src/operator-utils.c",
    }) |file| {
        shared.append(b.allocator, b.fmt(".vendor/xnnpack/{s}", .{file})) catch @panic("oom");
    }
    const c_flags = [_][]const u8{ "-std=gnu99", "-fno-sanitize=undefined", "-w" };
    var xnn_cxx: std.ArrayList([]const u8) = .empty;
    xnn_cxx.appendSlice(b.allocator, &.{ "-std=c++17", "-fno-sanitize=undefined", "-w" }) catch @panic("oom");
    if (is_wasm_arch(target)) xnn_cxx.append(b.allocator, "-fno-exceptions") catch @panic("oom");
    const cxx_flags = xnn_cxx.items;
    var seen = std.StringHashMap(void).init(b.allocator);
    for (shared.items) |file| {
        if ((seen.getOrPut(file) catch @panic("oom")).found_existing) continue;
        const flags: []const []const u8 = if (std.mem.endsWith(u8, file, ".cc")) cxx_flags else &c_flags;
        module.addCSourceFile(.{ .file = b.path(file), .flags = flags });
    }

    var micro_c_flags: std.ArrayList([]const u8) = .empty;
    micro_c_flags.appendSlice(b.allocator, &c_flags) catch @panic("oom");
    micro_c_flags.append(b.allocator, "-fno-math-errno") catch @panic("oom");
    if (is_x86) {
        micro_c_flags.appendSlice(b.allocator, &.{ "-mstack-alignment=64", "-fomit-frame-pointer", "-mstackrealign" }) catch @panic("oom");
    }
    const families: []const XnnpackFamily = if (is_arm)
        &xnnpack_aarch64_families
    else if (target.result.cpu.arch.isWasm())
        &xnnpack_wasm_families
    else
        &xnnpack_x86_64_families;
    for (families) |family| {
        const wants_features = !family.features.eql(std.Target.Cpu.Feature.Set.empty);
        const family_module = if (wants_features) blk: {
            var query = target.query;
            query.cpu_model = .baseline;
            query.cpu_features_add = family.features;
            const family_target = b.resolveTargetQuery(query);
            const family_module = b.createModule(.{ .target = family_target, .optimize = optimize });
            xnnpackConfigureModule(b, family_module, family_target);
            break :blk family_module;
        } else module;
        var sources: std.ArrayList([]const u8) = .empty;
        cmakeSourceList(b, ".vendor/xnnpack", b.fmt(".vendor/xnnpack/cmake/gen/{s}", .{family.list}), family.variable, &sources);
        var added = false;
        family_files: for (sources.items) |file| {
            if ((seen.getOrPut(file) catch @panic("oom")).found_existing) continue;
            for (family.exclude_contains) |pattern| {
                if (std.mem.indexOf(u8, file, pattern) != null) continue :family_files;
            }
            // Assembly runs through the integrated assembler, which takes
            // its instruction set from the architecture flag, not from the
            // module's cpu features.
            const flags: []const []const u8 = if (std.mem.endsWith(u8, file, ".cc"))
                cxx_flags
            else if (std.mem.endsWith(u8, file, ".S"))
                &[_][]const u8{ "-w", "-march=armv8.2-a+fp16+dotprod" }
            else
                micro_c_flags.items;
            family_module.addCSourceFile(.{ .file = b.path(file), .flags = flags });
            added = true;
        }
        if (wants_features and added) {
            const family_name = family.list[0 .. family.list.len - "_microkernels.cmake".len];
            const family_lib = b.addLibrary(.{
                .name = b.fmt("xnnpack-{s}", .{family_name}),
                .linkage = .static,
                .root_module = family_module,
            });
            if (libc) |file| family_lib.setLibCFile(file);
            if (family_sink) |sink| sink.append(b.allocator, family_lib) catch @panic("oom");
            module.linkLibrary(family_lib);
        }
    }

    const pin_text = b.build_root.handle.readFileAlloc(b.graph.io, "third_party/xnnpack/pin.zon", b.allocator, .limited(4096)) catch @panic("xnnpack pin unreadable");
    var digest: [std.crypto.hash.sha2.Sha256.digest_length]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(pin_text, &digest, .{});
    var id_source: std.ArrayList(u8) = .empty;
    id_source.appendSlice(b.allocator,
        \\#include <stdbool.h>
        \\#include <stdint.h>
        \\#include <stddef.h>
        \\#include <string.h>
        \\
        \\static const uint8_t xnn_build_identifier[] = {
        \\
    ) catch @panic("oom");
    for (digest, 0..) |byte, index| {
        id_source.appendSlice(b.allocator, b.fmt("{s}{d},", .{ if (index == 0) "  " else " ", byte })) catch @panic("oom");
    }
    id_source.appendSlice(b.allocator,
        \\
        \\};
        \\
        \\size_t xnn_experimental_get_build_identifier_size(void) {
        \\  return sizeof(xnn_build_identifier);
        \\}
        \\
        \\const void* xnn_experimental_get_build_identifier_data(void) {
        \\  return xnn_build_identifier;
        \\}
        \\
        \\bool xnn_experimental_check_build_identifier(const void* data, const size_t size) {
        \\  if (size != xnn_experimental_get_build_identifier_size()) {
        \\    return false;
        \\  }
        \\  return !memcmp(data, xnn_build_identifier, size);
        \\}
        \\
    ) catch @panic("oom");
    const identifier_file = b.addWriteFiles().add("xnnpack_build_identifier.c", id_source.items);
    module.addCSourceFile(.{ .file = identifier_file, .flags = &c_flags });

    const lib = b.addLibrary(.{ .name = "xnnpack", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

fn buildFft2dLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    const flags = [_][]const u8{ "-std=gnu99", "-fno-sanitize=undefined", "-w" };
    for ([_][]const u8{ "alloc.c", "fftsg.c", "fftsg2d.c" }) |file| {
        module.addCSourceFile(.{ .file = b.path(b.fmt(".vendor/fft2d/{s}", .{file})), .flags = &flags });
    }
    const lib = b.addLibrary(.{ .name = "fft2d", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
}

// One directory of runtime sources, mirroring the pinned build's shallow
// globs: every .c and .cc directly in the directory, minus test and tool
// files. Exclusions match on the file name.
const TfliteGroup = struct {
    dir: []const u8,
    exclude_contains: []const []const u8 = &.{},
    exclude_prefix: []const []const u8 = &.{},
};

const tflite_groups = [_]TfliteGroup{
    .{ .dir = ".", .exclude_contains = &.{ "tflite_with_xnnpack.", "with_selected_ops.", "tensorflow_profiler_logger.", "minimal_logging_" } },
    .{ .dir = "core" },
    .{ .dir = "core/acceleration/configuration", .exclude_contains = &.{"xnnpack_plugin"} },
    .{ .dir = "core/api" },
    .{ .dir = "core/async" },
    .{ .dir = "core/async/c" },
    .{ .dir = "core/async/interop" },
    .{ .dir = "core/async/interop/c" },
    .{ .dir = "core/c" },
    .{ .dir = "core/experimental/acceleration/configuration" },
    .{ .dir = "core/kernels" },
    .{ .dir = "core/tools" },
    .{ .dir = "c" },
    .{ .dir = "delegates" },
    .{ .dir = "delegates/external", .exclude_contains = &.{"_tester."} },
    .{ .dir = "delegates/xnnpack", .exclude_contains = &.{"_tester."} },
    .{ .dir = "experimental/remat" },
    .{ .dir = "experimental/resource" },
    .{ .dir = "kernels", .exclude_contains = &.{ "_test_util_internal.", "_ops_wrapper." }, .exclude_prefix = &.{"test_"} },
    .{ .dir = "kernels/internal" },
    .{ .dir = "kernels/internal/optimized" },
    .{ .dir = "kernels/internal/optimized/integer_ops" },
    .{ .dir = "kernels/internal/optimized/sparse_ops" },
    .{ .dir = "kernels/internal/optimized/4bit", .exclude_contains = &.{ "neon_", "sse_" } },
    .{ .dir = "kernels/internal/reference" },
    .{ .dir = "kernels/internal/reference/integer_ops" },
    .{ .dir = "kernels/internal/reference/sparse_ops" },
};

fn tfliteGroupSources(b: *std.Build, group: TfliteGroup, out: *std.ArrayList([]const u8)) void {
    const dir_path = if (std.mem.eql(u8, group.dir, "."))
        ".vendor/litert/tflite"
    else
        b.fmt(".vendor/litert/tflite/{s}", .{group.dir});
    // A directory absent from the pinned tree is an empty group, exactly
    // like the shallow glob it mirrors.
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(b.graph.io);
    var it = dir.iterate();
    files: while (it.next(b.graph.io) catch null) |entry| {
        if (entry.kind != .file) continue;
        const name = entry.name;
        if (!std.mem.endsWith(u8, name, ".c") and !std.mem.endsWith(u8, name, ".cc")) continue;
        const stem = name[0 .. std.mem.lastIndexOfScalar(u8, name, '.').?];
        if (std.mem.endsWith(u8, stem, "_test") or std.mem.endsWith(u8, stem, "test_util")) continue;
        for (group.exclude_contains) |pattern| {
            if (std.mem.indexOf(u8, name, pattern) != null) continue :files;
        }
        for (group.exclude_prefix) |pattern| {
            if (std.mem.startsWith(u8, name, pattern)) continue :files;
        }
        out.append(b.allocator, b.fmt("{s}/{s}", .{ dir_path, name })) catch @panic("oom");
    }
}

// The inference runtime itself: interpreter, builtin kernels, and the cpu
// delegate, aggregated the same way the pinned build does. Graph rewriting
// pieces the runtime still reaches for live in the sibling tensorflow pin.
fn buildTfliteLib(b: *std.Build, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode, flatc: *std.Build.Step.Compile, libc: ?std.Build.LazyPath) *std.Build.Step.Compile {
    const module = b.createModule(.{ .target = target, .optimize = optimize });
    module.link_libc = true;
    module.link_libcpp = true;
    if (target.result.abi.isAndroid()) module.pic = true;
    if (target.result.os.tag == .ios) addAppleSdkPaths(b, module);
    // The single-thread standard thread surface: the wasi standard library
    // omits these headers, and this module runs on one thread by design.
    var wasm_compat_flags: []const []const u8 = &.{};
    if (target.result.cpu.arch.isWasm()) {
        module.addIncludePath(b.path("adapters/tracking/wasi_std"));
        module.addCMacro("TFLITE_MMAP_DISABLED", "1");
        module.addCMacro("_WASI_EMULATED_MMAN", "1");
        wasm_compat_flags = &.{ "-include", b.pathFromRoot("adapters/tracking/wasi_std/wasi_compat.h") };
    }
    for ([_][]const u8{
        ".vendor/litert",           ".vendor/tensorflow",          ".vendor/tensorflow/third_party/xla",
        ".vendor/flatbuffers/include",
        ".vendor/abseil",           ".vendor/eigen",               ".vendor/ruy",
        ".vendor/gemmlowp",         ".vendor/ml-dtypes",           ".vendor/farmhash/src",
        ".vendor/neon2sse",
        ".vendor/cpuinfo/include",  ".vendor/pthreadpool/include", ".vendor/xnnpack",
        ".vendor/xnnpack/include",  ".vendor/fp16/include",
    }) |dir| {
        module.addIncludePath(b.path(dir));
    }

    // The cpu delegate checks its weight cache against a schema compiled at
    // build time by the pinned flatbuffers compiler.
    const schema_run = b.addRunArtifact(flatc);
    schema_run.addArgs(&.{ "-c", "--gen-mutable", "--gen-object-api", "-o" });
    const schema_out = schema_run.addOutputDirectoryArg("weight_cache_schema");
    schema_run.addFileArg(b.path(".vendor/litert/tflite/delegates/xnnpack/weight_cache_schema.fbs"));
    const generated = b.addWriteFiles();
    _ = generated.addCopyFile(schema_out.path(b, "weight_cache_schema_generated.h"), "tflite/delegates/xnnpack/weight_cache_schema_generated.h");
    module.addIncludePath(generated.getDirectory());

    module.addCMacro("EIGEN_NEON_GEBP_NR", "4");
    module.addCMacro("TFLITE_WITH_RUY", "1");
    module.addCMacro("TFLITE_KERNEL_USE_XNNPACK", "1");
    module.addCMacro("TFLITE_BUILD_WITH_XNNPACK_DELEGATE", "1");
    module.addCMacro("XNNPACK_DELEGATE_ENABLE_QS8", "1");
    module.addCMacro("XNNPACK_DELEGATE_ENABLE_QU8", "1");
    module.addCMacro("XNNPACK_DELEGATE_USE_LATEST_OPS", "1");
    module.addCMacro("XNNPACK_DELEGATE_ENABLE_SUBGRAPH_RESHAPING", "1");
    module.addCMacro("TFL_STATIC_LIBRARY_BUILD", "1");
    module.addCMacro("TF_MAJOR_VERSION", "2");
    module.addCMacro("TF_MINOR_VERSION", "19");
    module.addCMacro("TF_PATCH_VERSION", "0");
    module.addCMacro("TF_VERSION_SUFFIX", "\"\"");

    var sources: std.ArrayList([]const u8) = .empty;
    for (tflite_groups) |group| {
        tfliteGroupSources(b, group, &sources);
    }
    const os = target.result.os.tag;
    const logging_source: []const u8 = switch (os) {
        .ios => "minimal_logging_ios.cc",
        else => if (target.result.abi.isAndroid()) "minimal_logging_android.cc" else "minimal_logging_default.cc",
    };
    for ([_][]const u8{
        "delegates/nnapi/nnapi_delegate_disabled.cc",
        "nnapi/nnapi_implementation_disabled.cc",
        "profiling/platform_profiler.cc",
        "profiling/root_profiler.cc",
        "profiling/telemetry/profiler.cc",
        "profiling/telemetry/telemetry.cc",
        "profiling/telemetry/c/telemetry_setting_internal.cc",
        "kernels/internal/utils/sparsity_format_converter.cc",
    }) |file| {
        sources.append(b.allocator, b.fmt(".vendor/litert/tflite/{s}", .{file})) catch @panic("oom");
    }
    sources.append(b.allocator, b.fmt(".vendor/litert/tflite/{s}", .{logging_source})) catch @panic("oom");
    if (target.result.abi.isAndroid()) {
        sources.append(b.allocator, ".vendor/litert/tflite/profiling/atrace_profiler.cc") catch @panic("oom");
    }
    for ([_][]const u8{
        "compiler/mlir/lite/allocation.cc",
        "compiler/mlir/lite/core/api/error_reporter.cc",
        "compiler/mlir/lite/core/api/flatbuffer_conversions.cc",
        "compiler/mlir/lite/core/model_builder_base.cc",
        "compiler/mlir/lite/experimental/remat/metadata_util.cc",
        if (target.result.cpu.arch.isWasm()) "compiler/mlir/lite/mmap_allocation_disabled.cc" else "compiler/mlir/lite/mmap_allocation.cc",
        "compiler/mlir/lite/schema/schema_utils.cc",
        "compiler/mlir/lite/utils/string_utils.cc",
    }) |file| {
        sources.append(b.allocator, b.fmt(".vendor/tensorflow/tensorflow/{s}", .{file})) catch @panic("oom");
    }
    std.mem.sort([]const u8, sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    const c_flags = [_][]const u8{ "-std=gnu99", "-fno-sanitize=undefined", "-w" };
    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(b.allocator, &.{ "-std=c++20", "-fno-sanitize=undefined", "-w" }) catch @panic("oom");
    if (target.result.cpu.arch.isWasm()) cxx_flags.append(b.allocator, "-fno-exceptions") catch @panic("oom");
    cxx_flags.appendSlice(b.allocator, wasm_compat_flags) catch @panic("oom");
    if (target.result.cpu.arch == .x86_64) {
        cxx_flags.appendSlice(b.allocator, &.{ "-include", immintrinPath(b) }) catch @panic("oom");
    }
    for (sources.items) |file| {
        const flags: []const []const u8 = if (std.mem.endsWith(u8, file, ".c")) &c_flags else cxx_flags.items;
        module.addCSourceFile(.{ .file = b.path(file), .flags = flags });
    }
    if (os == .ios) {
        module.addCSourceFile(.{
            .file = b.path(".vendor/litert/tflite/profiling/signpost_profiler.mm"),
            .flags = &.{ "-std=c++20", "-fno-sanitize=undefined", "-w", "-fno-objc-arc" },
        });
    }
    const lib = b.addLibrary(.{ .name = "tflite", .linkage = .static, .root_module = module });
    if (libc) |file| lib.setLibCFile(file);
    return lib;
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

/// The active iOS SDK path (iPhoneOS for device, iPhoneSimulator for the
/// simulator variant), taken from whichever of the two ios-*-sdk options
/// the currently-running addIosStepImpl call set, so it reaches exactly
/// the apple-target modules that call built while it was set - a graph-
/// wide sysroot would leak into the host tools compiled along the way.
/// Safe as a single mutable global because the build script runs the
/// device and simulator phases sequentially, never interleaved: each
/// phase's own modules read this only during their own synchronous
/// construction.
var apple_sdk: ?[]const u8 = null;

fn addAppleSdkPaths(b: *std.Build, module: *std.Build.Module) void {
    const sdk = apple_sdk orelse b.sysroot orelse return;
    module.addSystemIncludePath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "include" }) });
    module.addLibraryPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "usr", "lib" }) });
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "Frameworks" }) });
    // Newer sdks split pieces of the ui frameworks into sub frameworks.
    module.addSystemFrameworkPath(.{ .cwd_relative = b.pathJoin(&.{ sdk, "System", "Library", "SubFrameworks" }) });
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

// Every immediate subdirectory of lenses/reference/ is one reference
// lens bundle. Missing the directory entirely (a fresh checkout before
// any reference lens exists) is not an error - an empty list.
fn listReferenceLenses(b: *std.Build) [][]const u8 {
    const dir_path = "lenses/reference";
    var dir = b.build_root.handle.openDir(b.graph.io, dir_path, .{ .iterate = true }) catch return &.{};
    defer dir.close(b.graph.io);
    var lenses: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (it.next(b.graph.io) catch return &.{}) |entry| {
        if (entry.kind != .directory) continue;
        lenses.append(b.allocator, b.fmt("{s}/{s}", .{ dir_path, entry.name })) catch @panic("oom");
    }
    std.mem.sort([]const u8, lenses.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    return lenses.items;
}

// The pinned toolchain is the only toolchain: .zigversion is the single place
// the version is written, and a mismatching compiler fails closed here. The
// shadow lane (weekly build against Zig master) is the one sanctioned bypass,
// via GOSS_ALLOW_ZIG_MISMATCH=1.
fn addIosStep(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile, flatc_exe: ?*std.Build.Step.Compile) void {
    addIosStepImpl(b, optimize, shaderc_exe, flatc_exe, .{
        .abi = .none,
        .sdk_option_name = "ios-sdk",
        .sdk_name = "iPhoneOS",
        .xcrun_sdk = "iphoneos",
        .install_dir = "ios",
        .step_name = "ios",
        .step_description = "Build gosslens and bgfx static libraries for iOS devices",
    });
}

/// The simulator variant of addIosStep, for exactly the same libraries
/// built against Zig's aarch64-ios-simulator target instead of device -
/// what a conformance run needs, since it proves determinism through a
/// real Swift SDK on a real (if not physical) window without the
/// Apple-ID/device-install gate a device run needs. Kept as one shared
/// implementation rather than a duplicate function: every module/vendor
/// build call below would otherwise drift in lockstep by hand, the same
/// reason a lens's own render passes share one draw-order function
/// instead of one per node kind.
fn addIosSimulatorStep(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile, flatc_exe: ?*std.Build.Step.Compile) void {
    addIosStepImpl(b, optimize, shaderc_exe, flatc_exe, .{
        .abi = .simulator,
        .sdk_option_name = "ios-simulator-sdk",
        .sdk_name = "iPhoneSimulator",
        .xcrun_sdk = "iphonesimulator",
        .install_dir = "ios-simulator",
        .step_name = "ios-simulator",
        .step_description = "Build gosslens and bgfx static libraries for the iOS Simulator",
    });
}

const IosStepConfig = struct {
    abi: std.Target.Abi,
    sdk_option_name: []const u8,
    sdk_name: []const u8,
    xcrun_sdk: []const u8,
    install_dir: []const u8,
    step_name: []const u8,
    step_description: []const u8,
};

fn addIosStepImpl(b: *std.Build, optimize: std.builtin.OptimizeMode, shaderc_exe: ?*std.Build.Step.Compile, flatc_exe: ?*std.Build.Step.Compile, config: IosStepConfig) void {
    const ios_step = b.step(config.step_name, config.step_description);
    const shaderc_tool = shaderc_exe orelse {
        ios_step.dependOn(&b.addFail("gosslens: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    };
    apple_sdk = b.option([]const u8, config.sdk_option_name, b.fmt("Path to the {s} SDK", .{config.sdk_name})) orelse
        (if (config.abi == .none) b.sysroot else null);
    if (apple_sdk == null) {
        const missing = b.addFail(b.fmt(
            "gosslens: run zig build {s} -D{s}=\"$(xcrun --sdk {s} --show-sdk-path)\"",
            .{ config.step_name, config.sdk_option_name, config.xcrun_sdk },
        ));
        ios_step.dependOn(&missing.step);
        return;
    }
    const ios_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .ios,
        .abi = config.abi,
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
    const makeup_mesh_ios = b.createModule(.{
        .root_source_file = b.path("core/tracking/makeup_mesh.zig"),
        .target = ios_target,
        .optimize = optimize,
    });
    const face_mesh_topology_ios = b.createModule(.{ .root_source_file = b.path("core/tracking/face_mesh_topology.zig"), .target = ios_target, .optimize = optimize });
    const render_ios = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "math", .module = math_ios },
            .{ .name = "makeup_mesh", .module = makeup_mesh_ios },
            .{ .name = "face_mesh_topology", .module = face_mesh_topology_ios },
        },
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
        // Zig's own panic backtrace symbolizer needs a dyld introspection
        // symbol iphoneos's SDK stub never exports (device dyld has it,
        // the link-time TBD doesn't); stripped, the library never reaches
        // for it. The ABI reports failures through goss_status, not panics.
        .strip = true,
        .imports = &.{
            .{ .name = "graph", .module = graph_ios },
            .{ .name = "math", .module = math_ios },
            .{ .name = "render", .module = render_ios },
        },
    });
    const tracking_cores_ios = trackingCoreModules(b, ios_target, optimize, math_ios);
    abi_ios.addImport("face", tracking_cores_ios.face);
    abi_ios.addImport("hand", tracking_cores_ios.hand);
    abi_ios.addImport("pose", tracking_cores_ios.pose);
    abi_ios.addImport("face_geometry", tracking_cores_ios.face_geometry);
    abi_ios.addImport("png", pngModule(b, ios_target, optimize));
    abi_ios.addImport("media_recording", recordingModule(b, ios_target, optimize));
    abi_ios.addImport("photo", photoModule(b, ios_target, optimize));
    abi_ios.addImport("audio_analysis", audioAnalysisModule(b, ios_target, optimize));
    abi_ios.addImport("physics", physicsModule(b, ios_target, optimize, false));
    const lens_manifest_ios = b.createModule(.{
        .root_source_file = b.path("core/lens/manifest.zig"),
        .target = ios_target,
        .optimize = optimize,
    });
    const lens_trigger_ios = b.createModule(.{
        .root_source_file = b.path("core/lens/trigger.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{.{ .name = "face", .module = tracking_cores_ios.face }},
    });
    const lens_animation_ios = b.createModule(.{
        .root_source_file = b.path("core/lens/animation.zig"),
        .target = ios_target,
        .optimize = optimize,
    });
    const lens_runtime_ios = b.createModule(.{
        .root_source_file = b.path("core/lens/runtime.zig"),
        .target = ios_target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "graph", .module = graph_ios },
            .{ .name = "manifest", .module = lens_manifest_ios },
            .{ .name = "trigger", .module = lens_trigger_ios },
            .{ .name = "animation", .module = lens_animation_ios },
            .{ .name = "face", .module = tracking_cores_ios.face },
        },
    });
    abi_ios.addImport("manifest", lens_manifest_ios);
    abi_ios.addImport("trigger", lens_trigger_ios);
    abi_ios.addImport("runtime", lens_runtime_ios);
    const have_inference_stack = blk: {
        for ([_][]const u8{ ".vendor/litert/tflite/CMakeLists.txt", ".vendor/xnnpack/CMakeLists.txt", ".vendor/fft2d/fftsg2d.c" }) |probe| {
            b.build_root.handle.access(b.graph.io, probe, .{}) catch break :blk false;
        }
        break :blk true;
    };
    const inference_ios = have_inference_stack and flatc_exe != null;
    var inference_libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
    if (inference_ios) {
        var family_libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
        const runtime_ios = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/runtime.zig"),
            .target = ios_target,
            .optimize = optimize,
        });
        runtime_ios.link_libc = true;
        runtime_ios.addIncludePath(b.path(".vendor/litert"));
        addAppleSdkPaths(b, runtime_ios);
        const tracking_ios = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/tracking.zig"),
            .target = ios_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "bundle", .module = tracking_cores_ios.bundle },
                .{ .name = "runtime", .module = runtime_ios },
                .{ .name = "detector", .module = tracking_cores_ios.detector },
                .{ .name = "sampler", .module = tracking_cores_ios.sampler },
                .{ .name = "face", .module = tracking_cores_ios.face },
                .{ .name = "hand", .module = tracking_cores_ios.hand },
                .{ .name = "pose", .module = tracking_cores_ios.pose },
                .{ .name = "tracker", .module = tracking_cores_ios.tracker },
                .{ .name = "graph", .module = graph_ios },
                .{ .name = "math", .module = math_ios },
            },
        });
        abi_ios.addImport("tracking", tracking_ios);
        const segment_ios = b.createModule(.{
            .root_source_file = b.path("core/tracking/segment.zig"),
            .target = ios_target,
            .optimize = optimize,
        });
        const transpose_conv_bias_ios = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/transpose_conv_bias.zig"),
            .target = ios_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_ios },
                .{ .name = "segment", .module = segment_ios },
            },
        });
        transpose_conv_bias_ios.link_libc = true;
        transpose_conv_bias_ios.addIncludePath(b.path(".vendor/litert"));
        const segmentation_ios = b.createModule(.{
            .root_source_file = b.path("adapters/tracking/segmentation.zig"),
            .target = ios_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "runtime", .module = runtime_ios },
                .{ .name = "sampler", .module = tracking_cores_ios.sampler },
                .{ .name = "math", .module = math_ios },
                .{ .name = "transpose_conv_bias", .module = transpose_conv_bias_ios },
            },
        });
        abi_ios.addImport("segmentation", segmentation_ios);
        const face106_ios = b.createModule(.{
            .root_source_file = b.path("core/tracking/face106.zig"),
            .target = ios_target,
            .optimize = optimize,
            .imports = &.{.{ .name = "face", .module = tracking_cores_ios.face }},
        });
        const beauty_ios_module = b.createModule(.{
            .root_source_file = b.path("adapters/beauty/beauty.zig"),
            .target = ios_target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "face", .module = tracking_cores_ios.face },
                .{ .name = "face106", .module = face106_ios },
            },
        });
        abi_ios.addImport("beauty", beauty_ios_module);
        for ([_]*std.Build.Step.Compile{
            buildTfliteLib(b, ios_target, optimize, flatc_exe.?, null),
            buildXnnpackLib(b, ios_target, optimize, null, &family_libs),
            buildAbseilLib(b, ios_target, optimize, null),
            buildRuyLib(b, ios_target, optimize, null),
            buildFarmhashLib(b, ios_target, optimize, null),
            buildFlatbuffersLib(b, ios_target, optimize, null),
            buildGpupixelLib(b, ios_target, optimize, null),
            buildLibyuvLib(b, ios_target, optimize, null),
            buildFft2dLib(b, ios_target, optimize, null),
            buildCpuinfoLib(b, ios_target, optimize, null),
            buildPthreadpoolLib(b, ios_target, optimize, null),
        }) |lib| {
            inference_libs.append(b.allocator, lib) catch @panic("oom");
        }
        inference_libs.appendSlice(b.allocator, family_libs.items) catch @panic("oom");
        // gpupixel links this lib internally already; installing it
        // separately is what makes zig-out/<target>/libangle.a exist for
        // Xcode's own -langle (zig's cache dedupes the real compile).
        // Both device and simulator: the demo links -langle on either SDK.
        inference_libs.append(b.allocator, buildAngleLib(b, ios_target, optimize)) catch @panic("oom");
    } else {
        abi_ios.addImport("tracking", trackingStubModule(b, ios_target, optimize, tracking_cores_ios.face, tracking_cores_ios.hand, tracking_cores_ios.pose, math_ios));
        abi_ios.addImport("segmentation", segmentationStubModule(b, ios_target, optimize, math_ios));
        abi_ios.addImport("beauty", beautyStubModule(b, ios_target, optimize, tracking_cores_ios.face));
    }
    const have_cgltf_ios = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/cgltf/cgltf.h", .{}) catch break :blk false;
        break :blk true;
    };
    const gltf_ios = if (have_cgltf_ios) gltfModule(b, ios_target, optimize, math_ios) else null;
    const ios_asset = realAssetModules(b, ios_target, optimize, gltf_ios);
    abi_ios.addImport("image", ios_asset.image);
    abi_ios.addImport("asset", ios_asset.asset);
    if (gltf_ios) |gm| abi_ios.addImport("gltf", gm);
    const gosslens_ios = b.addLibrary(.{
        .name = "gosslens",
        .linkage = .static,
        .root_module = abi_ios,
    });
    const bgfx_ios = buildBgfxLib(b, ios_target, optimize);
    var device_libs: std.ArrayList(*std.Build.Step.Compile) = .empty;
    device_libs.appendSlice(b.allocator, &.{ gosslens_ios, bgfx_ios }) catch @panic("oom");
    device_libs.appendSlice(b.allocator, inference_libs.items) catch @panic("oom");
    // Apple's linker requires 8-byte archive member alignment; the system
    // ranlib rewrites zig's archives into the accepted layout.
    for (device_libs.items) |lib| {
        const install = b.addInstallArtifact(lib, .{ .dest_dir = .{ .override = .{ .custom = config.install_dir } } });
        const fix = b.addSystemCommand(&.{ "ranlib", b.getInstallPath(.{ .custom = config.install_dir }, lib.out_filename) });
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
        step.dependOn(&b.addFail("gosslens: .vendor/bgfx missing, run zig build vendor-sync").step);
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

    // shaderc.h defaults SHADERC_CONFIG_HAS_DXC on for both Windows and
    // Linux, assuming a DXC install neither this vendor tree nor this
    // build provides (shaderc_dxil.cpp then reaches for <unknwnbase.h>,
    // a Windows SDK header, and fails outright on Linux). We only ever
    // emit metal/spirv/essl, never DXIL/D3D12, so it's a straight cut.
    const cxx17 = [_][]const u8{ "-std=c++20", "-fno-strict-aliasing", "-fno-sanitize=undefined", "-w", "-DBX_CONFIG_DEBUG=0", "-D__STDC_FORMAT_MACROS", "-DSHADERC_CONFIG_HAS_DXC=0" };
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

    // Google's Tint (SPIR-V -> WGSL only; every other reader/writer this
    // library can do is off). shaderc.h's own SHADERC_CONFIG_HAS_TINT
    // guard auto-detects <tint/api/tint.h> on the include path, so
    // linking this in is the only integration work needed. Source is
    // already vendored under bgfx's own 3rdparty/dawn (file globs and
    // defines mirror bgfx's own shaderc.lua); protobuf/abseil-cpp,
    // which that script lists as include dirs, aren't vendored here and
    // aren't referenced by the utils/lang-core/lang-spirv/lang-wgsl/api
    // subset this build actually compiles. spirv-tools' own
    // include/generated (core_tables_header.inc and friends) is added
    // here too - already vendored, just not on bgfx's own tint include
    // list.
    const tint_dir = bgfx_dir ++ "/3rdparty/dawn";
    const tint_module = b.createModule(.{ .target = target, .optimize = opt });
    tint_module.link_libcpp = true;
    for ([_][]const u8{ tint_dir, tint_dir ++ "/src/tint", spirv_tools, spirv_tools ++ "/include", spirv_tools ++ "/include/generated", spirv_headers ++ "/include" }) |dir| {
        tint_module.addIncludePath(b.path(dir));
    }
    tint_module.addCMacro("TINT_BUILD_GLSL_WRITER", "0");
    tint_module.addCMacro("TINT_BUILD_HLSL_WRITER", "0");
    tint_module.addCMacro("TINT_BUILD_MSL_WRITER", "0");
    tint_module.addCMacro("TINT_BUILD_NULL_WRITER", "0");
    tint_module.addCMacro("TINT_BUILD_SPV_READER", "1");
    tint_module.addCMacro("TINT_BUILD_SPV_WRITER", "0");
    tint_module.addCMacro("TINT_BUILD_WGSL_READER", "0");
    tint_module.addCMacro("TINT_BUILD_WGSL_WRITER", "1");
    tint_module.addCMacro("TINT_BUILD_IS_LINUX", if (target.result.os.tag == .linux) "1" else "0");
    tint_module.addCMacro("TINT_BUILD_IS_MAC", if (target.result.os.tag == .macos) "1" else "0");
    tint_module.addCMacro("TINT_BUILD_IS_WIN", if (target.result.os.tag == .windows) "1" else "0");
    tint_module.addCMacro("TINT_ENABLE_IR_VALIDATION", "0");
    var tint_sources: std.ArrayList([]const u8) = .empty;
    const tint_excludes = [_][]const u8{ "_test.cc", "_bench.cc", "fuzz" };
    for ([_][]const u8{ "src/tint/utils", "src/tint/lang/core", "src/tint/lang/spirv", "src/tint/lang/wgsl", "src/tint/api" }) |sub| {
        listFilesRecursive(b, b.fmt("{s}/{s}", .{ tint_dir, sub }), ".cc", &tint_excludes, &tint_sources);
    }
    std.mem.sort([]const u8, tint_sources.items, {}, struct {
        fn lessThan(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lessThan);
    for (tint_sources.items) |file| {
        tint_module.addCSourceFile(.{ .file = b.path(file), .flags = &cxx17 });
    }
    const tint_lib = b.addLibrary(.{ .name = "tint", .linkage = .static, .root_module = tint_module });

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
        tint_dir,
        // shaderc_wgsl.cpp includes the public <tint/api/tint.h>, which
        // resolves against src/ (tint/api/tint.h = src/tint/api/tint.h)
        // - different from Tint's own internal files, which use paths
        // relative to src/tint/ (the tint_module build above).
        tint_dir ++ "/src",
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
    shaderc_module.linkLibrary(tint_lib);
    step.dependOn(&b.addInstallArtifact(shaderc_exe, .{}).step);
    return shaderc_exe;
}

const EmToolchain = struct {
    em_plus_plus: []const u8,
    em_root: []const u8,
    em_python: []const u8,
    em_llvm_root: []const u8,
    em_config: []const u8,
    node_exe: []const u8,
};

// The vendored, opt-in emscripten toolchain's real paths, or null if it
// isn't synced (run: zig build vendor-sync -- --only emscripten &&
// zig build vendor-sync -- --only emscripten-python) or node is missing
// from PATH.
fn emscriptenToolchain(b: *std.Build) ?EmToolchain {
    const present = blk: {
        b.build_root.handle.access(b.graph.io, ".vendor/emscripten/emscripten/em++", .{}) catch break :blk false;
        b.build_root.handle.access(b.graph.io, ".vendor/emscripten-python/bin/python3", .{}) catch break :blk false;
        break :blk true;
    };
    if (!present) return null;
    const node_exe = b.findProgram(&.{"node"}, &.{}) catch return null;
    return .{
        .em_plus_plus = b.pathFromRoot(".vendor/emscripten/emscripten/em++"),
        .em_root = b.pathFromRoot(".vendor/emscripten"),
        .em_python = b.pathFromRoot(".vendor/emscripten-python/bin/python3"),
        .em_llvm_root = b.pathFromRoot(".vendor/emscripten/bin"),
        .em_config = b.pathFromRoot("adapters/bgfx/em_config_empty"),
        .node_exe = node_exe,
    };
}

fn setEmEnv(run: *std.Build.Step.Run, em: EmToolchain) void {
    run.setEnvironmentVariable("EMSDK_PYTHON", em.em_python);
    run.setEnvironmentVariable("EM_CONFIG", em.em_config);
    run.setEnvironmentVariable("EM_NODE_JS", em.node_exe);
    run.setEnvironmentVariable("EM_BINARYEN_ROOT", em.em_root);
    run.setEnvironmentVariable("EM_LLVM_ROOT", em.em_llvm_root);
}

fn addEmPlusPlusCompile(b: *std.Build, em: EmToolchain, src: []const u8, cxx_flags: []const []const u8, include_dirs: []const []const u8) std.Build.LazyPath {
    const run = b.addSystemCommand(&.{em.em_plus_plus});
    setEmEnv(run, em);
    run.addArgs(cxx_flags);
    for (include_dirs) |dir| {
        run.addArg("-I");
        run.addDirectoryArg(b.path(dir));
    }
    run.addArg("-c");
    run.addFileArg(b.path(src));
    run.addArg("-o");
    const obj_name = b.fmt("{s}.o", .{std.fs.path.stem(src)});
    return run.addOutputFileArg(obj_name);
}

// bgfx, bx, bimg, and astc-encoder for wasm32-emscripten, plus whatever
// extra_sources the caller needs compiled alongside them - every caller
// wants the same real GL backend under it, just a different driver on
// top. webgpu additionally compiles in BGFX_CONFIG_RENDERER_WEBGPU, an
// explicit per-caller opt-in rather than a shared default, since the
// matching --use-port=emdawnwebgpu link flag is only added by whichever
// caller wants this backend; the GLES-only production wasm-emscripten
// step must never regress if this one caller's own needs change.
fn addBgfxWasmObjects(b: *std.Build, em: EmToolchain, extra_sources: []const []const u8, webgpu: bool) std.ArrayList(std.Build.LazyPath) {
    var cxx_flags: std.ArrayList([]const u8) = .empty;
    cxx_flags.appendSlice(b.allocator, &.{
        "-std=c++20",
        "-fno-strict-aliasing",
        "-fno-exceptions",
        "-fno-rtti",
        "-Wno-date-time",
        "-D__STDC_FORMAT_MACROS",
        "-DBIMG_CONFIG_PARSE_AVIF=0",
        "-DBIMG_CONFIG_PARSE_HEIF=0",
        "-DBIMG_CONFIG_PARSE_EXR=0",
        "-DBX_CONFIG_DEBUG=0",
    }) catch @panic("oom");
    if (webgpu) cxx_flags.append(b.allocator, "-DBGFX_CONFIG_RENDERER_WEBGPU=1") catch @panic("oom");
    const include_dirs = [_][]const u8{
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
        ".vendor/bgfx/src",
    };

    var sources: std.ArrayList([]const u8) = .empty;
    sources.append(b.allocator, ".vendor/bgfx/src/amalgamated.cpp") catch @panic("oom");
    sources.append(b.allocator, ".vendor/bx/src/amalgamated.cpp") catch @panic("oom");
    for ([_][]const u8{ "image", "image_cubemap_filter", "image_decode", "image_encode" }) |name| {
        sources.append(b.allocator, b.fmt(".vendor/bimg/src/{s}.cpp", .{name})) catch @panic("oom");
    }
    if (listFiles(b, ".vendor/bimg/3rdparty/astc-encoder/source", ".cpp")) |astc_sources| {
        sources.appendSlice(b.allocator, astc_sources) catch @panic("oom");
    }
    sources.appendSlice(b.allocator, extra_sources) catch @panic("oom");

    var objects: std.ArrayList(std.Build.LazyPath) = .empty;
    for (sources.items) |src| {
        objects.append(b.allocator, addEmPlusPlusCompile(b, em, src, cxx_flags.items, &include_dirs)) catch @panic("oom");
    }
    return objects;
}

// The real web core (abi.zig + render.zig, real bgfx underneath, not
// render_stub.zig), built and linked into one wasm-emscripten module.
// Shared by both the WebGL2 (wasm-emscripten) and WebGPU
// (wasm-emscripten-webgpu) artifacts - identical Zig module graph and
// shader toolchain either way, differing only in which bgfx renderer
// backend gets compiled into the C++ objects (addBgfxWasmObjects's own
// `webgpu` flag) and the final em++ link flags. See the dual-artifact
// rationale at this function's call site in the top-level build graph.
fn addWasmEmscriptenStep(b: *std.Build, step: *std.Build.Step, shaderc_exe: ?*std.Build.Step.Compile, webgpu: bool) void {
    const em = emscriptenToolchain(b);
    if (em == null) {
        step.dependOn(&b.addFail("gosslens: emscripten vendors not synced; run: zig build vendor-sync -- --only emscripten && zig build vendor-sync -- --only emscripten-python").step);
        return;
    }
    if (shaderc_exe == null) {
        step.dependOn(&b.addFail("gosslens: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    }
    const em_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    const math_em = b.createModule(.{ .root_source_file = b.path("core/math/math.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const graph_em = b.createModule(.{ .root_source_file = b.path("core/graph/graph.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const shader_blobs_em = addShaderBlobs(b, shaderc_exe.?, em_target, .ReleaseSmall);
    const makeup_mesh_em = b.createModule(.{ .root_source_file = b.path("core/tracking/makeup_mesh.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const face_mesh_topology_em = b.createModule(.{ .root_source_file = b.path("core/tracking/face_mesh_topology.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const render_em = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "math", .module = math_em },
            .{ .name = "shader_blobs", .module = shader_blobs_em },
            .{ .name = "makeup_mesh", .module = makeup_mesh_em },
            .{ .name = "face_mesh_topology", .module = face_mesh_topology_em },
        },
    });
    render_em.addIncludePath(b.path(".vendor/bgfx/include"));
    render_em.addIncludePath(b.path(".vendor/bx/include"));
    render_em.addSystemIncludePath(b.path(".vendor/emscripten/emscripten/cache/sysroot/include"));

    const abi_em = b.createModule(.{
        .root_source_file = b.path("core/abi/abi.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "graph", .module = graph_em },
            .{ .name = "math", .module = math_em },
            .{ .name = "render", .module = render_em },
        },
    });
    // abiAllocator()'s std.heap.c_allocator branch on web needs
    // real libc linkage - symbol resolution happens later at
    // the em++ link step regardless, same as render_em's own
    // sysroot include path below.
    abi_em.link_libc = true;
    const tracking_cores_em = trackingCoreModules(b, em_target, .ReleaseSmall, math_em);
    abi_em.addImport("face", tracking_cores_em.face);
    abi_em.addImport("hand", tracking_cores_em.hand);
    abi_em.addImport("pose", tracking_cores_em.pose);
    abi_em.addImport("face_geometry", tracking_cores_em.face_geometry);
    abi_em.addImport("png", pngModule(b, em_target, .ReleaseSmall));
    abi_em.addImport("media_recording", recordingModule(b, em_target, .ReleaseSmall));
    abi_em.addImport("photo", photoModule(b, em_target, .ReleaseSmall));
    abi_em.addImport("audio_analysis", audioAnalysisModule(b, em_target, .ReleaseSmall));
    abi_em.addImport("physics", physicsModule(b, em_target, .ReleaseSmall, false));
    abi_em.addImport("tracking", trackingStubModule(b, em_target, .ReleaseSmall, tracking_cores_em.face, tracking_cores_em.hand, tracking_cores_em.pose, math_em));
    abi_em.addImport("segmentation", segmentationStubModule(b, em_target, .ReleaseSmall, math_em));
    abi_em.addImport("beauty", beautyStubModule(b, em_target, .ReleaseSmall, tracking_cores_em.face));
    // Web's own beauty.reshape dispatch needs the 106-point
    // contour directly (no gpupixel bridge to hand raw
    // landmarks to on this target) - the same module the real
    // beauty adapter already reduces tracked landmarks through.
    const face106_em = b.createModule(.{
        .root_source_file = b.path("core/tracking/face106.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "face", .module = tracking_cores_em.face }},
    });
    abi_em.addImport("face106", face106_em);
    const lens_manifest_em = b.createModule(.{ .root_source_file = b.path("core/lens/manifest.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const lens_trigger_em = b.createModule(.{
        .root_source_file = b.path("core/lens/trigger.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "face", .module = tracking_cores_em.face }},
    });
    const lens_animation_em = b.createModule(.{ .root_source_file = b.path("core/lens/animation.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const lens_runtime_em = b.createModule(.{
        .root_source_file = b.path("core/lens/runtime.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "graph", .module = graph_em },
            .{ .name = "manifest", .module = lens_manifest_em },
            .{ .name = "trigger", .module = lens_trigger_em },
            .{ .name = "animation", .module = lens_animation_em },
            .{ .name = "face", .module = tracking_cores_em.face },
        },
    });
    abi_em.addImport("manifest", lens_manifest_em);
    abi_em.addImport("trigger", lens_trigger_em);
    abi_em.addImport("runtime", lens_runtime_em);
    const image_em = imageStubModule(b, em_target, .ReleaseSmall);
    abi_em.addImport("image", image_em);
    const gltf_stub_em = gltfStubModule(b, em_target, .ReleaseSmall, math_em);
    abi_em.addImport("asset", assetStubModule(b, em_target, .ReleaseSmall, image_em, gltf_stub_em));
    abi_em.addImport("gltf", gltf_stub_em);

    const gosslens_em_obj = b.addObject(.{ .name = "gosslens_web", .root_module = abi_em });
    const bgfx_objects = addBgfxWasmObjects(b, em.?, &.{}, webgpu);
    const link = b.addSystemCommand(&.{em.?.em_plus_plus});
    setEmEnv(link, em.?);
    link.addFileArg(gosslens_em_obj.getEmittedBin());
    for (bgfx_objects.items) |obj| link.addFileArg(obj);
    if (webgpu) {
        // emdawnwebgpu is this pinned Emscripten's WebGPU port
        // (-sUSE_WEBGPU=1 is gone); ASYNCIFY lets bgfx_init block on
        // Dawn's async adapter/device request. No WebGL2 flags - this
        // artifact only ships after the TS SDK confirms an adapter.
        link.addArgs(&.{ "--use-port=emdawnwebgpu", "-sASYNCIFY=1" });
    } else {
        link.addArgs(&.{ "-sUSE_WEBGL2=1", "-sMIN_WEBGL_VERSION=2", "-sMAX_WEBGL_VERSION=2", "-sFULL_ES3=1" });
    }
    link.addArgs(&.{
        "-sALLOW_MEMORY_GROWTH=1",
        // 256MB up front. 64MB (comfortably past what session/
        // engine creation and a frame or two of textures need)
        // was enough until the TS SDK started submitting real
        // RGBA frames through goss_session_submit_frame_rgba_copy
        // - a single still test photo at 2400x3000 is 28.8MB by
        // itself, on top of live 1280x720 camera frames, LUT/
        // makeup textures, and bgfx's own state. Raised as a
        // precaution while chasing a real readback bug that
        // turned out to be unrelated (a stale bgfx view-target
        // binding, fixed at its actual source in abi.zig) -
        // kept anyway since a still-photo-sized upload genuinely
        // is close enough to the old budget to be worth the
        // headroom.
        "-sINITIAL_MEMORY=268435456",
        // Every goss_* entry point is a real call site the TS SDK
        // reaches dynamically, so EXPORT_ALL keeps them all
        // reachable rather than hand-listing EXPORTED_FUNCTIONS.
        // LINKABLE is also required, or every goss_* export comes
        // back undefined - deprecated upstream but still needed as
        // of this emscripten pin.
        "-sEXPORT_ALL=1",
        "-sLINKABLE=1",
        "-sMODULARIZE=1",
        "-sEXPORT_NAME=GosslensWebModule",
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,stringToNewUTF8,UTF8ToString,getValue,setValue",
        // A real ES module (import GosslensWebModule from
        // "./gosslens_web.js") rather than a plain-global
        // factory function a <script> tag would have to expose -
        // the TS SDK's whole build (bun, ESM throughout)
        // already assumes every dependency is import-able.
        "-sEXPORT_ES6=1",
        "-sUSE_ES6_IMPORT_META=1",
    });
    link.addArg("-o");
    const js_out = link.addOutputFileArg("gosslens_web.js");

    const install = b.addInstallDirectory(.{
        .source_dir = js_out.dirname(),
        .install_dir = .{ .custom = if (webgpu) "wasm-emscripten-webgpu" else "wasm-emscripten" },
        .install_subdir = "",
    });
    step.dependOn(&install.step);

    // sdk/ts/demo/ is a real source-tree directory, not under
    // zig-out - addInstallDirectory can't reach it (InstallDir is
    // always rooted at the install prefix), so this step's own build
    // output is the demo's actual input, keeping it from silently
    // testing a stale binary a manual `cp` forgot to re-run.
    const wasm_out = js_out.dirname().path(b, "gosslens_web.wasm");
    const demo_subdir = if (webgpu) "sdk/ts/demo/webgpu/" else "sdk/ts/demo/";
    const demo_copy = b.addUpdateSourceFiles();
    demo_copy.addCopyFileToSource(js_out, b.fmt("{s}gosslens_web.js", .{demo_subdir}));
    demo_copy.addCopyFileToSource(wasm_out, b.fmt("{s}gosslens_web.wasm", .{demo_subdir}));
    step.dependOn(&demo_copy.step);
}

// Compiles bgfx, bx, bimg, and astc-encoder for wasm32-emscripten and
// links wasm_bgfx_smoke_driver.cpp against them, through the vendored
// em++ alone - `zig cc`'s own bundled headers shadow libc++'s here and
// break the build.
fn addWasmBgfxSmokeStep(b: *std.Build, step: *std.Build.Step) void {
    const em = emscriptenToolchain(b) orelse {
        step.dependOn(&b.addFail("gosslens: emscripten vendors not synced; run: zig build vendor-sync -- --only emscripten && zig build vendor-sync -- --only emscripten-python").step);
        return;
    };
    const objects = addBgfxWasmObjects(b, em, &.{"adapters/bgfx/wasm_bgfx_smoke_driver.cpp"}, false);

    const link = b.addSystemCommand(&.{em.em_plus_plus});
    setEmEnv(link, em);
    for (objects.items) |obj| link.addFileArg(obj);
    link.addArgs(&.{ "-sUSE_WEBGL2=1", "-sMIN_WEBGL_VERSION=2", "-sMAX_WEBGL_VERSION=2", "-sFULL_ES3=1", "-sALLOW_MEMORY_GROWTH=1" });
    link.addArg("-o");
    const js_out = link.addOutputFileArg("wasm_bgfx_smoke.js");

    const install = b.addInstallDirectory(.{
        .source_dir = js_out.dirname(),
        .install_dir = .{ .custom = "wasm-bgfx-smoke" },
        .install_subdir = "",
    });
    step.dependOn(&install.step);
}

// Compiles bgfx with BGFX_CONFIG_RENDERER_WEBGPU=1 and links
// wasm_webgpu_smoke_driver.cpp against it via em++'s emdawnwebgpu port.
// Upstream bgfx leaves Emscripten out of this define's default-enabled
// platforms, and this project's pinned Emscripten dropped -sUSE_WEBGPU=1
// entirely in favor of this port. Kept fully separate from
// addWasmBgfxSmokeStep's own GLES recipe - two different bgfx renderer
// backends, two different drivers, sharing only addBgfxWasmObjects's
// compile machinery.
fn addWasmWebgpuSmokeStep(b: *std.Build, step: *std.Build.Step) void {
    const em = emscriptenToolchain(b) orelse {
        step.dependOn(&b.addFail("gosslens: emscripten vendors not synced; run: zig build vendor-sync -- --only emscripten && zig build vendor-sync -- --only emscripten-python").step);
        return;
    };
    const objects = addBgfxWasmObjects(b, em, &.{"adapters/bgfx/wasm_webgpu_smoke_driver.cpp"}, true);

    const link = b.addSystemCommand(&.{em.em_plus_plus});
    setEmEnv(link, em);
    for (objects.items) |obj| link.addFileArg(obj);
    link.addArgs(&.{ "-sALLOW_MEMORY_GROWTH=1", "--use-port=emdawnwebgpu", "-sASYNCIFY=1" });
    link.addArg("-o");
    const js_out = link.addOutputFileArg("wasm_webgpu_smoke.js");

    const install = b.addInstallDirectory(.{
        .source_dir = js_out.dirname(),
        .install_dir = .{ .custom = "wasm-webgpu-smoke" },
        .install_subdir = "",
    });
    step.dependOn(&install.step);
}

// The real render.zig - the one binding over bgfx every native SDK
// already runs, not a rewrite - compiled as a wasm32-emscripten object
// and linked against the same real bgfx/bx/bimg/astc-encoder objects
// wasm-bgfx-smoke proves, plus a small Zig driver exporting one probe
// function. Proves the whole mechanism the real web core needs: a Zig
// object and bgfx's C++ objects, from two different compilers, linked
// into one wasm module by em++ alone.
fn addWasmEmscriptenCoreSmokeStep(b: *std.Build, step: *std.Build.Step, shaderc_exe: ?*std.Build.Step.Compile, webgpu: bool) void {
    const em = emscriptenToolchain(b) orelse {
        step.dependOn(&b.addFail("gosslens: emscripten vendors not synced; run: zig build vendor-sync -- --only emscripten && zig build vendor-sync -- --only emscripten-python").step);
        return;
    };
    const shaderc_tool = shaderc_exe orelse {
        step.dependOn(&b.addFail("gosslens: shader compiler unavailable, run zig build vendor-sync").step);
        return;
    };

    const em_target = b.resolveTargetQuery(.{ .cpu_arch = .wasm32, .os_tag = .emscripten });
    const math_em = b.createModule(.{ .root_source_file = b.path("core/math/math.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const shader_blobs_em = addShaderBlobs(b, shaderc_tool, em_target, .ReleaseSmall);
    const makeup_mesh_em = b.createModule(.{ .root_source_file = b.path("core/tracking/makeup_mesh.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const face_mesh_topology_em = b.createModule(.{ .root_source_file = b.path("core/tracking/face_mesh_topology.zig"), .target = em_target, .optimize = .ReleaseSmall });
    const render_em = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/render.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{
            .{ .name = "math", .module = math_em },
            .{ .name = "shader_blobs", .module = shader_blobs_em },
            .{ .name = "makeup_mesh", .module = makeup_mesh_em },
            .{ .name = "face_mesh_topology", .module = face_mesh_topology_em },
        },
    });
    render_em.addIncludePath(b.path(".vendor/bgfx/include"));
    render_em.addIncludePath(b.path(".vendor/bx/include"));
    // Real linking against emscripten's libc only happens later, at the
    // em++ link step - this is an object-only build, so bgfx.h's own
    // #include <stdlib.h> just needs the emscripten sysroot's headers
    // on the search path, not Zig's own (nonexistent, for this target)
    // libc linkage.
    render_em.addSystemIncludePath(b.path(".vendor/emscripten/emscripten/cache/sysroot/include"));

    const driver_em = b.createModule(.{
        .root_source_file = b.path("adapters/bgfx/wasm_emscripten_core_smoke.zig"),
        .target = em_target,
        .optimize = .ReleaseSmall,
        .imports = &.{.{ .name = "render", .module = render_em }},
    });
    driver_em.link_libc = true;
    const zig_obj = b.addObject(.{ .name = "wasm_emscripten_core_smoke", .root_module = driver_em });

    const objects = addBgfxWasmObjects(b, em, &.{}, webgpu);
    const link = b.addSystemCommand(&.{em.em_plus_plus});
    setEmEnv(link, em);
    link.addFileArg(zig_obj.getEmittedBin());
    for (objects.items) |obj| link.addFileArg(obj);
    if (webgpu) {
        link.addArgs(&.{ "--use-port=emdawnwebgpu", "-sASYNCIFY=1" });
    } else {
        link.addArgs(&.{ "-sUSE_WEBGL2=1", "-sMIN_WEBGL_VERSION=2", "-sMAX_WEBGL_VERSION=2", "-sFULL_ES3=1" });
    }
    link.addArgs(&.{
        "-sALLOW_MEMORY_GROWTH=1",
        "-sEXPORTED_FUNCTIONS=_ck_core_smoke_probe,_ck_core_smoke_render_frame,_ck_core_smoke_read_texture,_malloc,_free",
        "-sEXPORTED_RUNTIME_METHODS=ccall,cwrap,UTF8ToString",
        "-sMODULARIZE=1",
        "-sEXPORT_NAME=CoreSmokeModule",
    });
    link.addArg("-o");
    const js_out = link.addOutputFileArg("wasm_emscripten_core_smoke.js");

    const install = b.addInstallDirectory(.{
        .source_dir = js_out.dirname(),
        .install_dir = .{ .custom = if (webgpu) "wasm-emscripten-core-smoke-webgpu" else "wasm-emscripten-core-smoke" },
        .install_subdir = "",
    });
    step.dependOn(&install.step);
}

// Compiles the kit's shaders with the vendored compiler at build time and
// exposes the blobs as one embedded module, per backend profile.
fn addShaderBlobs(b: *std.Build, shaderc_exe: *std.Build.Step.Compile, target: std.Build.ResolvedTarget, optimize: std.builtin.OptimizeMode) *std.Build.Module {
    const wf = b.addWriteFiles();
    var source: std.ArrayList(u8) = .empty;
    const shaders = [_]struct {
        name: []const u8,
        kind: []const u8,
        source_dir: []const u8 = "adapters/bgfx/shaders",
        varyingdef: []const u8 = "adapters/bgfx/shaders/varying.def.sc",
    }{
        .{ .name = "vs_preview", .kind = "vertex" },
        .{ .name = "fs_preview_rgba", .kind = "fragment" },
        .{ .name = "fs_preview_nv12", .kind = "fragment" },
        // The one fixed vertex contract every lens shader pass compiles
        // against - source and varying def both live under
        // lenses/shaders/, not the engine's own preview shader
        // directory, since that's the contract lens authors read.
        .{ .name = "vs_lens_pass", .kind = "vertex", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // lut.pass's own fixed fragment shader - kit-authored like the
        // vertex contract above, not per-lens, so it compiles here once
        // rather than through the validator's per-lens shader stage.
        .{ .name = "fs_lut_pass", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // blend.pass's own fixed fragment shader, same reasoning as
        // fs_lut_pass above.
        .{ .name = "fs_blend_pass", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // beauty.face's smooth effect blends toward this separable
        // blur, run twice (horizontal then vertical) by the two
        // different u_blurStep values the caller submits it with, same
        // program both times.
        .{ .name = "fs_blur_pass", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // beauty.face's own fixed fragment shader: smooth and whiten,
        // same reasoning as fs_lut_pass above.
        .{ .name = "fs_beauty_face", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // beauty.reshape's own fixed fragment shader: thin_face and
        // big_eye, same reasoning as fs_lut_pass above.
        .{ .name = "fs_beauty_reshape", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
        // beauty.lipstick/beauty.blusher's own mesh vertex stage - its
        // own varying def, a_position is vec2 here, not the vec3 every
        // other vertex contract in this project shares.
        .{ .name = "vs_makeup", .kind = "vertex", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying_makeup.def.sc" },
        // beauty.lipstick/beauty.blusher's own fixed fragment shader,
        // same reasoning as fs_lut_pass above.
        .{ .name = "fs_makeup", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying_makeup.def.sc" },
        // model.gltf's own fixed fragment shader: a flat material-tint
        // fill, same reasoning as fs_lut_pass above - pairs with the
        // shared vs_lens_pass.sc vertex contract, not its own stage.
        .{ .name = "fs_model", .kind = "fragment", .source_dir = "lenses/shaders", .varyingdef = "lenses/shaders/varying.def.sc" },
    };
    const profiles = [_]struct { profile: []const u8, platform: []const u8, tag: []const u8 }{
        .{ .profile = "metal", .platform = "ios", .tag = "metal" },
        .{ .profile = "spirv", .platform = "android", .tag = "spirv" },
        .{ .profile = "300_es", .platform = "android", .tag = "essl" },
        // Same GLSL ES 3.00 profile Android's essl blobs target - bgfx
        // reports OPENGLES for both - but compiled for asm.js rather
        // than android, its own tag since shaderc's platform argument
        // can affect the preprocessor defines it injects.
        .{ .profile = "300_es", .platform = "asm.js", .tag = "essl_web" },
        // shaderc.cpp reads WGSL output via SPIR-V through
        // tint::SpirvToWgsl, so this routes through the same SPIR-V
        // front end every other profile here does, just a different
        // back end.
        .{ .profile = "wgsl", .platform = "asm.js", .tag = "wgsl" },
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
            run.addFileArg(b.path(b.fmt("{s}/{s}.sc", .{ shader.source_dir, shader.name })));
            run.addArg("-o");
            const out_name = b.fmt("{s}.{s}.bin", .{ shader.name, profile.tag });
            const out = run.addOutputFileArg(out_name);
            run.addArgs(&.{ "--type", shader.kind, "--platform", profile.platform, "-p", profile.profile, "--varyingdef" });
            run.addFileArg(b.path(shader.varyingdef));
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
        std.process.fatal("gosslens: cannot read .zigversion: {t}", .{err});
    const pinned = std.mem.trim(u8, raw, " \t\r\n");
    if (std.mem.eql(u8, pinned, builtin.zig_version_string)) return;
    if (b.graph.environ_map.get("GOSS_ALLOW_ZIG_MISMATCH") != null) {
        std.debug.print("gosslens: shadow lane: building with Zig {s} against pin {s}\n", .{ builtin.zig_version_string, pinned });
        return;
    }
    std.process.fatal("gosslens: expected Zig {s}, found {s}, run tools/toolchain-sync", .{ pinned, builtin.zig_version_string });
}
