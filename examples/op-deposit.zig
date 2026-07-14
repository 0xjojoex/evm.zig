//! Downstream-style Regolith-and-later OP deposit composition example.
//!
//! This is not part of the evmz library API and is not a complete OP Stack STF.
//! It demonstrates how an external family can own the `0x7e` wire
//! representation, validation, mint/nonce lifecycle, request normalization,
//! and typed result while reusing the public engine seam. A real OP STF still
//! owns derivation authentication, block ordering and gas-pool accounting,
//! receipts, and sequenced Ethereum transactions.

const std = @import("std");

const evmz = @import("evmz");
const address = evmz.address;
const rlp = evmz.rlp;

const Address = address.Address;
const EthGas = evmz.transaction.For(evmz.Evm.Protocol).gas;
const EthSettlement = evmz.transaction.For(evmz.Evm.Protocol).settlement;

/// EIP-2718 type byte assigned to OP deposited transactions.
pub const type_id: u8 = 0x7e;

/// Borrowed decoded deposited transaction.
///
/// `input` aliases the encoded bytes when produced by `Codec.decode`.
pub const DepositTransaction = struct {
    source_hash: [32]u8,
    from: Address,
    to: ?Address,
    mint: u256 = 0,
    value: u256 = 0,
    gas_limit: u64,
    is_system_transaction: bool = false,
    input: []const u8 = &.{},
};

/// Canonical typed-envelope codec for a deposited transaction.
pub const Codec = struct {
    pub const DecodeError = rlp.ParseError || error{
        InvalidSystemTransactionFlag,
        UnexpectedTypeId,
    };
    pub const EncodeError = rlp.Writer.Error || rlp.Writer.OwnedSliceError;

    pub fn encodeAlloc(allocator: std.mem.Allocator, tx: DepositTransaction) EncodeError![]u8 {
        var fields = rlp.Writer.alloc(allocator);
        defer fields.deinit();
        try fields.bytes(&tx.source_hash);
        try fields.bytes(&tx.from);
        if (tx.to) |to| {
            try fields.bytes(&to);
        } else {
            try fields.bytes(&.{});
        }
        try fields.int(u256, tx.mint);
        try fields.int(u256, tx.value);
        try fields.int(u64, tx.gas_limit);
        try fields.int(u8, @intFromBool(tx.is_system_transaction));
        try fields.bytes(tx.input);

        var envelope = rlp.Writer.alloc(allocator);
        defer envelope.deinit();
        try envelope.listPayload(fields.written());
        const encoded_list = envelope.written();

        const encoded = try allocator.alloc(u8, encoded_list.len + 1);
        errdefer allocator.free(encoded);
        encoded[0] = type_id;
        @memcpy(encoded[1..], encoded_list);
        return encoded;
    }

    pub fn decode(encoded: []const u8) DecodeError!DepositTransaction {
        if (encoded.len == 0) return error.InputTooShort;
        if (encoded[0] != type_id) return error.UnexpectedTypeId;

        var envelope = rlp.Cursor.init(encoded[1..]);
        var fields = try envelope.nextList();
        try envelope.expectDone();

        var source_hash: [32]u8 = undefined;
        @memcpy(&source_hash, try fields.nextBytesExact(source_hash.len));

        var from: Address = undefined;
        @memcpy(&from, try fields.nextBytesExact(from.len));

        const to_bytes = try fields.nextBytes();
        const to: ?Address = switch (to_bytes.len) {
            0 => null,
            @sizeOf(Address) => blk: {
                var recipient: Address = undefined;
                @memcpy(&recipient, to_bytes);
                break :blk recipient;
            },
            else => return error.UnexpectedLength,
        };

        const mint = try fields.nextInt(u256);
        const value = try fields.nextInt(u256);
        const gas_limit = try fields.nextInt(u64);
        const system_flag = try fields.nextInt(u8);
        if (system_flag > 1) return error.InvalidSystemTransactionFlag;
        const input = try fields.nextBytes();
        try fields.expectDone();

        return .{
            .source_hash = source_hash,
            .from = from,
            .to = to,
            .mint = mint,
            .value = value,
            .gas_limit = gas_limit,
            .is_system_transaction = system_flag == 1,
            .input = input,
        };
    }
};

