//! Splices one lens's parsed manifest into the session's frame graph and
//! drives it forward one tick at a time: compiled triggers fire their
//! actions on the false-to-true edge, param_ramp/param_set
//! update the lens's own live parameter values, and animation.Ramp
//! carries an in-flight ramp to its target at the fixed graph timestep.
//! This module knows the shape of a running lens - node splice/unsplice,
//! trigger firing, parameter state - and nothing about how any of it
//! actually gets drawn. It has no adapter dependency of its own; the
//! caller (core/abi) walks tick()'s returned effect values and is the
//! one that knows how to hand them to the engine.
//!
//! Node types are the closed, kit-versioned vocabulary a lens manifest
//! can name: only the beauty family is wired here.
//! Shader passes, glTF draws, LUT passes, and compositing are real
//! remaining work, deliberately not stubbed in ahead of their own
//! execution landing.

const std = @import("std");
const graph = @import("graph");
const manifest = @import("manifest");
const trigger = @import("trigger");
const animation = @import("animation");

/// The beauty engine's six settable effects, named independently of
/// adapters/beauty.zig's own Effect enum - core/lens has no adapter
/// dependency - but numerically identical to it by construction; the
/// caller @enumFromInt's one into the other when dispatching.
pub const EffectSlot = enum(u3) {
    smooth = 0,
    whiten = 1,
    thin_face = 2,
    big_eye = 3,
    lipstick = 4,
    blush = 5,
};

pub const NodeType = enum { beauty_face, beauty_reshape, beauty_lipstick, beauty_blusher, shader_pass, lut_pass };

fn parseNodeType(type_str: []const u8) ?NodeType {
    if (std.mem.eql(u8, type_str, "beauty.face")) return .beauty_face;
    if (std.mem.eql(u8, type_str, "beauty.reshape")) return .beauty_reshape;
    if (std.mem.eql(u8, type_str, "beauty.lipstick")) return .beauty_lipstick;
    if (std.mem.eql(u8, type_str, "beauty.blusher")) return .beauty_blusher;
    if (std.mem.eql(u8, type_str, "shader.pass")) return .shader_pass;
    if (std.mem.eql(u8, type_str, "lut.pass")) return .lut_pass;
    return null;
}

const ParamSlot = struct { name: []const u8, effect: EffectSlot };

/// The param names each node type accepts and which effect slot each one
/// drives - the only place that mapping is declared. shader.pass and
/// lut.pass have no effect-slot params of their own: each one's id
/// names the asset it runs (a shader source file or a LUT image), the
/// same way a node's id already resolves against other nodes for
/// wiring.
fn paramSlotsFor(node_type: NodeType) []const ParamSlot {
    return switch (node_type) {
        .beauty_face => &.{
            .{ .name = "smooth", .effect = .smooth },
            .{ .name = "whiten", .effect = .whiten },
        },
        .beauty_reshape => &.{
            .{ .name = "thin_face", .effect = .thin_face },
            .{ .name = "big_eye", .effect = .big_eye },
        },
        .beauty_lipstick => &.{.{ .name = "blend", .effect = .lipstick }},
        .beauty_blusher => &.{.{ .name = "blend", .effect = .blush }},
        .shader_pass, .lut_pass => &.{},
    };
}

const ParamSource = union(enum) {
    literal: f32,
    parameter: u16,
};

const effect_slot_count = 6;

const LensNode = struct {
    graph_index: graph.NodeIndex,
    node_type: NodeType,
    bindings: [effect_slot_count]?ParamSource = @splat(null),
    /// Set only for .shader_pass and .lut_pass nodes: the node's own id,
    /// which also names the asset it runs (shaders/<id>.glsl for
    /// shader.pass, assets/<id>.png for lut.pass) - a slice into the
    /// Lens's own retained manifest arena, not separately owned.
    asset_stem: ?[]const u8 = null,
};

/// One shader.pass node ready for the caller to load and draw - which
/// graph node it is, and the shader (shaders/<stem>.glsl, plus its
/// packaged shaders/<stem>.<profile>.bin variants) it names. This
/// module has no bgfx dependency of its own; the caller resolves the
/// stem into actual bytes and does the real rendering work.
pub const ShaderPassNode = struct {
    graph_index: graph.NodeIndex,
    shader_stem: []const u8,
};

/// One lut.pass node ready for the caller to load and draw - which
/// graph node it is, and the LUT image (assets/<stem>.png) it names.
pub const LutPassNode = struct {
    graph_index: graph.NodeIndex,
    lut_stem: []const u8,
};

