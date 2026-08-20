//! A sandboxed per-lens script node backed by QuickJS-ng. The C shim hides
//! JSValue and hardens the context; this is the Zig surface the lens runtime
//! drives per tick. The script defines a global update(lens) that reads
//! lens.signals.<name> and writes lens.params.<name>; no I/O, clock, or RNG.
const std = @import("std");

const Handle = opaque {};
extern fn goss_script_new(source: [*]const u8, source_len: usize, fuel_per_tick: c_long) ?*Handle;
extern fn goss_script_free(s: ?*Handle) void;
extern fn goss_script_tick(
    s: ?*Handle,
    signal_names: [*]const [*:0]const u8,
    signal_values: [*]const f64,
    signal_count: c_int,
    param_names: [*]const [*:0]const u8,
    param_values: [*]f64,
    param_count: c_int,
) c_int;

pub const Script = struct {
    handle: *Handle,

    /// Compiles a lens script that must define a global update(lens)
    /// function. fuel_per_tick bounds the work one tick may do before it is
    /// interrupted; 0 uses the shim default.
    pub fn create(source: []const u8, fuel_per_tick: u32) !Script {
        const h = goss_script_new(source.ptr, source.len, @intCast(fuel_per_tick)) orelse
            return error.ScriptCompileFailed;
        return .{ .handle = h };
    }

    pub fn destroy(self: *Script) void {
        goss_script_free(self.handle);
        self.handle = undefined;
    }

    /// Runs update(lens) once. The script reads the named signals and
    /// reads/writes the named params; param_values is updated in place with
    /// whatever the script wrote. Errors on an exception or a fuel timeout.
    pub fn tick(
        self: *Script,
        signal_names: []const [*:0]const u8,
        signal_values: []const f64,
        param_names: []const [*:0]const u8,
        param_values: []f64,
    ) !void {
        std.debug.assert(signal_names.len == signal_values.len);
        std.debug.assert(param_names.len == param_values.len);
        const rc = goss_script_tick(
            self.handle,
            signal_names.ptr,
            signal_values.ptr,
            @intCast(signal_names.len),
            param_names.ptr,
            param_values.ptr,
            @intCast(param_names.len),
        );
        if (rc != 0) return error.ScriptTickFailed;
    }
};

test "a script reads a signal and writes a param, deterministically" {
    const src =
        \\function update(lens) {
        \\  lens.params.intensity = lens.signals.level * 0.5 + 0.1;
        \\}
    ;
    var a = try Script.create(src, 1_000_000);
    defer a.destroy();
    const sig_names = [_][*:0]const u8{"level"};
    const param_names = [_][*:0]const u8{"intensity"};
    var params = [_]f64{0.0};
    try a.tick(&sig_names, &[_]f64{0.8}, &param_names, &params);
    try std.testing.expectApproxEqAbs(@as(f64, 0.5), params[0], 1e-12);

    // A second fresh context, same inputs: identical output (deterministic).
    var b = try Script.create(src, 1_000_000);
    defer b.destroy();
    var params2 = [_]f64{0.0};
    try b.tick(&sig_names, &[_]f64{0.8}, &param_names, &params2);
    try std.testing.expectEqual(params[0], params2[0]);
}

test "a runaway script is stopped by fuel, not a hang" {
    const src = "function update(lens) { while (true) {} }";
    var s = try Script.create(src, 50_000);
    defer s.destroy();
    const names = [_][*:0]const u8{};
    var params = [_]f64{};
    try std.testing.expectError(error.ScriptTickFailed, s.tick(&names, &[_]f64{}, &names, &params));
}

test "a script with no update function is rejected at compile" {
    try std.testing.expectError(error.ScriptCompileFailed, Script.create("let x = 1;", 0));
}
