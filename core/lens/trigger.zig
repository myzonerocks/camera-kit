//! Trigger `when` expressions: the closed grammar in lenses/SPEC.md 6.1,
//! compiled once at lens load into a typed tree and evaluated every frame
//! against the session's live signals. compile() is the only allocating
//! pass; evaluate() walks the already-typed tree and allocates nothing,
//! so a lens with up to the format's 256-trigger ceiling costs a bounded,
//! predictable amount of frame time with no GC-style pressure behind it.

const std = @import("std");
const face = @import("face");

pub const max_depth = 8;

pub const SignalKind = enum {
    face_blendshape,
    face_present,
    hands_present,
    world_tracking_state,
    audio_level,
    timer,
    tap,
    param,
};

fn signalIsBoolean(kind: SignalKind) bool {
    return switch (kind) {
        .face_present, .hands_present, .tap => true,
        .face_blendshape, .world_tracking_state, .audio_level, .timer, .param => false,
    };
}

pub const Signal = struct {
    kind: SignalKind,
    blendshape_index: u8 = 0,
    param_index: u16 = 0,
    timer_name: []const u8 = "",
};

pub const CompareOp = enum { gt, lt, ge, le, eq, ne };

pub const Literal = union(enum) {
    number: f64,
    boolean: bool,
};

pub const Compare = struct { signal: Signal, op: CompareOp, literal: Literal };
pub const Combine = struct { lhs: *const Node, rhs: *const Node };

pub const Node = union(enum) {
    signal_bool: Signal,
    compare: Compare,
    not: *const Node,
    and_: Combine,
    or_: Combine,
};