/// Deposit validation performed before family lifecycle writes.
pub const ValidationError = enum {
    /// Regolith disables the legacy unmetered system-transaction flag.
    system_transaction_after_regolith,
};

/// Borrowed execution result for an included deposit.
///
/// `output` remains valid until another executor call replaces its output.
pub const ExecutionResult = struct {
    status: evmz.Interpreter.Status,
    gas: evmz.transaction.ResultGas,
    output: []const u8 = &.{},
    created_address: ?Address = null,
    source_hash: [32]u8,
    /// Sender nonce captured before EVM processing, as required by Regolith.
    deposit_nonce: u64,
};

pub const Result = union(enum) {
    executed: ExecutionResult,
    rejected: ValidationError,
};

/// Concrete family-owned VM facade for OP deposited transactions.
pub const Vm = struct {
    const Self = @This();

    pub const Transaction = DepositTransaction;
    pub const TxResult = Result;
    pub const Block = evmz.execution.BlockEnvironment;
    pub const Engine = evmz.Evm;

    pub const Init = struct {
        revision: evmz.Evm.Revision,
        chain_id: u256,
        state_reader: ?evmz.StateReader = null,
        block_hash_source: ?evmz.BlockHashSource = null,
        config: evmz.ExecutionConfig = .base,
        trace_sink: ?*evmz.trace.Sink = null,
    };

    /// One concrete Ethereum engine and overlay shared by sequenced Ethereum
    /// transactions and family-owned deposit execution.
    engine: Engine,

    pub fn init(allocator: std.mem.Allocator, options: Init) Self {
        return .{
            .engine = Engine.init(allocator, .{
                .revision = options.revision,
                .state_reader = options.state_reader,
                .block_hash_source = options.block_hash_source,
                .env = .{ .chain_id = options.chain_id },
                .config = options.config,
                .trace_sink = options.trace_sink,
            }),
        };
    }

    pub fn deinit(self: *Self) void {
        self.engine.deinit();
    }

    /// Ordinary Ethereum envelopes retain the default concrete API and run on
    /// the same overlay as family deposits.
    pub fn transactEthereum(self: *Self, tx: evmz.Evm.Transaction) !evmz.Evm.TransactResult {
        return self.engine.transact(tx);
    }

    /// Execute one authenticated, derived Regolith-or-later deposit.
    ///
    /// The caller owns the surrounding block gas pool. Engine/infrastructure
    /// errors restore the full transition, including mint. Included EVM
    /// failures preserve mint and one sender-nonce increment.
    pub fn transact(self: *Self, tx: Transaction, block: Block) !TxResult {
        const executor = &self.engine.executor;
        if (executor.hasPendingTransaction()) return error.PendingTransactionActive;
        if (tx.is_system_transaction) {
            return .{ .rejected = .system_transaction_after_regolith };
        }

        var outer = try executor.snapshot();
        defer outer.deinit(executor.allocator);
        executor.traceSnapshotLifecycle(.checkpoint, &outer);
        var outer_open = true;
        errdefer if (outer_open) {
            executor.traceSnapshotLifecycle(.revert, &outer);
            executor.rollbackTransaction(&outer) catch {};
        };

        // OP mint is the post-rollback baseline for all included failures.
        try executor.addBalance(tx.from, tx.mint);
        const sender = try executor.getOrCreateAccount(tx.from);
        const deposit_nonce = sender.nonce;

        const gas_plan = EthGas.gasPlan(executor.revision(), tx.input, tx.gas_limit, .{
            .is_create = tx.to == null,
            .value = tx.value,
            .is_self_transfer = if (tx.to) |to| std.mem.eql(u8, &tx.from, &to) else false,
        });
        const execution_gas = if (canExecute(executor.revision(), tx, gas_plan))
            gas_plan.execution
        else
            null;
        const request = executionRequest(
            self.engine.envContext().chain_id,
            block,
            tx,
            execution_gas orelse evmz.transaction.ExecutionGas.legacy(0),
        );
        try executor.beginMessageScope(request, .{});
        errdefer executor.closeTransaction();

        if (execution_gas == null) {
            try executor.incrementNonce(tx.from);
            const gas = try depositGas(self, tx, block, gas_plan, .{
                .gas_left = 0,
                .gas_refund = 0,
                .gas_reservoir = 0,
                .state_gas_spent = 0,
            });
            try executor.commitTransaction();
            executor.traceSnapshotLifecycle(.commit, &outer);
            outer_open = false;
            return .{ .executed = .{
                .status = .invalid,
                .gas = gas,
                .source_hash = tx.source_hash,
                .deposit_nonce = deposit_nonce,
            } };
        }

        var pre_execution = try executor.checkpoint();
        defer pre_execution.deinit();

        // CREATE derives its address from the current nonce and increments it in
        // the engine. CALL needs the equivalent transaction-level increment here.
        if (tx.to != null) try executor.incrementNonce(tx.from);

        const evm_result = try executor.executeMessage(request.message);
        const status = evm_result.status();
        const created_address = switch (evm_result) {
            .call => null,
            .create => |created| if (status == .success) created.address else null,
        };

        if (status == .success) {
            try pre_execution.commit();
        } else {
            try pre_execution.restore();
            // Restore removes the CALL pre-increment or CREATE runtime increment.
            try executor.incrementNonce(tx.from);
        }

        const gas = try depositGas(self, tx, block, gas_plan, .{
            .gas_left = evm_result.gasLeft(),
            .gas_refund = evm_result.gasRefund(),
            .gas_reservoir = evm_result.gasReservoir(),
            .state_gas_spent = evm_result.stateGasSpent(),
        });
        try executor.commitTransaction();

        executor.traceSnapshotLifecycle(.commit, &outer);
        outer_open = false;
        return .{ .executed = .{
            .status = status,
            .gas = gas,
            .output = evm_result.outputData(),
            .created_address = created_address,
            .source_hash = tx.source_hash,
            .deposit_nonce = deposit_nonce,
        } };
    }

    fn depositGas(
        self: *Self,
        tx: Transaction,
        block: Block,
        gas_plan: evmz.transaction.GasPlan,
        result: evmz.transaction.ExecutionGasResult,
    ) !evmz.transaction.ResultGas {
        const executor = &self.engine.executor;
        const settlement = EthSettlement.defaultPlanFromGasPlan(
            executor.revision(),
            tx.gas_limit,
            gas_plan,
            .{
                .gas_price = 0,
                .priority_fee = 0,
                .fee_recipient = block.coinbase,
                .value = tx.value,
            },
        );
        return EthSettlement.planGas(try EthSettlement.planCosts(settlement, result));
    }
};

