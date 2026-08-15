//! The frame graph as data: index-addressed nodes and typed edges, with a
//! topological schedule computed once per edit and cached. Editing allocates;
//! frame execution walks the cached order and allocates nothing.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// What flows along an edge. Producers and consumers must agree.
pub const DataKind = enum(u8) { texture, buffer, landmarks, tensor };

/// How the scheduler treats a node. Sources have no inputs, sinks no
/// outputs; analysis nodes publish asynchronously and never block render.
pub const NodeRole = enum(u8) { source, transform, analysis, sink };

pub const NodeIndex = u16;
pub const max_ports = 8;

pub const PortDesc = struct {
    kind: DataKind,
};

pub const NodeDesc = struct {
    role: NodeRole,
    inputs: []const PortDesc = &.{},
    outputs: []const PortDesc = &.{},
};

pub const Edge = struct {
    from_node: NodeIndex,
    from_port: u8,
    to_node: NodeIndex,
    to_port: u8,
    kind: DataKind,
};

pub const EditError = error{
    PortOutOfRange,
    KindMismatch,
    InputAlreadyConnected,
    RoleForbidsInput,
    RoleForbidsOutput,
    CycleDetected,
    OutOfMemory,
};

const Node = struct {
    role: NodeRole,
    input_kinds: [max_ports]DataKind,
    input_count: u8,
    output_kinds: [max_ports]DataKind,
    output_count: u8,
    input_connected: [max_ports]bool,
    // Removed nodes are tombstoned, not compacted: every other live node's
    // NodeIndex must stay valid across a removal, since callers (a lens's
    // own bookkeeping, in particular) hold onto indices across edits.
    alive: bool = true,
};

