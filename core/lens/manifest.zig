//! manifest.json parsing and structural validation for a lens bundle.
//! A trigger's `when` expression is carried here as its raw source string
//! only; compiling it into the typed expression tree is trigger.zig's job,
//! since the grammar is its own closed production set. Every rejection
//! collects a diagnostic naming the JSON pointer it came from rather than
//! stopping at the first one, so a lens author sees every problem at once.

const std = @import("std");

pub const max_manifest_bytes = 256 * 1024;
pub const max_json_depth = 32;
pub const max_parameters = 256;
pub const max_nodes = 128;
pub const max_triggers = 256;
pub const max_when_bytes = 1024;

pub const Capability = enum {
    face,
    hands,
    segmentation,
    world,
    audio_level,
};

pub const ParamType = enum { float, bool, int, color };

pub const ParamValue = union(ParamType) {
    float: f32,
    bool: bool,
    int: i32,
    color: [4]f32,
};

pub const Parameter = struct {
    name: []const u8,
    type: ParamType,
    default: ParamValue,
    min: f32 = 0,
    max: f32 = 0,
};

pub const ParamBinding = union(enum) {
    literal_float: f32,
    literal_bool: bool,
    literal_int: i32,
    param_ref: []const u8,
};

pub const NodeInput = struct { name: []const u8, source: []const u8 };
pub const NodeParam = struct { name: []const u8, binding: ParamBinding };

/// The mask channels a shader.pass node may name: the subject-compat
/// person mask, then the multiclass model's own label order. Frozen
/// lens-format vocabulary; a running session without the class serves
/// the zero mask, so the effect draws nothing rather than everywhere.
pub const mask_channels = [_][]const u8{
    "person", "background", "hair", "body_skin", "face_skin", "clothes", "others",
};

pub fn maskChannelIndex(name: []const u8) ?u8 {
    for (mask_channels, 0..) |candidate, i| {
        if (std.mem.eql(u8, candidate, name)) return @intCast(i);
    }
    return null;
}

/// A rigid body a model.gltf node rides: the body's pose drives the
/// model matrix once simulation starts.
pub const ClothField = struct {
    /// Grid resolution and world-space size of the cloth sheet.
    cols: u32,
    rows: u32,
    width: f32,
    height: f32,
};

pub const HairField = struct {
    /// Strand count, vertices per strand, and strand length in metres.
    strands: u32,
    verts: u32,
    length: f32,
};

pub const PhysicsBody = struct {
    shape: enum { box, sphere },
    /// Box half extents; a sphere reads its radius from [0].
    size: [3]f32,
    position: [3]f32,
    dynamic: bool,
    /// The engine drives this body's pose from its anchor each frame;
    /// chained bodies hang off it.
    kinematic: bool = false,
    /// The id of the node this body is chained to, and the chain
    /// length, for content hanging off an anchor.
    chain_to: ?[]const u8 = null,
    chain_length: f32 = 0,
};

pub const Node = struct {
    id: []const u8,
    type: []const u8,
    inputs: []const NodeInput,
    params: []const NodeParam,
    /// Index into mask_channels, set only when the manifest names one.
    mask_channel: ?u8 = null,
    /// True when a model.gltf node anchors to the tracked face.
    face_anchor: bool = false,
    /// True when a model.gltf node anchors to the tracked world.
    world_anchor: bool = false,
    /// Set when the manifest gives the node a rigid body.
    physics: ?PhysicsBody = null,
    /// Set when the node is a simulated cloth sheet instead of a glb.
    cloth: ?ClothField = null,
    /// Set when the node is simulated strand hair instead of a glb.
    hair: ?HairField = null,
    /// The inline script source, set only for a "script" node. It runs each
    /// tick to drive parameters and never joins the composite chain.
    script: ?[]const u8 = null,
};

pub const ActionKind = enum {
    param_ramp,
    param_set,
    show,
    hide,
    play_animation,
    swap_subgraph,
    reset_timer,
};

pub const Curve = enum { linear, spring };

pub const Action = struct {
    kind: ActionKind,
    target: []const u8 = "",
    to: f32 = 0,
    duration_ms: u32 = 0,
    curve: Curve = .linear,
    stiffness: f32 = 0,
    damping: f32 = 0,
};

pub const Trigger = struct {
    when_source: []const u8,
    action: Action,
};

/// A range over the ABI's major.minor: an optional lower bound (>= or >)
/// and optional upper bound (< or <=), space separated, each
/// `major.minor`. Anything wider is out of scope for GLF 1.0, which
/// only ever needs to express "at least this, before that".
pub const EngineRange = struct {
    has_min: bool = false,
    min_major: u16 = 0,
    min_minor: u16 = 0,
    min_inclusive: bool = true,
    has_max: bool = false,
    max_major: u16 = 0,
    max_minor: u16 = 0,
    max_inclusive: bool = false,

    pub fn contains(self: EngineRange, major: u16, minor: u16) bool {
        if (self.has_min) {
            const below = major < self.min_major or (major == self.min_major and minor < self.min_minor);
            const at_floor = major == self.min_major and minor == self.min_minor;
            if (below or (!self.min_inclusive and at_floor)) return false;
        }
        if (self.has_max) {
            const above = major > self.max_major or (major == self.max_major and minor > self.max_minor);
            const at_ceiling = major == self.max_major and minor == self.max_minor;
            if (above or (!self.max_inclusive and at_ceiling)) return false;
        }
        return true;
    }
};

pub const Manifest = struct {
    arena: std.heap.ArenaAllocator,
    glf_minor: u16,
    id: []const u8,
    version: []const u8,
    display_name: []const u8,
    engine_compat: EngineRange,
    capabilities: []const Capability,
    parameters: []const Parameter,
    nodes: []const Node,
    triggers: []const Trigger,

    pub fn deinit(self: *Manifest) void {
        self.arena.deinit();
        self.* = undefined;
    }
};

