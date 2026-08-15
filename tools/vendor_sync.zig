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
};

// Licenses that may enter this codebase. Anything else fails closed,
// including anything unknown.
const license_allowlist = [_][]const u8{ "MIT", "BSD-2-Clause", "BSD-3-Clause", "Apache-2.0", "Zlib" };

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
        if (!std.mem.eql(u8, std.mem.trim(u8, stamp, " \n"), pin.commit)) return false;
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

    fn syncOne(s: *Sync, name: []const u8) !void {
        const pin = s.loadPin(name) catch |err| {
            s.fail("{s}: cannot load pin: {t}", .{ name, err });
            return;
        };
        if (!std.mem.eql(u8, pin.name, name)) {
            s.fail("{s}: pin name '{s}' does not match its directory", .{ name, pin.name });
            return;
        }
        if (!licenseAllowed(pin.license)) {
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

        Io.Dir.cwd().createDirPath(s.io, ".vendor-archives") catch {};
        const archive_path = try std.fmt.allocPrint(s.arena, ".vendor-archives/{s}-{s}.tar.gz", .{ pin.name, pin.commit });
        if (!s.fileDigestMatches(archive_path, pin.archive_sha256)) {
            const url = if (pin.archive_url.len != 0)
                pin.archive_url
            else
                try std.fmt.allocPrint(s.arena, "{s}/archive/{s}.tar.gz", .{ pin.repo, pin.commit });
            std.debug.print("vendor-sync: fetching {s}\n", .{url});
            try s.run(&.{ "curl", "-fsSL", url, "-o", archive_path });
            if (!s.fileDigestMatches(archive_path, pin.archive_sha256)) {
                s.fail("{s}: archive digest mismatch after download", .{name});
                return;
            }
        }

        const dest = try std.fmt.allocPrint(s.arena, ".vendor/{s}", .{pin.name});
        Io.Dir.cwd().deleteTree(s.io, dest) catch {};
        try Io.Dir.cwd().createDirPath(s.io, dest);
        try s.run(&.{ "tar", "-xzf", archive_path, "-C", dest, "--strip-components=1" });

        const license_path = try std.fmt.allocPrint(s.arena, "{s}/{s}", .{ dest, pin.license_file });
        if (!s.fileDigestMatches(license_path, pin.license_sha256)) {
            s.fail("{s}: license file digest mismatch; upstream changed its license text", .{name});
            Io.Dir.cwd().deleteTree(s.io, dest) catch {};
            return;
        }

        const stamp_path = try std.fmt.allocPrint(s.arena, "{s}/.pin-commit", .{dest});
        try Io.Dir.cwd().writeFile(s.io, .{ .sub_path = stamp_path, .data = pin.commit });
        std.debug.print("vendor-sync: {s} {s} synced at {s}\n", .{ pin.name, pin.version, pin.commit[0..12] });
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
        try s.syncOne(name);
    }

    if (s.failures != 0) {
        std.debug.print("vendor-sync: {d} failure(s)\n", .{s.failures});
        return 1;
    }
    return 0;
}

const t = std.testing;

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
