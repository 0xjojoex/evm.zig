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

/// Small OP revision window for the composition spike. The runtime caller may
/// select one of these, but each selected VM is compiled from one exact spec.
pub const OpRevision = enum {
    canyon,
    delta,
    ecotone,
    fjord,
};

/// Ecotone adopts Cancun's transaction set without type-3 blob transactions.
const ecotone_transaction_kinds = kinds: {
    var kinds = evmz.eth.cancun.transaction.active_kinds;
    kinds.remove(.blob);
    break :kinds kinds;
};

/// Resolve family-owned environment facts once, before transaction-variant
/// dispatch. OP serves no blobs, so Ecotone pins the opcode-visible
/// BLOBBASEFEE at one for Ethereum transactions and deposits alike.
fn executionEnv(revision: OpRevision, inherited: evmz.Env) evmz.Env {
    var resolved = inherited;
    if (revision == .ecotone or revision == .fjord) resolved.blob_base_fee = 1;
    return resolved;
}

/// Fjord's exact precompile table: Cancun plus RIP-7212 at OP's gas price.
const fjord_precompile_config = resolved: {
    var result = evmz.eth.precompile.cancun_config;
    result.active[@intFromEnum(evmz.eth.precompile.Entry.p256verify)] = true;
    result.gas.set(.p256verify, 3_450);
    break :resolved result;
};
const FjordPrecompile = evmz.eth.precompile.Exact(fjord_precompile_config);

pub const canyon_spec = evmz.eth.shanghai;
pub const delta_spec = canyon_spec;
pub const ecotone_spec = evmz.eth.cancun.extend(.{
    .transaction = .{ .active_kinds = ecotone_transaction_kinds },
});
pub const fjord_spec = ecotone_spec.extend(.{
    .precompile = FjordPrecompile,
});

pub fn opSpec(comptime revision: OpRevision) evmz.eth.Spec {
    return switch (revision) {
        .canyon => canyon_spec,
        .delta => delta_spec,
        .ecotone => ecotone_spec,
        .fjord => fjord_spec,
    };
}

/// Borrowed decoded deposited transaction.
///
/// `input` aliases the encoded bytes when produced by `decode`.
pub const DepositTransaction = struct {
    /// EIP-2718 type byte assigned to OP deposited transactions.
    pub const type_id: u8 = 0x7e;

    source_hash: [32]u8,
    from: Address,
    to: ?Address,
    mint: u256 = 0,
    value: u256 = 0,
    gas_limit: u64,
    is_system_transaction: bool = false,
    input: []const u8 = &.{},

    pub const Rlp = rlp.Struct(@This(), .{
        // TODO: rlp optional builtin
        .to = rlp.OptionalFixedBytes(@sizeOf(Address)),
    });

    pub const DecodeError = rlp.DecodeError || error{UnexpectedTypeId};
    pub const EncodeError = rlp.EncodeError || std.mem.Allocator.Error;

    pub fn encodeAlloc(self: *const DepositTransaction, allocator: std.mem.Allocator) EncodeError![]u8 {
        const payload_len = try rlp.encodedLen(DepositTransaction, self);
        const encoded_len = std.math.add(usize, payload_len, 1) catch
            return error.EncodedLengthOverflow;
        const encoded = try allocator.alloc(u8, encoded_len);
        errdefer allocator.free(encoded);
        encoded[0] = type_id;
        _ = try rlp.encode(DepositTransaction, encoded[1..], self);
        return encoded;
    }

    pub fn decode(encoded: []const u8) DecodeError!DepositTransaction {
        if (encoded.len == 0) return error.InputTooShort;
        if (encoded[0] != type_id) return error.UnexpectedTypeId;
        return rlp.decode(DepositTransaction, encoded[1..]);
    }
};

/// Deposit validation performed before family lifecycle writes.
pub const DepositRejection = enum {
    /// Regolith disables the legacy unmetered system-transaction flag.
    system_transaction_after_regolith,
};

/// Borrowed execution result for an included deposit.
///
/// `output` remains valid until another executor call replaces its output.
pub const DepositOutput = struct {
    status: evmz.TxStatus,
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
    ethereum: evmz.Transaction,
    deposit: DepositTransaction,
};

