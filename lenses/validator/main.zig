//! The reference validator for one .glens bundle, checked directly
//! against lenses/SPEC.md: a bundle this program accepts is, by
//! definition, valid, and where this and the spec disagree the spec is
//! right and this has a bug. Four stages, each collecting every
//! diagnostic it finds rather than stopping at the first: bundle
//! structure (section 1), manifest.json (section 2 through 6, via
//! core/lens/manifest.zig), each trigger's `when` expression (6.1, via
//! core/lens/trigger.zig), then every shader in shaders/ compiled
//! through the pinned toolchain (section 7). Later stages only run once
//! the earlier one is clean, since e.g. a structurally invalid bundle
//! has no manifest worth parsing.
//!
//!   lens_validator <bundle-path>

const std = @import("std");
const manifest = @import("manifest");
const trigger = @import("trigger");
const build_options = @import("build_options");

const max_bundle_bytes: u64 = 64 * 1024 * 1024;
const max_shader_bytes: u64 = 256 * 1024;
const max_asset_bytes: u64 = 32 * 1024 * 1024;
const max_manifest_bytes: u64 = manifest.max_manifest_bytes;

const permitted_top_level = [_][]const u8{ "shaders", "assets" };
const shader_extensions = [_][]const u8{".glsl"};
const asset_extensions = [_][]const u8{ ".gltf", ".glb", ".png" };

fn hasAnyExtension(name: []const u8, extensions: []const []const u8) bool {
    for (extensions) |ext| {
        if (std.mem.endsWith(u8, name, ext)) return true;
    }
    return false;
}

/// Walks one bundle subtree (shaders/ or assets/), rejecting any file
/// over its category's size limit or of a type not permitted there, and
/// adding every file's size to total_bytes.
fn walkCategory(
    io: std.Io,
    gpa: std.mem.Allocator,
    diags: *manifest.Diagnostics,
    root: std.Io.Dir,
    category: []const u8,
    per_file_limit: u64,
    allowed_extensions: []const []const u8,
    total_bytes: *u64,
) !void {
    var category_dir = root.openDir(io, category, .{ .iterate = true }) catch return;
    defer category_dir.close(io);

    var walker = try category_dir.walk(gpa);
    defer walker.deinit();
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const path = try std.fmt.allocPrint(diags.arena, "/{s}/{s}", .{ category, entry.path });
        if (!hasAnyExtension(entry.basename, allowed_extensions)) {
            try diags.add(path, "file type not permitted in {s}/", .{category});
            continue;
        }
        const stat = entry.dir.statFile(io, entry.basename, .{}) catch |err| {
            try diags.add(path, "cannot stat: {t}", .{err});
            continue;
        };
        if (stat.size > per_file_limit) {
            try diags.add(path, "{d} bytes exceeds the {d} byte limit", .{ stat.size, per_file_limit });
        }
        total_bytes.* += stat.size;
    }
}

/// Bundle structure per SPEC.md section 1: only manifest.json at the
/// root plus shaders/ and assets/ subtrees, every file within its
/// category's size limit, the whole bundle within the total limit. No
/// path can escape the root by construction - every path here comes
/// from walking the real directory tree, never from a string a manifest
/// supplied.
fn validateBundle(io: std.Io, gpa: std.mem.Allocator, diags: *manifest.Diagnostics, bundle_path: []const u8) !bool {
    var bundle_dir = std.Io.Dir.cwd().openDir(io, bundle_path, .{ .iterate = true }) catch |err| {
        try diags.add("", "cannot open bundle directory '{s}': {t}", .{ bundle_path, err });
        return false;
    };
    defer bundle_dir.close(io);

    const manifest_stat = bundle_dir.statFile(io, "manifest.json", .{}) catch |err| {
        try diags.add("/manifest.json", "missing or unreadable: {t}", .{err});
        return false;
    };
    if (manifest_stat.size > max_manifest_bytes) {
        try diags.add("/manifest.json", "{d} bytes exceeds the {d} byte limit", .{ manifest_stat.size, max_manifest_bytes });
    }
    var total_bytes: u64 = manifest_stat.size;

    var top = bundle_dir.iterate();
    while (try top.next(io)) |entry| {
        if (std.mem.eql(u8, entry.name, "manifest.json")) continue;
        var recognized = false;
        for (permitted_top_level) |name| {
            if (std.mem.eql(u8, entry.name, name)) recognized = true;
        }
        if (!recognized or entry.kind != .directory) {
            const path = try std.fmt.allocPrint(diags.arena, "/{s}", .{entry.name});
            try diags.add(path, "not a permitted bundle entry (only manifest.json, shaders/, assets/)", .{});
        }
    }

    try walkCategory(io, gpa, diags, bundle_dir, "shaders", max_shader_bytes, &shader_extensions, &total_bytes);
    try walkCategory(io, gpa, diags, bundle_dir, "assets", max_asset_bytes, &asset_extensions, &total_bytes);

    if (total_bytes > max_bundle_bytes) {
        try diags.add("", "bundle totals {d} bytes, exceeds the {d} byte limit", .{ total_bytes, max_bundle_bytes });
    }

    return diags.list.items.len == 0;
}