fn canExecute(
    revision: evmz.Evm.Revision,
    tx: DepositTransaction,
    gas_plan: evmz.transaction.GasPlan,
) bool {
    if (gas_plan.execution == null) return false;
    if (tx.to == null and tx.input.len > EthGas.maxInitcodeSize(revision)) return false;
    if (evmz.Evm.Protocol.transaction.totalGasLimit(revision)) |limit| {
        if (tx.gas_limit > limit) return false;
    }
    return true;
}

fn executionRequest(
    chain_id: u256,
    block: evmz.execution.BlockEnvironment,
    tx: DepositTransaction,
    gas: evmz.transaction.ExecutionGas,
) evmz.execution.EvmExecutionRequest {
    const message: evmz.execution.Message = if (tx.to) |recipient|
        .{ .call = .{
            .sender = tx.from,
            .recipient = recipient,
            .input = tx.input,
            .gas = gas.regular_left,
            .gas_reservoir = gas.reservoir,
            .value = tx.value,
        } }
    else
        .{ .create = .{
            .sender = tx.from,
            .init_code = tx.input,
            .gas = gas.regular_left,
            .gas_reservoir = gas.reservoir,
            .value = tx.value,
        } };

    return .{
        .context = .{
            .chain = .{ .chain_id = chain_id },
            .block = block,
            .transaction = .{
                .origin = tx.from,
                .gas_price = 0,
            },
        },
        .message = message,
    };
}

fn expectEthereumExecuted(result: evmz.Evm.TransactResult) !evmz.vm.TxExecutionResult {
    return switch (result) {
        .pending => |value| blk: {
            var pending = value;
            defer pending.deinit();
            break :blk try pending.accept();
        },
        .rejected => error.UnexpectedEthereumRejection,
    };
}

