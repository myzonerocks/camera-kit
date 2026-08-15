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

const shader_profiles = [_]struct { profile: []const u8, platform: []const u8 }{
    .{ .profile = "metal", .platform = "ios" },
    .{ .profile = "spirv", .platform = "android" },
    .{ .profile = "300_es", .platform = "android" },
};

/// Every file under shaders/ is a fragment shader for a full-screen pass,
/// authored against the runtime's one fixed vertex/varying contract
/// (lenses/shaders/varying.def.sc, SPEC.md section 7). Compiled through
/// the pinned shaderc toolchain to every platform profile a conforming
/// runtime ships, since a shader that compiles for one platform and not
/// another is exactly the failure this stage exists to catch before a
/// lens ships.
fn validateShaders(io: std.Io, gpa: std.mem.Allocator, diags: *manifest.Diagnostics, bundle_path: []const u8) !bool {
    var bundle_dir = std.Io.Dir.cwd().openDir(io, bundle_path, .{ .iterate = true }) catch return true;
    defer bundle_dir.close(io);
    var shaders_dir = bundle_dir.openDir(io, "shaders", .{ .iterate = true }) catch return true;
    defer shaders_dir.close(io);

    var walker = try shaders_dir.walk(gpa);
    defer walker.deinit();
    var ok = true;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const diag_path = try std.fmt.allocPrint(diags.arena, "/shaders/{s}", .{entry.path});

        if (build_options.shaderc_path.len == 0) {
            try diags.add(diag_path, "shader toolchain unavailable (run zig build vendor-sync)", .{});
            ok = false;
            continue;
        }

        const disk_path = try std.fs.path.join(diags.arena, &.{ bundle_path, "shaders", entry.path });
        for (shader_profiles) |profile| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(gpa);
            try argv.appendSlice(gpa, &.{
                build_options.shaderc_path,
                "-f",           disk_path,
                "-o",           "/dev/null",
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

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = init.gpa;
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    const bundle_path = args.next() orelse {
        std.debug.print("lens_validator: usage: lens_validator <bundle-path>\n", .{});
        return 2;
    };

    var diags = manifest.Diagnostics{ .arena = arena };

    if (!try validateBundle(io, gpa, &diags, bundle_path)) {
        try report(io, bundle_path, diags.list.items, false);
        return 1;
    }

    const manifest_path = try std.fs.path.join(arena, &.{ bundle_path, "manifest.json" });
    const source = try std.Io.Dir.cwd().readFileAlloc(io, manifest_path, arena, .limited(max_manifest_bytes + 1));

    var lens = try manifest.parse(gpa, &diags, source) orelse {
        try report(io, bundle_path, diags.list.items, false);
        return 1;
    };
    defer lens.deinit();

    if (!try validateTriggers(gpa, &diags, &lens)) {
        try report(io, bundle_path, diags.list.items, false);
        return 1;
    }

    if (!try validateShaders(io, gpa, &diags, bundle_path)) {
        try report(io, bundle_path, diags.list.items, false);
        return 1;
    }

    try report(io, bundle_path, &.{}, true);
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
    try t.expect(try validateShaders(t.io, t.allocator, &diags, bundle_path));
    try t.expectEqual(@as(usize, 0), diags.list.items.len);
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
    try t.expect(!try validateShaders(t.io, t.allocator, &diags, bundle_path));
    var found = false;
    for (diags.list.items) |d| {
        if (std.mem.indexOf(u8, d.path, "fs_broken.glsl") != null) found = true;
    }
    try t.expect(found);
}