pub const Diagnostic = struct {
    path: []const u8,
    message: []const u8,
};

pub const Diagnostics = struct {
    arena: std.mem.Allocator,
    list: std.ArrayList(Diagnostic) = .empty,

    pub fn add(self: *Diagnostics, path: []const u8, comptime fmt: []const u8, args: anytype) error{OutOfMemory}!void {
        const message = try std.fmt.allocPrint(self.arena, fmt, args);
        const path_copy = try self.arena.dupe(u8, path);
        try self.list.append(self.arena, .{ .path = path_copy, .message = message });
    }
};

/// Builds "/a/b/2" style pointers without allocating: a fixed buffer big
/// enough for any path this format's own field/count limits can produce.
const PathStack = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn push(self: *PathStack, segment: []const u8) usize {
        const mark = self.len;
        if (self.len + 1 + segment.len <= self.buf.len) {
            self.buf[self.len] = '/';
            @memcpy(self.buf[self.len + 1 ..][0..segment.len], segment);
            self.len += 1 + segment.len;
        }
        return mark;
    }

    fn pushIndex(self: *PathStack, index: usize) usize {
        var tmp: [24]u8 = undefined;
        const s = std.fmt.bufPrint(&tmp, "{d}", .{index}) catch unreachable;
        return self.push(s);
    }

    fn pop(self: *PathStack, mark: usize) void {
        self.len = mark;
    }

    fn slice(self: *const PathStack) []const u8 {
        return self.buf[0..self.len];
    }
};

fn jsonDepth(value: std.json.Value) usize {
    return switch (value) {
        .array => |a| blk: {
            var max: usize = 0;
            for (a.items) |item| max = @max(max, jsonDepth(item));
            break :blk max + 1;
        },
        .object => |o| blk: {
            var max: usize = 0;
            var it = o.iterator();
            while (it.next()) |entry| max = @max(max, jsonDepth(entry.value_ptr.*));
            break :blk max + 1;
        },
        else => 0,
    };
}

fn readVec3(value: std.json.Value, out: *[3]f32) bool {
    if (value != .array or value.array.items.len != 3) return false;
    for (value.array.items, 0..) |item, i| {
        out[i] = switch (item) {
            .float => |f| @floatCast(f),
            .integer => |n| @floatFromInt(n),
            else => return false,
        };
    }
    return true;
}

fn getField(object: std.json.ObjectMap, name: []const u8) ?std.json.Value {
    return object.get(name);
}

fn expectObject(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?std.json.ObjectMap {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected an object", .{});
        return null;
    };
    return switch (v) {
        .object => |o| o,
        else => blk: {
            try diags.add(path.slice(), "expected an object", .{});
            break :blk null;
        },
    };
}

fn expectString(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?[]const u8 {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected a string", .{});
        return null;
    };
    return switch (v) {
        .string => |s| s,
        else => blk: {
            try diags.add(path.slice(), "expected a string", .{});
            break :blk null;
        },
    };
}

fn expectArray(diags: *Diagnostics, path: *PathStack, value: ?std.json.Value) error{OutOfMemory}!?std.json.Array {
    const v = value orelse {
        try diags.add(path.slice(), "missing, expected an array", .{});
        return null;
    };
    return switch (v) {
        .array => |a| a,
        else => blk: {
            try diags.add(path.slice(), "expected an array", .{});
            break :blk null;
        },
    };
}

fn numberOf(value: std.json.Value) ?f64 {
    return switch (value) {
        .integer => |i| @floatFromInt(i),
        .float => |f| f,
        else => null,
    };
}

/// Parses "major.minor" strictly: two decimal runs separated by one dot,
/// nothing else.
fn parseMajorMinor(s: []const u8) ?struct { major: u16, minor: u16 } {
    const dot = std.mem.indexOfScalar(u8, s, '.') orelse return null;
    if (std.mem.indexOfScalarPos(u8, s, dot + 1, '.') != null) return null;
    const major = std.fmt.parseInt(u16, s[0..dot], 10) catch return null;
    const minor = std.fmt.parseInt(u16, s[dot + 1 ..], 10) catch return null;
    return .{ .major = major, .minor = minor };
}

fn parseEngineCompat(diags: *Diagnostics, path: *PathStack, s: []const u8) error{OutOfMemory}!?EngineRange {
    var range = EngineRange{};
    var it = std.mem.tokenizeScalar(u8, s, ' ');
    var clauses: usize = 0;
    while (it.next()) |clause| {
        clauses += 1;
        if (clauses > 2) {
            try diags.add(path.slice(), "engine_compat takes at most a lower and an upper bound", .{});
            return null;
        }
        var inclusive = true;
        var rest = clause;
        var is_min: bool = undefined;
        if (std.mem.startsWith(u8, rest, ">=")) {
            is_min = true;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, ">")) {
            is_min = true;
            inclusive = false;
            rest = rest[1..];
        } else if (std.mem.startsWith(u8, rest, "<=")) {
            is_min = false;
            rest = rest[2..];
        } else if (std.mem.startsWith(u8, rest, "<")) {
            is_min = false;
            inclusive = false;
            rest = rest[1..];
        } else {
            try diags.add(path.slice(), "engine_compat clause '{s}' must start with >=, >, <=, or <", .{clause});
            return null;
        }
        const parsed = parseMajorMinor(rest) orelse {
            try diags.add(path.slice(), "engine_compat clause '{s}' must name major.minor", .{clause});
            return null;
        };
        if (is_min) {
            if (range.has_min) {
                try diags.add(path.slice(), "engine_compat names two lower bounds", .{});
                return null;
            }
            range.has_min = true;
            range.min_major = parsed.major;
            range.min_minor = parsed.minor;
            range.min_inclusive = inclusive;
        } else {
            if (range.has_max) {
                try diags.add(path.slice(), "engine_compat names two upper bounds", .{});
                return null;
            }
            range.has_max = true;
            range.max_major = parsed.major;
            range.max_minor = parsed.minor;
            range.max_inclusive = inclusive;
        }
    }
    if (clauses == 0) {
        try diags.add(path.slice(), "engine_compat is empty", .{});
        return null;
    }
    return range;
}

