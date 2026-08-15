//! Rebuilds .models from third_party/models.lock. Every model is pinned by
//! versioned url and digest; a fresh clone plus this tool reproduces the
//! model set bit for bit, and nothing under .models is ever committed.
//!
//!   fetch-models            fetch and verify everything the lock names
//!   fetch-models --check    verify only; exit 1 on anything missing or
//!                           tampered (part of the ci gate)

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const Model = struct {
    name: []const u8,
    url: []const u8,
    sha256: []const u8,
    license: []const u8,
};

const Lock = struct {
    models: []const Model,
};

const max_model_bytes: usize = 1 << 28;

fn sha256Hex(data: []const u8) [64]u8 {
    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(data, &digest, .{});
    return std.fmt.bytesToHex(digest, .lower);
}

const Fetch = struct {
    arena: Allocator,
    io: Io,
    check_only: bool,
    failures: usize = 0,

    fn fail(f: *Fetch, comptime fmt: []const u8, args: anytype) void {
        f.failures += 1;
        std.debug.print("fetch-models: " ++ fmt ++ "\n", args);
    }

    fn digestMatches(f: *Fetch, path: []const u8, expected: []const u8) bool {
        const data = Io.Dir.cwd().readFileAlloc(f.io, path, f.arena, .limited(max_model_bytes)) catch return false;
        return std.mem.eql(u8, &sha256Hex(data), expected);
    }

    fn licenseAllowed(license: []const u8) bool {
        // Models and corpus imagery may only enter under terms that allow
        // redistribution without conditions we cannot meet in a fetch.
        for ([_][]const u8{ "Apache-2.0", "Public-domain-US-government" }) |allowed| {
            if (std.mem.eql(u8, license, allowed)) return true;
        }
        return false;
    }

    fn syncOne(f: *Fetch, model: Model) !void {
        if (!licenseAllowed(model.license)) {
            f.fail("{s}: license '{s}' is not on the allowlist", .{ model.name, model.license });
            return;
        }
        const path = try std.fmt.allocPrint(f.arena, ".models/{s}", .{model.name});
        if (std.fs.path.dirname(path)) |parent| {
            Io.Dir.cwd().createDirPath(f.io, parent) catch {};
        }
        if (f.digestMatches(path, model.sha256)) {
            std.debug.print("fetch-models: {s} ok\n", .{model.name});
            return;
        }
        if (f.check_only) {
            f.fail("{s}: missing or tampered; run zig build fetch-models", .{model.name});
            return;
        }
        std.debug.print("fetch-models: fetching {s}\n", .{model.url});
        const res = try std.process.run(f.arena, f.io, .{ .argv = &.{ "curl", "-fsSL", model.url, "-o", path } });
        switch (res.term) {
            .exited => |code| if (code != 0) {
                f.fail("{s}: download failed: {s}", .{ model.name, res.stderr });
                return;
            },
            else => {
                f.fail("{s}: download terminated abnormally", .{model.name});
                return;
            },
        }
        if (!f.digestMatches(path, model.sha256)) {
            f.fail("{s}: digest mismatch after download", .{model.name});
            Io.Dir.cwd().deleteFile(f.io, path) catch {};
        } else {
            std.debug.print("fetch-models: {s} synced\n", .{model.name});
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next();
    var check_only = false;
    while (args.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) {
            check_only = true;
        } else {
            std.debug.print("fetch-models: unknown argument '{s}'\n", .{arg});
            return 2;
        }
    }

    const arena = init.arena.allocator();
    var f: Fetch = .{ .arena = arena, .io = init.io, .check_only = check_only };

    const source = try Io.Dir.cwd().readFileAllocOptions(f.io, "third_party/models.lock", arena, .limited(1 << 16), .of(u8), 0);
    const lock = try std.zon.parse.fromSliceAlloc(Lock, arena, source, null, .{});

    if (!check_only) Io.Dir.cwd().createDirPath(f.io, ".models") catch {};
    for (lock.models) |model| try f.syncOne(model);

    if (f.failures != 0) {
        std.debug.print("fetch-models: {d} failure(s)\n", .{f.failures});
        return 1;
    }
    return 0;
}

test "the license allowlist admits exactly the shipped terms" {
    try std.testing.expect(Fetch.licenseAllowed("Apache-2.0"));
    try std.testing.expect(Fetch.licenseAllowed("Public-domain-US-government"));
    try std.testing.expect(!Fetch.licenseAllowed("CC-BY-4.0"));
    try std.testing.expect(!Fetch.licenseAllowed(""));
}

test "digests hash to the expected hex" {
    const hex = sha256Hex("abc");
    try std.testing.expectEqualStrings("ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad", &hex);
}
