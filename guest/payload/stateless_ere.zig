const std = @import("std");
const builtin = @import("builtin");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_io = @import("guest_io");
const guest_allocator = @import("guest_allocator");

pub var evmz_guest_error: u32 = 0;

pub fn evmz_guest_entry() callconv(.c) c_int {
    const input = guest_io.readInput() catch |err| {
        recordError(err);
        return 1;
    };

    var allocator_state = guest_allocator.init();
    const result = runStatelessEreInput(allocator_state.allocator(), input) catch |err| {
        recordError(err);
        return 1;
    };

    evmz_guest_error = 0;
    guest_io.writeOutput(result);
    return 0;
}

comptime {
    if (!builtin.is_test) {
        @export(&evmz_guest_error, .{ .name = "evmz_guest_error" });
        @export(&evmz_guest_entry, .{ .name = "evmz_guest_entry" });
    }
    switch (guest_options.backend) {
        .native => {},
        .zisk => @export(&ziskMain, .{ .name = "main" }),
        .sp1 => @export(&sp1Main, .{ .name = "main" }),
        .openvm => @export(&openvmMain, .{ .name = "main" }),
    }
}

fn ziskMain() callconv(.c) c_int {
    return evmz_guest_entry();
}

fn sp1Main() callconv(.c) c_int {
    return evmz_guest_entry();
}

fn openvmMain() callconv(.c) void {
    _ = evmz_guest_entry();
}

pub fn runStatelessEreInput(allocator: std.mem.Allocator, input: []const u8) evmz.stateless.wire.Error![]u8 {
    return evmz.stateless.wire.validateStatelessBytes(allocator, input);
}

fn recordError(err: anyerror) void {
    evmz_guest_error = @truncate(@intFromError(err));
}