fn parseCapabilities(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Capability {
    var out: std.ArrayList(Capability) = .empty;
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const name = switch (item) {
            .string => |s| s,
            else => {
                try diags.add(path.slice(), "expected a capability name", .{});
                continue;
            },
        };
        const cap = std.meta.stringToEnum(Capability, name) orelse {
            try diags.add(path.slice(), "unknown capability '{s}'", .{name});
            continue;
        };
        try out.append(arena, cap);
    }
    return try out.toOwnedSlice(arena);
}

fn parseParamValue(diags: *Diagnostics, path: *PathStack, param_type: ParamType, value: std.json.Value) error{OutOfMemory}!?ParamValue {
    switch (param_type) {
        .float => {
            const n = numberOf(value) orelse {
                try diags.add(path.slice(), "expected a number", .{});
                return null;
            };
            return .{ .float = @floatCast(n) };
        },
        .int => {
            const n = numberOf(value) orelse {
                try diags.add(path.slice(), "expected a number", .{});
                return null;
            };
            return .{ .int = @intFromFloat(n) };
        },
        .bool => {
            return switch (value) {
                .bool => |b| .{ .bool = b },
                else => blk: {
                    try diags.add(path.slice(), "expected a bool", .{});
                    break :blk null;
                },
            };
        },
        .color => {
            const array = switch (value) {
                .array => |a| a,
                else => {
                    try diags.add(path.slice(), "expected a 4 element color array", .{});
                    return null;
                },
            };
            if (array.items.len != 4) {
                try diags.add(path.slice(), "color needs exactly 4 components", .{});
                return null;
            }
            var out: [4]f32 = undefined;
            for (array.items, 0..) |c, i| {
                out[i] = @floatCast(numberOf(c) orelse {
                    try diags.add(path.slice(), "color component {d} is not a number", .{i});
                    return null;
                });
            }
            return .{ .color = out };
        },
    }
}

fn parseParameters(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Parameter {
    if (array.items.len > max_parameters) {
        try diags.add(path.slice(), "at most {d} parameters, found {d}", .{ max_parameters, array.items.len });
        return null;
    }
    var out: std.ArrayList(Parameter) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const name_mark = path.push("name");
        const name = try expectString(diags, path, getField(object, "name")) orelse {
            path.pop(name_mark);
            continue;
        };
        path.pop(name_mark);
        if (seen.contains(name)) {
            try diags.add(path.slice(), "duplicate parameter name '{s}'", .{name});
            continue;
        }
        try seen.put(name, {});

        const type_mark = path.push("type");
        const type_str = try expectString(diags, path, getField(object, "type")) orelse {
            path.pop(type_mark);
            continue;
        };
        const param_type = std.meta.stringToEnum(ParamType, type_str) orelse {
            try diags.add(path.slice(), "unknown parameter type '{s}'", .{type_str});
            path.pop(type_mark);
            continue;
        };
        path.pop(type_mark);

        const default_mark = path.push("default");
        const default_value = getField(object, "default") orelse {
            try diags.add(path.slice(), "missing", .{});
            path.pop(default_mark);
            continue;
        };
        const default = try parseParamValue(diags, path, param_type, default_value) orelse {
            path.pop(default_mark);
            continue;
        };
        path.pop(default_mark);

        var min: f32 = 0;
        var max: f32 = 0;
        if (param_type == .float or param_type == .int) {
            const min_mark = path.push("min");
            min = @floatCast(numberOf(getField(object, "min") orelse .null) orelse {
                try diags.add(path.slice(), "missing, required for float and int parameters", .{});
                path.pop(min_mark);
                continue;
            });
            path.pop(min_mark);
            const max_mark = path.push("max");
            max = @floatCast(numberOf(getField(object, "max") orelse .null) orelse {
                try diags.add(path.slice(), "missing, required for float and int parameters", .{});
                path.pop(max_mark);
                continue;
            });
            path.pop(max_mark);
            if (min > max) {
                try diags.add(path.slice(), "min {d} exceeds max {d}", .{ min, max });
                continue;
            }
        }

        try out.append(arena, .{
            .name = try arena.dupe(u8, name),
            .type = param_type,
            .default = default,
            .min = min,
            .max = max,
        });
    }
    return try out.toOwnedSlice(arena);
}

fn parseBinding(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, value: std.json.Value) error{OutOfMemory}!?ParamBinding {
    switch (value) {
        .string => |s| {
            if (s.len > 0 and s[0] == '$') {
                return .{ .param_ref = try arena.dupe(u8, s[1..]) };
            }
            try diags.add(path.slice(), "string param bindings must start with $", .{});
            return null;
        },
        .bool => |b| return .{ .literal_bool = b },
        .integer, .float => {
            const n = numberOf(value).?;
            return .{ .literal_float = @floatCast(n) };
        },
        else => {
            try diags.add(path.slice(), "expected a number, bool, or $parameter reference", .{});
            return null;
        },
    }
}

