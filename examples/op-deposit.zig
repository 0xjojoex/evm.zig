//! Regolith-and-later OP deposit composition example.
//!
//! This is not part of the evmz library API and is not a complete OP Stack STF.
//! It demonstrates how an external family can own the `0x7e` wire
//! representation, validation, mint/nonce lifecycle, request normalization,
//! and typed result while reusing the public engine seam. A real OP STF still
//! owns raw envelope decoding, derivation authentication, block ordering and
//! gas-pool accounting, and receipts.

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

    pub const Rlp = rlp.Struct(@This(), .{
        .to = rlp.OptionalFixedBytes(@sizeOf(Address)),
    });
};

/// Canonical typed-envelope codec for a deposited transaction.
pub const Codec = struct {
    pub const DecodeError = rlp.DecodeError || error{UnexpectedTypeId};
    pub const EncodeError = rlp.EncodeError || std.mem.Allocator.Error;

    pub fn encodeAlloc(allocator: std.mem.Allocator, tx: DepositTransaction) EncodeError![]u8 {
        const payload_len = try rlp.encodedLen(DepositTransaction, tx);
        const encoded_len = std.math.add(usize, payload_len, 1) catch
            return error.EncodedLengthOverflow;
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);
        encoded[0] = type_id;
        _ = try rlp.encode(DepositTransaction, encoded[1..], tx);
        return encoded;
    }

    pub fn decode(encoded: []const u8) DecodeError!DepositTransaction {
        if (encoded.len == 0) return error.InputTooShort;
        if (encoded[0] != type_id) return error.UnexpectedTypeId;
        return rlp.decode(DepositTransaction, encoded[1..]);
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

/// Native OP-family transaction carrier. Ordinary Ethereum transactions and
/// deposits remain distinct while sharing one statically bound transaction
/// program and Executor.
pub const OpTransaction = union(enum) {
    ethereum: evmz.Evm.Transaction,
    deposit: DepositTransaction,
};

/// Op output preserves which transaction program produced the result.
pub const OpOutput = union(enum) {
    ethereum: evmz.Evm.Output,
    deposit: ExecutionResult,
};

/// Op rejection preserves the originating transaction program.
pub const OpRejection = union(enum) {
    ethereum: evmz.Evm.Rejection,
    deposit: ValidationError,
};

pub const OpInput = struct {
    env: evmz.Env,
    tx: OpTransaction,
    progress: evmz.transaction.PreparationBlockProgress = .{},
};

const OpContext = evmz.Evm.Context(OpInput);
const Gas = evmz.Evm.Gas;
const Settlement = evmz.Evm.Settlement;
const EthereumTransition = evmz.Evm.Transition(OpInput);

/// OP owns deposit policy; the shared transaction program owns the attempt,
/// rollback, and retain/discard lifetime around it.
const DepositTransition = struct {
    pub const Error = OpContext.Error || error{ Overflow, MissingCreateRecipient };

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
        const message = try evmz.execution.Message.init(.{
            .sender = tx.from,
            .to = tx.to,
            .input = tx.input,
            .value = tx.value,
            .create_recipient = created_address,
        });
        const request = evmz.transaction.executionRequest(
            input.env.executionContext(tx.from, 0, &.{}),
            message,
            execution_gas orelse evmz.execution.ExecutionGas.legacy(0),
        );

        try context.runPrelude();
        try attempt.beginExecution(request, .{});

        if (execution_gas == null) {
            try attempt.incrementNonce(tx.from);
            try attempt.finalizeState();
            return .{ .completed = .{
                .status = .invalid,
                .gas = try depositGas(context, tx, gas_plan, .{
                    .gas_left = 0,
                    .gas_refund = 0,
                    .gas_reservoir = 0,
                    .state_gas_spent = 0,
                }),
                .source_hash = tx.source_hash,
                .deposit_nonce = deposit_nonce,
            } };
        }

        // CREATE increments inside the engine. CALL gets the equivalent
        // transaction-level nonce increment before payload execution.
        if (tx.to != null) try attempt.incrementNonce(tx.from);
        const result = (try attempt.runPayload(request)).result;
        if (tx.to == null and result.status != .success) {
            try attempt.incrementNonce(tx.from);
        }
        try attempt.finalizeState();

        return .{ .completed = .{
            .status = result.status,
            .gas = try depositGas(context, tx, gas_plan, .{
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
                .fee_recipient = context.input().env.coinbase,
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

const OpTransition = struct {
    pub const Error = EthereumTransition.Error || DepositTransition.Error;

    pub fn transact(
        context: *OpContext,
        tx: OpTransaction,
    ) Error!evmz.transaction.TransitionOutcome(OpOutput, OpRejection) {
        return switch (tx) {
            // TODO: ZLS does not surface `transact` on this specialized type,
            // although the Zig compiler resolves and checks it correctly.
            .ethereum => |ethereum| switch (try EthereumTransition.transact(context, ethereum)) {
                .rejected => |reason| .{ .rejected = .{ .ethereum = reason } },
                .completed => |output| .{ .completed = .{ .ethereum = output } },
            },
            .deposit => |deposit| switch (try DepositTransition.transact(context, deposit)) {
                .rejected => |reason| .{ .rejected = .{ .deposit = reason } },
                .completed => |output| .{ .completed = .{ .deposit = output } },
            },
        };
    }
};

/// One typed OP-family transaction runtime. Both variants share the exact
/// Ethereum Executor while keeping the root `evmz.Evm.Transaction` unchanged.
pub const OpVm = evmz.Evm.Program(
    OpTransaction,
    OpInput,
    OpOutput,
    OpRejection,
    OpTransition,
);

// TODO: A shared helper needs an explicit contract for output slices borrowed
// from the executor; keep retention and variant typing demo-local for now.
fn retainOutput(outcome: OpVm.Outcome) !OpOutput {
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    const output = try executed.result();
    try executed.retain();
    return output;
}

fn retainDeposit(outcome: OpVm.Outcome) !ExecutionResult {
    return switch (try retainOutput(outcome)) {
        .deposit => |output| output,
        .ethereum => error.UnexpectedEthereumOutput,
    };
}

fn retainEthereum(outcome: OpVm.Outcome) !evmz.Evm.Output {
    return switch (try retainOutput(outcome)) {
        .ethereum => |output| output,
        .deposit => error.UnexpectedDepositOutput,
    };
}

pub fn main(init: std.process.Init) !void {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = evmz.Evm.Executor.init(init.gpa, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x11} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));

    if (executed.status != .success) return error.DepositExecutionFailed;
    if (try executor.getBalance(sender) != 7) return error.MintLifecycleMismatch;
    if (try executor.getBalance(recipient) != 3) return error.ValueTransferMismatch;

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

    const expected_hex =
        "7ef841a0" ++
        "1111111111111111111111111111111111111111111111111111111111111111" ++
        "94000000000000000000000000000000000000aaaa" ++
        "800703830186a080826000";
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, encoded);

    const decoded = try Codec.decode(encoded);
    try std.testing.expectEqualDeep(tx, decoded);
}

test "successful deposit preserves mint and advances nonce" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x22} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));

    try std.testing.expectEqual(evmz.Interpreter.Status.success, executed.status);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 3), try executor.getBalance(recipient));
}