fn validateTriggers(gpa: std.mem.Allocator, diags: *manifest.Diagnostics, lens: *const manifest.Manifest) !bool {
    var param_names: std.ArrayList([]const u8) = .empty;
    defer param_names.deinit(gpa);
    for (lens.parameters) |p| try param_names.append(gpa, p.name);

    var ok = true;
    for (lens.triggers, 0..) |lens_trigger, i| {
        var compile_err: ?trigger.CompileError = null;
        const expr = trigger.compile(gpa, diags.arena, lens_trigger.when_source, param_names.items, &compile_err) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (expr) |*e| {
            var mutable = e.*;
            mutable.deinit();
        } else {
            ok = false;
            const path = try std.fmt.allocPrint(diags.arena, "/triggers/{d}/when", .{i});
            const err = compile_err.?;
            try diags.add(path, "{s} (at offset {d})", .{ err.message, err.offset });
        }
    }
    return ok;
}

const shader_profiles = [_]struct { profile: []const u8, platform: []const u8, tag: []const u8 }{
    .{ .profile = "metal", .platform = "ios", .tag = "metal" },
    .{ .profile = "spirv", .platform = "android", .tag = "spirv" },
    .{ .profile = "300_es", .platform = "android", .tag = "essl" },
};

/// Every file under shaders/ is a fragment shader for a full-screen pass,
/// authored against the runtime's one fixed vertex/varying contract
/// (lenses/shaders/varying.def.sc, SPEC.md section 7). Compiled through
/// the pinned shaderc toolchain to every platform profile a conforming
/// runtime ships, since a shader that compiles for one platform and not
/// another is exactly the failure this stage exists to catch before a
/// lens ships. package_dir, when given, is a bundle directory tree
/// (already a copy of the source bundle, made by packageLens below)
/// that gets each compiled variant written into it as
/// shaders/<name>.<tag>.bin (SPEC.md section 1/7) instead of discarding
/// the bytes - the same compile, run once, either way.
fn validateShaders(io: std.Io, gpa: std.mem.Allocator, diags: *manifest.Diagnostics, bundle_path: []const u8, package_dir: ?[]const u8) !bool {
    var bundle_dir = std.Io.Dir.cwd().openDir(io, bundle_path, .{ .iterate = true }) catch return true;
    defer bundle_dir.close(io);
    var shaders_dir = bundle_dir.openDir(io, "shaders", .{ .iterate = true }) catch return true;
    defer shaders_dir.close(io);

    var walker = try shaders_dir.walk(gpa);
    defer walker.deinit();
    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        if (!std.mem.endsWith(u8, entry.basename, ".glsl")) continue;
        const diag_path = try std.fmt.allocPrint(diags.arena, "/shaders/{s}", .{entry.path});

        if (build_options.shaderc_path.len == 0) {
            try diags.add(diag_path, "shader toolchain unavailable (run zig build vendor-sync)", .{});
            ok = false;
            continue;
        }

        const disk_path = try std.fs.path.join(diags.arena, &.{ bundle_path, "shaders", entry.path });
        const stem = entry.path[0 .. entry.path.len - ".glsl".len];
        for (shader_profiles) |profile| {
            const out_path = if (package_dir) |dir|
                try std.fmt.allocPrint(diags.arena, "{s}/shaders/{s}.{s}.bin", .{ dir, stem, profile.tag })
            else
                "/dev/null";
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{
                build_options.shaderc_path,
                "-f",           disk_path,
                "-o",           out_path,
                "--type",       "fragment",
                "--platform",   profile.platform,
                "-p",           profile.profile,
                "--varyingdef", build_options.varyingdef_path,
                "-i",           build_options.shader_include_dir,
            });
            const result = std.process.run(gpa, io, .{ .argv = argv.items }) catch |err| {
                ok = false;
                try diags.add(diag_path, "shaderc ({s}/{s}) could not run: {t}", .{ profile.platform, profile.profile, err });
                continue;
            };
            defer gpa.free(result.stdout);
            defer gpa.free(result.stderr);
            const success = switch (result.term) {
                .exited => |code| code == 0,
                else => false,
            };
            if (!success) {
                ok = false;
                const raw = if (result.stderr.len > 0) result.stderr else result.stdout;
                const message = std.mem.trim(u8, raw, " \t\r\n");
                try diags.add(diag_path, "shaderc ({s}/{s}): {s}", .{ profile.platform, profile.profile, message });
            }
        }
    }
    return ok;
}

