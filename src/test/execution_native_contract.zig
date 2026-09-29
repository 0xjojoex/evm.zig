const std = @import("std");
const evmz = @import("../evm.zig");

const execution = evmz.execution;

const StatefulRuntime = struct {
    tx_kind: u8,
    status: execution.Status = .success,
    service_error: ?anyerror = null,

    fn service(self: *StatefulRuntime) execution.NativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(
        ptr: *anyopaque,
        call: execution.NativeContractCall,
    ) !execution.NativeContractResult {
        const self: *StatefulRuntime = @ptrCast(@alignCast(ptr));
        if (self.service_error) |err| return err;
        _ = try call.host.setStorage(.fromAddress(call.message.recipient), 7, self.tx_kind);
        const output = try call.allocator.alloc(u8, 1);
        output[0] = self.tx_kind;
        return .{
            .status = self.status,
            .output_data = output,
            .gas_left = call.message.gas - 9,
            .gas_reservoir = call.message.gas_reservoir,
        };
    }
};

const ReentrantRuntime = struct {
    child: evmz.Address,
    called: bool = false,

    fn service(self: *ReentrantRuntime) execution.NativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(
        ptr: *anyopaque,
        call: execution.NativeContractCall,
    ) !execution.NativeContractResult {
        const self: *ReentrantRuntime = @ptrCast(@alignCast(ptr));
        var ledger = execution.NativeContractResult.init(call.message);
        const result = (try call.host.call(.{
            .depth = call.message.depth + 1,
            .kind = .call,
            .gas = call.message.gas,
            .gas_reservoir = ledger.gas_reservoir,
            .recipient = self.child,
            .sender = call.message.recipient,
            .input_data = &.{},
            .value = 0,
            .is_static = call.message.is_static,
            .code_address = self.child,
        }));
        self.called = true;
        if (!ledger.settleChild(call.message.gas, 0, result)) return ledger;
        ledger.status = result.status();
        return ledger;
    }
};

const ReentrantOutputRuntime = struct {
    fn service(self: *ReentrantOutputRuntime) execution.NativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(
        ptr: *anyopaque,
        call: execution.NativeContractCall,
    ) !execution.NativeContractResult {
        const self: *ReentrantOutputRuntime = @ptrCast(@alignCast(ptr));
        _ = self;
        var ledger = execution.NativeContractResult.init(call.message);
        const output = try call.allocator.alloc(u8, 1);
        ledger.output_data = output;
        const outer = call.message.input_data.len == 0;
        output[0] = if (outer) 0xaa else 0xbb;

        if (outer) {
            const nested = (try call.host.call(.{
                .depth = call.message.depth + 1,
                .kind = .call,
                .gas = call.message.gas,
                .gas_reservoir = call.message.gas_reservoir,
                .recipient = call.message.recipient,
                .sender = call.message.recipient,
                .input_data = &.{0x01},
                .value = 0,
                .code_address = call.message.code_address,
            }));
            try std.testing.expectEqualSlices(u8, &.{0xbb}, nested.output_data);
            if (!ledger.settleChild(call.message.gas, 0, nested)) return ledger;
        }

        return ledger;
    }
};

const StatefulNativeContract = struct {
    const target = evmz.addr(0x1234);

    pub fn active(address: evmz.Address) bool {
        return evmz.Address.eql(address, target);
    }
};

const Latest = evmz.t.CustomVm(.latest, .{ .native_contract = StatefulNativeContract }).?;

test "active native contract requires an embedding runtime" {
    const sender = evmz.addr(0xaaaa);
    var executor = Latest.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try std.testing.expectError(
        error.MissingNativeContractRuntime,
        executor.executeStandalone(request(sender, StatefulNativeContract.target, &.{}), .{}),
    );
}