/// OP output preserves which transaction program produced the result.
pub const OpOutput = union(enum) {
    ethereum: evmz.TxExecutionResult,
    deposit: DepositOutput,
};

/// OP rejection preserves the originating transaction program.
pub const OpRejection = union(enum) {
    ethereum: evmz.Evm.Rejection,
    deposit: DepositRejection,
};

/// Resolved family input consumed by `OpVm`; direct callers construct it with
/// `init`, while block execution constructs it from an `OpBlockEnv`.
pub const OpInput = struct {
    env: evmz.Env,
    tx: OpTransaction,
    progress: evmz.transaction.PreparationBlockProgress = .{},

    pub fn init(comptime revision: OpRevision, env: evmz.Env, tx: OpTransaction) OpInput {
        return .{
            .env = executionEnv(revision, env),
            .tx = tx,
        };
    }
};

const DepositPrepared = struct {
    gas_plan: evmz.transaction.GasPlan,
    execution_gas: ?evmz.execution.ExecutionGas,
    request: evmz.execution.EvmExecutionRequest,
    created_address: ?Address,
    deposit_nonce: u64,
};

/// OP owns deposit policy; the shared transaction program owns the attempt,
/// rollback, and retain/discard lifetime around it.
fn DepositTransition(comptime OpContext: type, comptime EthereumVm: type) type {
    return struct {
        const Gas = EthereumVm.Gas;
        const Settlement = EthereumVm.Settlement;

        pub const Error = OpContext.Error || error{ Overflow, MissingCreateRecipient };

        pub fn transact(
            context: *OpContext,
            tx: DepositTransaction,
        ) Error!evmz.transaction.TransitionOutcome(DepositOutput, DepositRejection) {
            if (tx.is_system_transaction) {
                return .{ .rejected = .system_transaction_after_regolith };
            }

            const prepared = try prepare(context, tx);
            const attempt = try context.beginAttempt();
            // Mint the L1-escrowed value before any execution accounting.
            try attempt.addBalance(tx.from, tx.mint);

            try context.runPrelude();
            // The message scope opens even when the payload is skipped: nonce
            // advancement, finalizeState, and the lease lifecycle live inside it.
            try attempt.beginExecution(prepared.request, .{});
            const nonce_intent = try attempt.advanceTransactionNonce(prepared.request.message);

            var status: evmz.TxStatus = .invalid;
            var gas_result: evmz.transaction.ExecutionGasResult = .empty;
            var output: []const u8 = &.{};
            if (prepared.execution_gas == null) {
                try attempt.finalizeState();
            } else {
                const result = (try attempt.runPayload(prepared.request)).result;
                try attempt.finalizeState();
                status = result.status;
                gas_result = .{
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                    .gas_reservoir = result.gas_reservoir,
                    .state_gas_spent = result.state_gas_spent,
                };
                output = result.output_data;
            }
            // Regolith: even a failed deposit consumes the sender nonce.
            nonce_intent.complete();

            return .{ .completed = .{
                .status = status,
                .gas = try depositGas(context, tx, prepared.gas_plan, gas_result),
                .output = output,
                .created_address = if (status == .success) prepared.created_address else null,
                .source_hash = tx.source_hash,
                .deposit_nonce = prepared.deposit_nonce,
            } };
        }

        fn prepare(context: *OpContext, tx: DepositTransaction) Error!DepositPrepared {
            const gas_planner = Gas{};
            const gas_plan = gas_planner.gasPlan(tx.input, tx.gas_limit, .{
                .is_create = tx.to == null,
                .value = tx.value,
                .is_self_transfer = if (tx.to) |to| std.mem.eql(u8, &tx.from, &to) else false,
            });
            const execution_gas = resolveExecutionGas(context, gas_planner, tx, gas_plan);

            var state = context.preparationState();
            const sender = state.accountSummary(tx.from) catch |err|
                return context.infrastructureError(err);
            const deposit_nonce = if (sender) |account| account.nonce else 0;
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
            return .{
                .gas_plan = gas_plan,
                .execution_gas = execution_gas,
                // Deposits execute at gas price zero and carry no blob hashes.
                .request = evmz.transaction.executionRequest(
                    context.input().env.executionContext(tx.from, 0, &.{}),
                    message,
                    execution_gas orelse evmz.execution.ExecutionGas.none,
                ),
                .created_address = created_address,
                .deposit_nonce = deposit_nonce,
            };
        }

        /// Deposits are prepaid on L1: the zero-price settlement plan transfers
        /// nothing and only shapes the receipt gas.
        fn depositGas(
            context: *const OpContext,
            tx: DepositTransaction,
            gas_plan: evmz.transaction.GasPlan,
            result: evmz.transaction.ExecutionGasResult,
        ) !evmz.transaction.ResultGas {
            const planner = Settlement{};
            const settlement_plan = planner.defaultPlanFromGasPlan(
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

        /// Where Ethereum rejects a transaction that cannot reach execution,
        /// Regolith includes the deposit as a failed transaction that burns its
        /// full gas limit. Returning null selects that inclusion path.
        fn resolveExecutionGas(
            _: *const OpContext,
            gas_planner: Gas,
            tx: DepositTransaction,
            gas_plan: evmz.transaction.GasPlan,
        ) ?evmz.execution.ExecutionGas {
            const execution_gas = gas_plan.execution orelse return null;
            if (tx.to == null and tx.input.len > gas_planner.maxInitcodeSize()) return null;
            if (EthereumVm.specification.transaction.total_gas_limit) |limit| {
                if (tx.gas_limit > limit) return null;
            }
            return execution_gas;
        }
    };
}

fn OpTransition(
    comptime OpContext: type,
    comptime EthereumTransition: type,
    comptime DepositImplementation: type,
) type {
    return struct {
        pub const Error = EthereumTransition.Error || DepositImplementation.Error;

        pub fn transact(
            context: *OpContext,
            tx: OpTransaction,
        ) Error!evmz.transaction.TransitionOutcome(OpOutput, OpRejection) {
            return switch (tx) {
                .ethereum => |ethereum| switch (try EthereumTransition.transact(context, ethereum)) {
                    .rejected => |reason| .{ .rejected = .{ .ethereum = reason } },
                    .completed => |output| .{ .completed = .{ .ethereum = output } },
                },
                .deposit => |deposit| switch (try DepositImplementation.transact(context, deposit)) {
                    .rejected => |reason| .{ .rejected = .{ .deposit = reason } },
                    .completed => |output| .{ .completed = .{ .deposit = output } },
                },
            };
        }
    };
}

/// Minimal family-owned inclusion record. A real OP BlockSTF remains above
/// this fold and owns OP payload/header validation.
pub const OpIncludedTransaction = struct {
    /// May contain executor-owned slices that remain valid only until the next
    /// executor mutation; copy them when the included result must outlive it.
    output: OpOutput,
    cumulative_transactions: u64,
};

/// OP block ingress owns environment normalization before any transaction
/// variant is formed. The transaction program receives only the resolved EVM
/// environment stored here.
pub const OpBlockEnv = struct {
    execution: evmz.Env,

    pub fn init(comptime revision: OpRevision, inherited: evmz.Env) OpBlockEnv {
        return .{ .execution = executionEnv(revision, inherited) };
    }
};

/// Structural implementation of the `OpVm.Block` fold, kept to the smallest
/// legal state: a transaction count. The seam it demonstrates is the split
/// between `planInclude`, which may still fail while the output is only
/// borrowed, and `applyInclude`, which commits once the transaction retains.
const OpBlockProgram = struct {
    pub const State = u64;
    pub const Error = error{TransactionCountOverflow};
    pub const PreludeError = error{};
    pub const InclusionPlan = u64;

    pub fn init(_: OpBlockEnv) State {
        return 0;
    }

    pub fn transactInput(
        env: *const OpBlockEnv,
        _: *const State,
        tx: *const OpTransaction,
    ) OpInput {
        return .{ .env = env.execution, .tx = tx.* };
    }

    pub fn planInclude(
        _: *const OpBlockEnv,
        state: *const State,
        _: *const OpTransaction,
        _: *const OpOutput,
        _: evmz.state.TrackedState.LogView,
    ) Error!InclusionPlan {
        return std.math.add(u64, state.*, 1) catch error.TransactionCountOverflow;
    }

    pub fn included(
        _: *const OpTransaction,
        output: *const OpOutput,
        _: evmz.state.TrackedState.LogView,
        plan: InclusionPlan,
    ) OpIncludedTransaction {
        return .{
            .output = output.*,
            .cumulative_transactions = plan,
        };
    }

    pub fn applyInclude(state: *State, plan: InclusionPlan) void {
        state.* = plan;
    }

    pub fn finish(_: *const OpBlockEnv, state: *const State) u64 {
        return state.*;
    }
};

/// Compile one complete OP fork. Ethereum values are fixed before the generic
/// deposit program is bound, so no revision or runtime policy enters execution.
pub fn OpFamily(comptime revision: OpRevision) type {
    return OpFamilyFromSpec(revision, opSpec(revision));
}

fn OpFamilyFromSpec(comptime revision: OpRevision, comptime spec_value: evmz.eth.Spec) type {
    const EthereumVm = evmz.Vm(spec_value);
    const Context = EthereumVm.Context(OpInput);
    const EthereumTransition = EthereumVm.Transition(OpInput);
    const DepositImplementation = DepositTransition(Context, EthereumVm);
    const CombinedTransition = OpTransition(Context, EthereumTransition, DepositImplementation);
    const TransactionVm = EthereumVm.Program(
        OpTransaction,
        OpInput,
        OpOutput,
        OpRejection,
        CombinedTransition,
    );
    const BlockExecution = TransactionVm.Block(
        OpBlockEnv,
        OpIncludedTransaction,
        u64,
        OpBlockProgram,
    );

    return struct {
        pub const specification = spec_value;
        pub const op_revision = revision;
        pub const Evm = EthereumVm;
        pub const Vm = TransactionVm;
        pub const Block = BlockExecution;

        pub fn input(env: evmz.Env, tx: OpTransaction) OpInput {
            return OpInput.init(revision, env, tx);
        }

        pub fn blockEnv(env: evmz.Env) OpBlockEnv {
            return OpBlockEnv.init(revision, env);
        }
    };
}

pub const Canyon = OpFamily(.canyon);
pub const Delta = OpFamily(.delta);
pub const Ecotone = OpFamily(.ecotone);
pub const Fjord = OpFamily(.fjord);

fn retainOutput(outcome: anytype) !OpOutput {
    return switch (outcome) {
        .executed => |executed| try executed.retainResult(),
        .rejected => error.UnexpectedRejection,
    };
}

fn retainDeposit(outcome: anytype) !DepositOutput {
    return switch (try retainOutput(outcome)) {
        .deposit => |output| output,
        .ethereum => error.UnexpectedEthereumOutput,
    };
}

fn retainEthereum(outcome: anytype) !evmz.TxExecutionResult {
    return switch (try retainOutput(outcome)) {
        .ethereum => |output| output,
        .deposit => error.UnexpectedDepositOutput,
    };
}

fn seedTestAccount(executor: anytype, account_address: Address, balance: u256, code: []const u8) !void {
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    account.balance = balance;
    if (code.len != 0) try account.setCode(code);
    try executor.state.seedAccount(account_address, account);
}

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const revision = if (args.next()) |arg| try parseOpRevision(arg) else OpRevision.canyon;
    if (args.next() != null) return error.UnexpectedArgument;

    return switch (revision) {
        .canyon => runExample(Canyon, init.gpa),
        .delta => runExample(Delta, init.gpa),
        .ecotone => runExample(Ecotone, init.gpa),
        .fjord => runExample(Fjord, init.gpa),
    };
}

fn runExample(comptime Family: type, allocator: std.mem.Allocator) !void {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = Family.Evm.Executor.init(allocator, .{});
    defer executor.deinit();
    var vm = Family.Vm.init(&executor);

    const executed = try retainDeposit(try vm.transact(Family.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x11} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    )));

    if (executed.status != .success) return error.DepositExecutionFailed;
    if (try executor.getBalance(sender) != 7) return error.MintLifecycleMismatch;
    if (try executor.getBalance(recipient) != 3) return error.ValueTransferMismatch;

    std.debug.print("{s} deposit status: {s}, nonce: {d}, gas used: {d}\n", .{
        @tagName(Family.op_revision),
        @tagName(executed.status),
        executed.deposit_nonce,
        executed.gas.used,
    });
}