pub const Graph = struct {
    gpa: Allocator,
    nodes: std.ArrayList(Node) = .empty,
    edges: std.ArrayList(Edge) = .empty,
    schedule: std.ArrayList(NodeIndex) = .empty,
    schedule_valid: bool = false,
    // Tombstoned slots, ready for addNode to reuse before growing the
    // array - a lens spliced and unspliced repeatedly costs no unbounded
    // growth.
    free_nodes: std.ArrayList(NodeIndex) = .empty,

    pub fn init(gpa: Allocator) Graph {
        return .{ .gpa = gpa };
    }

    pub fn deinit(g: *Graph) void {
        g.nodes.deinit(g.gpa);
        g.edges.deinit(g.gpa);
        g.schedule.deinit(g.gpa);
        g.free_nodes.deinit(g.gpa);
    }

    pub fn addNode(g: *Graph, desc: NodeDesc) EditError!NodeIndex {
        if (desc.inputs.len > max_ports or desc.outputs.len > max_ports) return error.PortOutOfRange;
        if (desc.role == .source and desc.inputs.len != 0) return error.RoleForbidsInput;
        if (desc.role == .sink and desc.outputs.len != 0) return error.RoleForbidsOutput;
        var node: Node = .{
            .role = desc.role,
            .input_kinds = undefined,
            .input_count = @intCast(desc.inputs.len),
            .output_kinds = undefined,
            .output_count = @intCast(desc.outputs.len),
            .input_connected = @splat(false),
        };
        for (desc.inputs, 0..) |p, i| node.input_kinds[i] = p.kind;
        for (desc.outputs, 0..) |p, i| node.output_kinds[i] = p.kind;
        g.schedule_valid = false;
        if (g.free_nodes.pop()) |reused| {
            g.nodes.items[reused] = node;
            return reused;
        }
        const index: NodeIndex = @intCast(g.nodes.items.len);
        try g.nodes.append(g.gpa, node);
        return index;
    }

    /// Edit-time. Drops the node and every edge touching it, and resets
    /// input_connected on the far side of any edge that fed out of it, so
    /// a later splice can reconnect that input. index becomes eligible for
    /// addNode reuse; using it again before that is a caller bug (asserted
    /// in Debug/ReleaseSafe, since the freed slot's contents are otherwise
    /// silently overwritten by whatever addNode reuses it for next).
    pub fn removeNode(g: *Graph, index: NodeIndex) void {
        std.debug.assert(g.nodes.items[index].alive);
        g.nodes.items[index].alive = false;

        var write: usize = 0;
        for (g.edges.items) |e| {
            if (e.from_node == index or e.to_node == index) {
                if (e.to_node != index) g.nodes.items[e.to_node].input_connected[e.to_port] = false;
                continue;
            }
            g.edges.items[write] = e;
            write += 1;
        }
        g.edges.shrinkRetainingCapacity(write);

        g.free_nodes.append(g.gpa, index) catch {
            // Losing the slot to reuse is a bounded cost (the array simply
            // keeps that one entry tombstoned forever), never a correctness
            // problem, so an allocation failure here is not fatal.
        };
        g.schedule_valid = false;
    }

    /// Connects an output port to an input port. Kinds must match and an
    /// input accepts exactly one producer.
    pub fn connect(g: *Graph, from: NodeIndex, from_port: u8, to: NodeIndex, to_port: u8) EditError!void {
        const src = &g.nodes.items[from];
        const dst = &g.nodes.items[to];
        if (from_port >= src.output_count or to_port >= dst.input_count) return error.PortOutOfRange;
        const kind = src.output_kinds[from_port];
        if (kind != dst.input_kinds[to_port]) return error.KindMismatch;
        if (dst.input_connected[to_port]) return error.InputAlreadyConnected;

        try g.edges.append(g.gpa, .{
            .from_node = from,
            .from_port = from_port,
            .to_node = to,
            .to_port = to_port,
            .kind = kind,
        });
        dst.input_connected[to_port] = true;
        g.schedule_valid = false;

        // Reject the edge now if it closed a cycle, so the graph is never
        // left unschedulable.
        g.computeSchedule() catch |err| {
            _ = g.edges.pop();
            dst.input_connected[to_port] = false;
            return err;
        };
    }

    /// Kahn's algorithm over a compressed adjacency built per edit, linear
    /// in nodes plus edges. The result is cached and stable for identical
    /// edit sequences, which is what conformance determinism rests on.
    fn computeSchedule(g: *Graph) EditError!void {
        const n = g.nodes.items.len;
        const m = g.edges.items.len;
        var alive_count: usize = 0;
        for (g.nodes.items) |node| {
            if (node.alive) alive_count += 1;
        }
        g.schedule.clearRetainingCapacity();
        try g.schedule.ensureTotalCapacity(g.gpa, alive_count);

        // Successor lists in compressed form: counting pass, prefix sums,
        // fill pass. Edge insertion order is preserved, so ties in the
        // traversal resolve the same way every time.
        var offsets = try g.gpa.alloc(u32, n + 1);
        defer g.gpa.free(offsets);
        @memset(offsets, 0);
        for (g.edges.items) |e| offsets[e.from_node + 1] += 1;
        for (1..n + 1) |i| offsets[i] += offsets[i - 1];

        var successors = try g.gpa.alloc(NodeIndex, m);
        defer g.gpa.free(successors);
        var cursor = try g.gpa.alloc(u32, n);
        defer g.gpa.free(cursor);
        for (0..n) |i| cursor[i] = offsets[i];
        for (g.edges.items) |e| {
            successors[cursor[e.from_node]] = e.to_node;
            cursor[e.from_node] += 1;
        }

        var indegree = try g.gpa.alloc(u16, n);
        defer g.gpa.free(indegree);
        @memset(indegree, 0);
        for (g.edges.items) |e| indegree[e.to_node] += 1;

        var queue = try g.gpa.alloc(NodeIndex, n);
        defer g.gpa.free(queue);
        var head: usize = 0;
        var tail: usize = 0;
        for (indegree, 0..) |d, i| {
            if (d == 0 and g.nodes.items[i].alive) {
                queue[tail] = @intCast(i);
                tail += 1;
            }
        }

        while (head < tail) {
            const current = queue[head];
            head += 1;
            g.schedule.appendAssumeCapacity(current);
            for (successors[offsets[current]..offsets[current + 1]]) |next| {
                indegree[next] -= 1;
                if (indegree[next] == 0) {
                    queue[tail] = next;
                    tail += 1;
                }
            }
        }

        if (g.schedule.items.len != alive_count) return error.CycleDetected;
        g.schedule_valid = true;
    }

    /// The cached execution order. Valid whenever the last edit succeeded.
    pub fn executionOrder(g: *Graph) EditError![]const NodeIndex {
        if (!g.schedule_valid) try g.computeSchedule();
        return g.schedule.items;
    }

    pub fn nodeRole(g: *const Graph, index: NodeIndex) NodeRole {
        return g.nodes.items[index].role;
    }

    pub fn nodeCount(g: *const Graph) usize {
        return g.nodes.items.len;
    }
};

const t = std.testing;

fn cameraDesc() NodeDesc {
    return .{ .role = .source, .outputs = &.{.{ .kind = .texture }} };
}

test "schedule orders producers before consumers" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const camera = try g.addNode(cameraDesc());
    const beauty = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    const display = try g.addNode(.{ .role = .sink, .inputs = &.{.{ .kind = .texture }} });
    try g.connect(camera, 0, beauty, 0);
    try g.connect(beauty, 0, display, 0);

    const order = try g.executionOrder();
    try t.expectEqual(@as(usize, 3), order.len);
    var pos: [3]usize = undefined;
    for (order, 0..) |node, i| pos[node] = i;
    try t.expect(pos[camera] < pos[beauty]);
    try t.expect(pos[beauty] < pos[display]);
}