fn parseNodes(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Node {
    if (array.items.len > max_nodes) {
        try diags.add(path.slice(), "at most {d} nodes, found {d}", .{ max_nodes, array.items.len });
        return null;
    }
    var out: std.ArrayList(Node) = .empty;
    var seen = std.StringHashMap(void).init(arena);
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const id_mark = path.push("id");
        const id = try expectString(diags, path, getField(object, "id")) orelse {
            path.pop(id_mark);
            continue;
        };
        path.pop(id_mark);
        if (seen.contains(id)) {
            try diags.add(path.slice(), "duplicate node id '{s}'", .{id});
            continue;
        }
        try seen.put(id, {});

        const type_mark = path.push("type");
        const node_type = try expectString(diags, path, getField(object, "type")) orelse {
            path.pop(type_mark);
            continue;
        };
        path.pop(type_mark);

        var inputs: std.ArrayList(NodeInput) = .empty;
        if (getField(object, "inputs")) |inputs_value| {
            const inputs_mark = path.push("inputs");
            const inputs_object = switch (inputs_value) {
                .object => |o| o,
                else => blk: {
                    try diags.add(path.slice(), "expected an object mapping input names to node ids", .{});
                    break :blk null;
                },
            };
            if (inputs_object) |o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    const source = switch (entry.value_ptr.*) {
                        .string => |s| s,
                        else => {
                            const field_mark = path.push(entry.key_ptr.*);
                            try diags.add(path.slice(), "expected a node id string", .{});
                            path.pop(field_mark);
                            continue;
                        },
                    };
                    try inputs.append(arena, .{
                        .name = try arena.dupe(u8, entry.key_ptr.*),
                        .source = try arena.dupe(u8, source),
                    });
                }
            }
            path.pop(inputs_mark);
        }

        var params: std.ArrayList(NodeParam) = .empty;
        if (getField(object, "params")) |params_value| {
            const params_mark = path.push("params");
            const params_object = switch (params_value) {
                .object => |o| o,
                else => blk: {
                    try diags.add(path.slice(), "expected an object mapping param names to bindings", .{});
                    break :blk null;
                },
            };
            if (params_object) |o| {
                var it = o.iterator();
                while (it.next()) |entry| {
                    const field_mark = path.push(entry.key_ptr.*);
                    const binding = try parseBinding(diags, path, arena, entry.value_ptr.*);
                    path.pop(field_mark);
                    if (binding) |b| {
                        try params.append(arena, .{ .name = try arena.dupe(u8, entry.key_ptr.*), .binding = b });
                    }
                }
            }
            path.pop(params_mark);
        }

        var face_anchor = false;
        var world_anchor = false;
        var physics_body: ?PhysicsBody = null;
        var hair_field: ?HairField = null;
        if (getField(object, "hair")) |hair_value| {
            const hair_mark = path.push("hair");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "hair is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (hair_value != .object) {
                try diags.add(path.slice(), "hair must be an object", .{});
            } else {
                var field: HairField = .{ .strands = 24, .verts = 16, .length = 0.5 };
                if (getField(hair_value.object, "strands")) |v| {
                    if (v == .integer and v.integer >= 1 and v.integer <= 256) field.strands = @intCast(v.integer);
                }
                if (getField(hair_value.object, "verts")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.verts = @intCast(v.integer);
                }
                if (getField(hair_value.object, "length")) |v| {
                    switch (v) {
                        .float => |f| field.length = @floatCast(f),
                        .integer => |n| field.length = @floatFromInt(n),
                        else => {},
                    }
                }
                hair_field = field;
            }
            path.pop(hair_mark);
        }
        var cloth_field: ?ClothField = null;
        if (getField(object, "cloth")) |cloth_value| {
            const cloth_mark = path.push("cloth");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "cloth is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (cloth_value != .object) {
                try diags.add(path.slice(), "cloth must be an object", .{});
            } else {
                var field: ClothField = .{ .cols = 8, .rows = 8, .width = 1.0, .height = 1.0 };
                var ok = true;
                if (getField(cloth_value.object, "cols")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.cols = @intCast(v.integer) else {
                        try diags.add(path.slice(), "cloth cols must be an integer 2..64", .{});
                        ok = false;
                    }
                }
                if (getField(cloth_value.object, "rows")) |v| {
                    if (v == .integer and v.integer >= 2 and v.integer <= 64) field.rows = @intCast(v.integer) else {
                        try diags.add(path.slice(), "cloth rows must be an integer 2..64", .{});
                        ok = false;
                    }
                }
                if (getField(cloth_value.object, "width")) |v| {
                    switch (v) {
                        .float => |f| field.width = @floatCast(f),
                        .integer => |n| field.width = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "cloth width must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (getField(cloth_value.object, "height")) |v| {
                    switch (v) {
                        .float => |f| field.height = @floatCast(f),
                        .integer => |n| field.height = @floatFromInt(n),
                        else => {
                            try diags.add(path.slice(), "cloth height must be a number", .{});
                            ok = false;
                        },
                    }
                }
                if (ok) cloth_field = field;
            }
            path.pop(cloth_mark);
        }
        if (getField(object, "physics")) |physics_value| {
            const physics_mark = path.push("physics");
            if (!std.mem.eql(u8, node_type, "model.gltf")) {
                try diags.add(path.slice(), "physics is a model.gltf field, found it on '{s}'", .{node_type});
            } else if (physics_value != .object) {
                try diags.add(path.slice(), "physics must be an object", .{});
            } else {
                var body: PhysicsBody = .{ .shape = .box, .size = .{ 0.1, 0.1, 0.1 }, .position = .{ 0, 0, 0 }, .dynamic = true };
                var shape_ok = false;
                if (getField(physics_value.object, "body")) |body_value| {
                    if (try expectString(diags, path, body_value)) |body_name| {
                        if (std.mem.eql(u8, body_name, "box")) {
                            body.shape = .box;
                            shape_ok = true;
                        } else if (std.mem.eql(u8, body_name, "sphere")) {
                            body.shape = .sphere;
                            shape_ok = true;
                        } else {
                            try diags.add(path.slice(), "unknown physics body '{s}'", .{body_name});
                        }
                    }
                } else {
                    try diags.add(path.slice(), "physics needs a body", .{});
                }
                if (getField(physics_value.object, "size")) |size_value| {
                    if (!readVec3(size_value, &body.size)) {
                        try diags.add(path.slice(), "physics size must be three numbers", .{});
                        shape_ok = false;
                    }
                }
                if (getField(physics_value.object, "position")) |position_value| {
                    if (!readVec3(position_value, &body.position)) {
                        try diags.add(path.slice(), "physics position must be three numbers", .{});
                        shape_ok = false;
                    }
                }
                if (getField(physics_value.object, "motion")) |motion_value| {
                    if (try expectString(diags, path, motion_value)) |motion_name| {
                        if (std.mem.eql(u8, motion_name, "static")) {
                            body.dynamic = false;
                        } else if (std.mem.eql(u8, motion_name, "dynamic")) {
                            body.dynamic = true;
                        } else if (std.mem.eql(u8, motion_name, "kinematic")) {
                            body.dynamic = false;
                            body.kinematic = true;
                        } else {
                            try diags.add(path.slice(), "unknown physics motion '{s}'", .{motion_name});
                        }
                    }
                }
                if (getField(physics_value.object, "chain")) |chain_value| {
                    if (chain_value != .object) {
                        try diags.add(path.slice(), "physics chain must be an object", .{});
                    } else {
                        if (getField(chain_value.object, "to")) |to_value| {
                            if (try expectString(diags, path, to_value)) |to_name| {
                                body.chain_to = try arena.dupe(u8, to_name);
                            }
                        } else {
                            try diags.add(path.slice(), "physics chain needs a to", .{});
                        }
                        if (getField(chain_value.object, "length")) |len_value| {
                            switch (len_value) {
                                .float => |f| body.chain_length = @floatCast(f),
                                .integer => |n| body.chain_length = @floatFromInt(n),
                                else => try diags.add(path.slice(), "physics chain length must be a number", .{}),
                            }
                        }
                    }
                }
                if (shape_ok) physics_body = body;
            }
            path.pop(physics_mark);
        }
        if (getField(object, "anchor")) |anchor_value| {
            const anchor_mark = path.push("anchor");
            if (try expectString(diags, path, anchor_value)) |anchor_name| {
                if (!std.mem.eql(u8, node_type, "model.gltf")) {
                    try diags.add(path.slice(), "anchor is a model.gltf field, found it on '{s}'", .{node_type});
                } else if (std.mem.eql(u8, anchor_name, "face")) {
                    face_anchor = true;
                } else if (std.mem.eql(u8, anchor_name, "world")) {
                    world_anchor = true;
                } else {
                    try diags.add(path.slice(), "unknown anchor '{s}'", .{anchor_name});
                }
            }
            path.pop(anchor_mark);
        }

        var mask_channel: ?u8 = null;
        if (getField(object, "mask")) |mask_value| {
            const mask_mark = path.push("mask");
            if (try expectString(diags, path, mask_value)) |mask_name| {
                if (!std.mem.eql(u8, node_type, "shader.pass")) {
                    try diags.add(path.slice(), "mask is a shader.pass field, found it on '{s}'", .{node_type});
                } else if (maskChannelIndex(mask_name)) |channel| {
                    mask_channel = channel;
                } else {
                    try diags.add(path.slice(), "unknown mask channel '{s}'", .{mask_name});
                }
            }
            path.pop(mask_mark);
        }

        var script_source: ?[]const u8 = null;
        if (std.mem.eql(u8, node_type, "script")) {
            const src_mark = path.push("source");
            if (getField(object, "source")) |src_value| {
                if (try expectString(diags, path, src_value)) |src| {
                    script_source = try arena.dupe(u8, src);
                }
            } else {
                try diags.add(path.slice(), "a script node needs a source", .{});
            }
            path.pop(src_mark);
        }

        try out.append(arena, .{
            .id = try arena.dupe(u8, id),
            .type = try arena.dupe(u8, node_type),
            .inputs = try inputs.toOwnedSlice(arena),
            .params = try params.toOwnedSlice(arena),
            .mask_channel = mask_channel,
            .face_anchor = face_anchor,
            .world_anchor = world_anchor,
            .physics = physics_body,
            .cloth = cloth_field,
            .hair = hair_field,
            .script = script_source,
        });
    }
    return try out.toOwnedSlice(arena);
}