fn parseOpRevision(value: []const u8) !OpRevision {
    inline for (std.enums.values(OpRevision)) |revision| {
        if (std.mem.eql(u8, value, @tagName(revision))) return revision;
    }
    return error.UnknownOpRevision;
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
    const encoded = try tx.encodeAlloc(std.testing.allocator);
    defer std.testing.allocator.free(encoded);

    const expected_hex =
        "7ef841a0" ++
        "1111111111111111111111111111111111111111111111111111111111111111" ++
        "94000000000000000000000000000000000000aaaa" ++
        "800703830186a080826000";
    var expected: [expected_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&expected, expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, encoded);

    const decoded = try DepositTransaction.decode(encoded);
    try std.testing.expectEqualDeep(tx, decoded);
}

test "successful deposit preserves mint and advances nonce" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);

    const executed = try retainDeposit(try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x22} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    )));

    try std.testing.expectEqual(evmz.TxStatus.success, executed.status);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 3), try executor.getBalance(recipient));
}

test "reverted deposit keeps mint and nonce but rolls back EVM writes" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);
    try seedTestAccount(&executor, recipient, 0, &.{ 0x5f, 0x5f, 0xfd });

    const executed = try retainDeposit(try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x33} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    )));

    try std.testing.expectEqual(evmz.TxStatus.revert, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(recipient));
}

