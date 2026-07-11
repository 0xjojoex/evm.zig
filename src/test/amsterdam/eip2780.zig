const std = @import("std");
const evmz = @import("../../evm.zig");

const AccountState = evmz.state.Account;
const Address = evmz.Address;
const EthProtocol = evmz.Evm.Protocol;
const Executor = evmz.Executor;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const RootFrame = Executor.RootFrame;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;
const tx_protocol = transaction.For(EthProtocol);

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
    try std.testing.expectEqual(@as(u64, 21_000), tx_protocol.gas.intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .value = 1,
        .creates_account = true,
    }));

    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const root = RootFrame{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 21_000,
        .value = 1,
    } };
    const gas_plan = tx_protocol.gas.gasPlan(.amsterdam, &.{}, root.gasLimit(), .{
        .value = root.value(),
        .creates_account = true,
    });

    try std.testing.expect(gas_plan.execution != null);
    try std.testing.expectEqual(@as(u64, 0), gas_plan.intrinsic_state_gas);
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

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{evmz.Opcode.STOP.toByte()});
    try executor.state.accounts.put(target, target_account);

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
    const root = RootFrame{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 300_000,
        .value = 1,
    } };
    const scope = Executor.transactionScope(tx_context, .{
        .authorization_list = &authorization_list,
    });
    const gas_plan = tx_protocol.gas.gasPlan(.amsterdam, &.{}, root.gasLimit(), .{
        .authorization_count = authorization_list.len,
        .value = root.value(),
        .creates_account = true,
    });

    try executor.beginTransactionScope(scope, root);
    const result = try executor.runTopLevelTransactionWithEngine(scope, root, .{
        .execution = gas_plan.execution,
        .settlement = tx_protocol.settlement.settlementFromGasPlan(.amsterdam, root.gasLimit(), gas_plan, .{
            .gas_price = tx_context.gas_price,
            .priority_fee = 0,
            .coinbase = tx_context.coinbase,
            .payer = sender,
            .value = root.value(),
        }),
    }, .{ .execute = ExecuteTx.execute });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(u256, 1), executor.getAccount(recipient).?.balance);
}

test "Amsterdam top-frame delegated target charges cold even when warm" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    var executor = try executorWithSender(sender, 1_000_000);
    defer executor.deinit();

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    var authority_account = AccountState.init(std.testing.allocator);
    try authority_account.setCode(std.testing.allocator, &delegation_code);
    try executor.state.accounts.put(authority, authority_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{evmz.Opcode.STOP.toByte()});
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, authority);
    try executor.state.warmAccount(target);
    const result = try executor.executeCallTransaction(sender, authority, &.{}, .{
        .regular_left = 10_000,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 7_000), result.gas_left);
}

const ExecuteTx = struct {
    fn execute(
        ptr: ?*anyopaque,
        inner: *Executor,
        engine_root: RootFrame,
        gas: transaction.ExecutionGas,
    ) !Interpreter.Result {
        _ = ptr;
        return inner.executeTransactionMessage(engine_root, gas);
    }
};

fn executorWithSender(sender: Address, balance: u256) !Executor {
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = balance;
    try executor.state.accounts.put(sender, sender_account);
    return executor;
}

const testTxContext = evmz.t.defaultTxContext;