fn parseAction(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, object: std.json.ObjectMap) error{OutOfMemory}!?Action {
    const kind_mark = path.push("kind");
    const kind_str = try expectString(diags, path, getField(object, "kind")) orelse {
        path.pop(kind_mark);
        return null;
    };
    const kind = std.meta.stringToEnum(ActionKind, kind_str) orelse {
        try diags.add(path.slice(), "unknown action kind '{s}'", .{kind_str});
        path.pop(kind_mark);
        return null;
    };
    path.pop(kind_mark);

    var action = Action{ .kind = kind };
    if (getField(object, "target")) |v| {
        action.target = try arena.dupe(u8, switch (v) {
            .string => |s| s,
            else => blk: {
                const mark = path.push("target");
                try diags.add(path.slice(), "expected a string", .{});
                path.pop(mark);
                break :blk "";
            },
        });
    }
    if (getField(object, "to")) |v| {
        action.to = @floatCast(numberOf(v) orelse blk: {
            const mark = path.push("to");
            try diags.add(path.slice(), "expected a number", .{});
            path.pop(mark);
            break :blk 0;
        });
    }
    if (getField(object, "duration_ms")) |v| {
        const n = numberOf(v) orelse blk: {
            const mark = path.push("duration_ms");
            try diags.add(path.slice(), "expected a number", .{});
            path.pop(mark);
            break :blk 0;
        };
        action.duration_ms = @intFromFloat(@max(0, n));
    }
    if (getField(object, "curve")) |v| {
        const s = switch (v) {
            .string => |str| str,
            else => "",
        };
        action.curve = std.meta.stringToEnum(Curve, s) orelse blk: {
            const mark = path.push("curve");
            try diags.add(path.slice(), "unknown curve '{s}'", .{s});
            path.pop(mark);
            break :blk .linear;
        };
    }
    if (getField(object, "stiffness")) |v| action.stiffness = @floatCast(numberOf(v) orelse 0);
    if (getField(object, "damping")) |v| action.damping = @floatCast(numberOf(v) orelse 0);
    return action;
}