pub const Expression = struct {
    arena: std.heap.ArenaAllocator,
    root: *const Node,

    pub fn deinit(self: *Expression) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const TimerValue = struct { name: []const u8, seconds: f32 };

/// The live values a compiled expression reads at evaluation time. params
/// mirrors the manifest's parameter list by index, numeric-cast (a bool
/// param reads as 0/1; color params are not readable from an expression
/// and read as 0, since the grammar has no vector comparison).
pub const Signals = struct {
    face_present: bool = false,
    hands_present: bool = false,
    world_tracking_state: f64 = 0,
    audio_level: f64 = 0,
    tap: bool = false,
    blendshapes: ?*const [face.blendshape_count]f32 = null,
    params: []const f64 = &.{},
    timers: []const TimerValue = &.{},
};

pub fn evaluate(node: *const Node, signals: Signals) bool {
    return switch (node.*) {
        .signal_bool => |s| readBool(s, signals),
        .compare => |c| compareValue(c, signals),
        .not => |inner| !evaluate(inner, signals),
        .and_ => |b| evaluate(b.lhs, signals) and evaluate(b.rhs, signals),
        .or_ => |b| evaluate(b.lhs, signals) or evaluate(b.rhs, signals),
    };
}

fn readBool(s: Signal, signals: Signals) bool {
    return switch (s.kind) {
        .face_present => signals.face_present,
        .hands_present => signals.hands_present,
        .tap => signals.tap,
        else => unreachable,
    };
}

fn readNumber(s: Signal, signals: Signals) f64 {
    return switch (s.kind) {
        .face_blendshape => if (signals.blendshapes) |bs| bs[s.blendshape_index] else 0,
        .world_tracking_state => signals.world_tracking_state,
        .audio_level => signals.audio_level,
        .timer => blk: {
            for (signals.timers) |tv| {
                if (std.mem.eql(u8, tv.name, s.timer_name)) break :blk tv.seconds;
            }
            break :blk 0;
        },
        .param => if (s.param_index < signals.params.len) signals.params[s.param_index] else 0,
        else => unreachable,
    };
}

fn compareValue(c: Compare, signals: Signals) bool {
    switch (c.literal) {
        .boolean => |lit| {
            const value = readBool(c.signal, signals);
            return switch (c.op) {
                .eq => value == lit,
                .ne => value != lit,
                .gt, .lt, .ge, .le => false,
            };
        },
        .number => |lit| {
            const value = readNumber(c.signal, signals);
            return switch (c.op) {
                .gt => value > lit,
                .lt => value < lit,
                .ge => value >= lit,
                .le => value <= lit,
                .eq => value == lit,
                .ne => value != lit,
            };
        },
    }
}

pub const CompileError = struct {
    message: []const u8,
    offset: usize,
};

const Token = union(enum) {
    ident: []const u8,
    string: []const u8,
    number: f64,
    dot,
    lparen,
    rparen,
    op_and,
    op_or,
    op_not,
    op_gt,
    op_lt,
    op_ge,
    op_le,
    op_eq,
    op_ne,
    end,
};

const Tokenizer = struct {
    source: []const u8,
    pos: usize = 0,

    fn skipSpace(self: *Tokenizer) void {
        while (self.pos < self.source.len and std.ascii.isWhitespace(self.source[self.pos])) self.pos += 1;
    }

    fn next(self: *Tokenizer) !Token {
        self.skipSpace();
        if (self.pos >= self.source.len) return .end;
        const c = self.source[self.pos];
        switch (c) {
            '.' => {
                self.pos += 1;
                return .dot;
            },
            '(' => {
                self.pos += 1;
                return .lparen;
            },
            ')' => {
                self.pos += 1;
                return .rparen;
            },
            '\'' => {
                self.pos += 1;
                const start = self.pos;
                while (self.pos < self.source.len and self.source[self.pos] != '\'') self.pos += 1;
                if (self.pos >= self.source.len) return error.UnterminatedString;
                const s = self.source[start..self.pos];
                self.pos += 1;
                return .{ .string = s };
            },
            '&' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '&') {
                    self.pos += 2;
                    return .op_and;
                }
                return error.UnexpectedCharacter;
            },
            '|' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '|') {
                    self.pos += 2;
                    return .op_or;
                }
                return error.UnexpectedCharacter;
            },
            '!' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_ne;
                }
                self.pos += 1;
                return .op_not;
            },
            '=' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_eq;
                }
                return error.UnexpectedCharacter;
            },
            '>' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_ge;
                }
                self.pos += 1;
                return .op_gt;
            },
            '<' => {
                if (self.pos + 1 < self.source.len and self.source[self.pos + 1] == '=') {
                    self.pos += 2;
                    return .op_le;
                }
                self.pos += 1;
                return .op_lt;
            },
            else => {
                if (std.ascii.isAlphabetic(c) or c == '_') {
                    const start = self.pos;
                    while (self.pos < self.source.len and (std.ascii.isAlphanumeric(self.source[self.pos]) or self.source[self.pos] == '_')) self.pos += 1;
                    return .{ .ident = self.source[start..self.pos] };
                }
                if (std.ascii.isDigit(c) or c == '-') {
                    const start = self.pos;
                    self.pos += 1;
                    while (self.pos < self.source.len and (std.ascii.isDigit(self.source[self.pos]) or self.source[self.pos] == '.')) self.pos += 1;
                    const n = std.fmt.parseFloat(f64, self.source[start..self.pos]) catch return error.InvalidNumber;
                    return .{ .number = n };
                }
                return error.UnexpectedCharacter;
            },
        }
    }
};

