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

pub const OpEnv = evmz.Env;
pub const EthereumTransaction = evmz.Transaction;

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
/// dispatch. OP serves no blobs, so an exact spec with BLOBBASEFEE active pins
/// its opcode-visible value at one for Ethereum transactions and deposits.
fn executionEnv(comptime spec: evmz.Spec, inherited: evmz.Env) evmz.Env {
    var resolved = inherited;
    if (spec.instruction.entry(@intFromEnum(evmz.Opcode.BLOBBASEFEE)).active)
        resolved.blob_base_fee = 1;
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

    // `to` infers `rlp.Optional`: OP encodes an absent recipient as the empty
    // RLP byte string, and a 20-byte address can never collide with it.
    pub const Rlp = rlp.Struct(@This(), .{});

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
    ethereum: EthereumTransaction,
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

/// Shared input for direct and block family execution. The environment may be
/// inherited verbatim: every public OP entry resolves family-owned
/// environment facts at ingress before dispatch.
pub const OpInput = struct {
    env: evmz.Env,
    tx: OpTransaction,
    progress: evmz.transaction.PreparationBlockProgress = .{},

    fn normalize(self: OpInput, comptime spec: evmz.Spec) OpInput {
        var normalized = self;
        normalized.env = executionEnv(spec, self.env);
        return normalized;
    }
};

const DepositPrepared = struct {
    gas_plan: evmz.transaction.GasPlan,
    execution_gas: ?evmz.execution.ExecutionGas,
    request: evmz.execution.ExecutionRequest,
    created_address: ?Address,
    deposit_nonce: u64,
};

/// OP owns deposit policy; the shared transaction program owns active and
/// pending state plus the caller resolution contract.
fn DepositTransition(comptime spec: evmz.Spec) type {
    const Vm = OpVm(spec);

    return struct {
        const Context = Vm.Context;
        const Error = Context.Error || error{ MissingCreateRecipient, Overflow };

        const Gas = Context.Gas;
        const Settlement = Context.Settlement;

        pub fn transact(
            context: *Context,
            tx: DepositTransaction,
        ) Error!evmz.transaction.TransitionOutcomeType(DepositOutput, DepositRejection) {
            if (tx.is_system_transaction) {
                return .{ .rejected = .system_transaction_after_regolith };
            }

            const prepared = try prepare(context, tx);
            try context.beginTransaction();
            // Mint the L1-escrowed value before any execution accounting.
            try context.addBalance(tx.from, tx.mint);

            try context.runPrelude();
            // The message scope opens even when the payload is skipped: nonce
            // advancement and finalizeState live inside it.
            try context.beginExecution(prepared.request, .{});
            try context.advanceTransactionNonce(prepared.request.message);

            var status: evmz.TxStatus = .invalid;
            var gas_result: evmz.transaction.ExecutionGasResult = .empty;
            var output: []const u8 = &.{};
            if (prepared.execution_gas == null) {
                try context.finalizeState();
            } else {
                const result = (try context.runPayload(prepared.request)).result;
                try context.finalizeState();
                status = result.status();
                gas_result = .{
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                    .gas_reservoir = result.gas_reservoir,
                    .state_gas_spent = result.state_gas_spent,
                };
                output = result.output_data;
            }
            // Regolith: even a failed deposit consumes the sender nonce.

            return .{ .completed = .{
                .status = status,
                .gas = try depositGas(context, tx, prepared.gas_plan, gas_result),
                .output = output,
                .created_address = if (status == .success) prepared.created_address else null,
                .source_hash = tx.source_hash,
                .deposit_nonce = prepared.deposit_nonce,
            } };
        }

        fn prepare(context: *Context, tx: DepositTransaction) Error!DepositPrepared {
            const gas_planner = Gas{};
            const gas_plan = gas_planner.gasPlan(tx.input, tx.gas_limit, .{
                .is_create = tx.to == null,
                .value = tx.value,
                .is_self_transfer = if (tx.to) |to| tx.from.eql(to) else false,
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
                    context.input().env.executionContext(.{ .origin = tx.from }),
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
            context: *const Context,
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
            _: *const Context,
            gas_planner: Gas,
            tx: DepositTransaction,
            gas_plan: evmz.transaction.GasPlan,
        ) ?evmz.execution.ExecutionGas {
            const execution_gas = gas_plan.execution orelse return null;
            if (tx.to == null and tx.input.len > gas_planner.maxInitcodeSize()) return null;
            if (spec.transaction.total_gas_limit) |limit| {
                if (tx.gas_limit > limit) return null;
            }
            return execution_gas;
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

pub const OpBlockOutcome = union(enum) {
    rejected: OpRejection,
    included: OpIncludedTransaction,
};

pub const OpExecutorError = evmz.executor.errors.Error;

pub const OpBlockError = OpExecutorError || error{
    MissingCreateRecipient,
    Overflow,
    TransactionCountOverflow,
};

pub const OpTransactError = OpExecutorError || error{
    MissingCreateRecipient,
    Overflow,
};

pub const DepositResult = union(enum) {
    rejected: DepositRejection,
    completed: DepositOutput,
};

pub const EthereumResult = union(enum) {
    rejected: evmz.Evm.Rejection,
    completed: evmz.TxExecutionResult,
};

/// Compile one concrete OP transaction family and its chain-owned block fold.
pub fn OpVm(comptime spec: evmz.Spec) type {
    return struct {
        const Self = @This();
        const Engine = evmz.Engine(spec);

        pub const Executor = Engine.Executor;
        pub const Init = struct {
            state_reader: ?evmz.StateReader = null,
            prepared_code_backend: ?evmz.PreparedCodeBackend = null,
            block_hash_source: ?evmz.BlockHashSource = null,
            reentrant_native_contract_runtime: ?evmz.execution.ReentrantNativeContractRuntime = null,
        };
        pub const Transaction = OpTransaction;
        pub const TransactInput = OpInput;
        pub const Output = OpOutput;
        pub const Rejection = OpRejection;
        pub const Error = OpTransactError;
        pub const Executed = Executor.Executed(OpOutput);
        pub const Outcome = evmz.transaction.TransactOutcomeType(Executed, OpRejection);

        const Context = Engine.Context(OpInput);
        const EthereumTransition = Engine.EthereumTransition(OpInput);
        const Deposit = DepositTransition(spec);

        const Family = struct {
            pub fn transact(
                context: *Context,
                transaction_value: OpTransaction,
            ) OpTransactError!evmz.transaction.TransitionOutcomeType(OpOutput, OpRejection) {
                return switch (transaction_value) {
                    .ethereum => |tx| switch (try EthereumTransition.transact(context, tx)) {
                        .rejected => |reason| .{ .rejected = .{ .ethereum = reason } },
                        .completed => |output| .{ .completed = .{ .ethereum = output } },
                    },
                    .deposit => |tx| switch (try Deposit.transact(context, tx)) {
                        .rejected => |reason| .{ .rejected = .{ .deposit = reason } },
                        .completed => |output| .{ .completed = .{ .deposit = output } },
                    },
                };
            }
        };

        const Program = Engine.Program(
            OpInput,
            OpOutput,
            OpRejection,
            OpTransactError,
            Family,
        );

        pub const BlockExecution = struct {
            executor: *Executor,
            claim: evmz.block.Claim,
            env: evmz.Env,
            transaction_count: u64 = 0,

            pub fn init(
                vm: *Self,
                env: OpEnv,
            ) error{UncommittedChanges}!BlockExecution {
                const executor = &vm.executor;
                return .{
                    .executor = executor,
                    .claim = try evmz.block.Claim.begin(executor),
                    .env = executionEnv(spec, env),
                };
            }

            pub fn transact(self: *BlockExecution, tx: OpTransaction) OpBlockError!OpBlockOutcome {
                const outcome =
                    try Program.transactInBlock(self.executor, self.claim, .{
                        .env = self.env,
                        .tx = tx,
                    }, .normal);

                return switch (outcome) {
                    .rejected => |reason| .{ .rejected = reason },
                    .executed => |executed_value| blk: {
                        var executed = executed_value;
                        defer executed.discardIfCurrent();
                        const view = executed.view();
                        const transaction_count =
                            std.math.add(u64, self.transaction_count, 1) catch
                                return error.TransactionCountOverflow;
                        const included: OpIncludedTransaction = .{
                            .output = view.output.*,
                            .cumulative_transactions = transaction_count,
                        };
                        executed.retain();
                        self.transaction_count = transaction_count;
                        break :blk .{ .included = included };
                    },
                };
            }

            pub fn progress(self: *const BlockExecution) u64 {
                self.claim.requireActive(self.executor);
                return self.transaction_count;
            }

            pub fn finish(self: *BlockExecution) u64 {
                self.claim.requireActive(self.executor);
                const result = self.transaction_count;
                self.claim.release(self.executor);
                return result;
            }

            pub fn discardIfUnfinished(self: *BlockExecution) void {
                self.claim.discardIfUnfinished(self.executor);
            }
        };

        executor: Executor,

        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            return .{ .executor = Executor.init(allocator, .{
                .state = .{ .reader = options.state_reader },
                .prepared_code_backend = options.prepared_code_backend,
                .block_hash_source = options.block_hash_source,
                .reentrant_native_contract_runtime = options.reentrant_native_contract_runtime,
            }) };
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
        }

        /// Generic OP ingress. Resolves family-owned env facts before
        /// transaction-variant dispatch, so callers pass the inherited
        /// env verbatim.
        pub fn transact(self: *Self, input: OpInput) Error!Outcome {
            return Program.transact(&self.executor, input.normalize(spec));
        }

        pub fn transactDeposit(
            self: *Self,
            env: OpEnv,
            transaction_value: DepositTransaction,
        ) OpTransactError!DepositResult {
            return switch (try self.transact(.{
                .env = env,
                .tx = .{ .deposit = transaction_value },
            })) {
                .rejected => |reason| switch (reason) {
                    .deposit => |deposit| .{ .rejected = deposit },
                    .ethereum => unreachable,
                },
                .executed => |executed| switch (executed.retainResult()) {
                    .deposit => |deposit| .{ .completed = deposit },
                    .ethereum => unreachable,
                },
            };
        }

        pub fn transactEthereum(
            self: *Self,
            env: OpEnv,
            transaction_value: EthereumTransaction,
        ) OpTransactError!EthereumResult {
            return switch (try self.transact(.{
                .env = env,
                .tx = .{ .ethereum = transaction_value },
            })) {
                .rejected => |reason| switch (reason) {
                    .ethereum => |ethereum| .{ .rejected = ethereum },
                    .deposit => unreachable,
                },
                .executed => |executed| switch (executed.retainResult()) {
                    .ethereum => |ethereum| .{ .completed = ethereum },
                    .deposit => unreachable,
                },
            };
        }
    };
}

pub const Canyon = OpVm(canyon_spec);
pub const Delta = OpVm(delta_spec);
pub const Ecotone = OpVm(ecotone_spec);
pub const Fjord = OpVm(fjord_spec);

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();
    const revision: OpRevision = if (args.next()) |arg| try parseOpRevision(arg) else OpRevision.canyon;
    if (args.next() != null) return error.UnexpectedArgument;

    return switch (revision) {
        inline else => |rev| runExample(rev, init.gpa),
    };
}

fn runExample(comptime revision: OpRevision, allocator: std.mem.Allocator) !void {
    const spec = switch (revision) {
        .canyon => canyon_spec,
        .delta => delta_spec,
        .ecotone => ecotone_spec,
        .fjord => fjord_spec,
    };
    const Vm = OpVm(spec);
    var vm = Vm.init(allocator, .{});
    defer vm.deinit();

    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    const executed = switch (try vm.transactDeposit(
        .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .{
            .source_hash = [_]u8{0x11} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        },
    )) {
        .completed => |output| output,
        .rejected => return error.UnexpectedRejection,
    };

    if (executed.status != .success) return error.DepositExecutionFailed;
    if (try vm.executor.getBalance(sender) != 7) return error.MintLifecycleMismatch;
    if (try vm.executor.getBalance(recipient) != 3) return error.ValueTransferMismatch;

    std.debug.print("{t} deposit status: {t}, nonce: {d}, gas used: {d}\n", .{
        revision,
        executed.status,
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

fn seedTestAccount(executor: anytype, account_address: Address, balance: u256, code: []const u8) !void {
    var account = evmz.state.MemoryAccount.init(std.testing.allocator);
    account.account.balance = balance;
    if (code.len != 0) try account.setCode(code);
    try executor.state.seedAccount(account_address, account);
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
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    const outcome = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x22} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    });
    const executed = switch (outcome) {
        .executed => |result| result,
        .rejected => unreachable,
    };
    const result = executed.retainResult().deposit;

    try std.testing.expectEqual(evmz.TxStatus.success, result.status);
    try std.testing.expectEqual(@as(u64, 0), result.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 7), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 3), try vm.executor.getBalance(recipient));
}

test "reverted deposit keeps mint and nonce but rolls back EVM writes" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    try seedTestAccount(&vm.executor, recipient, 0, &.{ 0x5f, 0x5f, 0xfd });

    const outcome = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x33} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 10,
            .value = 3,
            .gas_limit = 100_000,
        } },
    });

    const result = outcome.executed.retainResult().deposit;

    try std.testing.expectEqual(evmz.TxStatus.revert, result.status);
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(recipient));
}