test "insufficient-value deposit becomes an included failure after mint" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);

    const executed = try retainDeposit(try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x34} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 2,
            .value = 3,
            .gas_limit = 100_000,
        } },
    )));

    try std.testing.expectEqual(evmz.TxStatus.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 2), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(recipient));
}

test "intrinsic-gas failure is included after mint with one nonce increment" {
    const sender = address.addr(0xaaaa);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);

    const executed = try retainDeposit(try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x44} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 5,
            .gas_limit = 20_000,
        } },
    )));

    try std.testing.expectEqual(evmz.TxStatus.invalid, executed.status);
    try std.testing.expectEqual(@as(u64, 20_000), executed.gas.used);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 5), try executor.getBalance(sender));
}

test "create deposit derives address from the pre-execution deposit nonce" {
    const sender = address.addr(0xaaaa);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);

    const executed = try retainDeposit(try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{
            .deposit = .{
                .source_hash = [_]u8{0x45} ** 32,
                .from = sender,
                .to = null,
                .gas_limit = 100_000,
                // PUSH0 PUSH0 RETURN deploys empty runtime code.
                .input = &.{ 0x5f, 0x5f, 0xf3 },
            },
        },
    )));

    try std.testing.expectEqual(evmz.TxStatus.success, executed.status);
    try std.testing.expectEqual(address.create(sender, 0), executed.created_address.?);
    try std.testing.expectEqual(@as(u64, 0), executed.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "legacy system deposit is rejected before lifecycle writes" {
    const sender = address.addr(0xaaaa);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);

    const result = try vm.transact(Canyon.input(
        .{ .chain_id = 10 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x55} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 5,
            .gas_limit = 100_000,
            .is_system_transaction = true,
        } },
    ));

    try std.testing.expectEqual(
        DepositRejection.system_transaction_after_regolith,
        result.rejected.deposit,
    );
    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(sender));
}

