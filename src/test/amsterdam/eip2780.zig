const std = @import("std");
const evmz = @import("../../evm.zig");

const MemoryAccount = evmz.state.MemoryAccount;
const Address = evmz.Address;
const Executor = evmz.Evm.Executor;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;
const Gas = transaction.GasRuntime(
    evmz.Evm.TransactionProtocol,
    @FieldType(evmz.Evm.TransactionPolicy, "transaction"),
);
const gas = Gas{ .transaction = &evmz.Evm.transaction_policy.transaction };

test "Amsterdam value-to-empty account state gas is charged at top frame" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try executor.beginTransaction(testTxContext(sender, 300_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = evmz.eth.transaction.amsterdam_new_account_state_gas - 1,
    }, 1);

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
    try std.testing.expect(!try executor.state.accountExists(recipient));
}

test "Amsterdam value-to-empty account state gas is not intrinsic" {
    try std.testing.expectEqual(@as(u64, 21_000), gas.intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .value = 1,
        .creates_account = true,
    }));

    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const message = evmz.execution.Message{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .value = 1,
    } };
    const gas_plan = gas.gasPlan(.amsterdam, &.{}, 21_000, .{
        .value = message.value(),
        .creates_account = true,
    });

    try std.testing.expect(gas_plan.execution != null);
}

test "Amsterdam top-frame value-to-empty account spends state gas on success" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    try executor.beginTransaction(testTxContext(sender, 300_000), sender, recipient);
    const result = try executor.executeCallTransaction(sender, recipient, &.{}, .{
        .regular_left = 50_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 1);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.state_gas_spent);
    try std.testing.expectEqual(@as(u256, 1), executor.getAccount(recipient).?.balance);
}

test "Amsterdam authorization-installed recipient suppresses top-frame new-account state gas" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    var tx_context = testTxContext(sender, 300_000);
    tx_context.gas_price = 1;
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = target,
        .signer = recipient,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    var vm = evmz.Evm.init(&executor);
    const executed = try expectExecuted(try vm.transact(.{
        .env = .{ .gas_limit = 300_000, .coinbase = tx_context.coinbase },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .max_fee_per_gas = tx_context.gas_price,
            .max_priority_fee_per_gas = 0,
            .value = 1,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    const result = try executed.result();

    try std.testing.expectEqual(evmz.TxStatus.success, result.status);
    // The authorization itself creates state, but the value transfer does not
    // charge a second new-account slice after installing the delegation.
    try std.testing.expectEqual(
        @as(u64, evmz.eth.transaction.amsterdam_authorization_state_gas),
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

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    var vm = evmz.Evm.init(&executor);
    const executed = try expectExecuted(try vm.transact(.{
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
    const result = try executed.result();

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

    var authority_account = MemoryAccount.init(std.testing.allocator);
    authority_account.balance = 1;
    try executor.state.seedAccount(authority, authority_account);

    const authorization_list = [_]transaction.AuthorizationTuple{.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    }};
    var vm = evmz.Evm.init(&executor);
    const executed = try expectExecuted(try vm.transact(.{
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
    const result = try executed.result();

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
    var authority_account = MemoryAccount.init(std.testing.allocator);
    try authority_account.setCode(&delegation_code);
    try executor.state.seedAccount(authority, authority_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, authority);
    try executor.state.warmAccount(target);
    const result = try executor.executeCallTransaction(sender, authority, &.{}, .{
        .regular_left = 10_000,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 9_900), result.gas_left);
}

fn executorWithSender(sender: Address, balance: u256) !Executor {
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = balance;
    try executor.state.seedAccount(sender, sender_account);
    return executor;
}

fn expectExecuted(outcome: evmz.Evm.Outcome) !evmz.Evm.Executed {
    return switch (outcome) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}

const testTxContext = evmz.t.defaultTxContext;