test "insufficient-value deposit becomes an included failure after mint" {
    const sender = address.addr(0xaaaa);
    const recipient = address.addr(0xbbbb);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    const outcome = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x34} ** 32,
            .from = sender,
            .to = recipient,
            .mint = 2,
            .value = 3,
            .gas_limit = 100_000,
        } },
    });

    const result = outcome.executed.retainResult().deposit;

    try std.testing.expectEqual(evmz.TxStatus.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 2), try vm.executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(recipient));
}

test "intrinsic-gas failure is included after mint with one nonce increment" {
    const sender = address.addr(0xaaaa);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    const outcome = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x44} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 5,
            .gas_limit = 20_000,
        } },
    });

    const result = outcome.executed.retainResult().deposit;

    try std.testing.expectEqual(evmz.TxStatus.invalid, result.status);
    try std.testing.expectEqual(@as(u64, 20_000), result.gas.used);
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 5), try vm.executor.getBalance(sender));
}

test "create deposit derives address from the pre-execution deposit nonce" {
    const sender = address.addr(0xaaaa);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    const outcome = try vm.transact(.{
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
    });

    const result = outcome.executed.retainResult().deposit;

    try std.testing.expectEqual(evmz.TxStatus.success, result.status);
    try std.testing.expectEqual(address.create(sender, 0), result.created_address.?);
    try std.testing.expectEqual(@as(u64, 0), result.deposit_nonce);
    try std.testing.expectEqual(@as(u64, 1), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
}

test "legacy system deposit is rejected before lifecycle writes" {
    const sender = address.addr(0xaaaa);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
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
        DepositRejection.system_transaction_after_regolith,
        result.rejected.deposit,
    );
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(sender));
}

