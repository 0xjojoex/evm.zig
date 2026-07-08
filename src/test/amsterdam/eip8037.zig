const std = @import("std");
const evmz = @import("../../evm.zig");

const AccountState = evmz.state.Account;
const Address = evmz.Address;
const EthProtocol = evmz.EthProtocol;
const Executor = evmz.Executor(EthProtocol);
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const RootFrame = Executor.RootFrame;
const eip7702 = evmz.eip7702;
const transaction = evmz.transaction;
const tx_protocol = transaction.For(EthProtocol);
const eth_tx = evmz.eth.transaction;

test "Amsterdam existing delegated EIP-7702 authority refills auth base state gas" {
    const sender = evmz.addr(0xaaaa);
    const authority = evmz.addr(0xbbbb);
    const old_target = evmz.addr(0xcccc);
    const new_target = evmz.addr(0xdddd);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var code: [eip7702.delegation_code_len]u8 = undefined;
    eip7702.writeDelegationCode(&code, old_target);
    var authority_account = AccountState.init(std.testing.allocator);
    try authority_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(authority, authority_account);

    try executor.beginTransaction(tx_context, sender, new_target);
    defer executor.closeTransaction();

    const refund = try executor.applyAuthorizationTuple(.{
        .chain_id = 0,
        .target = new_target,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    });

    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), refund.regular_refund);
    try std.testing.expectEqual(
        @as(u64, eth_tx.amsterdam_new_account_state_gas + eth_tx.amsterdam_auth_base_state_gas),
        refund.state_refund,
    );
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqualSlices(u8, &new_target, &eip7702.delegationTarget(executor.getAccount(authority).?.code).?);
}

test "Amsterdam clearing EIP-7702 authority refills auth base state gas" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    try executor.beginTransaction(tx_context, sender, recipient);
    defer executor.closeTransaction();

    const refund = try executor.applyAuthorizationTuple(.{
        .chain_id = 0,
        .target = evmz.address.zero_address,
        .signer = authority,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    });

    try std.testing.expectEqual(@as(u64, 0), refund.regular_refund);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_auth_base_state_gas), refund.state_refund);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqual(@as(usize, 0), executor.getAccount(authority).?.code.len);
}

test "Amsterdam create then clear EIP-7702 authority refills auth base twice" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    try executor.beginTransaction(tx_context, sender, recipient);
    defer executor.closeTransaction();

    const authorization_list = [_]transaction.AuthorizationTuple{
        .{
            .chain_id = 0,
            .target = target,
            .signer = authority,
            .nonce = 0,
            .y_parity = 0,
            .legacy_v = null,
            .r = 1,
            .s = 1,
        },
        .{
            .chain_id = 0,
            .target = evmz.address.zero_address,
            .signer = authority,
            .nonce = 1,
            .y_parity = 0,
            .legacy_v = null,
            .r = 1,
            .s = 1,
        },
    };

    const refund = try executor.applyAuthorizationList(&authorization_list);

    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), refund.regular_refund);
    try std.testing.expectEqual(
        @as(u64, eth_tx.amsterdam_new_account_state_gas + 2 * eth_tx.amsterdam_auth_base_state_gas),
        refund.state_refund,
    );
    try std.testing.expectEqual(@as(u64, 2), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqual(@as(usize, 0), executor.getAccount(authority).?.code.len);
}

test "Amsterdam invalid EIP-7702 authorization refills intrinsic auth gas" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    const tx_context = testTxContext(sender, 100_000);
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var authority_account = AccountState.init(std.testing.allocator);
    authority_account.nonce = std.math.maxInt(u64);
    try executor.state.accounts.put(authority, authority_account);

    try executor.beginTransaction(tx_context, sender, recipient);
    defer executor.closeTransaction();

    const refund = try executor.applyAuthorizationTuple(.{
        .chain_id = 0,
        .target = target,
        .signer = authority,
        .nonce = std.math.maxInt(u64),
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    });

    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_account_write_cost), refund.regular_refund);
    try std.testing.expectEqual(@as(u64, eth_tx.amsterdam_authorization_state_gas), refund.state_refund);
    try std.testing.expect(!executor.state.warm_accounts.contains(authority));
    try std.testing.expectEqual(std.math.maxInt(u64), executor.getAccount(authority).?.nonce);
    try std.testing.expectEqual(@as(usize, 0), executor.getAccount(authority).?.code.len);
}

test "Amsterdam existing EIP-7702 authority refills state gas reservoir" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const authority = evmz.addr(0xcccc);
    const target = evmz.addr(0xdddd);
    var tx_context = testTxContext(sender, 300_000);
    tx_context.gas_price = 1;
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const authority_account = AccountState.init(std.testing.allocator);
    try executor.state.accounts.put(authority, authority_account);

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
    const root = RootFrame{ .call = .{
        .sender = sender,
        .recipient = recipient,
        .gas_limit = 300_000,
    } };
    const scope = Executor.transactionScope(tx_context, .{
        .authorization_list = &authorization_list,
    });
    const gas_plan = tx_protocol.gas.gasPlan(.amsterdam, &.{}, root.gasLimit(), .{ .authorization_count = 1 });

    const CheckingEngine = struct {
        fn execute(
            ptr: ?*anyopaque,
            inner: *Executor,
            engine_root: RootFrame,
            gas: transaction.ExecutionGas,
        ) !Interpreter.Result {
            _ = ptr;
            _ = inner;
            _ = engine_root;
            try std.testing.expectEqual(@as(u64, 50_394), gas.regular_left);
            try std.testing.expectEqual(@as(u64, evmz.eth.transaction.amsterdam_new_account_state_gas), gas.reservoir);
            return .{
                .status = .success,
                .gas_left = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_refund = 0,
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .state_gas_spent = 0,
                .output_data = &.{},
            };
        }
    };

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
    }, .{ .execute = CheckingEngine.execute });

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, eth_tx.amsterdam_account_write_cost), result.gas_refund);
    try std.testing.expectEqual(@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.gas_reservoir);
    try std.testing.expectEqual(-@as(i64, evmz.eth.transaction.amsterdam_new_account_state_gas), result.state_gas_spent);
}

test "Amsterdam CREATE to pre-existing account refills parent state gas" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const create_address = evmz.address.create(contract, 1);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .CREATE, .POP,
        .PUSH1, 0x01,   .PUSH0, .SSTORE, .STOP,
    });
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.nonce = 1;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var create_account = AccountState.init(std.testing.allocator);
    create_account.balance = 1;
    try executor.state.accounts.put(create_address, create_account);

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

test "Amsterdam value CALL to new account keeps debited state reservoir" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    const recipient = evmz.addr(0xc0c0);
    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH1, 0x01, .PUSH2, 0xc0, 0xc0, .PUSH2, 0x27, 0x10, .CALL,
        .STOP,
    });
    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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

    var executor = Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
    });
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 10_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    try contract_account.setCode(std.testing.allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

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
