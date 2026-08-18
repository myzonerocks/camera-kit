//! Source-tracked gate. Enforces both directions of the repository's ignore
//! policy plus commit provenance, locally (git hooks) and in CI.
//!
//!   --staged            pre-commit: staged files through every check
//!   --tree              CI/local: all tracked files through every check
//!   --commit-msg <file> commit-msg hook: scan the message being written
//!   --log <range>       CI: scan commit messages in a rev range
//!
//! Direction one, outbound: no layer of ignore (repo, .git/info/exclude, or a
//! contributor's global file) may hide source this repository owns. Every
//! owned top-level tree must carry a `!tree/**` re-include in .gitignore, and
//! any file that is ignored must be ignored by this repository's own
//! .gitignore, never by a personal layer.
//!
//! Direction two, inbound: private docs, vendored trees, model weights, build
//! outputs, archives, and oversized binaries never enter history. History is
//! forever; the repository being private today proves nothing about tomorrow.

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;

const max_file_scan_bytes: usize = 1 << 20;
const max_staged_file_bytes: u64 = 4 << 20;

// Trees whose contents must never be committed. Anything staged under these
// prefixes was force-added past the ignore file.
const forbidden_prefixes = [_][]const u8{
    "docs/private/",
    ".models/",
    ".vendor/",
    ".vendor-archives/",
    "zig-out/",
    ".zig-cache/",
    ".local/",
};

// Path segments that only ever appear inside build detritus.
const forbidden_segments = [_][]const u8{
    "node_modules",
    "DerivedData",
    ".gradle",
    ".build",
};

// Artifact classes that are fetched or built, never tracked.
const forbidden_extensions = [_][]const u8{
    ".task", ".gguf",   ".tflite", ".onnx", ".safetensors",
    ".zip",  ".tar",    ".tgz",    ".xz",   ".gz",
    ".7z",   ".a",      ".so",     ".dylib", ".dll",
    ".o",    ".jar",    ".aar",    ".apk",  ".ipa",
    ".wasm", ".ptau",   ".pt",     ".h5",   ".out",
    ".jpg",  ".jpeg",   ".png",    ".webp", ".bmp",
};

// Ignored-by-design prefixes that are skipped before the foreign-layer check;
// they hold thousands of cache files and are attributed to the repo ignore.
const design_ignored_prefixes = [_][]const u8{
    ".zig-cache/",
    "zig-out/",
    ".local/",
    ".vendor/",
    ".vendor-archives/",
    ".models/",
    ".git/",
};

// Provenance tokens are assembled from halves so this file never contains the
// literal strings it bans.
const banned_tokens = [_][]const u8{
    "cla" ++ "ude",
    "anthro" ++ "pic",
    "chat" ++ "gpt",
    "open" ++ "ai",
    "copi" ++ "lot",
    "gem" ++ "ini",
    "deep" ++ "seek",
    "co-auth" ++ "ored-by",
    "generated " ++ "with",
    "ai-gen" ++ "erated",
};

// A comment states what the code does and why; it never narrates the
// investigation that led here (what was checked, how confident the
// author is, when it happened) or cites another tracked document by
// name. These markers catch that shape on added comment lines - this
// project's own recurring mistake, not a hypothetical.
const verbose_comment_markers = [_][]const u8{
    "verified",       "confirmed",       "not assumed",
    "found that",     "found a real",    "real finding",
    "real question",  "real, proven",    "real and proven",
    "owner-directed", "owner-ordered",   "DECISIONS.md",
    "SPEC.md",        "ENGINEERING.md",  "COMPLETION-BAR.md",
    "No-Gated-On-You", "DEFERRAL-LOOPHOLES",
};