test "Ethereum rejection remains tagged through the OP transaction program" {
    const sender = address.addr(0xaaaa);
    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);
    try seedTestAccount(&executor, sender, 100, &.{});

    const result = try vm.transact(Canyon.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .ethereum = .{
            .sender = sender,
            .nonce = 1,
            .gas_limit = 100_000,
            .to = address.addr(0xbbbb),
        } },
    ));

    try std.testing.expectEqual(Canyon.Evm.Rejection.nonce_too_high, result.rejected.ethereum);
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "OP transaction program composes a derived Ethereum family and deposit" {
    try std.testing.expect(evmz.Transaction == evmz.Evm.Transaction);
    try std.testing.expect(Canyon.Evm.Transaction == evmz.Evm.Transaction);
    try std.testing.expect(!@hasDecl(evmz, "DepositTransaction"));
    try std.testing.expect(Canyon.Vm.Transaction == OpTransaction);
    try std.testing.expect(Canyon.Vm.Output == OpOutput);
    try std.testing.expect(Canyon.Vm.Rejection == OpRejection);
    try std.testing.expect(Canyon.Vm.TransactInput == OpInput);
    try std.testing.expect(Canyon.Vm.Executor == Canyon.Evm.Executor);
    try std.testing.expect(Canyon.Vm.Executor != evmz.Evm.Executor);
    try std.testing.expect(Canyon.Block.TransactionRuntime == Canyon.Vm);
    try std.testing.expect(Canyon.Block.Executor == Canyon.Evm.Executor);
    try std.testing.expect(Canyon.Block.Transaction == OpTransaction);
    try std.testing.expect(Canyon.Block.Output == OpOutput);
    try std.testing.expect(Canyon.Block.Included == OpIncludedTransaction);
    try std.testing.expectEqual(OpRevision.canyon, Canyon.op_revision);
    try std.testing.expectEqual(OpRevision.delta, Delta.op_revision);
    try std.testing.expectEqual(OpRevision.ecotone, Ecotone.op_revision);
    try std.testing.expectEqual(OpRevision.fjord, Fjord.op_revision);
    try std.testing.expect(Canyon.specification.precompile == canyon_spec.precompile);
    try std.testing.expect(Ecotone.specification.precompile == ecotone_spec.precompile);
    try std.testing.expect(Fjord.specification.precompile == FjordPrecompile);
    try std.testing.expect(!@hasField(Canyon.Evm.Executor.Init, "revision"));
    try std.testing.expect(!@hasField(Ecotone.Evm.Executor.Init, "revision"));
    try std.testing.expect(Canyon.Vm.Error != anyerror);
}