fn report(io: std.Io, bundle_path: []const u8, diagnostics: []const manifest.Diagnostic, ok: bool) !void {
    var buffer: [4096]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(io, &buffer);
    const out = &stdout.interface;
    if (ok) {
        try out.print("lens_validator: {s} valid\n", .{bundle_path});
    } else {
        try out.print("lens_validator: {s} invalid, {d} problem(s)\n", .{ bundle_path, diagnostics.len });
        for (diagnostics) |d| {
            try out.print("  {s}: {s}\n", .{ if (d.path.len == 0) "/" else d.path, d.message });
        }
    }
    try out.flush();
}

/// Copies bundle_path's tree (manifest.json, shaders/ source, assets/)
/// into package_dir, creating it fresh. The compiled shader variants
/// validateShaders writes alongside the copied source, once validation
/// (which runs against the ORIGINAL bundle_path, never the copy) passes.
fn copyBundleTree(io: std.Io, gpa: std.mem.Allocator, bundle_path: []const u8, package_dir: []const u8) !void {
    const cwd = std.Io.Dir.cwd();
    try cwd.createDirPath(io, package_dir);
    var src = try cwd.openDir(io, bundle_path, .{ .iterate = true });
    defer src.close(io);

    var manifest_buf: [max_manifest_bytes]u8 = undefined;
    const manifest_bytes = try src.readFile(io, "manifest.json", &manifest_buf);
    const dest_manifest = try std.fs.path.join(gpa, &.{ package_dir, "manifest.json" });
    defer gpa.free(dest_manifest);
    try cwd.writeFile(io, .{ .sub_path = dest_manifest, .data = manifest_bytes });

    for (permitted_top_level) |category| {
        var category_dir = src.openDir(io, category, .{ .iterate = true }) catch continue;
        defer category_dir.close(io);
        var walker = try category_dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            const dest_path = try std.fmt.allocPrint(gpa, "{s}/{s}/{s}", .{ package_dir, category, entry.path });
            defer gpa.free(dest_path);
            if (std.fs.path.dirname(dest_path)) |parent| try cwd.createDirPath(io, parent);
            const bytes = try entry.dir.readFileAlloc(io, entry.basename, gpa, .limited(max_bundle_bytes));
            defer gpa.free(bytes);
            try cwd.writeFile(io, .{ .sub_path = dest_path, .data = bytes });
        }
    }
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var bundle_path: ?[]const u8 = null;
    var package_dir: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--package")) {
            package_dir = args.next() orelse {
                std.debug.print("lens_validator: --package requires a directory argument\n", .{});
                return 2;
            };
        } else if (bundle_path == null) {
            bundle_path = arg;
        } else {
            std.debug.print("lens_validator: unexpected argument '{s}'\n", .{arg});
            return 2;
        }
    }
    const path = bundle_path orelse {
        std.debug.print("lens_validator: usage: lens_validator <bundle-path> [--package <output-dir>]\n", .{});
        return 2;
    };

    var diags = manifest.Diagnostics{ .arena = arena };

    if (!try validateBundle(io, gpa, &diags, path)) {
        try report(io, path, diags.list.items, false);
        return 1;
    }

    const manifest_path = try std.fs.path.join(arena, &.{ path, "manifest.json" });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(max_manifest_bytes + 1));

    var lens = try manifest.parse(gpa, &diags, source) orelse {
        try report(io, path, diags.list.items, false);
        return 1;
    };
    defer lens.deinit();

    if (!try validateTriggers(gpa, &diags, &lens)) {
        try report(io, path, diags.list.items, false);
        return 1;
    }

    if (package_dir) |dir| try copyBundleTree(io, gpa, path, dir);

    if (!try validateShaders(io, gpa, &diags, path, package_dir)) {
        try report(io, path, diags.list.items, false);
        return 1;
    }

    try report(io, path, &.{}, true);
    if (package_dir) |dir| std.debug.print("lens_validator: packaged to {s}\n", .{dir});
    return 0;
}

