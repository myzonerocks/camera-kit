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
//! can name: the beauty family, shader passes, LUT passes, mask-driven
//! blend passes, and model.gltf are all wired here. This module has no
//! knowledge of a glTF asset's actual bytes - loading a .glb and
//! sampling its animation at a given elapsed time are the caller's job
//! (core/abi and the renderer); what this module owns is only whether
//! a model node is playing and for how long.

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

pub const NodeType = enum { beauty_face, beauty_reshape, beauty_lipstick, beauty_blusher, shader_pass, lut_pass, blend_pass, blur_pass, grade_pass, bloom_pass, model_gltf, mesh_face };

fn parseNodeType(type_str: []const u8) ?NodeType {
    if (std.mem.eql(u8, type_str, "beauty.face")) return .beauty_face;
    if (std.mem.eql(u8, type_str, "beauty.reshape")) return .beauty_reshape;
    if (std.mem.eql(u8, type_str, "beauty.lipstick")) return .beauty_lipstick;
    if (std.mem.eql(u8, type_str, "beauty.blusher")) return .beauty_blusher;
    if (std.mem.eql(u8, type_str, "shader.pass")) return .shader_pass;
    if (std.mem.eql(u8, type_str, "mesh.face")) return .mesh_face;
    if (std.mem.eql(u8, type_str, "lut.pass")) return .lut_pass;
    if (std.mem.eql(u8, type_str, "blend.pass")) return .blend_pass;
    if (std.mem.eql(u8, type_str, "blur.pass")) return .blur_pass;
    if (std.mem.eql(u8, type_str, "grade.pass")) return .grade_pass;
    if (std.mem.eql(u8, type_str, "bloom.pass")) return .bloom_pass;
    if (std.mem.eql(u8, type_str, "model.gltf")) return .model_gltf;
    return null;
}

const ParamSlot = struct { name: []const u8, effect: EffectSlot };

/// The param names each node type accepts and which effect slot each one
/// drives - the only place that mapping is declared. shader.pass,
/// lut.pass, blend.pass, and model.gltf have no effect-slot params of
/// their own: each one's id names the asset it runs (a shader source
/// file, a LUT image, a background image, or a .glb model), the same
/// way a node's id already resolves against other nodes for wiring.
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
        .shader_pass, .lut_pass, .blend_pass, .blur_pass, .grade_pass, .bloom_pass, .model_gltf, .mesh_face => &.{},
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
    /// Set only for .shader_pass, .lut_pass, .blend_pass, and
    /// .model_gltf nodes: the node's own id, which also names the asset
    /// it runs (shaders/<id>.glsl for shader.pass, assets/<id>.png for
    /// lut.pass and for blend.pass's background image, assets/<id>.glb
    /// for model.gltf) - a slice into the Lens's own retained manifest
    /// arena, not separately owned.
    asset_stem: ?[]const u8 = null,
    /// .shader_pass only: the named mask channel's index into
    /// manifest.mask_channels, when the manifest names one.
    mask_channel: ?u8 = null,
    /// .model_gltf only: the node anchors to the tracked face.
    face_anchor: bool = false,
    world_anchor: bool = false,
    physics: ?manifest.PhysicsBody = null,
    cloth: ?manifest.ClothField = null,
    hair: ?manifest.HairField = null,
    particles: ?manifest.ParticleField = null,
    /// .grade_pass only: the node's parametric color grade.
    grade: ?manifest.GradeField = null,
    /// .bloom_pass only: the node's glow threshold and intensity.
    bloom: ?manifest.BloomField = null,
    /// .model_gltf only: microseconds since play_animation last fired
    /// for this node, null if it never has. Advances every tick() the
    /// same way a ramp does - once a trigger starts it, not before.
    model_elapsed_us: ?u64 = null,
};

/// One shader.pass node ready for the caller to load and draw - which
/// graph node it is, and the shader (shaders/<stem>.glsl, plus its
/// packaged shaders/<stem>.<profile>.bin variants) it names. This
/// module has no bgfx dependency of its own; the caller resolves the
/// stem into actual bytes and does the real rendering work.
pub const ShaderPassNode = struct {
    graph_index: graph.NodeIndex,
    shader_stem: []const u8,
    /// Index into manifest.mask_channels when the node names one.
    mask_channel: ?u8 = null,
};