test "OP block execution normalizes and folds Ethereum and deposit transactions" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    const runtime_code = [_]u8{
        @intFromEnum(evmz.Opcode.BLOBBASEFEE),
        @intFromEnum(evmz.Opcode.PUSH0),
        @intFromEnum(evmz.Opcode.MSTORE),
        @intFromEnum(evmz.Opcode.PUSH1),
        0x20,
        @intFromEnum(evmz.Opcode.PUSH0),
        @intFromEnum(evmz.Opcode.RETURN),
    };

    var memory = evmz.state.MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 100;
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&runtime_code);

    var executor = Ecotone.Evm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    var block = try Ecotone.Block.init(
        &executor,
        Ecotone.blockEnv(.{
            .chain_id = 10,
            .gas_limit = 30_000_000,
            .blob_base_fee = 99,
        }),
    );
    defer block.discardIfUnfinished();

    const ethereum = switch (try block.transact(.{ .ethereum = .{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 100_000,
        .to = recipient,
    } })) {
        .included => |included| included,
        .rejected => return error.UnexpectedEthereumRejection,
    };
    try std.testing.expectEqual(@as(u64, 1), ethereum.cumulative_transactions);
    switch (ethereum.output) {
        .ethereum => |output| {
            try std.testing.expectEqual(evmz.TxStatus.success, output.status);
            try expectWordOne(output.output);
        },
        .deposit => return error.UnexpectedDepositOutput,
    }

    const deposit = switch (try block.transact(.{ .deposit = .{
        .source_hash = [_]u8{0x99} ** 32,
        .from = sender,
        .to = recipient,
        .gas_limit = 100_000,
    } })) {
        .included => |included| included,
        .rejected => return error.UnexpectedDepositRejection,
    };
    try std.testing.expectEqual(@as(u64, 2), deposit.cumulative_transactions);
    switch (deposit.output) {
        .deposit => |output| {
            try std.testing.expectEqual(evmz.TxStatus.success, output.status);
            try std.testing.expectEqual(@as(u64, 1), output.deposit_nonce);
            try expectWordOne(output.output);
        },
        .ethereum => return error.UnexpectedEthereumOutput,
    }

    const rejected = switch (try block.transact(.{ .ethereum = .{
        .kind = .blob,
        .sender = sender,
        .nonce = 2,
        .gas_limit = 100_000,
        .to = recipient,
    } })) {
        .rejected => |reason| reason,
        .included => return error.UnexpectedBlobInclusion,
    };
    try std.testing.expectEqual(Ecotone.Evm.Rejection.type_3_tx_pre_fork, rejected.ethereum);
    try std.testing.expectEqual(@as(u64, 2), block.progress());
    try std.testing.expectEqual(@as(u64, 2), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 2), try block.finish());
}

