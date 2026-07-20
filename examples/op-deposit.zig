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

pub const DepositOutcome = evmz.transaction.TransactOutcome(ExecutionResult, ValidationError);

const DepositInput = struct {
    tx: DepositTransaction,
    chain_id: u256,
    block: evmz.execution.BlockEnvironment,
};
const OpContext = evmz.transaction.Context(evmz.Evm, DepositInput);

/// OP owns deposit policy; the shared transaction program owns the attempt,
/// rollback, and retain/discard lifetime around it.
const DepositTransition = struct {
    pub const Input = DepositInput;
    const TransactionProtocol = OpContext.TransactionProtocol;
    const TransactionPolicy = OpContext.TransactionPolicy;
    const Gas = evmz.transaction.GasRuntime(
        TransactionProtocol,
        @FieldType(TransactionPolicy, "transaction"),
    );
    const Settlement = evmz.transaction.SettlementRuntime(
        TransactionProtocol,
        TransactionPolicy,
    );

    pub const Error = OpContext.Error || error{Overflow};

    pub fn transact(
        context: *OpContext,
        tx: DepositTransaction,
    ) Error!evmz.transaction.TransitionOutcome(ExecutionResult, ValidationError) {
        if (tx.is_system_transaction) {
            return .{ .rejected = .system_transaction_after_regolith };
        }

        const input = context.input();
        const attempt = try context.beginAttempt();
        try attempt.addBalance(tx.from, tx.mint);
        const deposit_nonce = if (try attempt.accountSummary(tx.from)) |sender|
            sender.nonce
        else
            0;

        const revision = context.revision();
        const gas_planner = Gas{ .transaction = &context.policy().transaction };
        const gas_plan = gas_planner.gasPlan(revision, tx.input, tx.gas_limit, .{
            .is_create = tx.to == null,
            .value = tx.value,
            .is_self_transfer = if (tx.to) |to| std.mem.eql(u8, &tx.from, &to) else false,
        });
        const execution_gas = if (canExecute(context, gas_planner, tx, gas_plan))
            gas_plan.execution
        else
            null;
        const created_address = if (tx.to == null)
            evmz.address.create(tx.from, deposit_nonce)
        else
            null;
        const request = executionRequest(
            input.chain_id,
            input.block,
            tx,
            created_address,
            execution_gas orelse evmz.execution.ExecutionGas.legacy(0),
        );

        try context.runPrelude();
        try attempt.beginExecution(request, .{});

        if (execution_gas == null) {
            try attempt.incrementNonce(tx.from);
            try attempt.finalizeState();
            return .{ .completed = .{
                .status = .invalid,
                .gas = try depositGas(context, tx, input.block, gas_plan, .{
                    .gas_left = 0,
                    .gas_refund = 0,
                    .gas_reservoir = 0,
                    .state_gas_spent = 0,
                }),
                .source_hash = tx.source_hash,
                .deposit_nonce = deposit_nonce,
            } };
        }

        var execution_checkpoint = try attempt.checkpoint();
        defer execution_checkpoint.deinit();

        // CREATE increments inside the engine. CALL gets the equivalent
        // transaction-level nonce increment before payload execution.
        if (tx.to != null) try attempt.incrementNonce(tx.from);
        const result = try attempt.executeRequest(request);
        if (result.status == .success) {
            execution_checkpoint.commit() catch |err| return context.infrastructureError(err);
        } else {
            execution_checkpoint.restore() catch |err| return context.infrastructureError(err);
            try attempt.incrementNonce(tx.from);
        }
        try attempt.finalizeState();

        return .{ .completed = .{
            .status = result.status,
            .gas = try depositGas(context, tx, input.block, gas_plan, .{
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
            }),
            .output = result.output_data,
            .created_address = if (result.status == .success and tx.to == null)
                address.create(tx.from, deposit_nonce)
            else
                null,
            .source_hash = tx.source_hash,
            .deposit_nonce = deposit_nonce,
        } };
    }

    fn depositGas(
        context: *const OpContext,
        tx: DepositTransaction,
        block: evmz.execution.BlockEnvironment,
        gas_plan: evmz.transaction.GasPlan,
        result: evmz.transaction.ExecutionGasResult,
    ) !evmz.transaction.ResultGas {
        const planner = Settlement{ .policy = context.policy() };
        const settlement_plan = planner.defaultPlanFromGasPlan(
            context.revision(),
            tx.gas_limit,
            gas_plan,
            .{
                .gas_price = 0,
                .priority_fee = 0,
                .fee_recipient = block.coinbase,
                .value = tx.value,
            },
        );
        return planner.planGas(try planner.planCosts(settlement_plan, result));
    }

    fn canExecute(
        context: *const OpContext,
        gas_planner: Gas,
        tx: DepositTransaction,
        gas_plan: evmz.transaction.GasPlan,
    ) bool {
        const revision = context.revision();
        if (gas_plan.execution == null) return false;
        if (tx.to == null and tx.input.len > gas_planner.maxInitcodeSize(revision)) return false;
        if (context.policy().transaction.totalGasLimit(revision)) |limit| {
            if (tx.gas_limit > limit) return false;
        }
        return true;
    }
};