const t = std.testing;

const minimal_valid_manifest =
    \\{
    \\  "glf": "1.0",
    \\  "id": "com.example.mylens",
    \\  "version": "1.0.0",
    \\  "display_name": "My Lens",
    \\  "engine_compat": ">=0.5 <1.0",
    \\  "capabilities": [],
    \\  "parameters": [
    \\    {"name": "amount", "type": "float", "default": 0.5, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [],
    \\  "triggers": [
    \\    {"when": "tap", "action": {"kind": "param_set", "target": "amount", "to": 1.0}}
    \\  ]
    \\}
;

fn tmpBundlePath(tmp: std.testing.TmpDir, buf: []u8) []const u8 {
    return std.fmt.bufPrint(buf, ".zig-cache/tmp/{s}", .{tmp.sub_path}) catch unreachable;
}

test "a minimal valid bundle passes all three stages" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(try validateBundle(t.io, t.allocator, &diags, bundle_path));
    try t.expectEqual(@as(usize, 0), diags.list.items.len);

    const manifest_path = try std.fs.path.join(arena.allocator(), &.{ bundle_path, "manifest.json" });
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, manifest_path, arena.allocator(), .limited(max_manifest_bytes + 1));
    var lens = try manifest.parse(t.allocator, &diags, source) orelse return error.TestUnexpectedResult;
    defer lens.deinit();
    try t.expect(try validateTriggers(t.allocator, &diags, &lens));
}

test "a disallowed top level file fails bundle structure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
    try tmp.dir.writeFile(t.io, .{ .sub_path = "notes.txt", .data = "should not be here" });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(!try validateBundle(t.io, t.allocator, &diags, bundle_path));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "not a permitted bundle entry") != null) found = true;
    }
    try t.expect(found);
}

test "an oversized shader file fails bundle structure" {
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
    try tmp.dir.createDirPath(t.io, "shaders");
    const oversized = try t.allocator.alloc(u8, max_shader_bytes + 1);
    defer t.allocator.free(oversized);
    @memset(oversized, 'a');
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shaders/big.glsl", .data = oversized });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(!try validateBundle(t.io, t.allocator, &diags, bundle_path));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.message, "exceeds the") != null) found = true;
    }
    try t.expect(found);
}

test "a trigger with a bad when expression fails trigger validation" {
    const bad_manifest =
        \\{
        \\  "glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x",
        \\  "engine_compat": ">=0.5", "capabilities": [],
        \\  "parameters": [{"name": "x", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}],
        \\  "nodes": [], "triggers": [
        \\    {"when": "audio.level", "action": {"kind": "param_set", "target": "x", "to": 1.0}}
        \\  ]
        \\}
    ;
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = bad_manifest });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };
    try t.expect(try validateBundle(t.io, t.allocator, &diags, bundle_path));

    const manifest_path = try std.fs.path.join(arena.allocator(), &.{ bundle_path, "manifest.json" });
    const source = try std.Io.Dir.cwd().readFileAlloc(t.io, manifest_path, arena.allocator(), .limited(max_manifest_bytes + 1));
    var lens = try manifest.parse(t.allocator, &diags, source) orelse return error.TestUnexpectedResult;
    defer lens.deinit();
    try t.expect(!try validateTriggers(t.allocator, &diags, &lens));
}

const valid_fragment_shader =
    \\$input v_texcoord0
    \\
    \\#include <bgfx_shader.sh>
    \\
    \\SAMPLER2D(s_texColor, 0);
    \\
    \\void main()
    \\{
    \\    gl_FragColor = texture2D(s_texColor, v_texcoord0);
    \\}
;

const broken_fragment_shader =
    \\$input v_texcoord0
    \\
    \\#include <bgfx_shader.sh>
    \\
    \\void main()
    \\{
    \\    gl_FragColor = this_symbol_does_not_exist;
    \\}
;

test "a fragment shader compiling against the fixed varying contract passes the shader-compile stage" {
    if (build_options.shaderc_path.len == 0) return error.SkipZigTest;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
    try tmp.dir.createDirPath(t.io, "shaders");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shaders/fs_tint.glsl", .data = valid_fragment_shader });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(try validateBundle(t.io, t.allocator, &diags, bundle_path));
    try t.expect(try validateShaders(t.io, t.allocator, &diags, bundle_path, null));
    try t.expectEqual(@as(usize, 0), diags.list.items.len);
}