fn parseTriggers(arena: std.mem.Allocator, diags: *Diagnostics, path: *PathStack, array: std.json.Array) error{OutOfMemory}!?[]const Trigger {
    if (array.items.len > max_triggers) {
        try diags.add(path.slice(), "at most {d} triggers, found {d}", .{ max_triggers, array.items.len });
        return null;
    }
    var out: std.ArrayList(Trigger) = .empty;
    for (array.items, 0..) |item, i| {
        const mark = path.pushIndex(i);
        defer path.pop(mark);
        const object = try expectObject(diags, path, item) orelse continue;

        const when_mark = path.push("when");
        const when_source = try expectString(diags, path, getField(object, "when")) orelse {
            path.pop(when_mark);
            continue;
        };
        if (when_source.len > max_when_bytes) {
            try diags.add(path.slice(), "when exceeds {d} bytes", .{max_when_bytes});
            path.pop(when_mark);
            continue;
        }
        path.pop(when_mark);

        const action_mark = path.push("action");
        const action_object = try expectObject(diags, path, getField(object, "action")) orelse {
            path.pop(action_mark);
            continue;
        };
        const action = try parseAction(diags, path, arena, action_object) orelse {
            path.pop(action_mark);
            continue;
        };
        path.pop(action_mark);

        try out.append(arena, .{ .when_source = try arena.dupe(u8, when_source), .action = action });
    }
    return try out.toOwnedSlice(arena);
}