pub const PassKind = enum { shader, lut };

/// One shader.pass or lut.pass node, tagged with which - the caller's
/// real draw order for a chain that may mix both kinds, since the
/// graph itself makes no distinction between them beyond node_type.
pub const CompositePass = struct {
    graph_index: graph.NodeIndex,
    kind: PassKind,
};

pub const ActivateError = error{
    UnknownNodeId,
    UnknownParameter,
    UnsupportedNodeType,
} || std.mem.Allocator.Error || graph.topology.EditError;

/// One resolved (effect, value) pair for the caller to apply. tick()
/// returns these instead of touching an engine directly.
pub const AppliedEffect = struct { effect: EffectSlot, value: f32 };

pub const Lens = struct {
    gpa: std.mem.Allocator,
    manifest: manifest.Manifest,
    compiled_triggers: []trigger.Expression,
    trigger_was_true: []bool,
    param_values: []f32,
    ramps: []?animation.Ramp,
    nodes: []LensNode,

    pub fn deinit(self: *Lens, g: *graph.Graph) void {
        for (self.nodes) |n| g.removeNode(n.graph_index);
        for (self.compiled_triggers) |*expr| expr.deinit();
        self.gpa.free(self.compiled_triggers);
        self.gpa.free(self.trigger_was_true);
        self.gpa.free(self.param_values);
        self.gpa.free(self.ramps);
        self.gpa.free(self.nodes);
        self.manifest.deinit();
        self.* = undefined;
    }

    /// Every currently-bound effect value across every spliced node, in
    /// splice order - what the caller applies to the beauty chain right
    /// after activation, before the first tick.
    pub fn currentEffects(self: *const Lens, gpa: std.mem.Allocator) std.mem.Allocator.Error![]AppliedEffect {
        var out: std.ArrayList(AppliedEffect) = .empty;
        errdefer out.deinit(gpa);
        for (self.nodes) |node| try self.collectNodeEffects(gpa, &out, node);
        return out.toOwnedSlice(gpa);
    }

    /// Every shader.pass node this lens spliced, in the graph's real
    /// execution order - the order a chain of passes must draw in so
    /// each one sees the previous stage's output, not just the order
    /// they happened to be declared in the manifest. g must be the same
    /// graph this lens was activated into.
    pub fn shaderPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]ShaderPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(ShaderPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .shader_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .shader_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every lut.pass node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes exactly, one node type
    /// over.
    pub fn lutPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]LutPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(LutPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .lut_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .lut_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every shader.pass and lut.pass node this lens spliced, in one
    /// real execution-order sequence - the actual draw order for a
    /// chain that mixes both kinds, which shaderPassNodes/lutPassNodes
    /// alone cannot express since each only ever sees its own kind.
    pub fn compositePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]CompositePass {
        const order = try g.executionOrder();
        var out: std.ArrayList(CompositePass) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            const kind: PassKind = switch (node.node_type) {
                .shader_pass => .shader,
                .lut_pass => .lut,
                else => continue,
            };
            try out.append(gpa, .{ .graph_index = node.graph_index, .kind = kind });
        }
        return out.toOwnedSlice(gpa);
    }

    fn findNode(self: *const Lens, graph_index: graph.NodeIndex) ?LensNode {
        for (self.nodes) |node| {
            if (node.graph_index == graph_index) return node;
        }
        return null;
    }

    fn collectNodeEffects(self: *const Lens, gpa: std.mem.Allocator, out: *std.ArrayList(AppliedEffect), node: LensNode) !void {
        for (node.bindings, 0..) |binding, i| {
            const source = binding orelse continue;
            const value = switch (source) {
                .literal => |v| v,
                .parameter => |idx| self.param_values[idx],
            };
            try out.append(gpa, .{ .effect = @enumFromInt(i), .value = value });
        }
    }
};