test "reverted deposit keeps mint and nonce but rolls back EVM writes" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);
    try executor.state.setCode(recipient, &.{ 0x5f, 0x5f, 0xfd });

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x33} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));

    try std.testing.expectEqual(evmz.Interpreter.Status.revert, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(recipient));
}

test "insufficient-value deposit becomes an included failure after mint" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x34} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 2,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));

    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 2), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(recipient));
}

test "intrinsic-gas failure is included after mint with one nonce increment" {
    const sender = address.addr(0xaaaa);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x44} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 5,
            .gas_limit = 20_000,
        } },
    }));

    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 20_000), executed.gas.used);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 5), try executor.getBalance(sender));
}

test "create deposit derives address from the pre-execution deposit nonce" {
    const sender = address.addr(0xaaaa);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const executed = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{
            .deposit = .{
                .source_hash = [_]u8{0x45} ** 32,
                .from = sender,
                .to = null,
                .gas_limit = 100_000,
                // PUSH0 PUSH0 RETURN deploys empty runtime code.
                .input = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
    }));

    try std.testing.expectEqual(evmz.Interpreter.Status.success, executed.status);
    try std.testing.expectEqual(address.create(sender, 0), executed.created_address.?);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "legacy system deposit is rejected before lifecycle writes" {
    const sender = address.addr(0xaaaa);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);

    const result = try vm.transact(.{
        .env = .{ .chain_id = 10 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x55} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 5,
            .gas_limit = 100_000,
            .is_system_transaction = true,
        } },
    });

    try std.testing.expectEqual(
        ValidationError.system_transaction_after_regolith,
        result.rejected.deposit,
    );
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(sender));
}