test "OP input assembly owns execution environment normalization" {
    const inherited = evmz.Env{ .blob_base_fee = 99 };
    const tx: OpTransaction = .{ .deposit = .{
        .source_hash = [_]u8{0x01} ** 32,
        .from = address.addr(0xaaaa),
        .to = address.addr(0xbbbb),
        .gas_limit = 100_000,
    } };

    try std.testing.expectEqual(@as(u256, 99), Delta.input(inherited, tx).env.blob_base_fee);
    try std.testing.expectEqual(@as(u256, 1), Ecotone.input(inherited, tx).env.blob_base_fee);
    try std.testing.expectEqual(@as(u256, 1), Ecotone.blockEnv(inherited).execution.blob_base_fee);
}

test "Ecotone rejects blob transactions while retaining Cancun execution" {
    const sender = address.addr(0xaaaa);
    var executor = Ecotone.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Ecotone.Vm.init(&executor);

    const outcome = try vm.transact(Ecotone.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000, .blob_base_fee = 99 },
        .{ .ethereum = .{
            .kind = .blob,
            .sender = sender,
            .gas_limit = 100_000,
            .to = address.addr(0xbbbb),
        } },
    ));

    try std.testing.expectEqual(Ecotone.Evm.Rejection.type_3_tx_pre_fork, outcome.rejected.ethereum);
    try std.testing.expect(Ecotone.specification.transaction.active_kinds.contains(.dynamic_fee));
    try std.testing.expect(!Ecotone.specification.transaction.active_kinds.contains(.blob));
}