const Gate = struct {
    arena: Allocator,
    io: Io,
    violations: std.ArrayList([]const u8) = .empty,

    fn flag(g: *Gate, comptime fmt: []const u8, args: anytype) !void {
        try g.violations.append(g.arena, try std.fmt.allocPrint(g.arena, fmt, args));
    }

    fn git(g: *Gate, argv: []const []const u8, ok_codes: []const u8) ![]u8 {
        const res = std.process.run(g.arena, g.io, .{ .argv = argv }) catch |err| {
            std.debug.print("gate: cannot run {s}: {t}\n", .{ argv[0], err });
            return error.GitUnavailable;
        };
        switch (res.term) {
            .exited => |code| {
                if (std.mem.indexOfScalar(u8, ok_codes, code) == null) {
                    std.debug.print("gate: {s} exited {d}: {s}\n", .{ argv[1], code, res.stderr });
                    return error.GitFailed;
                }
            },
            else => {
                std.debug.print("gate: {s} terminated abnormally\n", .{argv[1]});
                return error.GitFailed;
            },
        }
        return res.stdout;
    }

    fn nulSeparated(g: *Gate, out: []u8) ![][]const u8 {
        var list: std.ArrayList([]const u8) = .empty;
        var it = std.mem.tokenizeScalar(u8, out, 0);
        while (it.next()) |p| try list.append(g.arena, p);
        return list.items;
    }

    // Direction one: the re-include list and the foreign-layer check.
    fn checkIgnoreIntegrity(g: *Gate) !void {
        const gitignore = Io.Dir.cwd().readFileAlloc(g.io, ".gitignore", g.arena, .limited(1 << 16)) catch {
            try g.flag("ignore-integrity: .gitignore missing at repo root", .{});
            return;
        };

        var root = try Io.Dir.cwd().openDir(g.io, ".", .{ .iterate = true });
        defer root.close(g.io);
        var dir_it = root.iterate();
        while (try dir_it.next(g.io)) |entry| {
            if (entry.kind != .directory) continue;
            if (entry.name.len == 0 or entry.name[0] == '.') continue;
            if (std.mem.eql(u8, entry.name, "zig-out")) continue;
            const line = try std.fmt.allocPrint(g.arena, "!{s}/**", .{entry.name});
            if (!hasLine(gitignore, line)) {
                try g.flag("ignore-integrity: owned tree '{s}' lacks a '{s}' re-include in .gitignore", .{ entry.name, line });
            }
        }

        const ignored_out = try g.git(&.{ "git", "ls-files", "--others", "--ignored", "--exclude-standard", "-z" }, &.{0});
        const ignored = try g.nulSeparated(ignored_out);

        var to_check: std.ArrayList([]const u8) = .empty;
        for (ignored) |path| {
            if (hasAnyPrefix(path, &design_ignored_prefixes)) continue;
            try to_check.append(g.arena, path);
        }

        var i: usize = 0;
        while (i < to_check.items.len) : (i += 50) {
            const chunk = to_check.items[i..@min(i + 50, to_check.items.len)];
            var argv: std.ArrayList([]const u8) = .empty;
            try argv.appendSlice(g.arena, &.{ "git", "check-ignore", "-v", "--" });
            try argv.appendSlice(g.arena, chunk);
            // exit 1 means nothing matched, which cannot happen for known-ignored paths
            const out = try g.git(argv.items, &.{ 0, 1 });
            var lines = std.mem.tokenizeScalar(u8, out, '\n');
            while (lines.next()) |line| {
                // <source>:<linenum>:<pattern>\t<pathname>
                const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
                const source = line[0 .. std.mem.indexOfScalar(u8, line[0..tab], ':') orelse continue];
                const path = line[tab + 1 ..];
                if (!std.mem.eql(u8, source, ".gitignore")) {
                    try g.flag("ignore-integrity: '{s}' is hidden by a foreign ignore layer ({s}); the repo .gitignore is the only authority", .{ path, source });
                }
            }
        }
    }

    // Direction two: nothing forbidden, no build detritus, no artifact
    // classes, nothing oversized.
    fn checkInbound(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            if (forbiddenPrefix(path)) |p| {
                try g.flag("inbound: '{s}' is inside forbidden tree '{s}'", .{ path, p });
                continue;
            }
            if (forbiddenSegment(path)) |s| {
                try g.flag("inbound: '{s}' contains build-detritus segment '{s}'", .{ path, s });
                continue;
            }
            if (forbiddenExtension(path)) |e| {
                try g.flag("inbound: '{s}' has forbidden artifact extension '{s}'", .{ path, e });
                continue;
            }
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_staged_file_bytes) {
                try g.flag("inbound: '{s}' is {d} bytes; files over {d} bytes are fetched via a tracked lock, not committed", .{ path, stat.size, max_staged_file_bytes });
            }
        }
    }

    fn checkFileProvenance(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_file_scan_bytes) continue;
            const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch continue;
            if (looksBinary(content)) continue;
            if (findBannedToken(content)) |tok| {
                try g.flag("provenance: '{s}' contains banned token '{s}'", .{ path, tok });
            }
        }
    }

    fn checkMessage(g: *Gate, message: []const u8, context: []const u8) !void {
        if (findBannedToken(message)) |tok| {
            try g.flag("provenance: {s} contains banned token '{s}'", .{ context, tok });
        }
    }

    // Scans added lines in a unified diff for comment-hygiene violations.
    // diff_args are appended to `git diff` (e.g. `--cached ...` for
    // staged, or a rev range for CI) so this one scanner serves both.
    fn checkCommentHygiene(g: *Gate, diff_args: []const []const u8) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        try argv.appendSlice(g.arena, &.{ "git", "diff", "--diff-filter=ACMR", "-U0" });
        try argv.appendSlice(g.arena, diff_args);
        const out = try g.git(argv.items, &.{0});

        var current_path: []const u8 = "";
        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "+++ ")) {
                const rest = line["+++ ".len..];
                current_path = if (std.mem.startsWith(u8, rest, "b/")) rest["b/".len..] else rest;
                continue;
            }
            if (!std.mem.startsWith(u8, line, "+") or std.mem.startsWith(u8, line, "+++")) continue;
            const content = line[1..];
            if (!isCommentLine(content)) continue;
            if (findVerboseMarker(content)) |marker| {
                try g.flag("comment-hygiene: '{s}' has a verbose comment (matched '{s}'): {s}", .{ current_path, marker, std.mem.trim(u8, content, " \t") });
            }
        }
    }

    fn stagedPaths(g: *Gate) ![][]const u8 {
        const out = try g.git(&.{ "git", "diff", "--cached", "--name-only", "--diff-filter=ACMR", "-z" }, &.{0});
        return g.nulSeparated(out);
    }

    fn trackedPaths(g: *Gate) ![][]const u8 {
        const out = try g.git(&.{ "git", "ls-files", "-z" }, &.{0});
        return g.nulSeparated(out);
    }

    fn checkLogRange(g: *Gate, range: []const u8) !void {
        const out = try g.git(&.{ "git", "log", "--format=%H%x1f%B%x00", range }, &.{0});
        var records = std.mem.tokenizeScalar(u8, out, 0);
        while (records.next()) |rec| {
            const sep = std.mem.indexOfScalar(u8, rec, 0x1f) orelse continue;
            const sha = std.mem.trim(u8, rec[0..sep], "\n");
            const body = rec[sep + 1 ..];
            const ctx = try std.fmt.allocPrint(g.arena, "commit {s}", .{sha[0..@min(sha.len, 12)]});
            try g.checkMessage(body, ctx);
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var g: Gate = .{ .arena = arena, .io = init.io };

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program path
    const mode = args.next() orelse {
        std.debug.print("gate: usage: gate --staged | --tree | --commit-msg <file> | --log <range> | --diff <range>\n", .{});
        return 2;
    };

    if (std.mem.eql(u8, mode, "--staged")) {
        const paths = try g.stagedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
        try g.checkCommentHygiene(&.{"--cached"});
    } else if (std.mem.eql(u8, mode, "--tree")) {
        const paths = try g.trackedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
    } else if (std.mem.eql(u8, mode, "--commit-msg")) {
        const file = args.next() orelse {
            std.debug.print("gate: --commit-msg needs a file argument\n", .{});
            return 2;
        };
        const message = try Io.Dir.cwd().readFileAlloc(g.io, file, arena, .limited(max_file_scan_bytes));
        try g.checkMessage(message, "commit message");
    } else if (std.mem.eql(u8, mode, "--log")) {
        const range = args.next() orelse {
            std.debug.print("gate: --log needs a rev range argument\n", .{});
            return 2;
        };
        try g.checkLogRange(range);
    } else if (std.mem.eql(u8, mode, "--diff")) {
        const range = args.next() orelse {
            std.debug.print("gate: --diff needs a rev range argument\n", .{});
            return 2;
        };
        try g.checkCommentHygiene(&.{range});
    } else {
        std.debug.print("gate: unknown mode '{s}'\n", .{mode});
        return 2;
    }

    if (g.violations.items.len != 0) {
        for (g.violations.items) |v| std.debug.print("gate: {s}\n", .{v});
        std.debug.print("gate: {d} violation(s)\n", .{g.violations.items.len});
        return 1;
    }
    return 0;
}

fn hasLine(text: []const u8, wanted: []const u8) bool {
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, std.mem.trim(u8, line, " \t\r"), wanted)) return true;
    }
    return false;
}