test "typed block prelude propagates its non-empty error and rolls back" {
    const PreludeError = error{SyntheticPreludeFailure};
    const PreludeContext = Canyon.Program.PreludeContextFor(PreludeError);
    const Prelude = Canyon.Program.PreludeFor(PreludeError);
    const OtherPrelude = Canyon.Program.PreludeFor(error{OtherPreludeFailure});
    comptime std.debug.assert(Prelude.Binding != OtherPrelude.Binding);

    const Probe = struct {
        pub fn run(_: *@This(), _: PreludeContext) PreludeContext.Error!void {
            return error.SyntheticPreludeFailure;
        }
    };

    const sender = address.addr(0xaaaa);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    const claim = try evmz.block.Claim.begin(&vm.executor);
    defer claim.discardIfUnfinished(&vm.executor);
    var probe: Probe = .{};

    try std.testing.expectError(
        error.SyntheticPreludeFailure,
        Canyon.Program.transactInBlockWithPrelude(
            PreludeError,
            &vm.executor,
            claim,
            .{
                .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
                .tx = .{ .deposit = .{
                    .source_hash = [_]u8{0x56} ** 32,
                    .from = sender,
                    .to = address.addr(0xbbbb),
                    .mint = 5,
                    .gas_limit = 100_000,
                } },
            },
            Prelude.init(&probe),
            .normal,
        ),
    );
    claim.requireActive(&vm.executor);
    try std.testing.expect(!vm.executor.hasCurrentTransaction());
    try std.testing.expectEqual(@as(u256, 0), try vm.executor.getBalance(sender));
}

