const std = @import("std");
const evmz = @import("../evm.zig");

const execution = evmz.execution;

const StatefulRuntime = struct {
    tx_kind: u8,
    fail: bool = false,
    service_error: ?anyerror = null,
    invalid_borrow: bool = false,
    borrowed: [1]u8 = .{0xff},

    fn service(self: *StatefulRuntime) execution.PrecompileRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: execution.PrecompileCall) !evmz.precompile.Result {
        const self: *StatefulRuntime = @ptrCast(@alignCast(ptr));
        if (self.service_error) |err| return err;
        _ = try call.host.setStorage(call.message.recipient, 7, self.tx_kind);
        if (self.invalid_borrow) return .{
            .status = .success,
            .output_data = &self.borrowed,
            .gas_left = call.message.gas - 9,
            .output_owned = false,
        };
        const output = if (call.output_buffer) |buffer| blk: {
            if (buffer.len < 1) return error.OutputBufferTooSmall;
            buffer[0] = self.tx_kind;
            break :blk buffer[0..1];
        } else blk: {
            const owned = try call.allocator.alloc(u8, 1);
            owned[0] = self.tx_kind;
            break :blk owned;
        };
        return .{
            .status = if (self.fail) .failure else .success,
            .output_data = output,
            .gas_left = call.message.gas - 9,
            .output_owned = call.output_buffer == null,
        };
    }
};

const StatefulPrecompile = struct {
    const target = evmz.addr(0x1234);

    pub const Entry = enum { family };

    pub fn resolve(_: evmz.eth.Revision, address: evmz.Address) ?Entry {
        return if (std.mem.eql(u8, &address, &target)) .family else null;
    }

    pub fn execute(
        _: evmz.eth.Revision,
        _: Entry,
        call: execution.PrecompileCall,
    ) evmz.precompile.Error!execution.PrecompileOutcome {
        return call.executeRuntime();
    }
};

const StatefulVm = evmz.eth.extend(.{ .execution = .{
    .name = "stateful-precompile-service-test",
    .precompile = StatefulPrecompile,
} });

test "family precompile runtime can use host state and keeps EVM rollback semantics" {
    const sender = evmz.addr(0xaaaa);
    var runtime = StatefulRuntime{ .tx_kind = 0x7e };
    var executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .revision = .cancun,
        .precompile_runtime = runtime.service(),
    });
    defer executor.deinit();

    const success = (try executor.runStandaloneRequest(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqual(StatefulVm.Interpreter.Status.success, success.status);
    try std.testing.expectEqualSlices(u8, &.{0x7e}, success.output_data);
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulPrecompile.target, 7));

    runtime.tx_kind = 0x99;
    runtime.fail = true;
    const failure = (try executor.runStandaloneRequest(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqual(StatefulVm.Interpreter.Status.invalid, failure.status);
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulPrecompile.target, 7));

    runtime.fail = false;
    runtime.service_error = error.NotImplemented;
    try std.testing.expectError(
        error.NotImplemented,
        executor.runStandaloneRequest(request(sender, StatefulPrecompile.target, &.{}), .{}),
    );

    runtime.service_error = null;
    runtime.invalid_borrow = true;
    try std.testing.expectError(
        error.InvalidPrecompileOutput,
        executor.runStandaloneRequest(request(sender, StatefulPrecompile.target, &.{}), .{}),
    );

    runtime.invalid_borrow = false;
    runtime.tx_kind = 0x55;
    var bounded = try StatefulVm.Executor.initWithRuntimeResources(std.testing.allocator, .{
        .revision = .cancun,
        .precompile_runtime = runtime.service(),
    }, .{ .bounded = .{ .result_bytes = 1 } });
    defer bounded.deinit();
    const bounded_result = (try bounded.runStandaloneRequest(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqualSlices(u8, &.{0x55}, bounded_result.output_data);
}

test "bounded Executor reset preserves and replaces the precompile runtime" {
    const sender = evmz.addr(0xaaaa);
    var first_runtime = StatefulRuntime{ .tx_kind = 0x11 };
    var executor = try StatefulVm.initBoundExecutor(std.testing.allocator, .{
        .revision = .cancun,
        .precompile_runtime = first_runtime.service(),
    }, .{ .max_block_gas = 100_000 });
    defer executor.deinit();

    const first = (try executor.runStandaloneRequest(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqualSlices(u8, &.{0x11}, first.output_data);

    var second_runtime = StatefulRuntime{ .tx_kind = 0x22 };
    try executor.reset(.{
        .revision = .cancun,
        .precompile_runtime = second_runtime.service(),
    });
    const second = (try executor.runStandaloneRequest(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqualSlices(u8, &.{0x22}, second.output_data);
}

fn request(sender: evmz.Address, recipient: evmz.Address, input: []const u8) evmz.execution.EvmExecutionRequest {
    return .{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .input = input,
        } },
        .gas = .legacy(100_000),
    };
}
