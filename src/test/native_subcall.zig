//! Arc-inspired capability tests, not an implementation of Arc's CallFrom ABI or gas schedule.
const std = @import("std");
const evmz = @import("../evm.zig");
const testing = std.testing;

const Native = struct {
    const address = evmz.addr(0x1800000000000000000000000000000000000003);

    pub fn active(candidate: evmz.Address) bool {
        return evmz.Address.eql(candidate, address);
    }
};

const Latest = evmz.t.CustomVm(.latest, .{ .native_contract = Native }).?;
const sender = evmz.addr(0xaaaa);
const target = evmz.addr(0xbbbb);

const Runtime = struct {
    child: evmz.Address = target,
    completion_status: evmz.execution.Status = .success,
    child_status: ?evmz.execution.Status = null,
    child_refund: i64 = 0,
    native_depth: u16 = 0,
    sibling: bool = false,

    fn service(self: *Runtime) evmz.execution.NativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: evmz.execution.NativeContractCall) !evmz.execution.NativeContractResult {
        const self: *Runtime = @ptrCast(@alignCast(ptr));
        var ledger = evmz.execution.NativeContractResult.init(call.message);
        const child = if (call.message.depth < self.native_depth) Native.address else self.child;
        const result = try call.host.call(.{
            .depth = call.message.depth + 1,
            .kind = .call,
            .gas = call.message.gas,
            .gas_reservoir = call.message.gas_reservoir,
            .recipient = child,
            .sender = call.message.sender,
            .input_data = call.message.input_data,
            .value = 0,
            .is_static = call.message.is_static,
            .code_address = child,
        });
        self.child_status = result.status();
        self.child_refund = result.gas_refund;
        // Host output is borrowed until the next Host call. Copy before a sibling call.
        const output = try call.allocator.alloc(u8, result.output_data.len + 1);
        output[0] = @intFromBool(result.isSuccess());
        @memcpy(output[1..], result.output_data);
        ledger.output_data = output;
        if (!ledger.settleChild(call.message.gas, 0, result)) return ledger;
        if (self.sibling) {
            const forwarded = ledger.gas_left;
            const sibling = try call.host.call(.{
                .depth = call.message.depth + 1,
                .kind = .call,
                .gas = forwarded,
                .gas_reservoir = ledger.gas_reservoir,
                .is_static = call.message.is_static,
                .recipient = evmz.addr(4),
                .sender = call.message.recipient,
                .input_data = &.{0xff},
                .value = 0,
                .code_address = evmz.addr(4),
            });
            if (!ledger.settleChild(forwarded, 0, sibling)) return ledger;
        }
        ledger.status = self.completion_status;
        return ledger;
    }
};

fn seed(executor: *Latest.Executor, address: evmz.Address, code: []const u8) !void {
    var account = evmz.state.MemoryAccount.init(testing.allocator);
    errdefer account.deinit();
    try account.setCode(code);
    try account.storage.put(0, 1);
    try executor.state.seedAccount(address, account);
}

fn run(executor: *Latest.Executor, recipient: evmz.Address, input: []const u8) !evmz.Host.Result {
    return executor.executeStandalone(.{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{ .sender = sender, .recipient = recipient, .input = input } },
        .gas = .legacy(100_000),
    }, .{});
}

test "native subcall preserves sender and delegated account context" {
    const delegate = evmz.addr(0xcccc);
    var runtime = Runtime{};
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    const code = evmz.t.bytecode(.{
        .CALLER,  .PUSH0,  .MSTORE,
        .ADDRESS, .PUSH1,  32,
        .MSTORE,  .ORIGIN, .PUSH1,
        64,       .MSTORE, .PUSH1,
        96,       .PUSH0,  .RETURN,
    });
    try seed(&executor, delegate, &code);
    var designation: [23]u8 = undefined;
    @memcpy(designation[0..3], &[_]u8{ 0xef, 0x01, 0x00 });
    @memcpy(designation[3..], &delegate.bytes);
    try seed(&executor, target, &designation);
    const result = try run(&executor, Native.address, &.{});
    try testing.expectEqual(.success, result.status());
    try testing.expectEqual(@as(u8, 1), result.output_data[0]);
    try testing.expectEqual(sender.toU256(), std.mem.readInt(u256, result.output_data[1..33], .big));
    try testing.expectEqual(target.toU256(), std.mem.readInt(u256, result.output_data[33..65], .big));
    try testing.expectEqual(sender.toU256(), std.mem.readInt(u256, result.output_data[65..97], .big));
}

test "native subcall wraps child revert and rolls back storage and logs" {
    var runtime = Runtime{};
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    const code = evmz.t.bytecode(.{
        .PUSH1, 2,      .PUSH0,   .SSTORE,
        .PUSH0, .PUSH0, .LOG0,    .PUSH1,
        0x42,   .PUSH0, .MSTORE8, .PUSH1,
        1,      .PUSH0, .REVERT,
    });
    try seed(&executor, target, &code);
    const result = try run(&executor, Native.address, &.{});
    try testing.expectEqual(.success, result.status());
    try testing.expectEqualSlices(u8, &.{ 0, 0x42 }, result.output_data);
    try testing.expectEqual(@as(u256, 1), try executor.getStorage(target, 0));
    try testing.expectEqual(@as(usize, 0), executor.logView().len());
    try testing.expectEqual(@as(i64, 0), result.gas_refund);
}