test "kind mismatch and double connection are rejected" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const camera = try g.addNode(cameraDesc());
    const tracker = try g.addNode(.{ .role = .analysis, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .landmarks }} });
    const overlay = try g.addNode(.{ .role = .transform, .inputs = &.{ .{ .kind = .texture }, .{ .kind = .landmarks } }, .outputs = &.{.{ .kind = .texture }} });

    try t.expectError(error.KindMismatch, g.connect(tracker, 0, overlay, 0));
    try g.connect(camera, 0, overlay, 0);
    try t.expectError(error.InputAlreadyConnected, g.connect(camera, 0, overlay, 0));
    try g.connect(tracker, 0, overlay, 1);
}

test "role constraints hold at construction" {
    var g = Graph.init(t.allocator);
    defer g.deinit();
    try t.expectError(error.RoleForbidsInput, g.addNode(.{ .role = .source, .inputs = &.{.{ .kind = .buffer }} }));
    try t.expectError(error.RoleForbidsOutput, g.addNode(.{ .role = .sink, .outputs = &.{.{ .kind = .buffer }} }));
}

test "cycles are rejected and the graph stays usable" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const a = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    const b = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    try g.connect(a, 0, b, 0);
    try t.expectError(error.CycleDetected, g.connect(b, 0, a, 0));

    const camera = try g.addNode(cameraDesc());
    try g.connect(camera, 0, a, 0);
    const order = try g.executionOrder();
    try t.expectEqual(@as(usize, 3), order.len);
}

test "schedule is identical across recomputation" {
    var g = Graph.init(t.allocator);
    defer g.deinit();
    const camera = try g.addNode(cameraDesc());
    const seg = try g.addNode(.{ .role = .analysis, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .tensor }} });
    const face = try g.addNode(.{ .role = .analysis, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .landmarks }} });
    const comp = try g.addNode(.{ .role = .transform, .inputs = &.{ .{ .kind = .texture }, .{ .kind = .tensor }, .{ .kind = .landmarks } }, .outputs = &.{.{ .kind = .texture }} });
    const out = try g.addNode(.{ .role = .sink, .inputs = &.{.{ .kind = .texture }} });
    try g.connect(camera, 0, seg, 0);
    try g.connect(camera, 0, face, 0);
    try g.connect(camera, 0, comp, 0);
    try g.connect(seg, 0, comp, 1);
    try g.connect(face, 0, comp, 2);
    try g.connect(comp, 0, out, 0);

    const first = try t.allocator.dupe(NodeIndex, try g.executionOrder());
    defer t.allocator.free(first);
    g.schedule_valid = false;
    const second = try g.executionOrder();
    try t.expectEqualSlices(NodeIndex, first, second);
}

test "removing a node drops it from the schedule and its edges" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const camera = try g.addNode(cameraDesc());
    const beauty = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    const display = try g.addNode(.{ .role = .sink, .inputs = &.{.{ .kind = .texture }} });
    try g.connect(camera, 0, beauty, 0);
    try g.connect(beauty, 0, display, 0);

    g.removeNode(beauty);
    const order = try g.executionOrder();
    try t.expectEqual(@as(usize, 2), order.len);
    for (order) |n| try t.expect(n != beauty);

    // display's input freed up, so the camera can feed it directly now.
    try g.connect(camera, 0, display, 0);
    try t.expectEqual(@as(usize, 2), (try g.executionOrder()).len);
}

test "a removed node's slot is reused, so repeated splice/unsplice does not grow the graph" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const first = try g.addNode(cameraDesc());
    g.removeNode(first);
    const second = try g.addNode(.{ .role = .sink, .inputs = &.{.{ .kind = .texture }} });
    try t.expectEqual(first, second);
    try t.expectEqual(@as(usize, 1), g.nodeCount());
}

test "a reused slot starts clean: no edge or cycle state survives from before removal" {
    var g = Graph.init(t.allocator);
    defer g.deinit();

    const a = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    const b = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    try g.connect(a, 0, b, 0);
    try t.expectError(error.CycleDetected, g.connect(b, 0, a, 0));

    g.removeNode(b);
    const reused = try g.addNode(.{ .role = .transform, .inputs = &.{.{ .kind = .texture }}, .outputs = &.{.{ .kind = .texture }} });
    try t.expectEqual(b, reused);

    // a's prior edge into b is gone with b, so this is a fresh, acyclic
    // connection, not a repeat of the edge that used to exist.
    try g.connect(a, 0, reused, 0);
    const order = try g.executionOrder();
    try t.expectEqual(@as(usize, 2), order.len);
}
