const std = @import("std");
const evmz = @import("../../evm.zig");

const MemoryAccount = evmz.state.MemoryAccount;
const Address = evmz.Address;
const Executor = evmz.Evm.Executor;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;

test "Amsterdam cold BALANCE and EXTCODE opcodes charge 3000 total account access gas" {
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
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.nonce = std.math.maxInt(u64);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{ .regular_left = 100_000, .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(!executor.state.warm_accounts.contains(create_address));
}

test "Amsterdam SELFDESTRUCT to alive beneficiary charges no account write" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const beneficiary = evmz.addr(0xcccc);
    const code = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, .SELFDESTRUCT });
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var beneficiary_account = MemoryAccount.init(std.testing.allocator);
    beneficiary_account.balance = 1;
    try executor.state.seedAccount(beneficiary, beneficiary_account);

    try executor.beginTransaction(testTxContext(sender, 100_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(20_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 11_997), result.gas_left);
    try std.testing.expectEqual(@as(u256, 2), executor.getAccount(beneficiary).?.balance);
}

test "Amsterdam top-level create to alive target skips new-account state gas" {
    const sender = evmz.addr(0xaaaa);
    const create_address = evmz.address.create(sender, 0);
    const init_code = evmz.t.bytecode(.{ .ADDRESS, .SELFDESTRUCT });
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    target_account.balance = 1;
    try executor.state.seedAccount(create_address, target_account);

    const message = evmz.execution.Message{ .create = .{
        .sender = sender,
        .recipient = create_address,
        .init_code = &init_code,
    } };

    const context = (evmz.Env{ .gas_limit = 1_000_000 }).executionContext(sender, 0, &.{});
    const request = transaction.executionRequest(context, message, .legacy(100_000));
    try executor.beginMessageScope(request, .{});
    defer executor.closeTransaction();
    const result = try executor.executeTransactionRequest(request);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
}

test "Amsterdam created contract selfdestruct clears code and keeps account at commit" {
    const sender = evmz.addr(0xaaaa);
    const create_address = evmz.address.create(sender, 0);
    const init_code = evmz.t.bytecode(.{ .ADDRESS, .SELFDESTRUCT });
    const tx_context = testTxContext(sender, 1_000_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 10_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var vm = evmz.Evm.init(&executor);
    const executed = try expectExecuted(try vm.transact(.{
        .env = .{ .gas_limit = 1_000_000, .coinbase = tx_context.coinbase },
        .tx = .{
            .sender = sender,
            .gas_limit = 1_000_000,
            .input = &init_code,
        },
    }));
    defer executed.discardIfCurrent();
    try std.testing.expectEqual(evmz.TxStatus.success, (try executed.result()).status);
    const account = executor.getAccount(create_address).?;
    try std.testing.expectEqual(@as(u64, 0), account.nonce);
    try std.testing.expectEqual(@as(u256, 0), account.balance);
    try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(create_address)).len);
}

test "Amsterdam transaction program installs delegation before top-level call" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    var tx_context = testTxContext(sender, 300_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

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
        .env = .{ .gas_limit = 300_000, .coinbase = tx_context.coinbase },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = authority,
            .gas_limit = 300_000,
            .max_fee_per_gas = tx_context.gas_price,
            .max_priority_fee_per_gas = 0,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    try std.testing.expectEqual(evmz.TxStatus.success, (try executed.result()).status);
    try std.testing.expectEqualSlices(u8, &target, &eip7702.delegationTarget(try executor.getCode(authority)).?);
}

test "Amsterdam top-level delegated call charges cold target access" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const target = evmz.addr(0xcccc);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var delegation_code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&delegation_code, target);
    var authority_account = MemoryAccount.init(std.testing.allocator);
    try authority_account.setCode(&delegation_code);
    try executor.state.seedAccount(authority, authority_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.setCode(&.{evmz.Opcode.STOP.toByte()});
    try executor.state.seedAccount(target, target_account);

    try executor.beginTransaction(tx_context, sender, authority);
    const result = try executor.executeCallTransaction(sender, authority, &.{}, .legacy(10_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 7_000), result.gas_left);
}

fn expectAmsterdamColdAccountAccessGas(comptime opcode: evmz.Opcode) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 10_000;
    const bytecode = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, opcode, .STOP });

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &bytecode,
        .revision = .amsterdam,
    });
    defer frame.deinit();

    var interpreter = frame.interpreter();
    const result = try interpreter.execute();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 6_997), result.gas_left);
}

fn expectAmsterdamCodeAccessGas(comptime opcode: evmz.Opcode, status: Host.AccessStatus) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    const target = evmz.addr(0xcccc);
    if (status == .warm) {
        try mock_host.local_account.put(target, .{ .balance = 0 });
    }
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 10_000;
    const bytecode = evmz.t.bytecode(.{ .PUSH2, 0xcc, 0xcc, opcode, .STOP });

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &bytecode,
        .revision = .amsterdam,
    });
    defer frame.deinit();

    var interpreter = frame.interpreter();
    const result = try interpreter.execute();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    const expected_gas_left: i64 = switch (status) {
        .cold => 6_897,
        .warm => 9_797,
    };
    try std.testing.expectEqual(expected_gas_left, result.gas_left);
}

fn expectAmsterdamExtcodecopyAccessGas(status: Host.AccessStatus) !void {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    const target = evmz.addr(0xcccc);
    if (status == .warm) {
        try mock_host.local_account.put(target, .{ .balance = 0 });
    }
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    msg.gas = 10_000;
    const bytecode = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH2, 0xcc, 0xcc, .EXTCODECOPY, .STOP,
    });

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &bytecode,
        .revision = .amsterdam,
    });
    defer frame.deinit();

    var interpreter = frame.interpreter();
    const result = try interpreter.execute();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    const expected_gas_left: i64 = switch (status) {
        .cold => 6_891,
        .warm => 9_791,
    };
    try std.testing.expectEqual(expected_gas_left, result.gas_left);
}

const testTxContext = evmz.t.defaultTxContext;

fn expectExecuted(outcome: evmz.Evm.Outcome) !evmz.Evm.Executed {
    return switch (outcome) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}