pub fn main(init: std.process.Init) !void {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Vm.init(init.gpa, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x11} ** 32,
        .from = sender,
        .to = recipient,
        .mint = 10,
        .value = 3,
        .gas_limit = 100_000,
    }, .{ .gas_limit = 30_000_000 });
    const executed = switch (result) {
        .executed => |value| value,
        .rejected => return error.DepositRejected,
    };

    if (executed.status != .success) return error.DepositExecutionFailed;
    if (try vm.engine.executor.getBalance(sender) != 7) return error.MintLifecycleMismatch;
    if (try vm.engine.executor.getBalance(recipient) != 3) return error.ValueTransferMismatch;

    std.debug.print("deposit status: {s}, nonce: {d}, gas used: {d}\n", .{
        @tagName(executed.status),
        executed.deposit_nonce,
        executed.gas.used,
    });
}

test "deposit codec preserves the exact typed envelope" {
    const tx = DepositTransaction{
        .source_hash = [_]u8{0x11} ** 32,
        .from = address.addr(0xaaaa),
        .to = null,
        .mint = 7,
        .value = 3,
        .gas_limit = 100_000,
        .input = &.{ 0x60, 0x00 },
    };
    const encoded = try Codec.encodeAlloc(std.testing.allocator, tx);
    defer std.testing.allocator.free(encoded);

    try std.testing.expectEqual(type_id, encoded[0]);
    const decoded = try Codec.decode(encoded);
    try std.testing.expectEqualDeep(tx, decoded);
}

test "successful deposit preserves mint and advances nonce" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x22} ** 32,
        .from = sender,
        .to = recipient,
        .mint = 10,
        .value = 3,
        .gas_limit = 100_000,
    }, .{ .gas_limit = 30_000_000 });
    const executed = result.executed;

    try std.testing.expectEqual(evmz.Interpreter.Status.success, executed.status);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try vm.engine.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 7), try vm.engine.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 3), try vm.engine.executor.getBalance(recipient));
}

test "reverted deposit keeps mint and nonce but rolls back EVM writes" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    try vm.engine.executor.state.setCode(recipient, &.{ 0x5f, 0x5f, 0xfd });

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x33} ** 32,
        .from = sender,
        .to = recipient,
        .mint = 10,
        .value = 3,
        .gas_limit = 100_000,
    }, .{ .gas_limit = 30_000_000 });
    const executed = result.executed;

    try std.testing.expectEqual(evmz.Interpreter.Status.revert, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try vm.engine.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10), try vm.engine.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.engine.executor.getBalance(recipient));
}

test "insufficient-value deposit becomes an included failure after mint" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x34} ** 32,
        .from = sender,
        .to = recipient,
        .mint = 2,
        .value = 3,
        .gas_limit = 100_000,
    }, .{ .gas_limit = 30_000_000 });
    const executed = result.executed;

    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try vm.engine.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 2), try vm.engine.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.engine.executor.getBalance(recipient));
}

test "intrinsic-gas failure is included after mint with one nonce increment" {
    const sender = address.addr(0xaaaa);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x44} ** 32,
        .from = sender,
        .to = address.addr(0xbbbb),
        .mint = 5,
        .gas_limit = 20_000,
    }, .{ .gas_limit = 30_000_000 });
    const executed = result.executed;

    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 20_000), executed.gas.used);
    try std.testing.expectEqual(@as(u64, 1), (try vm.engine.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 5), try vm.engine.executor.getBalance(sender));
}

test "create deposit derives address from the pre-execution deposit nonce" {
    const sender = address.addr(0xaaaa);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x45} ** 32,
        .from = sender,
        .to = null,
        .gas_limit = 100_000,
        // PUSH0 PUSH0 RETURN deploys empty runtime code.
        .input = &.{ 0x5f, 0x5f, 0xf3 },
    }, .{ .gas_limit = 30_000_000 });
    const executed = result.executed;

    try std.testing.expectEqual(evmz.Interpreter.Status.success, executed.status);
    try std.testing.expectEqual(address.create(sender, 0), executed.created_address.?);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try vm.engine.executor.getAccountOrLoad(sender)).?.nonce);
}