pub const DepositProgram = evmz.transaction.Program(
    DepositTransaction,
    ExecutionResult,
    ValidationError,
    DepositTransition,
);
pub const DepositRuntime = DepositProgram.bind(evmz.Evm);

/// Small client-owned facade sequencing Ethereum and OP transaction programs
/// over one reusable execution branch.
pub const OpRuntime = struct {
    const Self = @This();

    pub const Transaction = DepositTransaction;
    pub const Outcome = DepositOutcome;
    pub const Block = evmz.execution.BlockEnvironment;
    pub const Engine = evmz.Evm;

    pub const Init = struct {
        revision: evmz.Evm.Revision,
        chain_id: u256,
        state_reader: ?evmz.StateReader = null,
        block_hash_source: ?evmz.BlockHashSource = null,
        config: evmz.ExecutionConfig = .base,
    };

    /// One mutable execution branch shared by sequenced Ethereum transactions
    /// and family-owned deposit execution.
    executor: Engine.Executor,
    env: evmz.vm.Env,

    pub fn init(allocator: std.mem.Allocator, options: Init) Self {
        return .{
            .executor = Engine.Executor.init(allocator, .{
                .revision = options.revision,
                .state_reader = options.state_reader,
                .block_hash_source = options.block_hash_source,
                .config = options.config,
            }),
            .env = .{ .chain_id = options.chain_id },
        };
    }

    pub fn deinit(self: *Self) void {
        self.executor.deinit();
    }

    /// Ordinary Ethereum envelopes use the family transaction STF over the
    /// same Executor branch as family deposits.
    pub fn transactEthereum(self: *Self, tx: evmz.Evm.Transaction) !evmz.Evm.Outcome {
        var ethereum = Engine.init(&self.executor);
        return ethereum.transact(.{
            .env = self.env,
            .tx = tx,
        });
    }

    /// Execute one authenticated, derived Regolith-or-later deposit.
    ///
    /// The caller owns the surrounding block gas pool. Engine/infrastructure
    /// errors restore the full transition, including mint. Included EVM
    /// failures preserve mint and one sender-nonce increment.
    pub fn transact(self: *Self, tx: Transaction, block: Block) !Outcome {
        var deposit = DepositRuntime.init(&self.executor);
        return switch (try deposit.transact(.{
            .tx = tx,
            .chain_id = self.env.chain_id,
            .block = block,
        })) {
            .rejected => |reason| .{ .rejected = reason },
            .executed => |executed| blk: {
                defer executed.discardIfCurrent();
                const result = try executed.result();
                try executed.retain();
                break :blk .{ .executed = result };
            },
        };
    }
};

fn executionRequest(
    chain_id: u256,
    block: evmz.execution.BlockEnvironment,
    tx: DepositTransaction,
    created_address: ?Address,
    gas: evmz.execution.ExecutionGas,
) evmz.execution.EvmExecutionRequest {
    const message: evmz.execution.Message = if (tx.to) |recipient|
        .{ .call = .{
            .sender = tx.from,
            .recipient = recipient,
            .input = tx.input,
            .value = tx.value,
        } }
    else
        .{ .create = .{
            .sender = tx.from,
            .recipient = created_address.?,
            .init_code = tx.input,
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
        .gas = gas,
    };
}

fn expectEthereumExecuted(executor: *evmz.Evm.Executor, result: evmz.Evm.Outcome) !evmz.vm.TxExecutionResult {
    return switch (result) {
        .executed => |execution| blk: {
            defer execution.discardIfCurrent();
            var diff = try execution.changeset();
            defer diff.deinit(executor.allocator);
            const output = try execution.result();
            try execution.retain();
            break :blk output;
        },
        .rejected => error.UnexpectedEthereumRejection,
    };
}

pub fn main(init: std.process.Init) !void {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = OpRuntime.init(init.gpa, .{ .revision = .cancun, .chain_id = 10 });
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
    if (try vm.executor.getBalance(sender) != 7) return error.MintLifecycleMismatch;
    if (try vm.executor.getBalance(recipient) != 3) return error.ValueTransferMismatch;

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
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
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
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 7), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 3), try vm.executor.getBalance(recipient));
}