/// Parses and structurally validates one manifest.json: bundle-independent
/// limits, the top level schema, engine_compat, capability names, and
/// cross references between nodes/params/triggers.
/// Shader compilation and asset decode are the bundle loader's job, not
/// this function's - they need the rest of the bundle on disk. Returns
/// null with diags populated on any validation failure; never partially
/// returns a Manifest.
pub fn parse(gpa: std.mem.Allocator, diags: *Diagnostics, source: []const u8) error{OutOfMemory}!?Manifest {
    var path = PathStack{};
    if (source.len > max_manifest_bytes) {
        try diags.add("", "manifest exceeds {d} bytes (got {d})", .{ max_manifest_bytes, source.len });
        return null;
    }

    var parsed = std.json.parseFromSlice(std.json.Value, gpa, source, .{}) catch |err| {
        try diags.add("", "invalid json: {t}", .{err});
        return null;
    };
    defer parsed.deinit();

    if (jsonDepth(parsed.value) > max_json_depth) {
        try diags.add("", "nesting exceeds a depth of {d}", .{max_json_depth});
        return null;
    }

    const root = try expectObject(diags, &path, parsed.value) orelse return null;

    var manifest: Manifest = .{
        .arena = std.heap.ArenaAllocator.init(gpa),
        .glf_minor = 0,
        .id = "",
        .version = "",
        .display_name = "",
        .engine_compat = .{},
        .capabilities = &.{},
        .parameters = &.{},
        .nodes = &.{},
        .triggers = &.{},
    };
    errdefer manifest.arena.deinit();
    const arena = manifest.arena.allocator();

    const diags_before = diags.list.items.len;

    {
        const mark = path.push("glf");
        if (try expectString(diags, &path, getField(root, "glf"))) |glf| {
            const parsed_version = parseMajorMinor(glf);
            if (parsed_version == null or parsed_version.?.major != 1) {
                try diags.add(path.slice(), "unsupported glf version '{s}', this runtime is 1.x", .{glf});
            } else {
                manifest.glf_minor = parsed_version.?.minor;
            }
        }
        path.pop(mark);
    }
    {
        const mark = path.push("id");
        if (try expectString(diags, &path, getField(root, "id"))) |id| manifest.id = try arena.dupe(u8, id);
        path.pop(mark);
    }
    {
        const mark = path.push("version");
        if (try expectString(diags, &path, getField(root, "version"))) |v| manifest.version = try arena.dupe(u8, v);
        path.pop(mark);
    }
    {
        const mark = path.push("display_name");
        if (try expectString(diags, &path, getField(root, "display_name"))) |v| manifest.display_name = try arena.dupe(u8, v);
        path.pop(mark);
    }
    {
        const mark = path.push("engine_compat");
        if (try expectString(diags, &path, getField(root, "engine_compat"))) |s| {
            if (try parseEngineCompat(diags, &path, s)) |range| manifest.engine_compat = range;
        }
        path.pop(mark);
    }
    {
        const mark = path.push("capabilities");
        if (try expectArray(diags, &path, getField(root, "capabilities"))) |array| {
            manifest.capabilities = try parseCapabilities(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("parameters");
        if (try expectArray(diags, &path, getField(root, "parameters"))) |array| {
            manifest.parameters = try parseParameters(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("nodes");
        if (try expectArray(diags, &path, getField(root, "nodes"))) |array| {
            manifest.nodes = try parseNodes(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }
    {
        const mark = path.push("triggers");
        if (try expectArray(diags, &path, getField(root, "triggers"))) |array| {
            manifest.triggers = try parseTriggers(arena, diags, &path, array) orelse &.{};
        }
        path.pop(mark);
    }

    try crossReference(diags, &path, arena, &manifest);

    if (diags.list.items.len > diags_before) {
        manifest.arena.deinit();
        return null;
    }
    return manifest;
}

/// Node inputs/params referencing an id or parameter that does not exist,
/// and trigger actions referencing a node id or parameter that does not
/// exist - its own validation stage, run only after the per-array shapes
/// above are already known good.
fn crossReference(diags: *Diagnostics, path: *PathStack, arena: std.mem.Allocator, manifest: *const Manifest) error{OutOfMemory}!void {
    var node_ids = std.StringHashMap(void).init(arena);
    for (manifest.nodes) |node| try node_ids.put(node.id, {});
    var param_names = std.StringHashMap(void).init(arena);
    for (manifest.parameters) |p| try param_names.put(p.name, {});

    const nodes_mark = path.push("nodes");
    for (manifest.nodes, 0..) |node, i| {
        const node_mark = path.pushIndex(i);
        const inputs_mark = path.push("inputs");
        for (node.inputs) |input| {
            // "camera" is the implicit capture input every lens graph
            // starts from; every other source must be a node id declared
            // above.
            if (!std.mem.eql(u8, input.source, "camera") and !node_ids.contains(input.source)) {
                const field_mark = path.push(input.name);
                try diags.add(path.slice(), "input '{s}' names unknown node id '{s}'", .{ input.name, input.source });
                path.pop(field_mark);
            }
        }
        path.pop(inputs_mark);
        const params_mark = path.push("params");
        for (node.params) |param| {
            if (param.binding == .param_ref and !param_names.contains(param.binding.param_ref)) {
                const field_mark = path.push(param.name);
                try diags.add(path.slice(), "binds unknown parameter '{s}'", .{param.binding.param_ref});
                path.pop(field_mark);
            }
        }
        path.pop(params_mark);
        path.pop(node_mark);
    }
    path.pop(nodes_mark);

    const triggers_mark = path.push("triggers");
    for (manifest.triggers, 0..) |trigger, i| {
        const trigger_mark = path.pushIndex(i);
        const action_mark = path.push("action");
        const needs_param = switch (trigger.action.kind) {
            .param_ramp, .param_set => true,
            else => false,
        };
        const needs_node = switch (trigger.action.kind) {
            .show, .hide, .swap_subgraph, .play_animation => true,
            else => false,
        };
        if (needs_param and !param_names.contains(trigger.action.target)) {
            try diags.add(path.slice(), "targets unknown parameter '{s}'", .{trigger.action.target});
        }
        if (needs_node and !node_ids.contains(trigger.action.target)) {
            try diags.add(path.slice(), "targets unknown node id '{s}'", .{trigger.action.target});
        }
        path.pop(action_mark);
        path.pop(trigger_mark);
    }
    path.pop(triggers_mark);
}

const t = std.testing;

fn parseOk(source: []const u8) !Manifest {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    const result = try parse(t.allocator, &diags, source);
    if (result == null) {
        for (diags.list.items) |d| std.debug.print("{s}: {s}\n", .{ d.path, d.message });
    }
    return result orelse error.TestUnexpectedResult;
}

const FailedParse = struct {
    arena: std.heap.ArenaAllocator,
    diags: std.ArrayList(Diagnostic),

    fn deinit(self: *FailedParse) void {
        self.arena.deinit();
    }
};

fn parseFails(source: []const u8) !FailedParse {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    errdefer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    const result = try parse(t.allocator, &diags, source);
    if (result) |*m| {
        var mutable = m.*;
        mutable.deinit();
        return error.TestUnexpectedResult;
    }
    return .{ .arena = arena, .diags = diags.list };
}

const minimal_valid =
    \\{
    \\  "glf": "1.0",
    \\  "id": "com.example.mylens",
    \\  "version": "1.0.0",
    \\  "display_name": "My Lens",
    \\  "engine_compat": ">=0.5 <1.0",
    \\  "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.5, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('mouthOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

test "a minimal valid manifest parses with every field populated" {
    var manifest = try parseOk(minimal_valid);
    defer manifest.deinit();
    try t.expectEqualStrings("com.example.mylens", manifest.id);
    try t.expectEqual(@as(usize, 1), manifest.capabilities.len);
    try t.expectEqual(Capability.face, manifest.capabilities[0]);
    try t.expectEqual(@as(usize, 1), manifest.parameters.len);
    try t.expectEqualStrings("smooth_amount", manifest.parameters[0].name);
    try t.expectEqual(@as(f32, 0.5), manifest.parameters[0].default.float);
    try t.expectEqual(@as(usize, 1), manifest.nodes.len);
    try t.expectEqualStrings("camera", manifest.nodes[0].inputs[0].source);
    try t.expectEqualStrings("smooth_amount", manifest.nodes[0].params[0].binding.param_ref);
    try t.expectEqual(@as(usize, 1), manifest.triggers.len);
    try t.expectEqual(ActionKind.param_ramp, manifest.triggers[0].action.kind);
    try t.expect(manifest.engine_compat.contains(0, 5));
    try t.expect(!manifest.engine_compat.contains(1, 0));
    try t.expect(!manifest.engine_compat.contains(0, 4));
}

test "a missing required field reports its exact path" {
    const source =
        \\{"glf": "1.0", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    try t.expect(result.diags.items.len >= 1);
    try t.expectEqualStrings("/id", result.diags.items[0].path);
}

test "an unknown node type is not rejected here, unknown capability is" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["telepathy"], "parameters": [], "nodes": [], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.eql(u8, d.path, "/capabilities/0")) found = true;
    }
    try t.expect(found);
}

test "a node input naming an unknown node id fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "beauty.reshape", "inputs": {"frame": "nonexistent"}, "params": {}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown node id") != null) found = true;
    }
    try t.expect(found);
}

test "a cloth field parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "flag", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "cloth": {"cols": 10, "rows": 6, "width": 1.5, "height": 1.0}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const cloth = manifest.nodes[0].cloth.?;
    try t.expectEqual(@as(u32, 10), cloth.cols);
    try t.expectEqual(@as(u32, 6), cloth.rows);
    try t.expectEqual(@as(f32, 1.5), cloth.width);
}

