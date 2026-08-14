//! The frame graph core. The graph is data: index-addressed nodes and typed
//! edges with a cached topological schedule. Pools bound every frame-path
//! resource, analysis publishes asynchronously through sequence-locked
//! slots, and the degradation ladder trades effect quality for frame time,
//! never the preview itself.

pub const topology = @import("topology.zig");
pub const pool = @import("pool.zig");
pub const analysis = @import("analysis.zig");
pub const degrade = @import("degrade.zig");

pub const Graph = topology.Graph;
pub const DataKind = topology.DataKind;
pub const NodeRole = topology.NodeRole;
pub const NodeIndex = topology.NodeIndex;
pub const Pool = pool.Pool;
pub const ResourceDesc = pool.ResourceDesc;
pub const ResultSlot = analysis.ResultSlot;
pub const DegradeLevel = degrade.Level;
pub const DegradeController = degrade.Controller;

test {
    _ = topology;
    _ = pool;
    _ = analysis;
    _ = degrade;
}
