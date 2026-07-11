const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_io = @import("guest_io");
const guest_allocator = @import("guest_allocator");

pub export var evmz_guest_public_values: evmz.stateless.ere.PublicValues = [_]u8{0} ** evmz.stateless.ere.public_values_size;
pub export var evmz_guest_error: u32 = 0;
pub export var evmz_guest_heap_capacity_bytes: u64 = 0;
pub export var evmz_guest_heap_peak_used_bytes: u64 = 0;

pub const RunResult = struct {
    public_values: evmz.stateless.ere.PublicValues,
};

export fn evmz_guest_entry() callconv(.c) void {
    const input = guest_io.readInput() catch |err| {
        writeError(err);
        return;
    };

    var fixed = guest_allocator.meteredFixedBufferAllocator();
    const result = runStatelessEreInput(fixed.allocator(), input) catch |err| {
        writeHeapTelemetry(&fixed);
        writeError(err);
        return;
    };

    writeHeapTelemetry(&fixed);
    evmz_guest_error = 0;
    evmz_guest_public_values = result.public_values;
    guest_io.writeOutput(&result.public_values);
}

comptime {
    if (guest_options.use_ziskos_staticlib) {
        @export(&ziskMain, .{ .name = "main" });
    }
}

fn ziskMain() callconv(.c) void {
    evmz_guest_entry();
}

pub fn runStatelessEreInput(allocator: std.mem.Allocator, input: []const u8) evmz.stateless.wire.Error!RunResult {
    const public_values = try evmz.stateless.ere.validateStatelessPublicValues(allocator, input);
    return .{ .public_values = public_values };
}

fn writeError(err: anyerror) void {
    evmz_guest_error = @truncate(@intFromError(err));
    var out: [32]u8 = [_]u8{0} ** 32;
    @memcpy(out[0..8], "EVMZERR1");
    std.mem.writeInt(u32, out[8..12], evmz_guest_error, .little);
    guest_io.writeOutput(&out);
}

fn writeHeapTelemetry(fixed: *const guest_allocator.MeteredFixedBufferAllocator) void {
    const metrics = fixed.metrics();
    evmz_guest_heap_capacity_bytes = @intCast(metrics.capacity_bytes);
    evmz_guest_heap_peak_used_bytes = @intCast(metrics.peak_used_bytes);
}