/// Splices lens_manifest's node subgraph into g, wired to camera_node
/// wherever a node's input names the implicit "camera" source. Every
/// trigger's `when` source compiles here too - the validator
/// already proved a shipped bundle's triggers compile clean, so a
/// compile failure at activation is a caller bug (a hand-built manifest
/// that skipped validation), not a normal-operation error path.
pub fn activate(gpa: std.mem.Allocator, g: *graph.Graph, camera_node: graph.NodeIndex, lens_manifest: manifest.Manifest) ActivateError!Lens {
    const param_values = try gpa.alloc(f32, lens_manifest.parameters.len);
    errdefer gpa.free(param_values);
    for (lens_manifest.parameters, 0..) |p, i| param_values[i] = switch (p.default) {
        .float => |v| v,
        .bool => |v| if (v) 1 else 0,
        .int => |v| @floatFromInt(v),
        .color => 0,
    };

    const ramps = try gpa.alloc(?animation.Ramp, lens_manifest.parameters.len);
    errdefer gpa.free(ramps);
    @memset(ramps, null);

    const param_names = try gpa.alloc([]const u8, lens_manifest.parameters.len);
    defer gpa.free(param_names);
    for (lens_manifest.parameters, 0..) |p, i| param_names[i] = p.name;

    const compiled_triggers = try gpa.alloc(trigger.Expression, lens_manifest.triggers.len);
    errdefer gpa.free(compiled_triggers);
    var compiled_count: usize = 0;
    errdefer for (compiled_triggers[0..compiled_count]) |*expr| expr.deinit();

    for (lens_manifest.triggers) |lens_trigger| {
        var diag_arena = std.heap.ArenaAllocator.init(gpa);
        defer diag_arena.deinit();
        var compile_err: ?trigger.CompileError = null;
        const expr = trigger.compile(gpa, diag_arena.allocator(), lens_trigger.when_source, param_names, &compile_err) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
        };
        compiled_triggers[compiled_count] = expr orelse return error.UnknownParameter;
        compiled_count += 1;
    }

    const trigger_was_true = try gpa.alloc(bool, lens_manifest.triggers.len);
    errdefer gpa.free(trigger_was_true);
    @memset(trigger_was_true, false);

    const nodes = try gpa.alloc(LensNode, lens_manifest.nodes.len);
    errdefer gpa.free(nodes);
    var spliced_count: usize = 0;
    errdefer for (nodes[0..spliced_count]) |n| g.removeNode(n.graph_index);

    var id_to_index = std.StringHashMap(graph.NodeIndex).init(gpa);
    defer id_to_index.deinit();

    for (lens_manifest.nodes) |node| {
        const node_type = parseNodeType(node.type) orelse return error.UnsupportedNodeType;
        const graph_index = try g.addNode(.{
            .role = .transform,
            .inputs = &.{.{ .kind = .texture }},
            .outputs = &.{.{ .kind = .texture }},
        });
        nodes[spliced_count] = .{
            .graph_index = graph_index,
            .node_type = node_type,
            .asset_stem = if (node_type == .shader_pass or node_type == .lut_pass) node.id else null,
        };

        for (node.inputs) |input| {
            const source_index = if (std.mem.eql(u8, input.source, "camera"))
                camera_node
            else
                id_to_index.get(input.source) orelse return error.UnknownNodeId;
            try g.connect(source_index, 0, graph_index, 0);
        }

        const slots = paramSlotsFor(node_type);
        for (node.params) |p| {
            for (slots) |slot| {
                if (!std.mem.eql(u8, p.name, slot.name)) continue;
                nodes[spliced_count].bindings[@intFromEnum(slot.effect)] = switch (p.binding) {
                    .literal_float => |v| .{ .literal = v },
                    .literal_bool => |v| .{ .literal = if (v) 1 else 0 },
                    .literal_int => |v| .{ .literal = @floatFromInt(v) },
                    .param_ref => |name| blk: {
                        for (lens_manifest.parameters, 0..) |param, i| {
                            if (std.mem.eql(u8, param.name, name)) break :blk .{ .parameter = @intCast(i) };
                        }
                        return error.UnknownParameter;
                    },
                };
            }
        }

        try id_to_index.put(node.id, graph_index);
        spliced_count += 1;
    }

    return .{
        .gpa = gpa,
        .manifest = lens_manifest,
        .compiled_triggers = compiled_triggers,
        .trigger_was_true = trigger_was_true,
        .param_values = param_values,
        .ramps = ramps,
        .nodes = nodes,
    };
}

fn paramIndex(lens: *const Lens, name: []const u8) ?u16 {
    for (lens.manifest.parameters, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return @intCast(i);
    }
    return null;
}

fn clampToParam(p: manifest.Parameter, value: f32) f32 {
    return switch (p.type) {
        .float, .int => std.math.clamp(value, p.min, p.max),
        .bool, .color => value,
    };
}

