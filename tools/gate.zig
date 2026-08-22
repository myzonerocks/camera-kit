//! Source-tracked gate. Enforces both directions of the repository's ignore
//! policy plus commit provenance, locally (git hooks) and in CI.
//!
//!   --staged            pre-commit: staged files through every check
//!   --tree              CI/local: all tracked files through every check
//!   --commit-msg <file> commit-msg hook: scan the message being written
//!   --log <range>       CI: scan commit messages in a rev range
//!   --diff <range>      CI: scan added lines in a rev range for comment hygiene
//!   --pr-body <file>    CI: scan a PR body for provenance and shape
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
// author is, when it happened) or cites a planning document. These
// markers catch that shape on added comment lines - this project's own
// recurring mistake, not a hypothetical. Local-only material is caught
// by its directory, never by enumerating its filenames here.
const verbose_comment_markers = [_][]const u8{
    "verified",       "confirmed",     "not assumed",
    "found that",     "found a real",  "real finding",
    "real question",  "real, proven",  "real and proven",
    "owner-directed", "owner-ordered", "SPEC.md",
    "docs/private",
};

// A comment explains the one thing a reader can't already see; it is
// not an essay. A run of consecutive added comment lines past this is
// the project's own recurring mistake (a narrated investigation where
// a sentence would do), not a hypothetical.
const max_comment_block_lines: usize = 4;

// A PR body is a short paragraph, not a report: what changed and why,
// nothing about how the change was proven out. Modeled on how ghostty's
// own PRs read - three sentences, no headers, no checklist.
const max_pr_body_lines: usize = 12;
const max_pr_body_bytes: usize = 900;

const banned_pr_body_headers = [_][]const u8{
    "summary",     "test plan",  "testing",   "changes",
    "overview",    "background", "motivation", "what changed",
    "how tested",  "verification",
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
        var run_len: usize = 0;
        var run_first: []const u8 = "";

        var lines = std.mem.splitScalar(u8, out, '\n');
        while (lines.next()) |line| {
            if (std.mem.startsWith(u8, line, "+++ ")) {
                try g.flagOverlongCommentBlock(current_path, run_len, run_first);
                run_len = 0;
                const rest = line["+++ ".len..];
                current_path = if (std.mem.startsWith(u8, rest, "b/")) rest["b/".len..] else rest;
                continue;
            }
            const is_added = std.mem.startsWith(u8, line, "+") and !std.mem.startsWith(u8, line, "+++") and !isGeneratedWrapperScript(current_path) and !isProseFile(current_path);
            const content = if (is_added) line[1..] else "";
            const is_added_comment = is_added and isCommentLine(content);

            if (is_added_comment) {
                if (run_len == 0) run_first = std.mem.trim(u8, content, " \t");
                run_len += 1;
            } else {
                try g.flagOverlongCommentBlock(current_path, run_len, run_first);
                run_len = 0;
            }

            if (!is_added_comment) continue;
            if (findVerboseMarker(content)) |marker| {
                try g.flag("comment-hygiene: '{s}' has a verbose comment (matched '{s}'): {s}", .{ current_path, marker, std.mem.trim(u8, content, " \t") });
            }
        }
        try g.flagOverlongCommentBlock(current_path, run_len, run_first);
    }

    fn flagOverlongCommentBlock(g: *Gate, path: []const u8, run_len: usize, first_line: []const u8) !void {
        if (run_len <= max_comment_block_lines) return;
        try g.flag("comment-hygiene: '{s}' adds a {d}-line comment block starting '{s}'; say it in {d} lines or fewer", .{ path, run_len, first_line, max_comment_block_lines });
    }

    // A short paragraph: what changed and why, nothing about how it was
    // tested. No markdown headers, no checklist syntax, no banned
    // section words as a leading line - those are the report-shaped
    // tells this scanner exists to catch, not a style nitpick.
    fn checkProseShape(g: *Gate, text: []const u8, context: []const u8) !void {
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len > max_pr_body_bytes) {
            try g.flag("body-shape: {s} is {d} bytes; keep it to a short paragraph, under {d}", .{ context, trimmed.len, max_pr_body_bytes });
        }

        var line_count: usize = 0;
        var lines = std.mem.splitScalar(u8, trimmed, '\n');
        while (lines.next()) |line| {
            line_count += 1;
            const stripped = std.mem.trim(u8, line, " \t\r");
            if (std.mem.startsWith(u8, stripped, "#")) {
                try g.flag("body-shape: {s} uses a markdown header ('{s}'); write prose, not a report", .{ context, stripped });
            }
            if (isChecklistLine(stripped)) {
                try g.flag("body-shape: {s} has a checklist line ('{s}'); a test plan belongs in the PR run, not the body", .{ context, stripped });
            }
            const header_word = headerLikeLine(stripped);
            if (header_word) |w| {
                try g.flag("body-shape: {s} opens a section with '{s}'; write one paragraph instead", .{ context, w });
            }
        }
        if (line_count > max_pr_body_lines) {
            try g.flag("body-shape: {s} is {d} lines; keep it to {d} or fewer, like a short paragraph", .{ context, line_count, max_pr_body_lines });
        }
    }

    // A dash that glues a lowercase clause onto a sentence is a machine
    // writing tell, not an appositive. Flags each hit with a quote and
    // the fix. Runs on doc prose, commit messages, and PR bodies.
    fn checkClauseDashes(g: *Gate, text: []const u8, context: []const u8) !void {
        var from: usize = 0;
        while (nextClauseDash(text, from)) |idx| {
            const snippet = clauseSnippet(text, idx);
            try g.flag("em-dash: {s} joins a clause with a dash (\"{s}\"); an em-dash joining a clause reads as AI-written, so restructure the sentence or use a spaced hyphen. An appositive like 'X - A definition' is allowed.", .{ context, snippet });
            from = idx + 3;
        }
    }

    fn checkProseDashes(g: *Gate, paths: []const []const u8) !void {
        for (paths) |path| {
            if (!isMarkdownDoc(path)) continue;
            const stat = Io.Dir.cwd().statFile(g.io, path, .{}) catch continue;
            if (stat.size > max_file_scan_bytes) continue;
            const content = Io.Dir.cwd().readFileAlloc(g.io, path, g.arena, .limited(max_file_scan_bytes)) catch continue;
            const ctx = try std.fmt.allocPrint(g.arena, "'{s}'", .{path});
            try g.checkClauseDashes(content, ctx);
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
            try g.checkClauseDashes(body, ctx);
        }
    }
};