test "packaging copies the bundle and writes compiled bytecode alongside each shader's source" {
    if (build_options.shaderc_path.len == 0) return error.SkipZigTest;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
    try tmp.dir.createDirPath(t.io, "shaders");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shaders/fs_tint.glsl", .data = valid_fragment_shader });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);
    var out_buf: [64]u8 = undefined;
    const package_dir = std.fmt.bufPrint(&out_buf, "{s}-packaged", .{bundle_path}) catch unreachable;
    defer std.Io.Dir.cwd().deleteTree(t.io, package_dir) catch {};

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(try validateBundle(t.io, t.allocator, &diags, bundle_path));
    try copyBundleTree(t.io, t.allocator, bundle_path, package_dir);
    try t.expect(try validateShaders(t.io, t.allocator, &diags, bundle_path, package_dir));

    const manifest_copy = try std.fs.path.join(arena.allocator(), &.{ package_dir, "manifest.json" });
    _ = try std.Io.Dir.cwd().readFileAlloc(t.io, manifest_copy, arena.allocator(), .limited(max_manifest_bytes));

    const source_copy = try std.fs.path.join(arena.allocator(), &.{ package_dir, "shaders/fs_tint.glsl" });
    _ = try std.Io.Dir.cwd().readFileAlloc(t.io, source_copy, arena.allocator(), .limited(max_shader_bytes));

    for ([_][]const u8{ "metal", "spirv", "essl" }) |tag| {
        const bin_path = try std.fmt.allocPrint(arena.allocator(), "{s}/shaders/fs_tint.{s}.bin", .{ package_dir, tag });
        const bytes = try std.Io.Dir.cwd().readFileAlloc(t.io, bin_path, arena.allocator(), .limited(max_shader_bytes));
        try t.expect(bytes.len > 0);
    }
}

test "a fragment shader referencing an unknown symbol fails the shader-compile stage" {
    if (build_options.shaderc_path.len == 0) return error.SkipZigTest;

    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
    try tmp.dir.createDirPath(t.io, "shaders");
    try tmp.dir.writeFile(t.io, .{ .sub_path = "shaders/fs_broken.glsl", .data = broken_fragment_shader });

    var path_buf: [64]u8 = undefined;
    const bundle_path = tmpBundlePath(tmp, &path_buf);

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };

    try t.expect(try validateBundle(t.io, t.allocator, &diags, bundle_path));
    try t.expect(!try validateShaders(t.io, t.allocator, &diags, bundle_path, null));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.path, "fs_broken.glsl") != null) found = true;
    }
    try t.expect(found);
}

/// Applies one small, random structural mutation to `base` - a bit flip,
/// a byte inserted or deleted, a truncation, a chunk duplicated
/// elsewhere in the string, or (occasionally) `base` ignored entirely in
/// favor of pure random bytes. This is what turns a handful of seed
/// corpus entries below into the thousands of malformed variations
/// SPEC.md section 9 requires the validator survive.
fn mutate(allocator: std.mem.Allocator, random: std.Random, base: []const u8) ![]u8 {
    switch (random.uintLessThan(u8, 6)) {
        0 => {
            const out = try allocator.alloc(u8, random.uintLessThan(usize, 512));
            random.bytes(out);
            return out;
        },
        1 => {
            if (base.len == 0) return allocator.dupe(u8, base);
            return allocator.dupe(u8, base[0..random.uintLessThan(usize, base.len)]);
        },
        2 => {
            const out = try allocator.dupe(u8, base);
            if (out.len > 0) {
                const idx = random.uintLessThan(usize, out.len);
                const bit: u3 = @truncate(random.int(u8));
                out[idx] ^= @as(u8, 1) << bit;
            }
            return out;
        },
        3 => {
            const idx = if (base.len == 0) 0 else random.uintLessThan(usize, base.len + 1);
            const out = try allocator.alloc(u8, base.len + 1);
            @memcpy(out[0..idx], base[0..idx]);
            out[idx] = random.int(u8);
            @memcpy(out[idx + 1 ..], base[idx..]);
            return out;
        },
        4 => {
            if (base.len == 0) return allocator.dupe(u8, base);
            const idx = random.uintLessThan(usize, base.len);
            const out = try allocator.alloc(u8, base.len - 1);
            @memcpy(out[0..idx], base[0..idx]);
            @memcpy(out[idx..], base[idx + 1 ..]);
            return out;
        },
        else => {
            if (base.len == 0) return allocator.dupe(u8, base);
            const a = random.uintLessThan(usize, base.len);
            const b = a + random.uintLessThan(usize, base.len - a + 1);
            const chunk = base[a..b];
            const idx = random.uintLessThan(usize, base.len + 1);
            const out = try allocator.alloc(u8, base.len + chunk.len);
            @memcpy(out[0..idx], base[0..idx]);
            @memcpy(out[idx..][0..chunk.len], chunk);
            @memcpy(out[idx + chunk.len ..], base[idx..]);
            return out;
        },
    }
}