test "a script node captures its inline source" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [{"name": "intensity", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}], "nodes": [
        \\   {"id": "drive", "type": "script", "params": {},
        \\    "source": "function update(lens) { lens.params.intensity = lens.signals.face_present > 0.5 ? 0.8 : 0.2; }"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expectEqual(@as(usize, 1), manifest.nodes.len);
    try t.expectEqualStrings("script", manifest.nodes[0].type);
    try t.expect(manifest.nodes[0].script != null);
}

test "a physics chain parses its target and length" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "anchor", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "box", "motion": "kinematic"}},
        \\   {"id": "bead", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "sphere", "motion": "dynamic", "chain": {"to": "anchor", "length": 0.4}}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].physics.?.kinematic);
    const bead = manifest.nodes[1].physics.?;
    try t.expectEqualStrings("anchor", bead.chain_to.?);
    try t.expectEqual(@as(f32, 0.4), bead.chain_length);
}

test "a physics body parses on a model node" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {},
        \\    "physics": {"body": "sphere", "size": [0.2, 0, 0], "position": [0, 1.5, 0], "motion": "dynamic"}}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    const body = manifest.nodes[0].physics.?;
    try t.expect(body.shape == .sphere);
    try t.expectEqual(@as(f32, 0.2), body.size[0]);
    try t.expectEqual(@as(f32, 1.5), body.position[1]);
    try t.expect(body.dynamic);
}

test "physics on a non-model node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}, "physics": {"body": "box"}}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "physics is a model.gltf field") != null) found = true;
    }
    try t.expect(found);
}

test "a face anchor parses on a model node and only there" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": ["face"], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "face"}
        \\ ], "triggers": []}
    ;
    var manifest = try parseOk(source);
    defer manifest.deinit();
    try t.expect(manifest.nodes[0].face_anchor);
}

test "an anchor on a non-model node is rejected" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "a", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {}, "anchor": "face"}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "anchor is a model.gltf field") != null) found = true;
    }
    try t.expect(found);
}

test "an unknown anchor name is rejected" {
    const source =
        \\{"glf": "1.0", "id": "m", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [
        \\   {"id": "m", "type": "model.gltf", "inputs": {"frame": "camera"}, "params": {}, "anchor": "skeleton"}
        \\ ], "triggers": []}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown anchor") != null) found = true;
    }
    try t.expect(found);
}

test "a trigger action targeting an unknown parameter fails cross reference" {
    const source =
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [], "nodes": [], "triggers": [
        \\   {"when": "tap", "action": {"kind": "param_set", "target": "nope", "to": 1.0}}
        \\ ]}
    ;
    var result = try parseFails(source);
    defer result.deinit();
    var found = false;
    for (result.diags.items) |d| {
        if (std.mem.indexOf(u8, d.message, "unknown parameter") != null) found = true;
    }
    try t.expect(found);
}

test "too many parameters is rejected before any of them are parsed" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendSlice(t.allocator,
        \\{"glf": "1.0", "id": "x", "version": "1.0.0", "display_name": "x", "engine_compat": ">=0.5",
        \\ "capabilities": [], "parameters": [
    );
    for (0..max_parameters + 1) |i| {
        if (i != 0) try buf.appendSlice(t.allocator, ",");
        const entry = try std.fmt.allocPrint(
            t.allocator,
            "{{\"name\": \"p{d}\", \"type\": \"float\", \"default\": 0, \"min\": 0, \"max\": 1}}",
            .{i},
        );
        defer t.allocator.free(entry);
        try buf.appendSlice(t.allocator, entry);
    }
    try buf.appendSlice(t.allocator, "], \"nodes\": [], \"triggers\": []}");
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expectEqualStrings("/parameters", result.diags.items[0].path);
}

test "nesting past the depth limit is rejected" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    for (0..max_json_depth + 4) |_| try buf.appendSlice(t.allocator, "[");
    try buf.appendSlice(t.allocator, "0");
    for (0..max_json_depth + 4) |_| try buf.appendSlice(t.allocator, "]");
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expect(std.mem.indexOf(u8, result.diags.items[0].message, "depth") != null);
}

test "a manifest over the byte limit is rejected before json parsing" {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(t.allocator);
    try buf.appendNTimes(t.allocator, ' ', max_manifest_bytes + 1);
    var result = try parseFails(buf.items);
    defer result.deinit();
    try t.expect(std.mem.indexOf(u8, result.diags.items[0].message, "exceeds") != null);
}

test "engine_compat range boundaries are exact" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var diags = Diagnostics{ .arena = arena.allocator() };
    var path = PathStack{};
    const range = (try parseEngineCompat(&diags, &path, ">=0.5 <1.0")).?;
    try t.expect(range.contains(0, 5));
    try t.expect(range.contains(0, 9));
    try t.expect(!range.contains(0, 4));
    try t.expect(!range.contains(1, 0));
}