/// Advances every in-flight ramp by real_dt_us, fires every trigger that
/// just transitioned false-to-true, and returns the effect
/// values that changed as a result - only param_set/param_ramp are
/// handled here; show/hide/play_animation/swap_subgraph/reset_timer are
/// not yet wired to anything (deliberately, see the module doc).
pub fn tick(lens: *Lens, gpa: std.mem.Allocator, real_dt_us: u32, signals: trigger.Signals) std.mem.Allocator.Error![]AppliedEffect {
    var touched_params = try gpa.alloc(bool, lens.param_values.len);
    defer gpa.free(touched_params);
    @memset(touched_params, false);

    // Triggers first, so a ramp an action starts this frame gets its
    // first real advance below in the same tick rather than sitting at
    // its starting value until the next one.
    for (lens.compiled_triggers, 0..) |*expr, i| {
        const is_true = trigger.evaluate(expr.root, signals);
        defer lens.trigger_was_true[i] = is_true;
        if (is_true and !lens.trigger_was_true[i]) {
            applyAction(lens, lens.manifest.triggers[i].action, touched_params);
        }
    }

    for (lens.ramps, 0..) |*ramp, i| {
        if (ramp.*) |*r| {
            const value = r.advance(real_dt_us);
            lens.param_values[i] = value;
            touched_params[i] = true;
            if (r.done) ramp.* = null;
        }
    }

    var out: std.ArrayList(AppliedEffect) = .empty;
    errdefer out.deinit(gpa);
    for (lens.nodes) |node| {
        for (node.bindings, 0..) |binding, slot| {
            const source = binding orelse continue;
            if (source != .parameter or !touched_params[source.parameter]) continue;
            try out.append(gpa, .{ .effect = @enumFromInt(slot), .value = lens.param_values[source.parameter] });
        }
    }
    return out.toOwnedSlice(gpa);
}

fn applyAction(lens: *Lens, action: manifest.Action, touched_params: []bool) void {
    switch (action.kind) {
        .param_set => {
            const idx = paramIndex(lens, action.target) orelse return;
            lens.param_values[idx] = clampToParam(lens.manifest.parameters[idx], action.to);
            lens.ramps[idx] = null;
            touched_params[idx] = true;
        },
        .param_ramp => {
            const idx = paramIndex(lens, action.target) orelse return;
            const target = clampToParam(lens.manifest.parameters[idx], action.to);
            lens.ramps[idx] = switch (action.curve) {
                .linear => animation.Ramp.startLinear(lens.param_values[idx], target, action.duration_ms),
                .spring => animation.Ramp.startSpring(lens.param_values[idx], target, action.stiffness, action.damping),
            };
        },
        .show, .hide, .play_animation, .swap_subgraph, .reset_timer => {},
    }
}

const t = std.testing;

const minimal_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.tick", "version": "1.0.0", "display_name": "Tick",
    \\  "engine_compat": ">=0.5", "capabilities": ["face"],
    \\  "parameters": [
    \\    {"name": "smooth_amount", "type": "float", "default": 0.0, "min": 0.0, "max": 1.0}
    \\  ],
    \\  "nodes": [
    \\    {"id": "reshape", "type": "beauty.reshape", "inputs": {"frame": "camera"}, "params": {"thin_face": "$smooth_amount"}}
    \\  ],
    \\  "triggers": [
    \\    {"when": "face.blendshape('jawOpen') > 0.6", "action": {"kind": "param_ramp", "target": "smooth_amount", "to": 1.0, "duration_ms": 200}}
    \\  ]
    \\}
;

fn parseTestManifest(gpa: std.mem.Allocator, source: []const u8) !manifest.Manifest {
    var arena = std.heap.ArenaAllocator.init(gpa);
    defer arena.deinit();
    var diags = manifest.Diagnostics{ .arena = arena.allocator() };
    return try manifest.parse(gpa, &diags, source) orelse error.TestUnexpectedResult;
}

test "activate splices one node into the graph, wired to the camera source" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.beauty_reshape, lens.nodes[0].node_type);
    try t.expectEqual(@as(usize, 2), g.nodeCount());
    _ = try g.executionOrder();
}

test "a param bound to a node reports its default as the initial effect value" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 1), effects.len);
    try t.expectEqual(EffectSlot.thin_face, effects[0].effect);
    try t.expectEqual(@as(f32, 0.0), effects[0].value);
}

const shader_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.shaderpass", "version": "1.0.0", "display_name": "Shader Pass",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a shader.pass node splices with no effect bindings and resolves its shader by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, shader_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.shader_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 1), passes.len);
    try t.expectEqualStrings("tint", passes[0].shader_stem);
    try t.expectEqual(lens.nodes[0].graph_index, passes[0].graph_index);
}