test "Ethereum rejection remains tagged through the OP transaction program" {
    const sender = address.addr(0xaaaa);
    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    try seedTestAccount(&vm.executor, sender, 100, &.{});

    const result = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 1,
            .gas_limit = 100_000,
            .to = address.addr(0xbbbb),
        } },
    });

    try std.testing.expectEqual(@FieldType(Canyon.Rejection, "ethereum").nonce_too_high, result.rejected.ethereum);
    try std.testing.expectEqual(@as(u64, 0), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
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
    sender_account.account.balance = 100;
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&runtime_code);

    var vm = Ecotone.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer vm.deinit();
    var block = try Ecotone.BlockExecution.init(&vm, .{
        .chain_id = 10,
        .gas_limit = 30_000_000,
        .blob_base_fee = 99,
    });
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
    try std.testing.expectEqual(@FieldType(Ecotone.Rejection, "ethereum").type_3_tx_pre_fork, rejected.ethereum);
    try std.testing.expectEqual(@as(u64, 2), block.progress());
    try std.testing.expectEqual(@as(u64, 2), (try vm.executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 2), block.finish());
}

test "OP family ingress owns execution environment normalization" {
    const inherited = evmz.Env{ .blob_base_fee = 99 };
    const tx: OpTransaction = .{ .deposit = .{
        .source_hash = [_]u8{0x01} ** 32,
        .from = address.addr(0xaaaa),
        .to = address.addr(0xbbbb),
        .gas_limit = 100_000,
    } };

    var delta = Delta.init(std.testing.allocator, .{});
    defer delta.deinit();
    const delta_outcome = try delta.transact(
        .{ .env = inherited, .tx = tx },
    );
    delta_outcome.executed.retain();

    var ecotone = Ecotone.init(std.testing.allocator, .{});
    defer ecotone.deinit();
    const ecotone_outcome = try ecotone.transact(
        .{ .env = inherited, .tx = tx },
    );
    ecotone_outcome.executed.retain();

    try std.testing.expectEqual(@as(u256, 99), executionEnv(delta_spec, inherited).blob_base_fee);
    try std.testing.expectEqual(@as(u256, 1), executionEnv(ecotone_spec, inherited).blob_base_fee);
}

