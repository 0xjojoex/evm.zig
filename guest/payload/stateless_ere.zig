const std = @import("std");
const builtin = @import("builtin");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_io = @import("guest_io");
const guest_allocator = @import("guest_allocator");

pub var evmz_guest_error: u32 = 0;
pub var evmz_guest_heap_capacity_bytes: u64 = 0;
pub var evmz_guest_heap_peak_used_bytes: u64 = 0;

pub fn evmz_guest_entry() callconv(.c) void {
    const input = guest_io.readInput() catch |err| {
        writeError(err);
        return;
    };

    var fixed = if (comptime guest_options.heap_metrics)
        guest_allocator.meteredFixedBufferAllocator()
    else
        guest_allocator.fixedBufferAllocator();
    const result = runStatelessEreInput(fixed.allocator(), input) catch |err| {
        if (comptime guest_options.heap_metrics) writeHeapTelemetry(&fixed);
        writeError(err);
        return;
    };

    if (comptime guest_options.heap_metrics) writeHeapTelemetry(&fixed);
    evmz_guest_error = 0;
    guest_io.writeOutput(result);
}

comptime {
    if (!builtin.is_test) {
        @export(&evmz_guest_error, .{ .name = "evmz_guest_error" });
        if (guest_options.heap_metrics) {
            @export(&evmz_guest_heap_capacity_bytes, .{ .name = "evmz_guest_heap_capacity_bytes" });
            @export(&evmz_guest_heap_peak_used_bytes, .{ .name = "evmz_guest_heap_peak_used_bytes" });
        }
        @export(&evmz_guest_entry, .{ .name = "evmz_guest_entry" });
    }
    switch (guest_options.backend) {
        .native => {},
        .zisk => @export(&ziskMain, .{ .name = "main" }),
        .sp1 => @export(&sp1Main, .{ .name = "main" }),
    }
}

fn ziskMain() callconv(.c) void {
    evmz_guest_entry();
}

fn sp1Main() callconv(.c) c_int {
    evmz_guest_entry();
    return 0;
}

pub fn runStatelessEreInput(allocator: std.mem.Allocator, input: []const u8) evmz.stateless.wire.Error![]u8 {
    return evmz.stateless.wire.v1.validateStatelessBytesOneShot(allocator, input);
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