const Parser = struct {
    tok: Tokenizer,
    current: Token,
    arena: std.mem.Allocator,
    diag_arena: std.mem.Allocator,
    param_names: []const []const u8,
    depth: u32 = 0,
    err: ?CompileError = null,

    // Diagnostic messages allocate from diag_arena, never from arena: on a
    // failed compile the caller frees arena (the would-be Expression's own
    // tree) but keeps the diagnostic, so the two must be independent.
    fn fail(self: *Parser, comptime fmt: []const u8, args: anytype) error{ OutOfMemory, Compile } {
        if (self.err == null) {
            self.err = .{
                .message = std.fmt.allocPrint(self.diag_arena, fmt, args) catch return error.OutOfMemory,
                .offset = self.tok.pos,
            };
        }
        return error.Compile;
    }

    fn advance(self: *Parser) !void {
        self.current = self.tok.next() catch |e| return self.fail("bad token: {t}", .{e});
    }

    fn expect(self: *Parser, comptime tag: std.meta.Tag(Token)) !void {
        if (self.current != tag) {
            return self.fail("expected {s}", .{@tagName(tag)});
        }
        try self.advance();
    }

    fn enterNesting(self: *Parser) !void {
        self.depth += 1;
        if (self.depth > max_depth) {
            return self.fail("nests past a depth of {d}", .{max_depth});
        }
    }

    fn newNode(self: *Parser, node: Node) error{OutOfMemory}!*const Node {
        const ptr = try self.arena.create(Node);
        ptr.* = node;
        return ptr;
    }

    fn parseExpr(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        return self.parseOr();
    }

    fn parseOr(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        var lhs = try self.parseAnd();
        while (self.current == .op_or) {
            try self.enterNesting();
            try self.advance();
            const rhs = try self.parseAnd();
            lhs = try self.newNode(.{ .or_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseAnd(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        var lhs = try self.parseUnary();
        while (self.current == .op_and) {
            try self.enterNesting();
            try self.advance();
            const rhs = try self.parseUnary();
            lhs = try self.newNode(.{ .and_ = .{ .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn parseUnary(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        if (self.current == .op_not) {
            try self.enterNesting();
            try self.advance();
            const inner = try self.parseUnary();
            return self.newNode(.{ .not = inner });
        }
        return self.parseAtom();
    }

    fn parseAtom(self: *Parser) error{ OutOfMemory, Compile }!*const Node {
        if (self.current == .lparen) {
            try self.enterNesting();
            try self.advance();
            const inner = try self.parseExpr();
            try self.expect(.rparen);
            self.depth -= 1;
            return inner;
        }
        const signal = try self.parseSignal();
        switch (self.current) {
            .op_gt, .op_lt, .op_ge, .op_le, .op_eq, .op_ne => {
                const op: CompareOp = switch (self.current) {
                    .op_gt => .gt,
                    .op_lt => .lt,
                    .op_ge => .ge,
                    .op_le => .le,
                    .op_eq => .eq,
                    .op_ne => .ne,
                    else => unreachable,
                };
                try self.advance();
                const literal = try self.parseLiteral();
                if (signalIsBoolean(signal.kind) and literal == .number) {
                    return self.fail("boolean signal compared to a number", .{});
                }
                if (!signalIsBoolean(signal.kind) and literal == .boolean) {
                    return self.fail("numeric signal compared to a bool", .{});
                }
                if ((op == .gt or op == .lt or op == .ge or op == .le) and literal == .boolean) {
                    return self.fail("ordering operators do not apply to bool", .{});
                }
                return self.newNode(.{ .compare = .{ .signal = signal, .op = op, .literal = literal } });
            },
            else => {
                if (!signalIsBoolean(signal.kind)) {
                    return self.fail("a numeric signal needs a comparison", .{});
                }
                return self.newNode(.{ .signal_bool = signal });
            },
        }
    }

    fn parseLiteral(self: *Parser) error{ OutOfMemory, Compile }!Literal {
        switch (self.current) {
            .number => |n| {
                try self.advance();
                return .{ .number = n };
            },
            .ident => |name| {
                if (std.mem.eql(u8, name, "true")) {
                    try self.advance();
                    return .{ .boolean = true };
                }
                if (std.mem.eql(u8, name, "false")) {
                    try self.advance();
                    return .{ .boolean = false };
                }
                return self.fail("expected a number, true, or false", .{});
            },
            else => {
                return self.fail("expected a literal", .{});
            },
        }
    }

    fn parseCall(self: *Parser) error{ OutOfMemory, Compile }![]const u8 {
        try self.expect(.lparen);
        const s = switch (self.current) {
            .string => |s| s,
            else => {
                return self.fail("expected a string argument", .{});
            },
        };
        try self.advance();
        try self.expect(.rparen);
        return s;
    }

    fn parseSignal(self: *Parser) error{ OutOfMemory, Compile }!Signal {
        const head = switch (self.current) {
            .ident => |name| name,
            else => {
                return self.fail("expected a signal", .{});
            },
        };
        try self.advance();

        if (std.mem.eql(u8, head, "tap")) return .{ .kind = .tap };
        if (std.mem.eql(u8, head, "timer")) {
            const name = try self.parseCall();
            return .{ .kind = .timer, .timer_name = try self.arena.dupe(u8, name) };
        }
        if (std.mem.eql(u8, head, "param")) {
            const name = try self.parseCall();
            for (self.param_names, 0..) |candidate, i| {
                if (std.mem.eql(u8, candidate, name)) return .{ .kind = .param, .param_index = @intCast(i) };
            }
            return self.fail("unknown parameter '{s}'", .{name});
        }

        try self.expect(.dot);
        const tail = switch (self.current) {
            .ident => |name| name,
            else => {
                return self.fail("expected a field after '{s}.'", .{head});
            },
        };
        try self.advance();

        if (std.mem.eql(u8, head, "face")) {
            if (std.mem.eql(u8, tail, "present")) return .{ .kind = .face_present };
            if (std.mem.eql(u8, tail, "blendshape")) {
                const name = try self.parseCall();
                const index = face.blendshapeIndex(name) orelse {
                    return self.fail("unknown blendshape '{s}'", .{name});
                };
                return .{ .kind = .face_blendshape, .blendshape_index = index };
            }
            return self.fail("unknown face signal '{s}'", .{tail});
        }
        if (std.mem.eql(u8, head, "hands") and std.mem.eql(u8, tail, "present")) {
            return .{ .kind = .hands_present };
        }
        if (std.mem.eql(u8, head, "world") and std.mem.eql(u8, tail, "tracking_state")) {
            return .{ .kind = .world_tracking_state };
        }
        if (std.mem.eql(u8, head, "audio") and std.mem.eql(u8, tail, "level")) {
            return .{ .kind = .audio_level };
        }
        return self.fail("unknown signal '{s}.{s}'", .{ head, tail });
    }
};

/// Compiles one `when` expression source string against the spec grammar.
/// param_names resolves `param('name')` reads the same way the manifest
/// cross-references parameter targets - an unresolvable name is a compile
/// failure, not a runtime one. Returns null with err populated on failure;
/// err's message allocates from diag_arena (independent of the Expression's
/// own arena, which is freed before returning on any failure path).
pub fn compile(gpa: std.mem.Allocator, diag_arena: std.mem.Allocator, source: []const u8, param_names: []const []const u8, err: *?CompileError) error{OutOfMemory}!?Expression {
    var expr = Expression{ .arena = std.heap.ArenaAllocator.init(gpa), .root = undefined };
    errdefer expr.arena.deinit();
    const arena = expr.arena.allocator();

    var parser = Parser{
        .tok = .{ .source = source },
        .current = undefined,
        .arena = arena,
        .diag_arena = diag_arena,
        .param_names = param_names,
    };
    parser.advance() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            expr.arena.deinit();
            return null;
        },
    };

    const root = parser.parseExpr() catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Compile => {
            err.* = parser.err;
            expr.arena.deinit();
            return null;
        },
    };
    if (parser.current != .end) {
        err.* = .{ .message = try std.fmt.allocPrint(diag_arena, "unexpected trailing input", .{}), .offset = parser.tok.pos };
        expr.arena.deinit();
        return null;
    }

    expr.root = root;
    return expr;
}

const t = std.testing;

fn compileOk(source: []const u8) !Expression {
    var err: ?CompileError = null;
    const result = try compile(t.allocator, t.allocator, source, &.{"smooth_amount"}, &err);
    if (result == null) std.debug.print("compile error: {s} at {d}\n", .{ err.?.message, err.?.offset });
    return result orelse error.TestUnexpectedResult;
}

/// The message is allocated from t.allocator; the caller frees it with
/// t.allocator.free(err.message) once done reading it.
fn compileFails(source: []const u8) !CompileError {
    var err: ?CompileError = null;
    var result = try compile(t.allocator, t.allocator, source, &.{"smooth_amount"}, &err);
    if (result) |*e| {
        e.deinit();
        return error.TestUnexpectedResult;
    }
    return err.?;
}

test "a bare boolean signal compiles and evaluates" {
    var expr = try compileOk("tap");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .tap = true }));
    try t.expect(!evaluate(expr.root, .{ .tap = false }));
}

test "a blendshape comparison resolves the real model index" {
    var expr = try compileOk("face.blendshape('jawOpen') > 0.6");
    defer expr.deinit();
    var shapes: [face.blendshape_count]f32 = @splat(0);
    shapes[face.blendshapeIndex("jawOpen").?] = 0.9;
    try t.expect(evaluate(expr.root, .{ .blendshapes = &shapes }));
    shapes[face.blendshapeIndex("jawOpen").?] = 0.1;
    try t.expect(!evaluate(expr.root, .{ .blendshapes = &shapes }));
}

test "an absent face reads every blendshape as zero, never crashes" {
    var expr = try compileOk("face.blendshape('jawOpen') > 0.6");
    defer expr.deinit();
    try t.expect(!evaluate(expr.root, .{}));
}

test "combinators and parens nest correctly" {
    var expr = try compileOk("face.present && (tap || audio.level > 0.5)");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .face_present = true, .tap = true }));
    try t.expect(!evaluate(expr.root, .{ .face_present = false, .tap = true }));
    try t.expect(evaluate(expr.root, .{ .face_present = true, .audio_level = 0.9 }));
    try t.expect(!evaluate(expr.root, .{ .face_present = true, .tap = false, .audio_level = 0.1 }));
}

