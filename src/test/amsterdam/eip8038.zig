const std = @import("std");
const evmz = @import("../../evm.zig");

const Executor = evmz.Evm.Executor;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;

test "Amsterdam cold BALANCE and EXTCODEHASH charge 3000 total account access gas" {
    try expectAmsterdamColdAccountAccessGas(.BALANCE);
    try expectAmsterdamColdAccountAccessGas(.EXTCODEHASH);
}

test "Amsterdam EXTCODESIZE and EXTCODECOPY charge code access gas" {
    try expectAmsterdamCodeAccessGas(.EXTCODESIZE, .cold);
    try expectAmsterdamCodeAccessGas(.EXTCODESIZE, .warm);
    try expectAmsterdamExtcodecopyAccessGas(.cold);
    try expectAmsterdamExtcodecopyAccessGas(.warm);
}

test "Amsterdam nonce-overflow CREATE does not warm aborted address" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, std.math.maxInt(u64));
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedExecutorAccount(&executor, contract, .{
        .nonce = std.math.maxInt(u64),
        .code = &code,
    });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{ .regular_left = 100_000, .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(!executor.state.isAccountWarm(create_address));
}

test "Amsterdam SELFDESTRUCT to alive beneficiary charges no account write" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedExecutorAccount(&executor, contract, .{ .balance = 1, .code = &code });
    try evmz.t.seedExecutorAccount(&executor, beneficiary, .{ .balance = 1 });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(20_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 11_997), result.gas_left);
    try std.testing.expectEqual(@as(u256, 2), executor.getAccount(beneficiary).?.balance);
}

test "Amsterdam top-level create to alive target skips new-account state gas" {
    const sender = evmz.addr(0xaaaa);
    const create_address = evmz.address.create(sender, 0);
    const init_code = evmz.t.bytecode(.{ .ADDRESS, .SELFDESTRUCT });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedExecutorAccount(&executor, create_address, .{ .balance = 1 });

    const message = evmz.execution.Message{ .create = .{
        .sender = sender,
        .recipient = create_address,
        .init_code = &init_code,
    } };

    const context = (evmz.Env{ .gas_limit = 1_000_000 }).executionContext(.{ .origin = sender });
    const request = transaction.executionRequest(context, message, .legacy(100_000));
    try executor.beginMessageScope(request, .{});
    defer executor.discardStateTransition();
    const result = try executor.executeTransactionRequest(request);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
}

test "Amsterdam created contract selfdestruct removes empty account at commit" {
    const sender = evmz.addr(0xaaaa);
    const create_address = evmz.address.create(sender, 0);
    const init_code = evmz.t.bytecode(.{ .ADDRESS, .SELFDESTRUCT });
    const execution_context = testExecutionContext(sender, 1_000_000);
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 10_000_000 });

    var vm = evmz.Evm.init(&executor);
    const executed = try evmz.t.expectExecuted(try vm.transact(.{
        .env = .{ .gas_limit = 1_000_000, .coinbase = execution_context.block.coinbase },
        .tx = .{
            .sender = sender,
            .gas_limit = 1_000_000,
            .input = &init_code,
        },
    }));
    defer executed.discardIfCurrent();
    try std.testing.expectEqual(evmz.TxStatus.success, executed.result().status);
    try std.testing.expect(executor.getAccount(create_address) == null);
    try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(create_address)).len);
}

test "Amsterdam top-level delegated call charges cold target access" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    const execution_context = testExecutionContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });
    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    try executor.beginTransaction(execution_context, sender, authority);
    const result = try executor.executeCallTransaction(sender, authority, &.{}, .legacy(10_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 7_000), result.gas_left);
}

fn expectAmsterdamColdAccountAccessGas(comptime opcode: evmz.Opcode) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 10_000;
    const bytecode = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, opcode, .STOP });

    const result = try evmz.t.runBytecodeWithHost(&host, &msg, &mock_host.execution_context, &bytecode, .amsterdam);
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 6_997), result.gas_left);
}

fn expectAmsterdamCodeAccessGas(comptime opcode: evmz.Opcode, status: evmz.execution.AccessStatus) !void {
    const bytecode = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, opcode, .STOP });
    const expected_gas_left: i64 = switch (status) {
        .cold => 6_897,
        .warm => 9_797,
    };
    try expectAmsterdamAccessGas(&bytecode, status, expected_gas_left);
}

fn expectAmsterdamExtcodecopyAccessGas(status: evmz.execution.AccessStatus) !void {
    const bytecode = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH2, 0xcc, 0xcc, .EXTCODECOPY, .STOP,
    });
    const expected_gas_left: i64 = switch (status) {
        .cold => 6_891,
        .warm => 9_791,
    };
    try expectAmsterdamAccessGas(&bytecode, status, expected_gas_left);
}

fn expectAmsterdamAccessGas(code: []const u8, status: evmz.execution.AccessStatus, expected_gas_left: i64) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    const target = evmz.addr(0xcccc);
    if (status == .warm) {
        try mock_host.local_account.put(target, .{ .balance = 0 });
    }
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 10_000;

    const result = try evmz.t.runBytecodeWithHost(&host, &msg, &mock_host.execution_context, code, .amsterdam);
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected_gas_left, result.gas_left);
}

const testExecutionContext = evmz.t.defaultExecutionContext;