pub fn main(init: std.process.Init) !u8 {
    const arena = init.arena.allocator();
    var g: Gate = .{ .arena = arena, .io = init.io };

    var args = std.process.Args.Iterator.init(init.minimal.args);
    _ = args.next(); // program path
    const mode = args.next() orelse {
        std.debug.print("gate: usage: gate --staged | --tree | --commit-msg <file> | --log <range> | --diff <range> | --pr-body <file>\n", .{});
        return 2;
    };

    if (std.mem.eql(u8, mode, "--staged")) {
        const paths = try g.stagedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
        try g.checkCommentHygiene(&.{"--cached"});
        try g.checkProseDashes(paths);
    } else if (std.mem.eql(u8, mode, "--tree")) {
        const paths = try g.trackedPaths();
        try g.checkIgnoreIntegrity();
        try g.checkInbound(paths);
        try g.checkFileProvenance(paths);
        try g.checkProseDashes(paths);
    } else if (std.mem.eql(u8, mode, "--commit-msg")) {
        const file = args.next() orelse {
            std.debug.print("gate: --commit-msg needs a file argument\n", .{});
            return 2;
        };
        const message = try Io.Dir.cwd().readFileAlloc(g.io, file, arena, .limited(max_file_scan_bytes));
        try g.checkMessage(message, "commit message");
        try g.checkClauseDashes(message, "commit message");
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
    } else if (std.mem.eql(u8, mode, "--pr-body")) {
        const file = args.next() orelse {
            std.debug.print("gate: --pr-body needs a file argument\n", .{});
            return 2;
        };
        const body = try Io.Dir.cwd().readFileAlloc(g.io, file, arena, .limited(max_file_scan_bytes));
        try g.checkMessage(body, "PR body");
        try g.checkProseShape(body, "PR body");
        try g.checkClauseDashes(body, "PR body");
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
    if (std.mem.startsWith(u8, path, "sdk/ts/demo/res/") and std.mem.endsWith(u8, path, ".png")) {
        return null;
    }
    // Gradle's own bootstrap stub, not a build output - JitPack (and
    // anyone else) clones this repo and runs ./gradlew directly, which
    // does not exist without the jar next to it.
    if (std.mem.eql(u8, path, "sdk/kotlin/gradle/wrapper/gradle-wrapper.jar")) {
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

// Gradle's own wrapper script - `gradle wrapper` generates it verbatim
// and it is never hand-edited, the same reasoning a vendored tree gets.
fn isGeneratedWrapperScript(path: []const u8) bool {
    return std.mem.endsWith(u8, path, "/gradlew") or std.mem.eql(u8, path, "gradlew");
}

// Markdown is prose, not source - its `#` headings and `*` bullets look
// like comment syntax to this scanner but are the document itself.
// Patch files carry verbatim upstream diff content, not authored
// comments, so they get the same pass.
fn isProseFile(path: []const u8) bool {
    return std.mem.endsWith(u8, path, ".md") or std.mem.endsWith(u8, path, ".patch");
}

// A `#`-led line that is real C/ObjC code (#define, #include, #if...),
// not a shell/Python/YAML comment - the two share a leading marker.
fn isPreprocessorDirective(trimmed: []const u8) bool {
    const rest = std.mem.trimStart(u8, trimmed[1..], " \t");
    // Deliberately excludes if/ifdef/ifndef/else/elif/endif - real
    // directives, but also how plenty of plain-English comments open.
    const directives = [_][]const u8{ "define", "include", "pragma", "import" };
    for (directives) |word| {
        if (std.mem.startsWith(u8, rest, word)) {
            const after = rest[word.len..];
            if (after.len == 0 or !std.ascii.isAlphanumeric(after[0])) return true;
        }
    }
    return false;
}

fn isCommentLine(line: []const u8) bool {
    const trimmed = std.mem.trim(u8, line, " \t");
    // A `*` line is a block-comment continuation only when the star
    // stands alone or is followed by a space or `/` - a pointer store
    // like `*ptr = x;` is code, not commentary.
    const star_continuation = std.mem.startsWith(u8, trimmed, "*") and
        (trimmed.len == 1 or trimmed[1] == ' ' or trimmed[1] == '/');
    return std.mem.startsWith(u8, trimmed, "//") or
        std.mem.startsWith(u8, trimmed, "///") or
        star_continuation or
        (std.mem.startsWith(u8, trimmed, "#") and !isPreprocessorDirective(trimmed));
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

// A line that is just a banned word, optionally with a trailing colon
// or markdown bold - "Summary", "**Test plan**", "Testing:" - read as a
// report's section header, not a sentence that happens to contain the
// word.
fn headerLikeLine(line: []const u8) ?[]const u8 {
    var body = std.mem.trim(u8, line, "*# \t");
    if (std.mem.endsWith(u8, body, ":")) body = body[0 .. body.len - 1];
    for (banned_pr_body_headers) |word| {
        if (std.ascii.eqlIgnoreCase(body, word)) return word;
    }
    return null;
}

fn isChecklistLine(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "- [ ]") or std.mem.startsWith(u8, line, "- [x]");
}

fn findVerboseMarker(line: []const u8) ?[]const u8 {
    for (verbose_comment_markers) |marker| {
        if (std.ascii.indexOfIgnoreCase(line, marker) != null) return marker;
    }
    if (hasIsoDate(line)) return "a dated timeline entry, not a fact about the code";
    return null;
}

// An em-dash (U+2014) or en-dash (U+2013) at the start of s, returned as
// its byte length, or 0. Both encode as three bytes under E2 80.
fn dashLen(s: []const u8) usize {
    if (s.len >= 3 and s[0] == 0xE2 and s[1] == 0x80 and (s[2] == 0x94 or s[2] == 0x93)) return 3;
    return 0;
}

// A dash joins a clause when its next non-space character is a lowercase
// ascii letter. An uppercase letter (an appositive or definition), a
// digit (a numeric range like 10-20), or anything else is left alone.
fn joinsClause(after: []const u8) bool {
    var i: usize = 0;
    while (i < after.len and (after[i] == ' ' or after[i] == '\t')) i += 1;
    if (i >= after.len) return false;
    return after[i] >= 'a' and after[i] <= 'z';
}

// Index of the next clause-joining dash at or after `from`, or null. The
// one scanner behind both the flag path and the test helper.
fn nextClauseDash(text: []const u8, from: usize) ?usize {
    var i: usize = from;
    while (i < text.len) : (i += 1) {
        const dl = dashLen(text[i..]);
        if (dl == 0) continue;
        if (joinsClause(text[i + dl ..])) return i;
        i += dl - 1;
    }
    return null;
}

fn hasClauseDash(text: []const u8) bool {
    return nextClauseDash(text, 0) != null;
}

// A short quote around the dash, bounded to its own line and a small
// window so a violation shows the joined clause, not the paragraph.
fn clauseSnippet(text: []const u8, dash_index: usize) []const u8 {
    var line_start: usize = dash_index;
    while (line_start > 0 and text[line_start - 1] != '\n') line_start -= 1;
    var line_end: usize = dash_index;
    while (line_end < text.len and text[line_end] != '\n') line_end += 1;
    const window: usize = 24;
    const start = if (dash_index - line_start > window) dash_index - window else line_start;
    const stop = if (line_end - dash_index > window) dash_index + window else line_end;
    return std.mem.trim(u8, text[start..stop], " \t\r");
}

// Authored markdown prose, the only files scanned for clause dashes. The
// private docs tree is gitignored and never scanned; source keeps its
// own spaced hyphens and is out of scope.
fn isMarkdownDoc(path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".md")) return false;
    if (std.mem.startsWith(u8, path, "docs/private/")) return false;
    return true;
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
    try std.testing.expectEqualStrings("node_modules", forbiddenSegment("sdk/ts/node_modules/x/y.js").?);
    try std.testing.expectEqualStrings(".build", forbiddenSegment("sdk/swift/.build/debug/a").?);
    try std.testing.expectEqualStrings(".xcframework", forbiddenSegment("sdk/swift/Gosslens.xcframework/Info.plist").?);
    try std.testing.expect(forbiddenSegment("core/graph/scheduler.zig") == null);
}

test "forbidden extensions catch artifact classes" {
    try std.testing.expectEqualStrings(".task", forbiddenExtension("face_landmarker.task").?);
    try std.testing.expectEqualStrings(".wasm", forbiddenExtension("sdk/ts/core.wasm").?);
    try std.testing.expectEqualStrings(".a", forbiddenExtension("libfoo.a").?);
    try std.testing.expectEqualStrings(".out", forbiddenExtension("a.out").?);
    try std.testing.expect(forbiddenExtension("core/math/mat4.zig") == null);
    try std.testing.expect(forbiddenExtension("include/gosslens.h") == null);
    // A png anywhere else is still a fetched/scratch artifact - only a
    // reference lens's own assets/ directory is real bundle content.
    try std.testing.expectEqualStrings(".png", forbiddenExtension("sdk/kotlin/demo/src/main/assets/res/mouth.png").?);
    try std.testing.expect(forbiddenExtension("lenses/reference/background-swap/assets/beach.png") == null);
    try std.testing.expect(forbiddenExtension("sdk/ts/demo/res/lookup_gray.png") == null);
    // A jar anywhere else is still a build output - only the Gradle
    // wrapper's own bootstrap stub is real, necessary bundle content.
    try std.testing.expectEqualStrings(".jar", forbiddenExtension("some/other/lib.jar").?);
    try std.testing.expect(forbiddenExtension("sdk/kotlin/gradle/wrapper/gradle-wrapper.jar") == null);
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
    // A block-comment continuation is a star alone or star-space; a
    // pointer store is code.
    try std.testing.expect(isCommentLine(" * continuation text"));
    try std.testing.expect(isCommentLine(" */"));
    try std.testing.expect(!isCommentLine("*previous_program = 0;"));
    try std.testing.expect(!isCommentLine("  *ptr += 1;"));
}

test "preprocessor directives are not comments, even though they share a shell comment's # marker" {
    try std.testing.expect(!isCommentLine("#define ANGLE_COMMIT_DATE \"2026-08-18\""));
    try std.testing.expect(!isCommentLine("#include <zlib.h>"));
    try std.testing.expect(!isCommentLine("#import <UIKit/UIKit.h>"));
    try std.testing.expect(!isCommentLine("#pragma once"));
    // if/ifdef/endif stay comment-classified on purpose - too many real
    // English comments open the same way ("# if this ever fires...").
    try std.testing.expect(isCommentLine("#if this ever fires, retry"));
    try std.testing.expect(isCommentLine("  # a shell comment"));
}

test "generated wrapper scripts are recognized, hand-written scripts are not" {
    try std.testing.expect(isGeneratedWrapperScript("sdk/kotlin/gradlew"));
    try std.testing.expect(isGeneratedWrapperScript("gradlew"));
    try std.testing.expect(!isGeneratedWrapperScript("sdk/kotlin/demo/prove-emulator.sh"));
}

test "markdown and patches are prose, source is not" {
    try std.testing.expect(isProseFile("NOTICE.md"));
    try std.testing.expect(isProseFile("docs/API.md"));
    try std.testing.expect(isProseFile("third_party/bgfx/patches/0001-webgpu-timer-query-noop.patch"));
    try std.testing.expect(!isProseFile("core/abi/abi.zig"));
    try std.testing.expect(!isProseFile("adapters/beauty/beauty_shim.cc"));
}

test "verbose comment markers are caught, plain ones are not" {
    try std.testing.expect(findVerboseMarker("// verified this is correct") != null);
    try std.testing.expect(findVerboseMarker("// see docs/private/notes.md for context") != null);
    try std.testing.expect(findVerboseMarker("// found 2026-08-17 that this works") != null);
    try std.testing.expect(findVerboseMarker("// converts YUV to RGB via a fixed matrix") == null);
}

test "header-like lines catch report section markers, not prose that mentions them" {
    try std.testing.expectEqualStrings("summary", headerLikeLine("Summary").?);
    try std.testing.expectEqualStrings("test plan", headerLikeLine("## Test plan").?);
    try std.testing.expectEqualStrings("testing", headerLikeLine("**Testing:**").?);
    try std.testing.expect(headerLikeLine("this change needed real testing before landing") == null);
    try std.testing.expect(headerLikeLine("adds a snapshot decoder option") == null);
}

test "checklist lines are recognized" {
    try std.testing.expect(isChecklistLine("- [ ] zig build ci green"));
    try std.testing.expect(isChecklistLine("- [x] real device run"));
    try std.testing.expect(!isChecklistLine("- a plain bullet"));
}

test "a dash joining a lowercase clause is the AI tell, an appositive and a range are not" {
    // Em-dash then a lowercase clause is the pattern to catch.
    try std.testing.expect(hasClauseDash("someone \xE2\x80\x94 every thread stays end-to-end encrypted"));
    // Em-dash then a capital is an appositive or definition, allowed.
    try std.testing.expect(!hasClauseDash("Melbourne \xE2\x80\x94 A city located in Victoria, AU."));
    // A digit on the far side is a numeric range, allowed.
    try std.testing.expect(!hasClauseDash("2013\xE2\x80\x9315"));
    try std.testing.expect(!hasClauseDash("10\xE2\x80\x9320"));
    // An en-dash gluing a lowercase clause is the same tell.
    try std.testing.expect(hasClauseDash("it stopped \xE2\x80\x93 then it resumed"));
    // A title like the SDK headers keeps its dash before a capital.
    try std.testing.expect(!hasClauseDash("Gosslens \xE2\x80\x94 Kotlin SDK"));
    // A plain spaced hyphen is never a hit.
    try std.testing.expect(!hasClauseDash("a real web page - see the demo"));
}

test "only authored markdown prose is scanned for clause dashes" {
    try std.testing.expect(isMarkdownDoc("README.md"));
    try std.testing.expect(isMarkdownDoc("lenses/format.md"));
    try std.testing.expect(isMarkdownDoc("sdk/ts/README.md"));
    try std.testing.expect(!isMarkdownDoc("docs/private/notes.md"));
    try std.testing.expect(!isMarkdownDoc("core/graph/node.zig"));
    try std.testing.expect(!isMarkdownDoc("adapters/beauty/beauty_shim.cc"));
}