fn hasAnyPrefix(path: []const u8, prefixes: []const []const u8) bool {
    for (prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return true;
    }
    return false;
}

fn forbiddenPrefix(path: []const u8) ?[]const u8 {
    for (forbidden_prefixes) |p| {
        if (std.mem.startsWith(u8, path, p)) return p;
    }
    return null;
}

fn forbiddenSegment(path: []const u8) ?[]const u8 {
    var segs = std.mem.tokenizeScalar(u8, path, '/');
    while (segs.next()) |seg| {
        for (forbidden_segments) |bad| {
            if (std.mem.eql(u8, seg, bad)) return bad;
        }
        if (std.mem.endsWith(u8, seg, ".xcframework")) return ".xcframework";
    }
    return null;
}

fn forbiddenExtension(path: []const u8) ?[]const u8 {
    // A reference lens's own assets/*.png is real bundle content the
    // format itself defines (lut.pass and blend.pass name an asset by
    // id the same way shader.pass names a .glsl source file) - not a
    // fetched or built artifact like every other extension here.
    if (std.mem.startsWith(u8, path, "lenses/") and std.mem.endsWith(u8, path, ".png") and std.mem.indexOf(u8, path, "/assets/") != null) {
        return null;
    }
    // The web demo's own beauty LUT textures - same reasoning, real
    // bundle content copied in once rather than fetched or built.
    if (std.mem.startsWith(u8, path, "shells/ts/demo/res/") and std.mem.endsWith(u8, path, ".png")) {
        return null;
    }
    for (forbidden_extensions) |ext| {
        if (std.mem.endsWith(u8, path, ext)) return ext;
    }
    return null;
}