test "reverted deposit keeps mint and nonce but rolls back EVM writes" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    try vm.executor.state.setCode(recipient, &.{ 0x5f, 0x5f, 0xfd });

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
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(recipient));
}

test "insufficient-value deposit becomes an included failure after mint" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
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
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 2), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(recipient));
}

test "intrinsic-gas failure is included after mint with one nonce increment" {
    const sender = address.addr(0xaaaa);
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
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
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 5), try vm.executor.getBalance(sender));
}

test "create deposit derives address from the pre-execution deposit nonce" {
    const sender = address.addr(0xaaaa);
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
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
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
}

test "legacy system deposit is rejected before lifecycle writes" {
    const sender = address.addr(0xaaaa);
    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
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
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(sender));
}

test "family facade does not widen the concrete Ethereum transaction API" {
    try std.testing.expect(evmz.Transaction == evmz.Evm.Transaction);
    try std.testing.expect(!@hasDecl(evmz, "DepositTransaction"));
    try std.testing.expect(OpRuntime.Transaction == DepositTransaction);
    try std.testing.expect(OpRuntime.Outcome == DepositOutcome);
    try std.testing.expect(DepositProgram.Transaction == DepositTransaction);
    try std.testing.expect(DepositProgram.Output == ExecutionResult);
    try std.testing.expect(DepositRuntime.Executor == evmz.Evm.Executor);
    try std.testing.expect(DepositRuntime.TransactionProtocol == evmz.Evm.TransactionProtocol);
    try std.testing.expect(DepositRuntime.Context == OpContext);
    try std.testing.expect(DepositRuntime.Error != anyerror);
}

test "deposit transition uses its runtime policy snapshot" {
    const sender = address.addr(0xaaaa);
    const GasLimit = struct {
        fn total(_: evmz.Evm.Revision) ?u64 {
            return 1;
        }
    };
    var policy = evmz.Evm.transaction_policy;
    policy.transaction.totalGasLimit = GasLimit.total;

    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var deposit = DepositRuntime.initWithPolicy(&executor, policy);
    const outcome = try deposit.transact(.{
        .tx = .{
            .source_hash = [_]u8{0x77} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 1,
            .gas_limit = 100_000,
        },
        .chain_id = 10,
        .block = .{ .gas_limit = 30_000_000 },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    const result = try executed.result();
    try executed.retain();
    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, result.status);
}

test "deposit cannot mutate an unresolved Ethereum transaction" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const block = evmz.execution.BlockEnvironment{ .gas_limit = 30_000_000 };

    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    vm.env.gas_limit = block.gas_limit;
    try vm.executor.addBalance(sender, 100);

    const outcome = try vm.transactEthereum(.{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = ethereum_recipient,
        .value = 10,
    });
    const execution = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedEthereumRejection,
    };
    defer execution.discardIfCurrent();

    try std.testing.expectError(error.ExecutedTransactionActive, vm.transact(.{
        .source_hash = [_]u8{0x66} ** 32,
        .from = sender,
        .to = deposit_recipient,
        .mint = 7,
        .value = 3,
        .gas_limit = 100_000,
    }, block));

    _ = try execution.result();
    var diff = try execution.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 90), (try vm.executor.getAccountOrLoad(sender)).?.balance);
    try std.testing.expectEqual(@as(u256, 10), (try vm.executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expect((try vm.executor.getAccountOrLoad(deposit_recipient)) == null);
}

test "one concrete Evm alternates Ethereum and deposit flows on one overlay" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const block = evmz.execution.BlockEnvironment{ .gas_limit = 30_000_000 };

    var vm = OpRuntime.init(std.testing.allocator, .{ .revision = .cancun, .chain_id = 10 });
    defer vm.deinit();
    vm.env.gas_limit = block.gas_limit;
    try vm.executor.addBalance(sender, 100);

    const ethereum_1 = try expectEthereumExecuted(&vm.executor, try vm.transactEthereum(.{
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

    const ethereum_2 = try expectEthereumExecuted(&vm.executor, try vm.transactEthereum(.{
        .sender = sender,
        .nonce = 3,
        .gas_limit = 100_000,
        .to = ethereum_recipient,
        .value = 4,
    }));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_2.status);

    const sender_account = (try vm.executor.getAccountOrLoad(sender)).?;
    try std.testing.expectEqual(@as(u64, 4), sender_account.nonce);
    try std.testing.expectEqual(@as(u256, 95), sender_account.balance);
    try std.testing.expectEqual(@as(u256, 14), (try vm.executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expectEqual(@as(u256, 3), (try vm.executor.getAccountOrLoad(deposit_recipient)).?.balance);
}