test "Ecotone rejects blob transactions while retaining Cancun execution" {
    const sender = address.addr(0xaaaa);
    var vm = Ecotone.init(std.testing.allocator, .{});
    defer vm.deinit();
    const outcome = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000, .blob_base_fee = 99 },
        .tx = .{ .ethereum = .{
            .kind = .blob,
            .sender = sender,
            .gas_limit = 100_000,
            .to = address.addr(0xbbbb),
        } },
    });

    try std.testing.expectEqual(@FieldType(Ecotone.Rejection, "ethereum").type_3_tx_pre_fork, outcome.rejected.ethereum);
    try std.testing.expect(ecotone_spec.transaction.active_kinds.contains(.dynamic_fee));
    try std.testing.expect(!ecotone_spec.transaction.active_kinds.contains(.blob));
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

    var ethereum_vm = Ecotone.init(std.testing.allocator, .{});
    defer ethereum_vm.deinit();
    try seedTestAccount(&ethereum_vm.executor, sender, 1, &.{});
    try seedTestAccount(&ethereum_vm.executor, recipient, 0, &runtime_code);

    {
        const outcome = try ethereum_vm.transact(.{
            .env = env,
            .tx = .{ .ethereum = .{
                .sender = sender,
                .gas_limit = 100_000,
                .to = recipient,
            } },
        });
        const ethereum_output = outcome.executed.retainResult().ethereum;
        try std.testing.expectEqual(evmz.TxStatus.success, ethereum_output.status);
        try expectWordOne(ethereum_output.output);
    }

    {
        var deposit_vm = Ecotone.init(std.testing.allocator, .{});
        defer deposit_vm.deinit();
        try seedTestAccount(&deposit_vm.executor, recipient, 0, &runtime_code);
        const outcome = try deposit_vm.transact(.{
            .env = env,
            .tx = .{ .deposit = .{
                .source_hash = [_]u8{0x88} ** 32,
                .from = sender,
                .to = recipient,
                .gas_limit = 100_000,
            } },
        });
        const deposit_output = outcome.executed.retainResult().deposit;
        try std.testing.expectEqual(evmz.TxStatus.success, deposit_output.status);
        try expectWordOne(deposit_output.output);
    }
}

