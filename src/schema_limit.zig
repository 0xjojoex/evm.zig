const std = @import("std");

/// Validate an arbitrary-precision SSZ schema capacity.
pub fn assertValid(comptime limit: comptime_int) void {
    if (limit < 0) @compileError("SSZ schema limits cannot be negative");
}

/// Return whether a runtime-addressable count exceeds a declared schema limit.
pub fn exceededBy(actual: usize, comptime limit: comptime_int) bool {
    comptime assertValid(limit);
    const max_runtime_count: comptime_int = std.math.maxInt(usize);
    if (comptime limit > max_runtime_count) return false;
    return actual > @as(usize, @intCast(limit));
}