test "native contract can use host state and keeps EVM rollback semantics" {
    const sender = evmz.addr(0xaaaa);
    var runtime = StatefulRuntime{ .tx_kind = 0x7e };
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract_runtime = runtime.service(),
    });
    defer executor.deinit();

    const success = (try executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqual(Latest.Interpreter.Status.success, success.status());
    try std.testing.expectEqualSlices(u8, &.{0x7e}, success.output_data);
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulNativeContract.target, 7));
    try std.testing.expectEqual(@as(usize, 0), executor.frame_store.maxRowCount());

    runtime.tx_kind = 0x99;
    runtime.status = .revert;
    const failure = (try executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqual(Latest.Interpreter.Status.revert, failure.status());
    try std.testing.expectEqualSlices(u8, &.{0x99}, failure.output_data);
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulNativeContract.target, 7));

    runtime.status = .success;
    runtime.service_error = error.NotImplemented;
    try std.testing.expectError(
        error.NotImplemented,
        executor.executeStandalone(request(sender, StatefulNativeContract.target, &.{}), .{}),
    );
}

test "executor construction selects the supplied native contract runtime" {
    const sender = evmz.addr(0xaaaa);
    var first_runtime = StatefulRuntime{ .tx_kind = 0x11 };
    var first_executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract_runtime = first_runtime.service(),
    });
    defer first_executor.deinit();

    const first = (try first_executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqualSlices(u8, &.{0x11}, first.output_data);

    var second_runtime = StatefulRuntime{ .tx_kind = 0x22 };
    var second_executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract_runtime = second_runtime.service(),
    });
    defer second_executor.deinit();

    const second = (try second_executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqualSlices(u8, &.{0x22}, second.output_data);
}

test "native contract output survives synchronous host reentry" {
    const sender = evmz.addr(0xaaaa);
    var runtime = ReentrantOutputRuntime{};
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract_runtime = runtime.service(),
    });
    defer executor.deinit();

    const result = (try executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));

    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
}

test "native contract preserves parent stack across arena growth" {
    const sender = evmz.addr(0xaaaa);
    const parent = evmz.addr(0xbbbb);
    const child = evmz.addr(0x5678);
    const filler_words = 599;
    const parent_tail = evmz.t.bytecode(.{
        // Together with the filler, retain 600 words below CALL's operands.
        .PUSH1, 0x2a,
        .PUSH0, .PUSH0,
        .PUSH0, .PUSH0,
        .PUSH0, .PUSH2,
        0x12,   0x34,
        .GAS,   .CALL,
        .POP,   .PUSH1,
        0x2a,   .EQ,
        .PUSH0, .SSTORE,
        .STOP,
    });
    var parent_code: [filler_words + parent_tail.len]u8 = undefined;
    @memset(parent_code[0..filler_words], evmz.Opcode.PUSH0.toByte());
    @memcpy(parent_code[filler_words..], &parent_tail);

    const child_code = evmz.t.bytecode(.{
        // Leave one live word while recursively calling this same account.
        // This raises the lazy row high-water mark and grows the packed arena.
        .PUSH1, 0x77,   .PUSH1, 0x09,   .SSTORE,
        .PUSH1, 0x2a,   .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH2, 0x56,   0x78,
        .GAS,   .CALL,  .POP,   .STOP,
    });

    var runtime = ReentrantRuntime{ .child = child };
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract_runtime = runtime.service(),
    });
    defer executor.deinit();

    var parent_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try parent_account.setCode(&parent_code);
    try executor.state.seedAccount(parent, parent_account);
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&child_code);
    try executor.state.seedAccount(child, child_account);

    const result = (try executor.executeStandalone(request(sender, parent, &.{}), .{}));

    try std.testing.expect(runtime.called);
    try std.testing.expectEqual(Latest.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(parent, 0));
    try std.testing.expectEqual(@as(u256, 0x77), try executor.getStorage(child, 9));
    try std.testing.expect(executor.frame_store.maxStackBase() >= 600);
    try std.testing.expect(executor.frame_store.maxStackWordCount() >= 600 + 1024);
    try std.testing.expect(executor.frame_store.maxRowCount() > 8);
}

fn request(sender: evmz.Address, recipient: evmz.Address, input: []const u8) evmz.execution.ExecutionRequest {
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
        .gas = .{
            .regular_left = 100_000,
            .reservoir = @intCast(4 * Latest.spec.storage.sstoreStateGas(.added).charge),
        },
    };
}