test "Fjord activates RIP-7212 P256VERIFY at 3450 gas" {
    const p256_address = evmz.precompile.Contract.p256verify.toAddress();
    try std.testing.expect(!ecotone_spec.precompile.active(p256_address));
    try std.testing.expect(fjord_spec.precompile.active(p256_address));

    const gas = fjord_precompile_config.gas.get(.p256verify) + 1;
    const precompile = fjord_spec.precompile.resolve(p256_address).?;
    const result = try fjord_spec.precompile.execute(precompile, .{
        .allocator = std.testing.allocator,
        .input_data = &.{},
        .gas = gas,
    });

    try std.testing.expectEqual(evmz.precompile.Status.success, result.status);
    try std.testing.expectEqual(gas - fjord_precompile_config.gas.get(.p256verify), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}

fn expectWordOne(output: []const u8) !void {
    var expected = [_]u8{0} ** 32;
    expected[31] = 1;
    try std.testing.expectEqualSlices(u8, &expected, output);
}

test "deposit transition uses its exact spec value" {
    const sender = address.addr(0xaaaa);
    const Limited = OpVm(canyon_spec.extend(.{
        .transaction = .{ .total_gas_limit = .{ .replace = 1 } },
    }));

    var vm = Limited.init(std.testing.allocator, .{});
    defer vm.deinit();
    const result = try vm.transact(.{
        .env = .{ .chain_id = 10, .gas_limit = 30_000_000 },
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x77} ** 32,
            .from = sender,
            .to = address.addr(0xbbbb),
            .mint = 1,
            .gas_limit = 100_000,
        } },
    });

    try std.testing.expectEqual(evmz.TxStatus.invalid, result.executed.retainResult().deposit.status);
}

test "unresolved Ethereum transaction keeps exclusive state ownership" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    try seedTestAccount(&vm.executor, sender, 100, &.{});

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

    try std.testing.expect(vm.executor.hasCurrentTransaction());
    _ = execution.result();
    _ = execution.changes();
    try std.testing.expectEqual(@as(u256, 90), (try vm.executor.getAccountOrLoad(sender)).?.balance);
    try std.testing.expectEqual(@as(u256, 10), (try vm.executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expect((try vm.executor.getAccountOrLoad(deposit_recipient)) == null);
}

test "one OP transaction program alternates Ethereum and deposit variants on one overlay" {
    const sender = address.addr(0xaaaa);
    const ethereum_recipient = address.addr(0xbbbb);
    const deposit_recipient = address.addr(0xcccc);
    const env = evmz.Env{ .chain_id = 10, .gas_limit = 30_000_000 };

    var vm = Canyon.init(std.testing.allocator, .{});
    defer vm.deinit();
    try seedTestAccount(&vm.executor, sender, 100, &.{});

    const ethereum_1 = try vm.transact(.{
        .env = env,
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 0,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 10,
        } },
    });
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_1.executed.retainResult().ethereum.status);

    const deposit = try vm.transact(.{
        .env = env,
        .tx = .{ .deposit = .{
            .source_hash = [_]u8{0x66} ** 32,
            .from = sender,
            .to = deposit_recipient,
            .mint = 7,
            .value = 3,
            .gas_limit = 100_000,
        } },
    });
    const deposit_result = deposit.executed.retainResult().deposit;
    try std.testing.expectEqual(evmz.TxStatus.success, deposit_result.status);
    try std.testing.expectEqual(@as(u64, 1), deposit_result.deposit_nonce);

    const reverted_deposit = try vm.transact(.{
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
    });
    const reverted_deposit_result = reverted_deposit.executed.retainResult().deposit;
    try std.testing.expectEqual(evmz.TxStatus.revert, reverted_deposit_result.status);
    try std.testing.expectEqual(@as(u64, 2), reverted_deposit_result.deposit_nonce);

    const ethereum_2 = try vm.transact(.{
        .env = env,
        .tx = .{ .ethereum = .{
            .sender = sender,
            .nonce = 3,
            .gas_limit = 100_000,
            .to = ethereum_recipient,
            .value = 4,
        } },
    });
    try std.testing.expectEqual(evmz.TxStatus.success, ethereum_2.executed.retainResult().ethereum.status);

    const sender_account = (try vm.executor.getAccountOrLoad(sender)).?;
    try std.testing.expectEqual(@as(u64, 4), sender_account.nonce);
    try std.testing.expectEqual(@as(u256, 95), sender_account.balance);
    try std.testing.expectEqual(@as(u256, 14), (try vm.executor.getAccountOrLoad(ethereum_recipient)).?.balance);
    try std.testing.expectEqual(@as(u256, 3), (try vm.executor.getAccountOrLoad(deposit_recipient)).?.balance);
}
