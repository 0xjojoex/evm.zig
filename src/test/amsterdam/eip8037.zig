const std = @import("std");
const evmz = @import("../../evm.zig");

const MemoryAccount = evmz.state.MemoryAccount;
const Address = evmz.Address;
const Executor = evmz.Evm.Executor;
const Interpreter = evmz.interpreter;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;
const eth_tx = evmz.eth.transaction;

test "Amsterdam authorization policy charges the first authority write" {
    const adjustment = evmz.Evm.specification.authorization.successGasAdjustment(.{
        .account_exists = true,
        .account_already_written = false,
        .clears_delegation = false,
        .delegated_before_transaction = true,
        .delegation_set_before = false,
    });

    try std.testing.expectEqual(@as(u64, 0), adjustment.account_state_charge);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), adjustment.account_write_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.delegation_state_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.regular_refund);
}

test "Amsterdam authorization policy charges a newly-created authority leaf" {
    const adjustment = evmz.Evm.specification.authorization.successGasAdjustment(.{
        .account_exists = false,
        .account_already_written = false,
        .clears_delegation = true,
        .delegated_before_transaction = false,
        .delegation_set_before = false,
    });

    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_new_account_state_gas), adjustment.account_state_charge);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), adjustment.account_write_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.delegation_state_charge);
}

test "Amsterdam authorization policy charges create then clear only once" {
    var adjustment = evmz.Evm.specification.authorization.successGasAdjustment(.{
        .account_exists = false,
        .account_already_written = false,
        .clears_delegation = false,
        .delegated_before_transaction = false,
        .delegation_set_before = false,
    });
    adjustment.add(evmz.Evm.specification.authorization.successGasAdjustment(.{
        .account_exists = true,
        .account_already_written = true,
        .clears_delegation = true,
        .delegated_before_transaction = false,
        .delegation_set_before = true,
    }));

    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_new_account_state_gas), adjustment.account_state_charge);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), adjustment.account_write_charge);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_auth_base_state_gas), adjustment.delegation_state_charge);
}

test "Amsterdam invalid authorization policy has no runtime charge" {
    const adjustment = evmz.Evm.specification.authorization.invalid_gas_adjustment;

    try std.testing.expectEqual(@as(u64, 0), adjustment.account_state_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.account_write_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.delegation_state_charge);
    try std.testing.expectEqual(@as(u64, 0), adjustment.regular_refund);
}

test "Amsterdam transaction program applies EIP-7702 authorization" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    var tx_context = testTxContext(sender, 300_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    const authority_account = MemoryAccount.init(std.testing.allocator);
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
        .env = .{ .gas_limit = 300_000, .coinbase = tx_context.coinbase },
        .tx = .{
            .kind = .set_code,
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .max_fee_per_gas = tx_context.gas_price,
            .max_priority_fee_per_gas = 0,
            .authorization_list = &authorization_list,
        },
    }));
    defer executed.discardIfCurrent();
    try std.testing.expectEqual(evmz.TxStatus.success, executed.result().status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqualSlices(u8, &target, &eip7702.delegationTarget(try executor.getCode(authority)).?);
}

test "Amsterdam CREATE collision with alive target skips state charge before child gas" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 1);
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.nonce = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var create_account = MemoryAccount.init(std.testing.allocator);
    create_account.nonce = 1;
    try executor.state.seedAccount(create_address, create_account);

    try executor.beginTransaction(testTxContext(sender, 300_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_spent);
    try std.testing.expectEqual(@as(u64, 2), executor.getAccount(contract).?.nonce);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(create_address).?.nonce);
}

test "Amsterdam CREATE to pre-existing account leaves state reservoir available" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 1);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .CREATE, .POP,
        .PUSH1, 0x01,   .PUSH0, .SSTORE, .STOP,
    });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.nonce = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    var create_account = MemoryAccount.init(std.testing.allocator);
    create_account.balance = 1;
    try executor.state.seedAccount(create_address, create_account);

    try executor.beginTransaction(testTxContext(sender, 300_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 50_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u64, 2), executor.getAccount(contract).?.nonce);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(create_address).?.nonce);
}