test "native subcall completion failure rolls back a successful child" {
    inline for (.{ evmz.execution.Status.revert, evmz.execution.Status.out_of_gas }) |status| {
        var runtime = Runtime{ .completion_status = status };
        var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
        defer executor.deinit();
        const code = evmz.t.bytecode(.{
            .PUSH0, .PUSH0, .SSTORE,
            .PUSH0, .PUSH0, .LOG0,
            .STOP,
        });
        try seed(&executor, target, &code);
        const result = try run(&executor, Native.address, &.{});
        try testing.expectEqual(.success, runtime.child_status.?);
        try testing.expect(runtime.child_refund > 0);
        try testing.expectEqual(status, result.status());
        try testing.expectEqual(@as(u256, 1), try executor.getStorage(target, 0));
        try testing.expectEqual(@as(usize, 0), executor.logView().len());
        try testing.expectEqual(@as(i64, 0), result.gas_refund);
        if (status == .out_of_gas) try testing.expectEqual(@as(i64, 0), result.gas_left);
    }
}

test "native subcall copies terminal precompile output before sibling reentry" {
    var runtime = Runtime{ .child = evmz.addr(4), .sibling = true };
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    const result = try run(&executor, Native.address, &.{ 0xaa, 0xbb });
    try testing.expectEqualSlices(u8, &.{ 1, 0xaa, 0xbb }, result.output_data);
}

test "native subcall forwards successful child storage refunds" {
    var runtime = Runtime{};
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .SSTORE, .STOP });
    try seed(&executor, target, &code);
    const result = try run(&executor, Native.address, &.{});
    try testing.expectEqual(.success, result.status());
    try testing.expect(runtime.child_refund > 0);
    try testing.expectEqual(runtime.child_refund, result.gas_refund);
}

test "native subcall completion failure leaves its bytecode caller alive" {
    const parent = evmz.addr(0xdddd);
    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 7,       .PUSH0, .SSTORE,
        .PUSH0, .PUSH0,  .PUSH0, .PUSH0,
        .PUSH0, .PUSH20,
    }) ++ Native.address.bytes ++ evmz.t.bytecode(.{
        .GAS, .CALL, .PUSH0, .MSTORE, .PUSH1, 32, .PUSH0, .RETURN,
    });
    const child_code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .SSTORE, .PUSH0, .PUSH0, .LOG0, .STOP });
    inline for (.{ evmz.execution.Status.revert, evmz.execution.Status.out_of_gas }) |status| {
        var runtime = Runtime{ .completion_status = status };
        var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
        defer executor.deinit();
        try seed(&executor, target, &child_code);
        try seed(&executor, parent, &parent_code);
        const result = try run(&executor, parent, &.{});
        try testing.expectEqual(.success, result.status());
        try testing.expectEqual(.success, runtime.child_status.?);
        try testing.expectEqual(@as(u256, 0), std.mem.readInt(u256, result.output_data[0..32], .big));
        try testing.expectEqual(@as(u256, 7), try executor.getStorage(parent, 0));
        try testing.expectEqual(@as(u256, 1), try executor.getStorage(target, 0));
        try testing.expectEqual(@as(usize, 0), executor.logView().len());
        try testing.expectEqual(@as(i64, 0), result.gas_refund);
    }
}

test "native subcall wraps immediate empty code and exceptional halt outcomes" {
    inline for (.{ false, true }) |halt| {
        var runtime = Runtime{};
        var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
        defer executor.deinit();
        if (halt) try seed(&executor, target, &evmz.t.bytecode(.{.INVALID}));
        const result = try run(&executor, Native.address, &.{});
        try testing.expectEqual(.success, result.status());
        try testing.expectEqualSlices(u8, &.{@intFromBool(!halt)}, result.output_data);
        try testing.expectEqual(@as(i64, 0), result.gas_refund);
        if (halt) try testing.expectEqual(@as(i64, 0), result.gas_left);
    }
}

test "native subcall output survives repeated native recursion" {
    var runtime = Runtime{ .child = evmz.addr(4), .native_depth = 24 };
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    const result = try run(&executor, Native.address, &.{ 0xaa, 0xbb });
    var expected: [27]u8 = @splat(1);
    expected[25..].* = .{ 0xaa, 0xbb };
    try testing.expectEqual(.success, result.status());
    try testing.expectEqualSlices(u8, &expected, result.output_data);
    try testing.expectEqual(@as(usize, 0), executor.frame_store.maxRowCount());
}

test "native subcall inherits static context in its bytecode child" {
    const parent = evmz.addr(0xdddd);
    const parent_code = evmz.t.bytecode(.{
        .PUSH1, 1, .PUSH0, .PUSH0, .PUSH0, .PUSH20,
    }) ++ Native.address.bytes ++ evmz.t.bytecode(.{
        .GAS, .STATICCALL, .POP, .PUSH1, 1, .PUSH0, .RETURN,
    });
    var runtime = Runtime{};
    var executor = Latest.Executor.init(testing.allocator, .{ .native_contract_runtime = runtime.service() });
    defer executor.deinit();
    try seed(&executor, target, &evmz.t.bytecode(.{ .PUSH0, .PUSH0, .SSTORE, .STOP }));
    try seed(&executor, parent, &parent_code);
    const result = try run(&executor, parent, &.{});
    try testing.expectEqual(.success, result.status());
    try testing.expectEqual(.invalid, runtime.child_status.?);
    try testing.expectEqualSlices(u8, &.{0}, result.output_data);
    try testing.expectEqual(@as(u256, 1), try executor.getStorage(target, 0));
}