test "Ecotone resolves BLOBBASEFEE to one for Ethereum and deposit transactions" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    const runtime_code = [_]u8{
        @intFromEnum(evmz.Opcode.BLOBBASEFEE),
        @intFromEnum(evmz.Opcode.PUSH0),
        @intFromEnum(evmz.Opcode.MSTORE),
        @intFromEnum(evmz.Opcode.PUSH1),
        0x20,
        @intFromEnum(evmz.Opcode.PUSH0),
        @intFromEnum(evmz.Opcode.RETURN),
    };
    const env = evmz.Env{
        .chain_id = 10,
        .gas_limit = 30_000_000,
        // The OP semantic override must not expose this inherited value.
        .blob_base_fee = 99,
    };

    var ethereum_executor = Ecotone.Evm.Executor.init(std.testing.allocator, .{});
    defer ethereum_executor.deinit();
    var ethereum_vm = Ecotone.Vm.init(&ethereum_executor);
    try seedTestAccount(&ethereum_executor, sender, 1, &.{});
    try seedTestAccount(&ethereum_executor, recipient, 0, &runtime_code);

    const ethereum_output = try retainEthereum(try ethereum_vm.transact(Ecotone.input(
        env,
        .{ .ethereum = .{
            .sender = sender,
            .gas_limit = 100_000,
            .to = recipient,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_output.status);
    try expectWordOne(ethereum_output.output);

    var deposit_executor = Ecotone.Evm.Executor.init(std.testing.allocator, .{});
    defer deposit_executor.deinit();
    var deposit_vm = Ecotone.Vm.init(&deposit_executor);
    try seedTestAccount(&deposit_executor, recipient, 0, &runtime_code);

    const deposit_output = try retainDeposit(try deposit_vm.transact(Ecotone.input(
        env,
        .{ .deposit = .{
            .source_hash = [_]u8{0x88} ** 32,
            .from = sender,
            .to = recipient,
            .gas_limit = 100_000,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.success, deposit_output.status);
    try expectWordOne(deposit_output.output);
}

test "Fjord activates RIP-7212 P256VERIFY at 3450 gas" {
    const p256_address = evmz.precompile.Contract.p256verify.toAddress();
    try std.testing.expect(!Ecotone.Evm.specification.precompile.active(p256_address));
    try std.testing.expect(Fjord.Evm.specification.precompile.active(p256_address));

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const message: evmz.Host.Message = .{
        .depth = 0,
        .kind = .call,
        .gas = fjord_precompile_config.gas.get(.p256verify) + 1,
        .sender = address.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    const precompile = Fjord.Evm.specification.precompile.resolve(p256_address).?;
    const outcome = try Fjord.Evm.specification.precompile.execute(precompile, .{
        .allocator = std.testing.allocator,
        .host = &host,
        .message = &message,
    });
    const result = outcome.result;

    try std.testing.expectEqual(evmz.precompile.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 1), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}

fn expectWordOne(output: []const u8) !void {
    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "deposit transition uses its exact spec value" {
    const sender = address.addr(0xaaaa);
    const Limited = OpFamilyFromSpec(.canyon, canyon_spec.extend(.{
        .transaction = .{ .total_gas_limit = .{ .replace = 1 } },
    }));

    var executor = Limited.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Limited.Vm.init(&executor);
    const result = try retainDeposit(try vm.transact(Limited.input(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{ .deposit = .{
            .source_hash = [_]u8{0x77} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 1,
            .gas_limit = 100_000,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.invalid, result.status);
}

test "unresolved Ethereum transaction keeps exclusive state ownership" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);
    try seedTestAccount(&executor, sender, 100, &.{});

    const outcome = try vm.transact(Canyon.input(
        env,
        .{ .ethereum = .{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 10,
        } },
    ));
    const execution = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedEthereumRejection,
    };
    defer execution.discardIfCurrent();

    try std.testing.expect(executor.hasCurrentTransaction());
    _ = execution.result();
    _ = execution.changes();
    try std.testing.expectEqual(@as(u256, 90), (try executor.getAccountOrLoad(sender)).?.balance);
    try std.testing.expectEqual(@as(u256, 10), (try executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expect((try executor.getAccountOrLoad(deposit_recipient)) == null);
}

test "one OP transaction program alternates Ethereum and deposit variants on one overlay" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var executor = Canyon.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var vm = Canyon.Vm.init(&executor);
    try seedTestAccount(&executor, sender, 100, &.{});

    const ethereum_1 = try retainEthereum(try vm.transact(Canyon.input(
        env,
        .{ .ethereum = .{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 10,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_1.status);

    const deposit = try retainDeposit(try vm.transact(Canyon.input(
        env,
        .{ .deposit = .{
            .source_hash = [_]u8{0x66} ** 32,
            .from = sender,
            .to = deposit_recipient,
            .mint = 7,
            .value = 3,
            .gas_limit = 100_000,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.success, deposit.status);
    try std.testing.expectEqual(@as(u64, 1), deposit.deposit_nonce);

    const reverted_deposit = try retainDeposit(try vm.transact(Canyon.input(
        env,
        .{
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
    )));
    try std.testing.expectEqual(evmz.TxStatus.revert, reverted_deposit.status);
    try std.testing.expectEqual(@as(u64, 2), reverted_deposit.deposit_nonce);

    const ethereum_2 = try retainEthereum(try vm.transact(Canyon.input(
        env,
        .{ .ethereum = .{
            .sender = sender,
            .nonce = 3,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 4,
        } },
    )));
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_2.status);

    const sender_account = (try executor.getAccountOrLoad(sender)).?;
    try std.testing.expectEqual(@as(u64, 4), sender_account.nonce);
    try std.testing.expectEqual(@as(u256, 95), sender_account.balance);
    try std.testing.expectEqual(@as(u256, 14), (try executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expectEqual(@as(u256, 3), (try executor.getAccountOrLoad(deposit_recipient)).?.balance);
}