test "Ethereum rejection remains tagged through the OP transaction program" {
    const sender = address.addr(0xaaaa);
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);
    try executor.addBalance(sender, 100);

    const result = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 1,
            .gas_limit = 100_000,
            .to = address.addr(0xbbbb),
        } },
    });

    try std.testing.expectEqual(evmz.Evm.Rejection.nonce_too_high, result.rejected.ethereum);
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "OP transaction program composes Ethereum and deposit without widening root Evm" {
    try std.testing.expect(evmz.Transaction == evmz.Evm.Transaction);
    try std.testing.expect(!@hasDecl(evmz, "DepositTransaction"));
    try std.testing.expect(OpVm.Transaction == OpTransaction);
    try std.testing.expect(OpVm.Output == OpOutput);
    try std.testing.expect(OpVm.Rejection == OpRejection);
    try std.testing.expect(OpVm.TransactInput == OpInput);
    try std.testing.expect(OpVm.Executor == evmz.Evm.Executor);
    try std.testing.expect(OpVm.Error != anyerror);
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
    var vm = OpVm.initWithPolicy(&executor, policy);
    const result = try retainDeposit(try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x77} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 1,
            .gas_limit = 100_000,
        } },
    }));
    try std.testing.expectEqual(evmz.Interpreter.Status.invalid, result.status);
}

test "deposit cannot mutate an unresolved Ethereum transaction" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);
    try executor.addBalance(sender, 100);

    const outcome = try vm.transact(.{
        .env = env,
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 10,
        } },
    });
    const execution = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedEthereumRejection,
    };
    defer execution.discardIfCurrent();

    try std.testing.expectError(error.ExecutedTransactionActive, vm.transact(.{
        .env = env,
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x66} ** 32,
            .from = sender,
            .to = deposit_recipient,
            .mint = 7,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));

    _ = try execution.result();
    var diff = try execution.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(u256, 90), (try executor.getAccountOrLoad(sender)).?.balance);
    try std.testing.expectEqual(@as(u256, 10), (try executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expect((try executor.getAccountOrLoad(deposit_recipient)) == null);
}

test "one OP transaction program alternates Ethereum and deposit variants on one overlay" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    var vm = OpVm.init(&executor);
    try executor.addBalance(sender, 100);

    const ethereum_1 = try retainEthereum(try vm.transact(.{
        .env = env,
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 10,
        } },
    }));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_1.status);

    const deposit = try retainDeposit(try vm.transact(.{
        .env = env,
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x66} ** 32,
            .from = sender,
            .to = deposit_recipient,
            .mint = 7,
            .value = 3,
            .gas_limit = 100_000,
        } },
    }));
    try std.testing.expectEqual(evmz.Interpreter.Status.success, deposit.status);
    try std.testing.expectEqual(@as(u64, 1), deposit.deposit_nonce);

    const reverted_deposit = try retainDeposit(try vm.transact(.{
        .env = env,
        .tx = .{
            .deposit = .{
                .source_hash = [_]u8{0x77} ** 32,
                .from = sender,
                .to = null,
                .mint = 5,
                .gas_limit = 100_000,
                // PUSH0 PUSH0 REVERT.
                .input = &.{ 0x5f, 0x5f, 0xfd },
            },
        },
    }));
    try std.testing.expectEqual(evmz.Interpreter.Status.revert, reverted_deposit.status);
    try std.testing.expectEqual(@as(u64, 2), reverted_deposit.deposit_nonce);

    const ethereum_2 = try retainEthereum(try vm.transact(.{
        .env = env,
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 3,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 4,
        } },
    }));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_2.status);

    const sender_account = (try executor.getAccountOrLoad(sender)).?;
    try std.testing.expectEqual(@as(u64, 4), sender_account.nonce);
    try std.testing.expectEqual(@as(u256, 95), sender_account.balance);
    try std.testing.expectEqual(@as(u256, 14), (try executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expectEqual(@as(u256, 3), (try executor.getAccountOrLoad(deposit_recipient)).?.balance);
}