/// One lut.pass node ready for the caller to load and draw - which
/// graph node it is, and the LUT image (assets/<stem>.png) it names.
pub const LutPassNode = struct {
    graph_index: graph.NodeIndex,
    lut_stem: []const u8,
};

/// One blend.pass node ready for the caller to load and draw - which
/// graph node it is, and the background image (assets/<stem>.png) it
/// swaps in behind the segmentation mask.
pub const BlendPassNode = struct {
    graph_index: graph.NodeIndex,
    background_stem: []const u8,
};

/// One model.gltf node ready for the caller to load and draw - which
/// graph node it is, and the .glb (assets/<stem>.glb) it names.
pub const ModelNode = struct {
    graph_index: graph.NodeIndex,
    model_stem: []const u8,
    /// The lens-format node id, so cross-node references (a physics
    /// chain naming its anchor) resolve at draw setup.
    node_id: []const u8,
    face_anchor: bool = false,
    world_anchor: bool = false,
    physics: ?manifest.PhysicsBody = null,
    cloth: ?manifest.ClothField = null,
    hair: ?manifest.HairField = null,
    particles: ?manifest.ParticleField = null,
};

/// One mesh.face node ready for the caller to load and draw - which
/// graph node it is, and the texture (assets/<stem>.png) it warps over
/// the tracked face.
pub const MeshFaceNode = struct {
    graph_index: graph.NodeIndex,
    texture_stem: []const u8,
};

/// One grade.pass node ready for the caller to draw - which graph node
/// it is, and its parametric color grade packed as (exposure, contrast,
/// saturation, temperature) for the renderer's u_grade uniform.
pub const GradePassNode = struct {
    graph_index: graph.NodeIndex,
    grade: [4]f32,
};

/// One bloom.pass node ready for the caller to draw - which graph node it
/// is, and its glow packed as (threshold, intensity, 0, 0) for u_bloom.
pub const BloomPassNode = struct {
    graph_index: graph.NodeIndex,
    bloom: [4]f32,
};

pub const PassKind = enum { shader, lut, blend, blur, grade, bloom, model, mesh };