const fuzz_seed_manifests = [_][]const u8{
    minimal_valid_manifest,
    "{}",
    "",
    "null",
    "[]",
    "\"just a string\"",
    "{\"glf\": \"1.0\"}",
    \\{"glf":"1.0","id":"x","version":"1","display_name":"x","engine_compat":">=0.5",
    \\ "capabilities":["face"],"parameters":[{"name":"a","type":"float","default":0,"min":0,"max":1}],
    \\ "nodes":[{"id":"n","type":"beauty.reshape","inputs":{"frame":"camera"},"params":{"x":"$a"}}],
    \\ "triggers":[{"when":"face.present && tap","action":{"kind":"param_set","target":"a","to":1}}]}
    ,
};

// SPEC.md section 9: the validator runs against a fuzz corpus of
// malformed manifests in CI, and a fuzz-found crash or leak is a spec
// violation of section 8's guarantee, not a lens-author error. Every
// candidate is either rejected with diagnostics or returns a Manifest
// this test immediately deinits - std.testing.allocator catches a leak
// in either path at the end of the run, and a crash here fails the
// whole test binary, which is the point.
test "manifest.parse never crashes or leaks on malformed input (fuzz)" {
    var prng = std.Random.DefaultPrng.init(0xC0FFEE);
    const random = prng.random();

    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();

    var i: usize = 0;
    while (i < 4000) : (i += 1) {
        _ = arena.reset(.retain_capacity);
        const base = fuzz_seed_manifests[random.uintLessThan(usize, fuzz_seed_manifests.len)];
        const candidate = try mutate(arena.allocator(), random, base);

        var diags = manifest.Diagnostics{ .arena = arena.allocator() };
        var result = try manifest.parse(t.allocator, &diags, candidate);
        if (result) |*lens| {
            var mutable = lens.*;
            mutable.deinit();
        }
    }
}

const fuzz_seed_shaders = [_][]const u8{
    valid_fragment_shader,
    broken_fragment_shader,
    "",
    "$input v_texcoord0",
    "#include <bgfx_shader.sh>\nvoid main() {}",
};

// The shader-input half of SPEC.md section 9's fuzz corpus requirement.
// Malformed source reaching a real compiler is expected to fail with
// diagnostics, not to crash or hang our process - shaderc runs as a
// child process specifically so a compiler crash on adversarial input
// surfaces as a Term this test observes, never a signal our own
// process receives. Kept to a smaller iteration count than the
// manifest fuzzer since every case spawns real subprocesses.
test "the shader-compile stage never crashes or leaks on malformed shader source (fuzz)" {
    if (build_options.shaderc_path.len == 0) return error.SkipZigTest;

    var prng = std.Random.DefaultPrng.init(0x5EED);
    const random = prng.random();

    var i: usize = 0;
    while (i < 40) : (i += 1) {
        var tmp = t.tmpDir(.{});
        defer tmp.cleanup();
        try tmp.dir.writeFile(t.io, .{ .sub_path = "manifest.json", .data = minimal_valid_manifest });
        try tmp.dir.createDirPath(t.io, "shaders");

        var mutate_arena = std.heap.ArenaAllocator.init(t.allocator);
        defer mutate_arena.deinit();
        const base = fuzz_seed_shaders[random.uintLessThan(usize, fuzz_seed_shaders.len)];
        const candidate = try mutate(mutate_arena.allocator(), random, base);
        try tmp.dir.writeFile(t.io, .{ .sub_path = "shaders/fs_fuzz.glsl", .data = candidate });

        var path_buf: [64]u8 = undefined;
        const bundle_path = tmpBundlePath(tmp, &path_buf);

        var diag_arena = std.heap.ArenaAllocator.init(t.allocator);
        defer diag_arena.deinit();
        var diags = manifest.Diagnostics{ .arena = diag_arena.allocator() };
        _ = try validateShaders(t.io, t.allocator, &diags, bundle_path, null);
    }
}
