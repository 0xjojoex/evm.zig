const std = @import("std");
const evmz = @import("../../evm.zig");

const Address = evmz.Address;
const Executor = evmz.Evm.Executor;
const Interpreter = evmz.interpreter;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;

test "EIP-2780 transaction reference cases have decomposed intrinsic gas" {
    const AmsterdamGas = transaction.GasRuntime(evmz.eth.amsterdam);
    const cases = [_]struct {
        name: []const u8,
        options: transaction.IntrinsicGasOptions,
        expected: u64,
    }{
        .{ .name = "ETH transfer to self", .options = .{ .value = 1, .is_self_transfer = true }, .expected = 12_000 },
        .{ .name = "no-transfer to EOA", .options = .{}, .expected = 15_000 },
        .{ .name = "no-transfer to contract", .options = .{}, .expected = 15_000 },
        .{ .name = "ETH transfer to existing EOA", .options = .{ .value = 1 }, .expected = 21_000 },
        .{ .name = "ETH transfer to contract", .options = .{ .value = 1 }, .expected = 21_000 },
        .{ .name = "no-transfer to delegated account", .options = .{}, .expected = 15_000 },
        .{ .name = "ETH transfer to delegated account", .options = .{ .value = 1 }, .expected = 21_000 },
        .{ .name = "ETH transfer to self with delegated sender", .options = .{ .value = 1, .is_self_transfer = true }, .expected = 12_000 },
        .{ .name = "ETH transfer creating new account", .options = .{ .value = 1, .creates_account = true }, .expected = 21_000 },
        .{ .name = "create without value", .options = .{ .is_create = true, .creates_account = true }, .expected = 24_000 },
        .{ .name = "create with value", .options = .{ .is_create = true, .value = 1, .creates_account = true }, .expected = 24_000 },
        .{ .name = "create over pre-existing balance", .options = .{ .is_create = true, .value = 1 }, .expected = 24_000 },
    };

    const gas = AmsterdamGas{};
    for (cases) |case| {
        std.testing.expectEqual(
            case.expected,
            gas.intrinsicGasForTransaction(&.{}, case.options),
        ) catch |err| {
            std.debug.print("EIP-2780 reference case failed: {s}\n", .{case.name});
            return err;
        };
    }
}

test "Amsterdam value-to-empty account state gas is charged at top frame" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try executor.beginTransaction(testExecutionContext(sender, 300_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = evmz.eth.eip8037.new_account_state_gas - 1,
    }, 1);

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status());
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam top-frame value-to-empty account spends state gas on success" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try executor.beginTransaction(testExecutionContext(sender, 300_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = 50_000,
        .reservoir = evmz.eth.eip8037.new_account_state_gas,
    }, 1);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, evmz.eth.eip8037.new_account_state_gas), result.state_gas_spent);
    try std.testing.expectEqual(@as(u256, 1), executor.getAccount(recipient).?.balance);
}

test "Amsterdam authorization-installed recipient suppresses top-frame new-account state gas" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    var execution_context = testExecutionContext(sender, 300_000);
    execution_context.transaction.gas_price = 1;
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    const authorization_list = [_]transaction.AuthorizationTuple{evmz.t.testAuthorization(recipient, target)};
    const executed = try evmz.t.expectExecuted(try evmz.Evm.Advanced.transact(&executor, .{
        .env = .{ .gas_limit = 300_000, .coinbase = execution_context.block.coinbase },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .max_fee_per_gas = execution_context.transaction.gas_price,
            .max_priority_fee_per_gas = 0,
            .value = 1,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    const result = executed.result();

    try std.testing.expectEqual(evmz.TxStatus.success, result.status);
    // The authorization itself creates state, but the value transfer does not
    // charge a second new-account slice after installing the delegation.
    try std.testing.expectEqual(
        @as(u64, evmz.eth.eip8037.authorization_state_gas),
        result.gas.block.state,
    );
    try std.testing.expectEqual(@as(u256, 1), executor.getAccount(recipient).?.balance);
}

test "Amsterdam authorization state-gas OOG is included and rolls back authorization" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    const authorization_list = [_]transaction.AuthorizationTuple{evmz.t.testAuthorization(authority, target)};
    const executed = try evmz.t.expectExecuted(try evmz.Evm.Advanced.transact(&executor, .{
        .env = .{ .gas_limit = 300_000 },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = recipient,
            .gas_limit = 30_000,
            .max_fee_per_gas = 1,
            .max_priority_fee_per_gas = 0,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    const result = executed.result();

    try std.testing.expectEqual(evmz.TxStatus.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 30_000), result.gas.used);
    try std.testing.expectEqual(@as(u64, 0), result.gas.block.state);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expect(!try executor.state.accountExists(authority));
}

test "Amsterdam dispatch state-gas OOG rolls back completed authorization" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try evmz.t.seedExecutorAccount(&executor, authority, .{ .balance = 1 });

    const authorization_list = [_]transaction.AuthorizationTuple{evmz.t.testAuthorization(authority, target)};
    const executed = try evmz.t.expectExecuted(try evmz.Evm.Advanced.transact(&executor, .{
        .env = .{ .gas_limit = 300_000 },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = recipient,
            .gas_limit = 200_000,
            .max_fee_per_gas = 1,
            .max_priority_fee_per_gas = 0,
            .value = 1,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    const result = executed.result();

    try std.testing.expectEqual(evmz.TxStatus.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 200_000), result.gas.used);
    try std.testing.expectEqual(@as(u64, 0), result.gas.block.state);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqual(@as(u64, 0), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(authority)).len);
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam top-frame delegated target honors transaction warmth" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    try evmz.t.seedExecutorAccount(&executor, authority, .{ .code = &delegation_code });
    try evmz.t.seedExecutorAccount(&executor, target, .{ .code = &.{evmz.Opcode.STOP.toByte()} });

    try executor.beginTransaction(testExecutionContext(sender, 100_000), sender, authority);
    try executor.state.warmAccount(target);
    const result = try executor.executeCallTransaction(sender, authority, &.{}, .{
        .regular_left = 10_000,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 9_900), result.gas_left);
}

fn executorWithSender(sender: Address, balance: u256) !Executor {
    var executor = Executor.init(std.testing.allocator, .{});
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = balance });
    return executor;
}

const testExecutionContext = evmz.t.defaultExecutionContext;