fn looksBinary(content: []const u8) bool {
    const probe = content[0..@min(content.len, 4096)];
    return std.mem.indexOfScalar(u8, probe, 0) != null;
}

fn findBannedToken(text: []const u8) ?[]const u8 {
    for (banned_tokens) |tok| {
        if (std.ascii.indexOfIgnoreCase(text, tok) != null) return tok;
    }
    return null;
}

fn isCommentLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    return std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "///") or
        std.mem.startsWith(u8, trimmed, "*") or
        std.mem.startsWith(u8, trimmed, "#");
}

fn hasIsoDate(line: []const u8) bool {
    if (line.len < 10) return false;
    var i: usize = 0;
    while (i + 10 <= line.len) : (i += 1) {
        const s = line[i..][0..10];
        if (s[0] == '2' and s[1] == '0' and
            std.ascii.isDigit(s[2]) and std.ascii.isDigit(s[3]) and
            s[4] == '-' and std.ascii.isDigit(s[5]) and std.ascii.isDigit(s[6]) and
            s[7] == '-' and std.ascii.isDigit(s[8]) and std.ascii.isDigit(s[9]))
        {
            return true;
        }
    }
    return false;
}

fn findVerboseMarker(line: []const u8) ?[]const u8 {
    for (verbose_comment_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(line, marker) != null) return marker;
    }
    if (hasIsoDate(line)) return "a dated timeline entry, not a fact about the code";
    return null;
}

