//! Stub script backend for targets that do not link QuickJS yet. It
//! reports the capability honestly absent, so a lens carrying a script node
//! degrades to its default parameter values instead of failing.
const std = @import("std");

pub const Script = struct {
    handle: *anyopaque,

    pub fn create(source: []const u8, fuel_per_tick: u32) !Script {
        _ = source;
        _ = fuel_per_tick;
        return error.ScriptUnsupported;
    }

    pub fn destroy(self: *Script) void {
        _ = self;
    }

    pub fn tick(
        self: *Script,
        signal_names: []const [*:0]const u8,
        signal_values: []const f64,
        param_names: []const [*:0]const u8,
        param_values: []f64,
    ) !void {
        _ = self;
        _ = signal_names;
        _ = signal_values;
        _ = param_names;
        _ = param_values;
        return error.ScriptUnsupported;
    }
};