/// One shader.pass, lut.pass, blend.pass, or model.gltf node, tagged
/// with which - the caller's real draw order for a chain that may mix
/// any of the four, since the graph itself makes no distinction
/// between them beyond node_type.
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
    /// Every distinct timer('name') this lens's triggers reference,
    /// each name individually owned (not a slice into a compiled
    /// trigger's own arena, so freeing timer_names never depends on
    /// compiled_triggers' own deinit order). timer_elapsed_us is a
    /// parallel array: microseconds since lens activation, running
    /// continuously (not trigger-gated - a timer is a clock a trigger
    /// reads, not a value a trigger's action starts).
    timer_names: [][]u8,
    timer_elapsed_us: []u64,
    /// tick()'s working and output storage, sized once at activation so
    /// the per-frame path allocates nothing: timer snapshot, per-param
    /// touch flags, and room for every parameter-bound effect at once.
    tick_timer_values: []trigger.TimerValue,
    tick_touched: []bool,
    tick_applied: []AppliedEffect,
    /// Bundle-relative paths of sounds a play_sound trigger fired this tick;
    /// the host drains them each frame. Sized to the trigger count, so the
    /// frame path never allocates.
    tick_sounds: [][]const u8,
    tick_sound_count: usize = 0,

    pub fn deinit(self: *Lens, g: *graph.Graph) void {
        for (self.nodes) |n| g.removeNode(n.graph_index);
        for (self.compiled_triggers) |*expr| expr.deinit();
        self.gpa.free(self.compiled_triggers);
        self.gpa.free(self.trigger_was_true);
        self.gpa.free(self.param_values);
        self.gpa.free(self.ramps);
        self.gpa.free(self.nodes);
        for (self.timer_names) |name| self.gpa.free(name);
        self.gpa.free(self.timer_names);
        self.gpa.free(self.timer_elapsed_us);
        self.gpa.free(self.tick_timer_values);
        self.gpa.free(self.tick_touched);
        self.gpa.free(self.tick_applied);
        self.gpa.free(self.tick_sounds);
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
            try out.append(gpa, .{ .graph_index = node.graph_index, .shader_stem = node.asset_stem.?, .mask_channel = node.mask_channel });
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

    /// Every blend.pass node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes/lutPassNodes exactly,
    /// one more node type over.
    pub fn blendPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]BlendPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(BlendPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .blend_pass) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .background_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every grade.pass node this lens spliced, in execution order, each
    /// carrying its parametric grade - mirrors the other per-kind accessors.
    pub fn gradePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]GradePassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(GradePassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .grade_pass) continue;
            const gr = node.grade orelse manifest.GradeField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .grade = .{ gr.exposure, gr.contrast, gr.saturation, gr.temperature } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every bloom.pass node this lens spliced, in execution order, each
    /// carrying its glow params - mirrors gradePassNodes.
    pub fn bloomPassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]BloomPassNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(BloomPassNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .bloom_pass) continue;
            const bl = node.bloom orelse manifest.BloomField{};
            try out.append(gpa, .{ .graph_index = node.graph_index, .bloom = .{ bl.threshold, bl.intensity, 0, 0 } });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every model.gltf node this lens spliced, in the graph's real
    /// execution order - mirrors shaderPassNodes/lutPassNodes/
    /// blendPassNodes exactly, one more node type over.
    pub fn modelNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]ModelNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(ModelNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .model_gltf) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .model_stem = node.asset_stem.?, .node_id = node.asset_stem.?, .face_anchor = node.face_anchor, .world_anchor = node.world_anchor, .physics = node.physics, .cloth = node.cloth, .hair = node.hair, .particles = node.particles });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every mesh.face node this lens spliced, in execution order -
    /// mirrors the other per-kind accessors exactly.
    pub fn meshFaceNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]MeshFaceNode {
        const order = try g.executionOrder();
        var out: std.ArrayList(MeshFaceNode) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            if (node.node_type != .mesh_face) continue;
            try out.append(gpa, .{ .graph_index = node.graph_index, .texture_stem = node.asset_stem.? });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Every shader.pass, lut.pass, blend.pass, and model.gltf node
    /// this lens spliced, in one real execution-order sequence - the
    /// actual draw order for a chain that mixes any of the four kinds,
    /// which the per-kind accessors alone cannot express since each
    /// only ever sees its own kind.
    pub fn compositePassNodes(self: *const Lens, gpa: std.mem.Allocator, g: *graph.Graph) ![]CompositePass {
        const order = try g.executionOrder();
        var out: std.ArrayList(CompositePass) = .empty;
        errdefer out.deinit(gpa);
        for (order) |graph_index| {
            const node = self.findNode(graph_index) orelse continue;
            const kind: PassKind = switch (node.node_type) {
                .shader_pass => .shader,
                .lut_pass => .lut,
                .blend_pass => .blend,
                .blur_pass => .blur,
                .grade_pass => .grade,
                .bloom_pass => .bloom,
                .model_gltf => .model,
                .mesh_face => .mesh,
                else => continue,
            };
            try out.append(gpa, .{ .graph_index = node.graph_index, .kind = kind });
        }
        return out.toOwnedSlice(gpa);
    }

    /// Current playback position for a model.gltf node, microseconds
    /// since its play_animation trigger last fired - null if it never
    /// has. The caller samples the loaded animation clip at this time;
    /// this module holds no clip data of its own.
    pub fn modelElapsedUs(self: *const Lens, graph_index: graph.NodeIndex) ?u64 {
        const node = self.findNode(graph_index) orelse return null;
        return node.model_elapsed_us;
    }

    /// The inline source of this lens's script node, or null if it has none.
    /// The host runs it each tick to drive parameters.
    pub fn scriptSource(self: *const Lens) ?[]const u8 {
        for (self.manifest.nodes) |node| {
            if (node.script) |src| return src;
        }
        return null;
    }

    /// Sets a live parameter by name, clamped to its declared range. Silent
    /// no-op for an unknown name, the same tolerance a trigger action takes.
    pub fn setParam(self: *Lens, name: []const u8, value: f32) void {
        const i = paramIndex(self, name) orelse return;
        self.param_values[i] = clampToParam(self.manifest.parameters[i], value);
    }

    /// Reads a live parameter by name, or null if there is no such name.
    pub fn paramValue(self: *const Lens, name: []const u8) ?f32 {
        const i = paramIndex(self, name) orelse return null;
        return self.param_values[i];
    }

    /// The bundle-relative sound paths a play_sound trigger fired on the last
    /// tick, for the host to start on its mixer.
    pub fn firedSounds(self: *const Lens) []const []const u8 {
        return self.tick_sounds[0..self.tick_sound_count];
    }

    /// Whether this lens spliced any beauty.* node - what gates whether
    /// the live preview needs the GPU beauty compositing bridge running
    /// at all. A lens with no beauty node still lets a session enable
    /// beauty (currentEffects then applies nothing, all identity values),
    /// but compositing every frame through gpupixel for a chain that can
    /// never produce a visible difference would be pure waste.
    pub fn hasBeautyNodes(self: *const Lens) bool {
        for (self.nodes) |node| {
            switch (node.node_type) {
                .beauty_face, .beauty_reshape, .beauty_lipstick, .beauty_blusher => return true,
                else => {},
            }
        }
        return false;
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

    // Script nodes are skipped below (they drive parameters, they do not
    // splice), so size the node array to the composite nodes only.
    var composite_count: usize = 0;
    for (lens_manifest.nodes) |node| {
        if (!std.mem.eql(u8, node.type, "script")) composite_count += 1;
    }
    const nodes = try gpa.alloc(LensNode, composite_count);
    errdefer gpa.free(nodes);
    var spliced_count: usize = 0;
    errdefer for (nodes[0..spliced_count]) |n| g.removeNode(n.graph_index);

    var id_to_index = std.StringHashMap(graph.NodeIndex).init(gpa);
    defer id_to_index.deinit();

    for (lens_manifest.nodes) |node| {
        // A script node drives parameters each tick; it is not a composite
        // pass, so it never enters the graph. Its source is read separately.
        if (std.mem.eql(u8, node.type, "script")) continue;
        const node_type = parseNodeType(node.type) orelse return error.UnsupportedNodeType;
        const graph_index = try g.addNode(.{
            .role = .transform,
            .inputs = &.{.{ .kind = .texture }},
            .outputs = &.{.{ .kind = .texture }},
        });
        nodes[spliced_count] = .{
            .graph_index = graph_index,
            .node_type = node_type,
            .asset_stem = switch (node_type) {
                .shader_pass, .lut_pass, .blend_pass, .model_gltf, .mesh_face => node.id,
                else => null,
            },
            .mask_channel = if (node_type == .shader_pass) node.mask_channel else null,
            .face_anchor = node_type == .model_gltf and node.face_anchor,
            .world_anchor = node_type == .model_gltf and node.world_anchor,
            .physics = if (node_type == .model_gltf) node.physics else null,
            .cloth = if (node_type == .model_gltf) node.cloth else null,
            .hair = if (node_type == .model_gltf) node.hair else null,
            .particles = if (node_type == .model_gltf) node.particles else null,
            .grade = if (node_type == .grade_pass) node.grade else null,
            .bloom = if (node_type == .bloom_pass) node.bloom else null,
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

    var timer_names: std.ArrayList([]u8) = .empty;
    errdefer {
        for (timer_names.items) |name| gpa.free(name);
        timer_names.deinit(gpa);
    }
    for (compiled_triggers) |*expr| try collectTimerNames(gpa, expr.root, &timer_names);
    const timer_elapsed_us = try gpa.alloc(u64, timer_names.items.len);
    errdefer gpa.free(timer_elapsed_us);
    @memset(timer_elapsed_us, 0);

    const tick_timer_values = try gpa.alloc(trigger.TimerValue, timer_names.items.len);
    errdefer gpa.free(tick_timer_values);
    const tick_touched = try gpa.alloc(bool, param_values.len);
    errdefer gpa.free(tick_touched);
    var bound_count: usize = 0;
    for (nodes) |node| {
        for (node.bindings) |binding| {
            const source = binding orelse continue;
            if (source == .parameter) bound_count += 1;
        }
    }
    const tick_applied = try gpa.alloc(AppliedEffect, bound_count);
    errdefer gpa.free(tick_applied);
    const tick_sounds = try gpa.alloc([]const u8, lens_manifest.triggers.len);
    errdefer gpa.free(tick_sounds);

    return .{
        .gpa = gpa,
        .manifest = lens_manifest,
        .compiled_triggers = compiled_triggers,
        .trigger_was_true = trigger_was_true,
        .param_values = param_values,
        .ramps = ramps,
        .nodes = nodes,
        .timer_names = try timer_names.toOwnedSlice(gpa),
        .timer_elapsed_us = timer_elapsed_us,
        .tick_timer_values = tick_timer_values,
        .tick_touched = tick_touched,
        .tick_applied = tick_applied,
        .tick_sounds = tick_sounds,
    };
}

/// Collects every distinct timer('name') a compiled trigger tree
/// references, deduped, each name individually owned by the caller -
/// see Lens.timer_names for why these are duped rather than borrowed
/// from the trigger's own compile-time arena.
fn collectTimerNames(gpa: std.mem.Allocator, node: *const trigger.Node, names: *std.ArrayList([]u8)) std.mem.Allocator.Error!void {
    switch (node.*) {
        .signal_bool => {},
        .compare => |c| {
            if (c.signal.kind != .timer) return;
            for (names.items) |existing| {
                if (std.mem.eql(u8, existing, c.signal.timer_name)) return;
            }
            try names.append(gpa, try gpa.dupe(u8, c.signal.timer_name));
        },
        .not => |inner| try collectTimerNames(gpa, inner, names),
        .and_, .or_ => |combine| {
            try collectTimerNames(gpa, combine.lhs, names);
            try collectTimerNames(gpa, combine.rhs, names);
        },
    }
}

fn paramIndex(lens: *const Lens, name: []const u8) ?u16 {
    for (lens.manifest.parameters, 0..) |p, i| {
        if (std.mem.eql(u8, p.name, name)) return @intCast(i);
    }
    return null;
}

fn timerIndex(lens: *const Lens, name: []const u8) ?usize {
    for (lens.timer_names, 0..) |existing, i| {
        if (std.mem.eql(u8, existing, name)) return i;
    }
    return null;
}

fn clampToParam(p: manifest.Parameter, value: f32) f32 {
    return switch (p.type) {
        .float, .int => std.math.clamp(value, p.min, p.max),
        .bool, .color => value,
    };
}

/// Advances every named timer and in-flight ramp, fires every trigger
/// that just transitioned false-to-true, and returns the effect values
/// that changed as a result. Timers advance before triggers evaluate
/// (a timer is a continuously-running clock a trigger reads, so this
/// frame's trigger pass needs this frame's own elapsed time); ramps and
/// model playback advance after, so an action that starts one this
/// frame gets its first real advance now rather than sitting at its
/// starting value until the next tick. show/hide/swap_subgraph are
/// still not wired to anything (real remaining work, tracked
/// separately from this lens's own scope).
pub fn tick(lens: *Lens, real_dt_us: u32, signals: trigger.Signals) []const AppliedEffect {
    for (lens.timer_elapsed_us) |*elapsed| elapsed.* += real_dt_us;
    for (lens.timer_names, lens.timer_elapsed_us, 0..) |name, elapsed_us, i| {
        lens.tick_timer_values[i] = .{ .name = name, .seconds = @as(f32, @floatFromInt(elapsed_us)) / 1_000_000.0 };
    }
    var live_signals = signals;
    live_signals.timers = lens.tick_timer_values;

    const touched_params = lens.tick_touched;
    @memset(touched_params, false);
    lens.tick_sound_count = 0;

    for (lens.compiled_triggers, 0..) |*expr, i| {
        const is_true = trigger.evaluate(expr.root, live_signals);
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

    for (lens.nodes) |*node| {
        if (node.model_elapsed_us) |*elapsed| elapsed.* += real_dt_us;
    }

    // Borrowed from the lens's own activation-sized storage, valid until
    // the next tick - the frame path allocates nothing.
    var count: usize = 0;
    for (lens.nodes) |node| {
        for (node.bindings, 0..) |binding, slot| {
            const source = binding orelse continue;
            if (source != .parameter or !touched_params[source.parameter]) continue;
            lens.tick_applied[count] = .{ .effect = @enumFromInt(slot), .value = lens.param_values[source.parameter] };
            count += 1;
        }
    }
    return lens.tick_applied[0..count];
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
        .play_animation => {
            for (lens.nodes) |*node| {
                if (node.node_type != .model_gltf) continue;
                const stem = node.asset_stem orelse continue;
                if (!std.mem.eql(u8, stem, action.target)) continue;
                node.model_elapsed_us = 0;
            }
        },
        .reset_timer => {
            const idx = timerIndex(lens, action.target) orelse return;
            lens.timer_elapsed_us[idx] = 0;
        },
        .play_sound => {
            if (lens.tick_sound_count < lens.tick_sounds.len) {
                lens.tick_sounds[lens.tick_sound_count] = action.target;
                lens.tick_sound_count += 1;
            }
        },
        .show, .hide, .swap_subgraph => {},
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

const blend_pass_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.blendpass", "version": "1.0.0", "display_name": "Blend Pass",
    \\  "engine_compat": ">=0.5", "capabilities": ["segmentation"],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "beach", "type": "blend.pass", "inputs": {"frame": "camera"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "a blend.pass node splices with no effect bindings and resolves its background by id" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, blend_pass_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    try t.expectEqual(@as(usize, 1), lens.nodes.len);
    try t.expectEqual(NodeType.blend_pass, lens.nodes[0].node_type);

    const effects = try lens.currentEffects(t.allocator);
    defer t.allocator.free(effects);
    try t.expectEqual(@as(usize, 0), effects.len);

    const blends = try lens.blendPassNodes(t.allocator, &g);
    defer t.allocator.free(blends);
    try t.expectEqual(@as(usize, 1), blends.len);
    try t.expectEqualStrings("beach", blends[0].background_stem);
    try t.expectEqual(lens.nodes[0].graph_index, blends[0].graph_index);

    // Neither of the other two accessors picks up this node type's node.
    const passes = try lens.shaderPassNodes(t.allocator, &g);
    defer t.allocator.free(passes);
    try t.expectEqual(@as(usize, 0), passes.len);
    const luts = try lens.lutPassNodes(t.allocator, &g);
    defer t.allocator.free(luts);
    try t.expectEqual(@as(usize, 0), luts.len);
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

const three_way_chain_manifest =
    \\{
    \\  "glf": "1.0", "id": "com.example.threewaychain", "version": "1.0.0", "display_name": "Three Way Chain",
    \\  "engine_compat": ">=0.5", "capabilities": ["segmentation"],
    \\  "parameters": [],
    \\  "nodes": [
    \\    {"id": "tint", "type": "shader.pass", "inputs": {"frame": "camera"}, "params": {}},
    \\    {"id": "warm-lut", "type": "lut.pass", "inputs": {"frame": "tint"}, "params": {}},
    \\    {"id": "beach", "type": "blend.pass", "inputs": {"frame": "warm-lut"}, "params": {}}
    \\  ],
    \\  "triggers": []
    \\}
;

test "compositePassNodes interleaves all three kinds in one real draw-order sequence" {
    var g = graph.Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(.{ .role = .source, .outputs = &.{.{ .kind = .texture }} });

    const lens_manifest = try parseTestManifest(t.allocator, three_way_chain_manifest);
    var lens = try activate(t.allocator, &g, camera, lens_manifest);
    defer lens.deinit(&g);

    const chain = try lens.compositePassNodes(t.allocator, &g);
    defer t.allocator.free(chain);
    try t.expectEqual(@as(usize, 3), chain.len);
    try t.expectEqual(PassKind.shader, chain[0].kind);
    try t.expectEqual(PassKind.lut, chain[1].kind);
    try t.expectEqual(PassKind.blend, chain[2].kind);

    const blends = try lens.blendPassNodes(t.allocator, &g);
    defer t.allocator.free(blends);
    try t.expectEqual(@as(usize, 1), blends.len);
    try t.expectEqualStrings("beach", blends[0].background_stem);
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
    // Copy values out before the next tick - the returned slice borrows
    // the lens's own storage and the next call overwrites it.
    const first = tick(&lens, animation.fixed_step_us, signals_open);
    try t.expectEqual(@as(usize, 1), first.len);
    const first_value = first[0].value;
    try t.expect(first_value > 0.0 and first_value < 1.0);
    try t.expect(lens.trigger_was_true[0]);

    // Still true: does not refire - a level-triggered restart would
    // reset the ramp's progress back toward the start every frame.
    const second = tick(&lens, animation.fixed_step_us, signals_open);
    try t.expect(second[0].value > first_value);

    // Enough further ticks for the 200ms linear ramp to fully settle.
    var settle: usize = 0;
    while (settle < 40) : (settle += 1) {
        _ = tick(&lens, animation.fixed_step_us, signals_open);
    }
    try t.expectEqual(@as(f32, 1.0), lens.param_values[0]);
    try t.expect(lens.ramps[0] == null);

    // Falling edge resets the trigger's own state, ready to fire again.
    _ = tick(&lens, animation.fixed_step_us, signals_closed);
    try t.expect(!lens.trigger_was_true[0]);
}