test "negation flips a boolean signal" {
    var expr = try compileOk("!face.present");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .face_present = false }));
    try t.expect(!evaluate(expr.root, .{ .face_present = true }));
}

test "timer reads by name from the caller-supplied live values" {
    var expr = try compileOk("timer('intro') > 2.0");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .timers = &.{.{ .name = "intro", .seconds = 3.0 }} }));
    try t.expect(!evaluate(expr.root, .{ .timers = &.{.{ .name = "intro", .seconds = 1.0 }} }));
    try t.expect(!evaluate(expr.root, .{ .timers = &.{} }));
}

test "param reads the caller-supplied numeric view by resolved index" {
    var expr = try compileOk("param('smooth_amount') >= 0.5");
    defer expr.deinit();
    try t.expect(evaluate(expr.root, .{ .params = &.{0.7} }));
    try t.expect(!evaluate(expr.root, .{ .params = &.{0.2} }));
}

test "an unknown blendshape name fails to compile" {
    const err = try compileFails("face.blendshape('not_real') > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown blendshape") != null);
}

test "an unknown parameter name fails to compile" {
    const err = try compileFails("param('not_declared') > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "unknown parameter") != null);
}

test "a boolean signal cannot compare against a number" {
    const err = try compileFails("tap > 0.5");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "boolean signal") != null);
}

test "a numeric signal used bare needs a comparison" {
    const err = try compileFails("audio.level");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "needs a comparison") != null);
}

test "nesting past the depth limit is rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    for (0..max_depth + 2) |_| try buf.appendSlice(t.allocator, "(");
    try buf.appendSlice(t.allocator, "tap");
    for (0..max_depth + 2) |_| try buf.appendSlice(t.allocator, ")");
    const err = try compileFails(buf.items);
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "depth") != null);
}

test "trailing garbage after a valid expression is rejected" {
    const err = try compileFails("tap tap");
    defer t.allocator.free(err.message);
    try t.expect(std.mem.indexOf(u8, err.message, "trailing") != null);
}