test "top-level trees require their re-include line" {
    const ignore = "!core/**\n!tools/**\ndocs/private/\n";
    try std.testing.expect(hasLine(ignore, "!core/**"));
    try std.testing.expect(hasLine(ignore, "!tools/**"));
    try std.testing.expect(!hasLine(ignore, "!lenses/**"));
}

test "forbidden prefixes catch force-added trees" {
    try std.testing.expectEqualStrings("docs/private/", forbiddenPrefix("docs/private/ENGINEERING.md").?);
    try std.testing.expectEqualStrings(".models/", forbiddenPrefix(".models/face.task").?);
    try std.testing.expectEqualStrings("zig-out/", forbiddenPrefix("zig-out/bin/gate").?);
    try std.testing.expect(forbiddenPrefix("docs/ROADMAP.md") == null);
    try std.testing.expect(forbiddenPrefix("core/graph/node.zig") == null);
}

test "forbidden segments catch build detritus anywhere in the path" {
    try std.testing.expectEqualStrings("node_modules", forbiddenSegment("shells/ts/node_modules/x/y.js").?);
    try std.testing.expectEqualStrings(".build", forbiddenSegment("shells/swift/.build/debug/a").?);
    try std.testing.expectEqualStrings(".xcframework", forbiddenSegment("shells/swift/CameraKit.xcframework/Info.plist").?);
    try std.testing.expect(forbiddenSegment("core/graph/scheduler.zig") == null);
}

test "forbidden extensions catch artifact classes" {
    try std.testing.expectEqualStrings(".task", forbiddenExtension("face_landmarker.task").?);
    try std.testing.expectEqualStrings(".wasm", forbiddenExtension("shells/ts/core.wasm").?);
    try std.testing.expectEqualStrings(".a", forbiddenExtension("libfoo.a").?);
    try std.testing.expectEqualStrings(".out", forbiddenExtension("a.out").?);
    try std.testing.expect(forbiddenExtension("core/math/mat4.zig") == null);
    try std.testing.expect(forbiddenExtension("include/camerakit.h") == null);
    // A png anywhere else is still a fetched/scratch artifact - only a
    // reference lens's own assets/ directory is real bundle content.
    try std.testing.expectEqualStrings(".png", forbiddenExtension("shells/kotlin/demo/src/main/assets/res/mouth.png").?);
    try std.testing.expect(forbiddenExtension("lenses/reference/background-swap/assets/beach.png") == null);
    try std.testing.expect(forbiddenExtension("shells/ts/demo/res/lookup_gray.png") == null);
}

test "banned tokens match case-insensitively and only when present" {
    const dirty = "Co-Auth" ++ "ored-By: somebody";
    try std.testing.expect(findBannedToken(dirty) != null);
    const clean = "frame graph scheduling with bounded pools";
    try std.testing.expect(findBannedToken(clean) == null);
}

test "binary probe" {
    try std.testing.expect(looksBinary("\x00\x01\x02"));
    try std.testing.expect(!looksBinary("plain text"));
}

test "design-ignored prefixes are skipped" {
    try std.testing.expect(hasAnyPrefix(".zig-cache/h/x", &design_ignored_prefixes));
    try std.testing.expect(!hasAnyPrefix("core/x.zig", &design_ignored_prefixes));
}

test "comment lines are recognized across languages" {
    try std.testing.expect(isCommentLine("    // a comment"));
    try std.testing.expect(isCommentLine("/// a doc comment"));
    try std.testing.expect(isCommentLine("  # a shell comment"));
    try std.testing.expect(!isCommentLine("    const x = 1;"));
}

test "verbose comment markers are caught, plain ones are not" {
    try std.testing.expect(findVerboseMarker("// verified this is correct") != null);
    try std.testing.expect(findVerboseMarker("// see DECISIONS.md for context") != null);
    try std.testing.expect(findVerboseMarker("// found 2026-08-17 that this works") != null);
    try std.testing.expect(findVerboseMarker("// converts YUV to RGB via a fixed matrix") == null);
}