const shader_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.shaderchain", "version": "1.0.0", "display_name": "Shader Chain",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "warm", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "vignette", "type": "shader.pass", "inputs": {"frame": "warm"}, "params": {}},
    \\    {"id": "grain", "type": "shader.pass", "inputs": {"frame": "vignette"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "shaderPassNodes orders a multi-pass chain by real graph dependency, not declaration position" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, shader_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 3), passes.len);
    try t.expectEqualStrings("warm", passes[0].shader_stem);
    try t.expectEqualStrings("vignette", passes[1].shader_stem);
    try t.expectEqualStrings("grain", passes[2].shader_stem);
}

const lut_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.lutpass", "version": "1.0.0", "display_name": "LUT Pass",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a lut.pass node splices with no effect bindings and resolves its LUT by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, lut_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.lut_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 1), luts.len);
    try t.expectEqualStrings("warm-lut", luts[0].lut_stem);
    try t.expectEqual(lens.nodes[0].graph_index, luts[0].graph_index);

    // Neither accessor picks up the other node type's node.
    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 0), passes.len);
}

const mixed_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.mixedchain", "version": "1.0.0", "display_name": "Mixed Chain",
    \\  "engine_compat": ">=0.5", "capabilities": [],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "tint"}, "params": {}},
    \\    {"id": "vignette", "type": "shader.pass", "inputs": {"frame": "warm-lut"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "shader.pass and lut.pass nodes interleave in one chain, each accessor seeing only its own kind in order" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, mixed_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 2), passes.len);
    try t.expectEqualStrings("tint", passes[0].shader_stem);
    try t.expectEqualStrings("vignette", passes[1].shader_stem);

    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 1), luts.len);
    try t.expectEqualStrings("warm-lut", luts[0].lut_stem);
}

test "compositePassNodes interleaves both kinds in one real draw-order sequence" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, mixed_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 3), chain.len);
    try t.expectEqual(NodeType.shader_pass, lens.nodes[0].node_type);
    try t.expectEqual(PassKind.shader, chain[0].kind);
    try t.expectEqual(PassKind.lut, chain[1].kind);
    try t.expectEqual(PassKind.shader, chain[2].kind);
    try t.expectEqual(lens.nodes[0].graph_index, chain[0].graph_index);
    try t.expectEqual(lens.nodes[1].graph_index, chain[1].graph_index);
    try t.expectEqual(lens.nodes[2].graph_index, chain[2].graph_index);
}

test "a trigger firing on the rising edge starts a ramp that settles, does not refire while held, and rearms on the falling edge" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, minimal_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const face_mod = @import("face");
    var open_shapes: [face_mod.blendshape_count]f32 = @splat(0);
    open_shapes[face_mod.blendshapeIndex("jawOpen").?] = 0.9;
    const closed_shapes: [face_mod.blendshape_count]f32 = @splat(0);
    const signals_open = trigger.Signals{ .face_present = true, .blendshapes = &open_shapes };
    const signals_closed = trigger.Signals{ .face_present = true, .blendshapes = &closed_shapes };

    // Rising edge: the ramp starts and gets its first real advance
    // within this same tick, landing strictly between start and target.
    const first = try tick(&lens, t.allocator, animation.fixed_step_us, signals_open);
    defer t.allocator.free(first);
    try t.expectEqual(@as(usize, 1), first.len);
    try t.expect(first[0].value > 0.0 and first[0].value < 1.0);
    try t.expect(lens.trigger_was_true[0]);

    // Still true: does not refire - a level-triggered restart would
    // reset the ramp's progress back toward the start every frame.
    const second = try tick(&lens, t.allocator, animation.fixed_step_us, signals_open);
    defer t.allocator.free(second);
    try t.expect(second[0].value > first[0].value);

    // Enough further ticks for the 200ms linear ramp to fully settle.
    var settle: usize = 0;
    while (settle < 40) : (settle += 1) {
        const drained = try tick(&lens, t.allocator, animation.fixed_step_us, signals_open);
        t.allocator.free(drained);
    }
    try t.expectEqual(@as(f32, 1.0), lens.param_values[0]);
    try t.expect(lens.ramps[0] == null);

    // Falling edge resets the trigger's own state, ready to fire again.
    _ = try tick(&lens, t.allocator, animation.fixed_step_us, signals_closed);
    try t.expect(!lens.trigger_was_true[0]);
}