test "legacy system deposit is rejected before lifecycle writes" {
    const sender = address.addr(0xaaaa);
    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();

    const result = try vm.transact(.{
        .source_hash = [_]u8{0x55} ** 32,
        .from = sender,
        .to = address.addr(0xbbbb),
        .mint = 5,
        .gas_limit = 100_000,
        .is_system_transaction = true,
    }, .{});

    try std.testing.expectEqual(ValidationError.system_transaction_after_regolith, result.rejected);
    try std.testing.expectEqual(@as(u256, 0), try vm.engine.executor.getBalance(sender));
}

test "family facade does not widen the concrete Ethereum transaction API" {
    try std.testing.expect(evmz.Transaction == evmz.Evm.Transaction);
    try std.testing.expect(!@hasDecl(evmz, "DepositTransaction"));
    try std.testing.expect(Vm.Transaction == DepositTransaction);
    try std.testing.expect(Vm.TxResult == Result);
}

test "deposit cannot mutate an unresolved Ethereum transaction" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const block = evmz.execution.BlockEnvironment{ .gas_limit = 30_000_000 };

    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    vm.engine.env.gas_limit = block.gas_limit;
    try vm.engine.creditBalance(sender, 100);

    const outcome = try vm.transactEthereum(.{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = ethereum_recipient,
        .value = 10,
    });
    var pending = switch (outcome) {
        .pending => |value| value,
        .rejected => return error.UnexpectedEthereumRejection,
    };
    defer pending.deinit();

    try std.testing.expectError(error.PendingTransactionActive, vm.transact(.{
        .source_hash = [_]u8{0x66} ** 32,
        .from = sender,
        .to = deposit_recipient,
        .mint = 7,
        .value = 3,
        .gas_limit = 100_000,
    }, block));

    _ = try pending.accept();
    try std.testing.expectEqual(@as(u256, 90), (try vm.engine.getAccount(sender)).?.balance);
    try std.testing.expectEqual(@as(u256, 10), (try vm.engine.getAccount(ethereum_recipient)).?.balance);
    try std.testing.expect((try vm.engine.getAccount(deposit_recipient)) == null);
}

test "one concrete Evm alternates Ethereum and deposit flows on one overlay" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const block = evmz.execution.BlockEnvironment{ .gas_limit = 30_000_000 };

    var vm = Vm.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    vm.engine.env.gas_limit = block.gas_limit;
    try vm.engine.creditBalance(sender, 100);

    const ethereum_1 = try expectEthereumExecuted(try vm.transactEthereum(.{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = ethereum_recipient,
        .value = 10,
    }));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_1.status);

    const deposit = (try vm.transact(.{
        .source_hash = [_]u8{0x66} ** 32,
        .from = sender,
        .to = deposit_recipient,
        .mint = 7,
        .value = 3,
        .gas_limit = 100_000,
    }, block)).executed;
    try std.testing.expectEqual(evmz.Interpreter.Status.success, deposit.status);
    try std.testing.expectEqual(@as(u64, 1), deposit.deposit_nonce);

    const reverted_deposit = (try vm.transact(.{
        .source_hash = [_]u8{0x77} ** 32,
        .from = sender,
        .to = null,
        .mint = 5,
        .gas_limit = 100_000,
        // PUSH0 PUSH0 REVERT.
        .input = &.{ 0x5f, 0x5f, 0xfd },
    }, block)).executed;
    try std.testing.expectEqual(evmz.Interpreter.Status.revert, reverted_deposit.status);
    try std.testing.expectEqual(@as(u64, 2), reverted_deposit.deposit_nonce);

    const ethereum_2 = try expectEthereumExecuted(try vm.transactEthereum(.{
        .sender = sender,
        .nonce = 3,
        .gas_limit = 100_000,
        .to = ethereum_recipient,
        .value = 4,
    }));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_2.status);

    const sender_account = (try vm.engine.getAccount(sender)).?;
    try std.testing.expectEqual(@as(u64, 4), sender_account.nonce);
    try std.testing.expectEqual(@as(u256, 95), sender_account.balance);
    try std.testing.expectEqual(@as(u256, 14), (try vm.engine.getAccount(ethereum_recipient)).?.balance);
    try std.testing.expectEqual(@as(u256, 3), (try vm.engine.getAccount(deposit_recipient)).?.balance);
}
