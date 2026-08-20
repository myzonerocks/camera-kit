//! Rebuilds .vendor from the pins in third_party. Each vendor is pinned by
//! exact commit and archive digest; the fetched tree is verified before use
//! and its license must be on the allowlist with the exact text the pin
//! recorded. A fresh clone plus this tool reproduces the vendor trees bit
//! for bit; nothing under .vendor is ever committed.
//!
//!   vendor-sync            fetch and verify everything the pins name
//!   vendor-sync --check    verify only; exit 1 if anything is missing,
//!                          tampered, or license-violating (the CI gate)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Pin = struct {
    name: []const u8,
    repo: []const u8,
    version: []const u8,
    commit: []const u8,
    archive_sha256: []const u8,
    license: []const u8,
    license_file: []const u8,
    license_sha256: []const u8,
    /// Overrides the github archive pattern for other hosts or tag URLs.
    archive_url: []const u8 = "",
    /// Per-host-platform prebuilt archive, for a vendor with no single
    /// source tree every target compiles itself.
    macos_aarch64_url: []const u8 = "",
    macos_aarch64_sha256: []const u8 = "",
    linux_x86_64_url: []const u8 = "",
    linux_x86_64_sha256: []const u8 = "",
    /// Skip rather than fail on a host with no matching platform archive.
    host_optional: bool = false,
    /// Excluded from the default (no --only) sync - large, single-use
    /// vendors name this so every CI job's setup doesn't pay for them.
    opt_in: bool = false,
};

const builtin = @import("builtin");

const ArchiveRef = struct { url: []const u8, sha256: []const u8 };

fn hostArchiveOverrideFor(pin: Pin, os_tag: std.Target.Os.Tag, cpu_arch: std.Target.Cpu.Arch) ?ArchiveRef {
    if (os_tag == .macos and cpu_arch == .aarch64 and pin.macos_aarch64_url.len != 0) {
        return .{ .url = pin.macos_aarch64_url, .sha256 = pin.macos_aarch64_sha256 };
    }
    if (os_tag == .linux and cpu_arch == .x86_64 and pin.linux_x86_64_url.len != 0) {
        return .{ .url = pin.linux_x86_64_url, .sha256 = pin.linux_x86_64_sha256 };
    }
    return null;
}

fn hostArchiveOverride(pin: Pin) ?ArchiveRef {
    return hostArchiveOverrideFor(pin, builtin.os.tag, builtin.cpu.arch);
}