test "Amsterdam nested CREATE records its target before state-charge OOG" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .PUSH0, .CREATE, .STOP });
    var observations = AccountObservation{ .address = create_address };
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginObservedTransaction(testTxContext(sender, 100_000), sender, contract);
    defer executor.closeTransaction();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = eth_tx.amsterdam_new_account_state_gas - 1,
    }, 0);
    try executor.closeTransactionObserved(&observations);

    try std.testing.expectEqual(Interpreter.Status.out_of_gas, result.status);
    try std.testing.expect(observations.found);
}

test "Amsterdam root CREATE records and charges a storage-only target before collision" {
    const sender = evmz.addr(0xaaaa);
    const create_address = evmz.address.create(sender, 0);
    var observations = AccountObservation{ .address = create_address };
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var target_account = MemoryAccount.init(std.testing.allocator);
    try target_account.storage.put(1, 1);
    try executor.state.seedAccount(create_address, target_account);

    const message = evmz.execution.Message{ .create = .{
        .sender = sender,
        .recipient = create_address,
        .init_code = &.{},
    } };
    const context = (evmz.Env{ .gas_limit = 1_000_000 }).executionContext(sender, 0, &.{});
    const request = transaction.executionRequest(context, message, .{
        .regular_left = eth_tx.amsterdam_new_account_state_gas - 1,
    });
    try executor.beginObservedMessageScope(request, .{});
    defer executor.closeTransaction();
    const outcome = try executor.executeTransactionRequestPhased(request);
    try executor.closeTransactionObserved(&observations);

    try std.testing.expectEqual(evmz.executor.TransactionExecutionStage.preparation, outcome.stage);
    try std.testing.expectEqual(Interpreter.Status.out_of_gas, outcome.result.status);
    try std.testing.expect(observations.found);
}

test "Amsterdam value CALL to new account keeps debited state reservoir" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xc0c0);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH1, 0x01, .PUSH2, 0xc0, 0xc0, .PUSH2, 0x27, 0x10, .CALL,
        .STOP,
    });
    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 300_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .{
        .regular_left = 100_000,
        .reservoir = evmz.eth.transaction.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.state_gas_spent);
    try std.testing.expectEqual(@as(u256, 1), executor.getAccount(recipient).?.balance);
}

test "Amsterdam CREATE opcode accepts max initcode size" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 0);
    const code = evmz.t.bytecode(.{
        .CALLDATASIZE, .PUSH0, .PUSH0, .CALLDATACOPY,
        .CALLDATASIZE, .PUSH0, .PUSH0, .CREATE,
        .STOP,
    });
    const input = try std.testing.allocator.alloc(u8, eth_tx.amsterdam_max_initcode_size);
    defer std.testing.allocator.free(input);
    @memset(input, 0);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var sender_account = MemoryAccount.init(std.testing.allocator);
    sender_account.balance = 10_000_000;
    try executor.state.seedAccount(sender, sender_account);

    var contract_account = MemoryAccount.init(std.testing.allocator);
    try contract_account.setCode(&code);
    try executor.state.seedAccount(contract, contract_account);

    try executor.beginTransaction(testTxContext(sender, 5_000_000), sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, input, .{
        .regular_left = 5_000_000,
        .reservoir = eth_tx.amsterdam_new_account_state_gas,
    }, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(contract).?.nonce);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(create_address).?.nonce);
}

const testTxContext = evmz.t.defaultTxContext;

const AccountObservation = struct {
    address: Address,
    found: bool = false,

    pub fn observe(
        self: *@This(),
        pending: evmz.state.TrackedState.PendingView,
    ) !void {
        const accounts = pending.observations().accounts;
        var index: u32 = 0;
        while (index < accounts.len()) : (index += 1) {
            const fact = accounts.at(index);
            if (std.mem.eql(u8, &fact.address, &self.address)) {
                try std.testing.expect(fact.observation.semantic_access);
                self.found = true;
                return;
            }
        }
    }
};

fn expectExecuted(outcome: evmz.Evm.Outcome) !evmz.Evm.Executed {
    return switch (outcome) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}
