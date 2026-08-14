//! The frame graph core. The graph is data: index-addressed nodes and typed
//! edges with a cached topological schedule computed at edit time, so frame
//! execution walks a flat array and allocates nothing.

pub const topology = @import("topology.zig");

pub const Graph = topology.Graph;
pub const DataKind = topology.DataKind;
pub const NodeRole = topology.NodeRole;
pub const NodeIndex = topology.NodeIndex;

test {
    _ = topology;
}