// Licenses that may enter this codebase. Anything else fails closed,
// including anything unknown.
const license_allowlist = [_][]const u8{ "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "Zlib" };

// Named exceptions: a specific vendor may carry a specific license outside
// the allowlist, recorded in the decisions log. Nothing else inherits it.
const license_exceptions = [_]struct { name: []const u8, license: []const u8 }{
    .{ .name = "eigen", .license = "MPL-2.0" },
    .{ .name = "fft2d", .license = "Ooura" },
    .{ .name = "emscripten-python", .license = "PSF-2.0" },
};

const max_archive_bytes: usize = 1 << 29;

const Sync = struct {
    arena: Allocator,
    io: Io,
    check_only: bool,
    failures: usize = 0,

    fn fail(s: *Sync, comptime fmt: []const u8, args: anytype) void {
        s.failures += 1;
        std.debug.print("vendor-sync: " ++ fmt ++ "\n", args);
    }

    fn sha256Hex(data: []const u8) [64]u8 {
        var digest: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
        return std.fmt.bytesToHex(digest, .lower);
    }

    fn fileDigestMatches(s: *Sync, path: []const u8, expected: []const u8) bool {
        const data = Io.Dir.cwd().readFileAlloc(s.io, path, s.arena, .limited(max_archive_bytes)) catch return false;
        return std.mem.eql(u8, &sha256Hex(data), expected);
    }

    /// Sorted (filename order, matching application order) *.patch names
    /// under third_party/<name>/patches - empty, not an error, when that
    /// directory doesn't exist (the common no-patches case).
    fn sortedPatchNames(s: *Sync, patches_dir_path: []const u8) ![][]const u8 {
        var dir = Io.Dir.cwd().openDir(s.io, patches_dir_path, .{ .iterate = true }) catch return &.{};
        defer dir.close(s.io);

        var names: std.ArrayList([]const u8) = .empty;
        var it = dir.iterate();
        while (try it.next(s.io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.name, ".patch")) continue;
            try names.append(s.arena, try s.arena.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn lessThan(_: void, a: []const u8, b: []const u8) bool {
                return std.mem.lessThan(u8, a, b);
            }
        }.lessThan);
        return names.items;
    }

    /// Digest over every patch's name and content, in application order.
    /// Folded into the synced-vendor stamp so that adding, editing, or
    /// removing a patch invalidates the "already synced" fast path - without
    /// this, a patch added after a vendor's first sync would silently never
    /// apply, since vendorSynced() only used to compare pin.commit.
    fn patchesDigest(s: *Sync, name: []const u8) ![64]u8 {
        const patches_dir_path = try std.fmt.allocPrint(s.arena, "third_party/{s}/patches", .{name});
        const names = try s.sortedPatchNames(patches_dir_path);

        var buf: std.ArrayList(u8) = .empty;
        for (names) |patch_name| {
            const patch_path = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ patches_dir_path, patch_name });
            const data = try Io.Dir.cwd().readFileAlloc(s.io, patch_path, s.arena, .limited(1 << 20));
            try buf.appendSlice(s.arena, patch_name);
            try buf.append(s.arena, '\n');
            try buf.appendSlice(s.arena, data);
            try buf.append(s.arena, '\n');
        }
        return sha256Hex(buf.items);
    }

    fn licenseExcepted(name: []const u8, license: []const u8) bool {
        for (license_exceptions) |exception| {
            if (std.mem.eql(u8, exception.name, name) and std.mem.eql(u8, exception.license, license)) return true;
        }
        return false;
    }

    fn licenseAllowed(license: []const u8) bool {
        for (license_allowlist) |ok| {
            if (std.mem.eql(u8, license, ok)) return true;
        }
        return false;
    }

    fn loadPin(s: *Sync, name: []const u8) !Pin {
        const path = try std.fmt.allocPrint(s.arena, "third_party/{s}/pin.zon", .{name});
        const source = try Io.Dir.cwd().readFileAllocOptions(s.io, path, s.arena, .limited(1 << 16), .of(u8), 0);
        return std.zon.parse.fromSliceAlloc(Pin, s.arena, source, null, .{});
    }

    fn vendorSynced(s: *Sync, pin: Pin) bool {
        const stamp_path = std.fmt.allocPrint(s.arena, ".vendor/{s}/.pin-commit", .{pin.name}) catch return false;
        const stamp = Io.Dir.cwd().readFileAlloc(s.io, stamp_path, s.arena, .limited(256)) catch return false;
        var lines = std.mem.splitScalar(u8, std.mem.trim(u8, stamp, " \n"), '\n');
        const stamped_commit = lines.next() orelse return false;
        if (!std.mem.eql(u8, stamped_commit, pin.commit)) return false;
        // Old-format stamps (pre-dating patch tracking) have no second
        // line - treated as unsynced so the one-time upgrade re-syncs and
        // re-stamps rather than silently trusting a tree patches may have
        // moved past.
        const stamped_patches = lines.next() orelse return false;
        const current_patches = s.patchesDigest(pin.name) catch return false;
        if (!std.mem.eql(u8, stamped_patches, &current_patches)) return false;
        const license_path = std.fmt.allocPrint(s.arena, ".vendor/{s}/{s}", .{ pin.name, pin.license_file }) catch return false;
        return s.fileDigestMatches(license_path, pin.license_sha256);
    }

    fn run(s: *Sync, argv: []const []const u8) !void {
        const res = try std.process.run(s.arena, s.io, .{ .argv = argv });
        switch (res.term) {
            .exited => |code| if (code == 0) return,
            else => {},
        }
        std.debug.print("vendor-sync: {s} failed: {s}\n", .{ argv[0], res.stderr });
        return error.CommandFailed;
    }

    fn syncOne(s: *Sync, name: []const u8, explicit: bool) !void {
        const pin = s.loadPin(name) catch |err| {
            s.fail("{s}: cannot load pin: {t}", .{ name, err });
            return;
        };
        if (!std.mem.eql(u8, pin.name, name)) {
            s.fail("{s}: pin name '{s}' does not match its directory", .{ name, pin.name });
            return;
        }
        if (pin.opt_in and !explicit) {
            std.debug.print("vendor-sync: {s} opt-in, skipped\n", .{name});
            return;
        }
        if (!licenseAllowed(pin.license) and !licenseExcepted(pin.name, pin.license)) {
            s.fail("{s}: license '{s}' is not on the allowlist", .{ name, pin.license });
            return;
        }
        if (s.vendorSynced(pin)) {
            std.debug.print("vendor-sync: {s} {s} ok\n", .{ pin.name, pin.version });
            return;
        }
        if (s.check_only) {
            s.fail("{s}: not synced or tampered; run zig build vendor-sync", .{name});
            return;
        }

        const override = hostArchiveOverride(pin);
        const platform_pinned = pin.macos_aarch64_url.len != 0 or pin.linux_x86_64_url.len != 0;
        if (override == null and platform_pinned and pin.archive_url.len == 0) {
            if (pin.host_optional) {
                std.debug.print("vendor-sync: {s} not needed on this host, skipped\n", .{name});
                return;
            }
            s.fail("{s}: no prebuilt archive pinned for this host ({t}-{t})", .{ name, builtin.os.tag, builtin.cpu.arch });
            return;
        }
        const url = if (override) |o|
            o.url
        else if (pin.archive_url.len != 0)
            pin.archive_url
        else
            try std.fmt.allocPrint(s.arena, "{s}/archive/{s}.tar.gz", .{ pin.repo, pin.commit });
        const archive_sha256 = if (override) |o| o.sha256 else pin.archive_sha256;
        const archive_ext = if (std.mem.endsWith(u8, url, ".tar.xz")) ".tar.xz" else ".tar.gz";

        Io.Dir.cwd().createDirPath(s.io, ".vendor-archives") catch {};
        const archive_path = try std.fmt.allocPrint(s.arena, ".vendor-archives/{s}-{s}{s}", .{ pin.name, pin.commit, archive_ext });
        if (!s.fileDigestMatches(archive_path, archive_sha256)) {
            std.debug.print("vendor-sync: fetching {s}\n", .{url});
            try s.run(&.{ "curl", "-fsSL", url, "-o", archive_path });
            if (!s.fileDigestMatches(archive_path, archive_sha256)) {
                s.fail("{s}: archive digest mismatch after download", .{name});
                return;
            }
        }

        const dest = try std.fmt.allocPrint(s.arena, ".vendor/{s}", .{pin.name});
        Io.Dir.cwd().deleteTree(s.io, dest) catch {};
        try Io.Dir.cwd().createDirPath(s.io, dest);
        // -f auto-detects gzip vs xz.
        try s.run(&.{ "tar", "-xf", archive_path, "-C", dest, "--strip-components=1" });

        const license_path = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dest, pin.license_file });
        if (!s.fileDigestMatches(license_path, pin.license_sha256)) {
            s.fail("{s}: license file digest mismatch; upstream changed its license text", .{name});
            Io.Dir.cwd().deleteTree(s.io, dest) catch {};
            return;
        }

        const patches_dir_path = try std.fmt.allocPrint(s.arena, "third_party/{s}/patches", .{name});
        try s.applyPatches(name, patches_dir_path, dest);

        const patches_digest = try s.patchesDigest(name);
        const stamp_data = try std.fmt.allocPrint(s.arena, "{s}\n{s}\n", .{ pin.commit, patches_digest });
        const stamp_path = try std.fmt.allocPrint(s.arena, "{s}/.pin-commit", .{dest});
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = stamp_path, .data = stamp_data });
        std.debug.print("vendor-sync: {s} {s} synced at {s}\n", .{ pin.name, pin.version, pin.commit[0..@min(pin.commit.len, 12)] });
    }

    /// Applies third_party/<name>/patches/*.patch, in filename order, onto
    /// the just-extracted dest tree - local modifications layered on top
    /// of the pristine, digest-checked archive, never folded into what's
    /// cryptographically pinned (pin.archive_sha256 stays anchored to the
    /// unpatched source). No patches/ directory is the common case and a
    /// silent no-op. A patch that no longer applies cleanly against the
    /// pinned commit fails the whole sync loudly (via `try`, matching how
    /// this function's own curl/tar steps above already fail) rather than
    /// leaving a half-patched tree that looks synced.
    fn applyPatches(s: *Sync, name: []const u8, patches_dir_path: []const u8, dest: []const u8) !void {
        const names = try s.sortedPatchNames(patches_dir_path);

        for (names) |patch_name| {
            // patch's own -d chdirs into dest before it opens -i's file,
            // so -i must resolve from there, not from this process's cwd.
            // Climb back out by dest's own depth, then down to the patch,
            // which stays correct for any relative dest.
            var climb: std.ArrayList(u8) = .empty;
            var segments = std.mem.tokenizeScalar(u8, dest, '/');
            while (segments.next()) |_| try climb.appendSlice(s.arena, "../");
            const patch_path = try std.fmt.allocPrint(s.arena, "{s}{s}/{s}", .{ climb.items, patches_dir_path, patch_name });
            std.debug.print("vendor-sync: {s} applying {s}\n", .{ name, patch_name });
            try s.run(&.{ "patch", "-p1", "-d", dest, "-i", patch_path });
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var check_only = false;
    var only: ?[]const u8 = null;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else if (std.mem.eql(u8, arg, "--only")) {
            only = args.next() orelse {
                std.debug.print("vendor-sync: --only needs a vendor name\n", .{});
                return 2;
            };
        } else {
            std.debug.print("vendor-sync: unknown argument '{s}'\n", .{arg});
            return 2;
        }
    }

    var s: Sync = .{ .arena = init.arena.allocator(), .io = init.io, .check_only = check_only };

    var names: std.ArrayList([]const u8) = .empty;
    var dir = Io.Dir.cwd().openDir(s.io, "third_party", .{ .iterate = true }) catch {
        std.debug.print("vendor-sync: no third_party directory\n", .{});
        return 1;
    };
    defer dir.close(s.io);
    var it = dir.iterate();
    while (try it.next(s.io)) |entry| {
        if (entry.kind != .directory) continue;
        try names.append(s.arena, try s.arena.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn lessThan(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lessThan);

    for (names.items) |name| {
        if (only) |wanted| {
            if (!std.mem.eql(u8, name, wanted)) continue;
        }
        try s.syncOne(name, only != null);
    }

    if (s.failures != 0) {
        std.debug.print("vendor-sync: {d} failure(s)\n", .{s.failures});
        return 1;
    }
    return 0;
}

const t = std.testing;

test "named exceptions admit exactly one vendor and license pair" {
    try t.expect(Sync.licenseExcepted("eigen", "MPL-2.0"));
    try t.expect(Sync.licenseExcepted("fft2d", "Ooura"));
    try t.expect(!Sync.licenseExcepted("eigen", "GPL-3.0"));
    try t.expect(!Sync.licenseExcepted("somelib", "MPL-2.0"));
}

test "license allowlist admits permissive and rejects the rest" {
    try t.expect(Sync.licenseAllowed("MIT"));
    try t.expect(Sync.licenseAllowed("Apache-2.0"));
    try t.expect(Sync.licenseAllowed("Zlib"));
    try t.expect(!Sync.licenseAllowed("GPL-3.0"));
    try t.expect(!Sync.licenseAllowed("AGPL-3.0"));
    try t.expect(!Sync.licenseAllowed("LGPL-2.1"));
    try t.expect(!Sync.licenseAllowed(""));
    try t.expect(!Sync.licenseAllowed("mit"));
}

test "sha256 hex matches a known vector" {
    const hex = Sync.sha256Hex("abc");
    try t.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
}

test "host archive override picks the matching platform pin" {
    const pin = Pin{
        .name = "x",
        .repo = "",
        .version = "",
        .commit = "",
        .archive_sha256 = "",
        .license = "MIT",
        .license_file = "",
        .license_sha256 = "",
        .macos_aarch64_url = "mac-url",
        .macos_aarch64_sha256 = "mac-sha",
        .linux_x86_64_url = "linux-url",
        .linux_x86_64_sha256 = "linux-sha",
    };
    try t.expectEqualStrings("mac-url", hostArchiveOverrideFor(pin, .macos, .aarch64).?.url);
    try t.expectEqualStrings("linux-url", hostArchiveOverrideFor(pin, .linux, .x86_64).?.url);
    try t.expect(hostArchiveOverrideFor(pin, .windows, .x86_64) == null);
    try t.expect(hostArchiveOverrideFor(pin, .macos, .x86_64) == null);
}

test "host archive override is null with no platform pins set" {
    const pin = Pin{
        .name = "x",
        .repo = "",
        .version = "",
        .commit = "",
        .archive_sha256 = "",
        .license = "MIT",
        .license_file = "",
        .license_sha256 = "",
    };
    try t.expect(hostArchiveOverrideFor(pin, .macos, .aarch64) == null);
}

test "applyPatches finds, sorts, and really applies a patch onto a synced vendor tree" {
    const cwd = Io.Dir.cwd();
    // A unique root per run: this test compiles into several parallel
    // test binaries, and a fixed path let one instance delete the tree
    // under another's running patch child. The tmp dir also keeps
    // debris out of the tracked third_party tree.
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    const vendor_name = "_test_patch_vendor";
    var patches_buf: [96]u8 = undefined;
    const patches_dir = try std.fmt.bufPrint(&patches_buf, ".zig-cache/tmp/{s}/patches", .{&tmp.sub_path});
    var dest_buf: [96]u8 = undefined;
    const dest = try std.fmt.bufPrint(&dest_buf, ".zig-cache/tmp/{s}/vendor", .{&tmp.sub_path});

    try cwd.createDirPath(t.io, patches_dir);
    try cwd.createDirPath(t.io, dest);
    var hello_buf: [128]u8 = undefined;
    const hello_path = try std.fmt.bufPrint(&hello_buf, "{s}/hello.txt", .{dest});
    try cwd.writeFile(t.io, .{ .sub_path = hello_path, .data = "before\n" });
    // Two patches, named so alphabetical order matters (0002 depends on
    // 0001 having already landed) - proves real ordering, not just that
    // a single patch applies.
    var second_buf: [160]u8 = undefined;
    const second_path = try std.fmt.bufPrint(&second_buf, "{s}/0002-second.patch", .{patches_dir});
    try cwd.writeFile(t.io, .{ .sub_path = second_path, .data =
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -1 +1 @@
        \\-middle
        \\+after
        \\
    });
    var first_buf: [160]u8 = undefined;
    const first_path = try std.fmt.bufPrint(&first_buf, "{s}/0001-first.patch", .{patches_dir});
    try cwd.writeFile(t.io, .{ .sub_path = first_path, .data =
        \\--- a/hello.txt
        \\+++ b/hello.txt
        \\@@ -1 +1 @@
        \\-before
        \\+middle
        \\
    });

    var arena_state = std.heap.ArenaAllocator.init(t.allocator);
    defer arena_state.deinit();
    var s: Sync = .{ .arena = arena_state.allocator(), .io = t.io, .check_only = false };
    try s.applyPatches(vendor_name, patches_dir, dest);

    const result = try cwd.readFileAlloc(t.io, hello_path, t.allocator, .limited(1024));
    defer t.allocator.free(result);
    try t.expectEqualStrings("after\n", result);
}

test "opt_in and host_optional default to false" {
    const pin = Pin{
        .name = "x",
        .repo = "",
        .version = "",
        .commit = "",
        .archive_sha256 = "",
        .license = "MIT",
        .license_file = "",
        .license_sha256 = "",
    };
    try t.expect(!pin.opt_in);
    try t.expect(!pin.host_optional);
}
