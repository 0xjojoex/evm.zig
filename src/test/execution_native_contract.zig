const std = @import("std");
const evmz = @import("../evm.zig");

const execution = evmz.execution;

const StatefulRuntime = struct {
    tx_kind: u8,
    status: execution.Status = .success,
    service_error: ?anyerror = null,

    fn execute(self: *StatefulRuntime, ctx: anytype, call: execution.NativeContractCall) !execution.NativeContractStep {
        if (self.service_error) |err| return err;
        _ = try ctx.setStorage(call.message.recipient, 7, self.tx_kind);
        _ = call.ledger.trackGas(9);
        const output = try call.allocator.alloc(u8, 1);
        output[0] = self.tx_kind;
        return .{ .done = .{ .status = self.status, .output_data = output } };
    }
};

/// Calls `child` with all remaining gas and reports the child's status.
const ReentrantRuntime = struct {
    child: evmz.Address,
    called: bool = false,

    fn execute(self: *ReentrantRuntime, _: anytype, call: execution.NativeContractCall) !execution.NativeContractStep {
        if (call.child) |child| {
            self.called = true;
            return .{ .done = .{ .status = child.status() } };
        }
        return .{ .call = .{
            .kind = .call,
            .recipient = self.child,
            .code_address = self.child,
            .sender = call.message.recipient,
            .gas = call.ledger.gas_left,
        } };
    }
};

/// The outer activation calls itself; each returns one marker byte.
const ReentrantOutputRuntime = struct {
    fn execute(_: *ReentrantOutputRuntime, _: anytype, call: execution.NativeContractCall) !execution.NativeContractStep {
        const outer = call.message.input_data.len == 0;
        if (outer and call.child == null) return .{ .call = .{
            .kind = .call,
            .recipient = call.message.recipient,
            .code_address = call.message.code_address,
            .sender = call.message.recipient,
            .input_data = &.{0x01},
            .gas = call.ledger.gas_left,
        } };
        if (call.child) |nested| try std.testing.expectEqualSlices(u8, &.{0xbb}, nested.output_data);
        return .{ .done = .{ .output_data = try call.allocator.dupe(u8, &.{if (outer) 0xaa else 0xbb}) } };
    }
};

/// Each test binds one runtime; they share one executor instantiation.
const StatefulNativeContract = union(enum) {
    stateful: *StatefulRuntime,
    reentrant: *ReentrantRuntime,
    reentrant_output: *ReentrantOutputRuntime,

    const target = evmz.addr(0x1234);

    pub fn active(address: evmz.Address) bool {
        return evmz.Address.eql(address, target);
    }

    pub fn execute(self: *StatefulNativeContract, ctx: anytype, call: execution.NativeContractCall) !execution.NativeContractStep {
        return switch (self.*) {
            inline else => |runtime| runtime.execute(ctx, call),
        };
    }
};

const Latest = evmz.t.CustomVm(.latest, .{ .native_contract = StatefulNativeContract }).?;

test "active native contract requires an embedding instance" {
    const sender = evmz.addr(0xaaaa);
    var executor = Latest.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try std.testing.expectError(
        error.MissingNativeContract,
        executor.executeStandalone(request(sender, StatefulNativeContract.target, &.{}), .{}),
    );
}

test "native contract can use host state and keeps EVM rollback semantics" {
    const sender = evmz.addr(0xaaaa);
    var runtime = StatefulRuntime{ .tx_kind = 0x7e };
    var native: StatefulNativeContract = .{ .stateful = &runtime };
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract = &native,
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

test "executor construction selects the supplied native contract instance" {
    const sender = evmz.addr(0xaaaa);
    var first_runtime = StatefulRuntime{ .tx_kind = 0x11 };
    var first_native: StatefulNativeContract = .{ .stateful = &first_runtime };
    var first_executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract = &first_native,
    });
    defer first_executor.deinit();

    const first = (try first_executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqualSlices(u8, &.{0x11}, first.output_data);

    var second_runtime = StatefulRuntime{ .tx_kind = 0x22 };
    var second_native: StatefulNativeContract = .{ .stateful = &second_runtime };
    var second_executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract = &second_native,
    });
    defer second_executor.deinit();

    const second = (try second_executor.executeStandalone(
        request(sender, StatefulNativeContract.target, &.{}),
        .{},
    ));
    try std.testing.expectEqualSlices(u8, &.{0x22}, second.output_data);
}

test "native contract output survives self reentry" {
    const sender = evmz.addr(0xaaaa);
    var runtime = ReentrantOutputRuntime{};
    var native: StatefulNativeContract = .{ .reentrant_output = &runtime };
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract = &native,
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
    var native: StatefulNativeContract = .{ .reentrant = &runtime };
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .native_contract = &native,
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
