//! Public runtime VM facade.
//!
//! `Vm` is the object an integration holds across blocks. It owns the low-level
//! `executor`, current environment, and optional commit sink. Protocol
//! transactions go through `transact`; diagnostics, benchmarks, and fixtures can
//! drive `executor` directly when they need raw execution control.

const std = @import("std");

const evmz = @import("evm.zig");
const address = @import("./address.zig");
const executor_module = @import("./executor.zig");
const resource_bound = @import("./executor/resource_bound.zig");
const Host = @import("./Host.zig");
const Interpreter = @import("./Interpreter.zig");
const transaction = @import("./transaction.zig");

const Address = address.Address;
const addr = address.addr;
const Changeset = evmz.state.Changeset;
const AccountState = evmz.state.Account;
const MemoryStore = evmz.state.MemoryStore;

pub const StateReader = executor_module.state_io.StateReader;
pub const BlockHashSource = evmz.BlockHashSource;
pub const Committer = executor_module.state_io.Committer;
pub const Log = Host.Log;

/// Block/environment values supplied by the caller.
pub const Env = struct {
    chain_id: u256 = 1,
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    gas_limit: u64 = 0,
    prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
    /// Optional dynamic chain/fixture override for blob gas rules.
    /// When null, transaction validation and settlement use the protocol schedule for the active revision.
    blob_schedule: ?transaction.BlobSchedule = null,

    pub fn txContext(
        self: Env,
        origin: Address,
        gas_price: u256,
        gas_limit: u64,
        blob_hashes: []const u256,
    ) Host.TxContext {
        return .{
            .chain_id = self.chain_id,
            .gas_price = gas_price,
            .origin = origin,
            .coinbase = self.coinbase,
            .number = self.number,
            .slot_number = self.slot_number,
            .timestamp = self.timestamp,
            .gas_limit = gas_limit,
            .prev_randao = self.prev_randao,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .blob_hashes = blob_hashes,
        };
    }
};

/// Block/environment values for VMs whose block gas limit comes from a
/// comptime resource policy.
///
/// `gas_limit` is intentionally not exposed here: the VM injects the policy gas
/// limit when it builds the internal `Env`.
pub const BlockPolicyEnv = struct {
    chain_id: u256 = 1,
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
    slot_number: u64 = 0,
    timestamp: u64 = 0,
    prev_randao: u256 = 0,
    base_fee: u256 = 0,
    blob_base_fee: u256 = 0,
    /// Optional dynamic chain/fixture override for blob gas rules.
    /// When null, transaction validation and settlement use the protocol schedule for the active revision.
    blob_schedule: ?transaction.BlobSchedule = null,

    fn toEnv(self: BlockPolicyEnv, gas_limit: u64) Env {
        return .{
            .chain_id = self.chain_id,
            .coinbase = self.coinbase,
            .number = self.number,
            .slot_number = self.slot_number,
            .timestamp = self.timestamp,
            .gas_limit = gas_limit,
            .prev_randao = self.prev_randao,
            .base_fee = self.base_fee,
            .blob_base_fee = self.blob_base_fee,
            .blob_schedule = self.blob_schedule,
        };
    }
};

/// Terminal status of a transaction that reached execution.
pub const TxStatus = enum {
    success,
    revert,
    invalid,
    out_of_gas,
};

/// Execution payload for a transaction that passed validation and ran.
///
/// `output` is borrowed from the VM and remains valid until the next VM call
/// that can replace call output.
pub const TxExecutionResult = struct {
    status: TxStatus,
    /// Settled transaction gas: receipt gas, refund gas, and block contribution.
    gas: transaction.ResultGas = .{},
    output: []const u8 = &.{},
    created_address: ?Address = null,
};

/// Result of `Vm.transact`.
///
/// Validation rejection is tx/protocol state, not execution. `BlockSession`
/// reports block inclusion failures, such as block gas exhaustion, through
/// Zig errors so rejected transactions cannot accidentally build receipts.
pub fn TxResultFor(comptime Protocol: type) type {
    return union(enum) {
        executed: TxExecutionResult,
        rejected: Protocol.Transaction.ValidationError,
    };
}

/// Borrowed transaction receipt view for client/fixture receipt builders.
///
/// `logs` is borrowed from the VM and is invalidated by the next transaction,
/// discard, commit, or VM teardown. Copy it when constructing owned receipts.
pub const TxReceiptView = struct {
    status: TxStatus,
    /// Receipt gas for this transaction.
    gas_used: u64 = 0,
    /// Receipt cumulative gas across accepted transactions in this block session.
    cumulative_gas_used: u64 = 0,
    created_address: ?Address = null,
    logs: []const Log = &.{},
};

/// Summary of accepted transactions in a `BlockSession`.
pub const BlockResult = struct {
    /// Cumulative receipt gas.
    gas_used: u64 = 0,
    /// Cumulative block/header gas contribution.
    block_gas: transaction.BlockGas = .{},
    tx_count: u64 = 0,
};

/// Read-only account view borrowed from the VM overlay/state-reader cache.
pub const AccountView = struct {
    nonce: u64,
    balance: u256,
    code: []const u8 = &.{},
};

pub const Call = executor_module.Call;
pub const Create = executor_module.Create;
pub const Message = executor_module.Message;
pub const EvmResult = executor_module.EvmResult;
pub const RuntimeResources = executor_module.RuntimeResources;
pub const BoundedRuntimeResources = executor_module.BoundedRuntimeResources;

/// Explicit non-transaction system call for block-hook style operations.
pub const SystemCall = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
};

/// The runtime VM bound to a concrete `Protocol`.
///
/// Returns the facade described in the module doc: an object held across blocks
/// that validates and runs `Protocol` transactions via `transact`, groups them
/// into a block through `BlockSession`, and commits the resulting state diff.
/// `evm.zig` exposes the mainnet instantiation as `Evm`.
pub fn Vm(comptime Protocol: type) type {
    return VmWithOptions(Protocol, .{});
}

pub fn VmWithOptions(comptime Protocol: type, comptime options_literal: anytype) type {
    const vm_options = parseVmOptions(options_literal);
    const block_resource_bound = vm_options.resource_bound;
    const block_policy_gas_limit = vm_options.blockGasLimit();
    const block_policy_max_live_frames = vm_options.max_live_frames;

    return struct {
        const Self = @This();
        const Executor = executor_module.Executor(Protocol);
        const tx_protocol = transaction.For(Protocol);
        const has_block_resource_policy = block_resource_bound != null;

        pub const Transaction = Protocol.Transaction.Value;
        pub const TxResult = TxResultFor(Protocol);
        pub const PreparedTransaction = transaction.Prepared(Protocol);
        pub const PreparedTransactionResult = transaction.PrepareResult(Protocol);

        /// Low-level execution substrate for diagnostics, fixtures, and benchmarks.
        executor: Executor,
        /// Current block/environment values used to build transaction host contexts.
        env: BlockEnv,
        /// Optional sink used by `commit` to persist the overlay diff.
        committer: ?Committer,

        pub const BlockEnv = if (has_block_resource_policy) BlockPolicyEnv else Env;
        pub const InitResult = if (has_block_resource_policy) anyerror!Self else Self;

        pub const Init = struct {
            revision: Protocol.Revision,
            state_reader: ?StateReader = null,
            block_hash_source: ?BlockHashSource = null,
            committer: ?Committer = null,
            env: BlockEnv = .{},
            config: evmz.ExecutionConfig = .base,
            trace_sink: ?*evmz.trace.Sink = null,
        };

        pub const RuntimeResources = executor_module.RuntimeResources;
        pub const BoundedRuntimeResources = executor_module.BoundedRuntimeResources;
        pub const BlockGas = transaction.BlockGas;
        pub const ResultGas = transaction.ResultGas;

        /// A single block's transaction sequence over one `Vm`.
        ///
        /// It executes session for multiple txs under one env, Not a Ethereum block processor.
        /// Feed transactions through `transact` to accumulate block-level gas
        /// and the transaction count; each executable call snapshots so a tx
        /// that cannot fit this block rolls back without tearing down the block.
        pub const BlockSession = struct {
            vm: *Self,
            /// Cumulative receipt gas for accepted transactions.
            gas_used: u64 = 0,
            /// Cumulative block/header gas for accepted transactions.
            block_gas: transaction.BlockGas = .{},
            tx_count: u64 = 0,

            pub fn transact(self: *BlockSession, tx: Self.Transaction) !Self.TxResult {
                const prepared = try self.vm.prepareTransaction(tx);
                switch (prepared) {
                    .rejected => |err| return .{ .rejected = err },
                    .executable => |executable| {
                        var pre_tx = try self.vm.executor.snapshot();
                        defer pre_tx.deinit(self.vm.executor.allocator);

                        const result = try self.vm.executePreparedTransaction(executable);
                        const next_gas_used = std.math.add(u64, self.gas_used, result.gas.used) catch {
                            return self.drop(&pre_tx);
                        };
                        const next_block_gas = self.block_gas.add(result.gas.block) catch {
                            return self.drop(&pre_tx);
                        };
                        if (!next_block_gas.withinLimit(self.vm.runtimeEnv().gas_limit)) {
                            return self.drop(&pre_tx);
                        }

                        self.gas_used = next_gas_used;
                        self.block_gas = next_block_gas;
                        self.tx_count += 1;
                        return .{ .executed = result };
                    },
                }
            }

            pub fn receipt(self: *const BlockSession, result: TxExecutionResult) TxReceiptView {
                return .{
                    .status = result.status,
                    .gas_used = result.gas.used,
                    .cumulative_gas_used = self.gas_used,
                    .created_address = result.created_address,
                    .logs = self.vm.logs(),
                };
            }

            pub fn systemCall(self: *BlockSession, call: SystemCall) !EvmResult {
                var pre_call = try self.vm.executor.snapshot();
                defer pre_call.deinit(self.vm.executor.allocator);

                const result = try self.vm.executeSystemCall(call);
                const spent = systemCallGasUsed(call.gas, result.gasLeft());
                const next_block_gas = self.block_gas.add(transaction.BlockGas.legacy(spent)) catch {
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const next_gas_used = std.math.add(u64, self.gas_used, spent) catch {
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                };
                const env = self.vm.runtimeEnv();
                if (!next_block_gas.withinLimit(env.gas_limit)) {
                    try self.vm.executor.restore(&pre_call);
                    return error.GasAllowanceExceeded;
                }

                self.gas_used = next_gas_used;
                self.block_gas = next_block_gas;
                return result;
            }

            pub fn finish(self: *const BlockSession) BlockResult {
                return .{
                    .gas_used = self.gas_used,
                    .block_gas = self.block_gas,
                    .tx_count = self.tx_count,
                };
            }

            fn drop(self: *BlockSession, pre_tx: *Executor.Snapshot) !Self.TxResult {
                try self.vm.executor.restore(pre_tx);
                return error.BlockGasExceeded;
            }
        };

        pub fn init(allocator: std.mem.Allocator, options: Init) InitResult {
            if (comptime has_block_resource_policy) {
                return initWithRuntimeResourcesInternal(allocator, options, .{
                    .bounded = try boundedRuntimeResourcesForBlockPolicy(options.revision),
                });
            }

            return .{
                .executor = Executor.init(allocator, .{
                    .revision = options.revision,
                    .state_reader = options.state_reader,
                    .block_hash_source = options.block_hash_source,
                    .config = options.config,
                    .trace_sink = options.trace_sink,
                }),
                .env = options.env,
                .committer = options.committer,
            };
        }

        /// Initialize a VM and reserve reusable execution resources up front.
        pub fn initWithRuntimeResources(allocator: std.mem.Allocator, options: Init, runtime_resources: executor_module.RuntimeResources) !Self {
            if (comptime has_block_resource_policy) {
                @compileError("block resource policy VMs reserve resources through init");
            }
            return initWithRuntimeResourcesInternal(allocator, options, runtime_resources);
        }

        fn initWithRuntimeResourcesInternal(allocator: std.mem.Allocator, options: Init, runtime_resources: executor_module.RuntimeResources) !Self {
            var result = Self{
                .executor = try Executor.initWithRuntimeResources(allocator, .{
                    .revision = options.revision,
                    .state_reader = options.state_reader,
                    .block_hash_source = options.block_hash_source,
                    .config = options.config,
                    .trace_sink = options.trace_sink,
                }, runtime_resources),
                .env = options.env,
                .committer = options.committer,
            };
            if (comptime has_block_resource_policy) {
                result.executor.lockRuntimeResources();
            }
            return result;
        }

        pub fn boundedRuntimeResourcesForBlockPolicy(revision: Protocol.Revision) !executor_module.BoundedRuntimeResources {
            if (comptime !has_block_resource_policy) {
                @compileError("boundedRuntimeResourcesForBlockPolicy requires .block_policy.resource_bound");
            }
            const envelope = try resourceEnvelopeForBlockPolicy(revision);
            return executor_module.BoundedRuntimeResources.fromResourceEnvelope(envelope);
        }

        fn resourceEnvelopeForBlockPolicy(revision: Protocol.Revision) !resource_bound.Envelope {
            return switch (block_resource_bound.?) {
                .gas_derived => |gas| try tx_protocol.gas_bound.resourceEnvelope(.{
                    .revision = revision,
                    .block_gas_limit = gas.block_gas_limit,
                    .max_live_frames = block_policy_max_live_frames,
                }),
            };
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
        }

        /// Rebind fixture/benchmark inputs while retaining executor capacity.
        pub fn reset(self: *Self, options: Init) !void {
            try self.executor.reset(.{
                .revision = options.revision,
                .state_reader = options.state_reader,
                .block_hash_source = options.block_hash_source,
                .config = options.config,
                .trace_sink = options.trace_sink,
            });
            self.env = options.env;
            self.committer = options.committer;
        }

        pub fn setEnv(self: *Self, env: BlockEnv) void {
            self.env = env;
        }

        pub fn beginBlock(self: *Self, env: BlockEnv) BlockSession {
            self.setEnv(env);
            return .{ .vm = self };
        }

        pub fn envContext(self: *const Self) Env {
            return self.runtimeEnv();
        }

        pub fn getAccount(self: *Self, address_value: Address) !?AccountView {
            const account = try self.executor.getAccountOrLoad(address_value) orelse return null;
            return .{
                .nonce = account.nonce,
                .balance = account.balance,
                .code = account.code,
            };
        }

        pub fn getStorage(self: *Self, address_value: Address, key: u256) !u256 {
            return self.executor.getStorage(address_value, key);
        }

        /// Borrow logs emitted by the most recent transaction/system-call scope.
        ///
        /// Receipt builders can copy these immediately after `transact`; the slice is
        /// invalidated by the next transaction, discard, commit, or VM teardown.
        pub fn logs(self: *const Self) []const Log {
            return self.executor.logs();
        }

        /// Execute an explicit non-transaction system call.
        pub fn systemCall(self: *Self, call: SystemCall) !EvmResult {
            if (comptime has_block_resource_policy) {
                @compileError("block resource policy VMs must execute system calls through BlockSession");
            }
            return self.executeSystemCall(call);
        }

        fn executeSystemCall(self: *Self, call: SystemCall) !EvmResult {
            const env = self.runtimeEnv();
            if (env.gas_limit != 0 and call.gas > env.gas_limit) return error.GasAllowanceExceeded;
            const context_gas_limit = if (env.gas_limit == 0) call.gas else env.gas_limit;
            const result = try self.executor.executeSystemCall(
                env.txContext(call.sender, 0, context_gas_limit, &.{}),
                call.sender,
                call.recipient,
                call.input,
                call.gas,
            );
            return Host.Result.fromCall(.{
                .status = result.status,
                .output_data = result.output_data,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        }

        /// Execute one protocol transaction into the VM overlay.
        pub fn transact(self: *Self, tx: Self.Transaction) !Self.TxResult {
            if (comptime has_block_resource_policy) {
                @compileError("block resource policy VMs must transact through BlockSession");
            }
            const prepared = try self.prepareTransaction(tx);
            return switch (prepared) {
                .rejected => |err| .{ .rejected = err },
                .executable => |executable| .{ .executed = try self.executePreparedTransaction(executable) },
            };
        }

        fn prepareTransaction(self: *Self, tx: Self.Transaction) !Self.PreparedTransactionResult {
            self.executor.clearLogs();
            const env = self.runtimeEnv();
            const view = Protocol.Transaction.view(tx);
            const input: transaction.PrepareInput(Protocol) = .{
                .revision = self.executor.revision(),
                .tx = tx,
                .view = view,
                .env = envFacts(env),
                .state = try self.stateFacts(view),
            };
            return Protocol.Transaction.prepare(Protocol, input);
        }

        fn executePreparedTransaction(self: *Self, prepared: Self.PreparedTransaction) !TxExecutionResult {
            try self.executor.beginTransactionScope(prepared.scope, prepared.root);
            errdefer self.executor.closeTransaction();
            const result = try self.executor.runTopLevelTransaction(prepared.scope, prepared.root, .{
                .execution = prepared.execution_gas,
                .settlement = prepared.settlement,
            });

            const costs = try tx_protocol.settlement.planCosts(prepared.settlement, .{
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
            });
            return .{
                .status = txStatus(result.status),
                .gas = costs.gas,
                .output = result.output_data,
                .created_address = if (result.status == .success) prepared.created_address else null,
            };
        }

        /// Convenience for one-off callers. Block executors should usually call
        /// `transact` many times, then one `commit`.
        pub fn transactCommit(self: *Self, tx: Self.Transaction) !Self.TxResult {
            if (comptime has_block_resource_policy) {
                @compileError("block resource policy VMs must transact through BlockSession");
            }
            const result = try self.transact(tx);
            switch (result) {
                .rejected => return result,
                .executed => {},
            }
            try self.commit();
            return result;
        }

        fn stateFacts(self: *Self, view: Protocol.Transaction.View) !transaction.StateFacts {
            const sender_account = try self.executor.getAccountOrLoad(view.sender);
            const sender_balance: u256 = if (sender_account) |account| account.balance else 0;
            const sender_nonce: u64 = if (sender_account) |account| account.nonce else 0;
            const sender_code_kind = if (sender_account) |account| senderCodeKind(account) else transaction.SenderCodeKind.empty;
            return .{
                .sender_balance = sender_balance,
                .sender_nonce = sender_nonce,
                .sender_code_kind = sender_code_kind,
                .value_transfer_creates_account = try self.valueTransferCreatesAccount(view),
            };
        }

        fn senderCodeKind(account: *const AccountState) transaction.SenderCodeKind {
            if (account.code.len == 0) return .empty;
            if (executor_module.eip7702.delegationTarget(account.code) != null) return .delegation;
            return .non_delegating;
        }

        fn valueTransferCreatesAccount(self: *Self, view: Protocol.Transaction.View) !bool {
            if (view.value == 0 or view.to == null or isSelfTransfer(view)) return false;
            return (try self.executor.getAccountOrLoad(view.to.?)) == null;
        }

        fn isSelfTransfer(view: Protocol.Transaction.View) bool {
            const recipient = view.to orelse return false;
            return std.mem.eql(u8, &view.sender, &recipient);
        }

        fn envFacts(env: Env) transaction.EnvFacts {
            return .{
                .chain_id = env.chain_id,
                .coinbase = env.coinbase,
                .number = env.number,
                .slot_number = env.slot_number,
                .timestamp = env.timestamp,
                .gas_limit = env.gas_limit,
                .prev_randao = env.prev_randao,
                .base_fee = env.base_fee,
                .blob_base_fee = env.blob_base_fee,
                .blob_schedule = env.blob_schedule,
            };
        }

        fn txStatus(status: Interpreter.Status) TxStatus {
            return switch (status) {
                .success => .success,
                .revert => .revert,
                .invalid => .invalid,
                .out_of_gas => .out_of_gas,
            };
        }

        fn systemCallGasUsed(gas: u64, gas_left: i64) u64 {
            if (gas_left <= 0) return gas;
            const left = std.math.cast(u64, gas_left) orelse return 0;
            return gas -| @min(gas, left);
        }

        /// Return the current pending state diff without persisting it.
        pub fn changeset(self: *Self) !Changeset {
            return self.executor.changeset();
        }

        /// Drop pending overlay changes without writing them to the commit sink.
        pub fn discard(self: *Self) void {
            self.executor.discardChanges();
        }

        /// Persist the current overlay diff, then rebase the VM to the updated state reader.
        ///
        /// The committer is expected to write to the same canonical state observed by
        /// the reader. After a successful commit, the in-memory overlay is cleared so
        /// the same VM can process the next block.
        pub fn commit(self: *Self) !void {
            const committer = self.committer orelse return error.ReadOnly;
            var diff = try self.executor.changeset();
            defer diff.deinit(self.executor.allocator);
            try committer.commit(&diff);
            self.executor.discardChanges();
        }

        fn applyBlockEnvPolicy(env: BlockEnv) Env {
            if (comptime has_block_resource_policy) {
                return env.toEnv(block_policy_gas_limit.?);
            }
            return env;
        }

        fn runtimeEnv(self: *const Self) Env {
            return applyBlockEnvPolicy(self.env);
        }
    };
}

const ParsedVmOptions = struct {
    resource_bound: ?BlockResourceBoundSource = null,
    max_live_frames: usize = executor_module.default_max_live_frames,

    fn blockGasLimit(self: ParsedVmOptions) ?u64 {
        return switch (self.resource_bound orelse return null) {
            .gas_derived => |gas| gas.block_gas_limit,
        };
    }
};

const GasDerivedBlockResourceBound = struct {
    block_gas_limit: u64,
};

const BlockResourceBoundSource = union(enum) {
    gas_derived: GasDerivedBlockResourceBound,
};

fn parseVmOptions(comptime options: anytype) ParsedVmOptions {
    const Options = @TypeOf(options);
    switch (@typeInfo(Options)) {
        .@"struct" => {},
        else => @compileError("Vm options must be a struct literal"),
    }

    var parsed = ParsedVmOptions{};
    if (@hasField(Options, "block_policy")) {
        const block_policy = options.block_policy;
        const BlockPolicy = @TypeOf(block_policy);
        switch (@typeInfo(BlockPolicy)) {
            .@"struct" => {},
            else => @compileError("Vm block_policy must be a struct literal"),
        }
        if (!@hasField(BlockPolicy, "resource_bound")) {
            @compileError("Vm block_policy must provide resource_bound");
        }
        parsed.resource_bound = parseBlockResourceBound(block_policy.resource_bound);
        if (@hasField(BlockPolicy, "max_live_frames")) {
            parsed.max_live_frames = block_policy.max_live_frames;
        }
    }
    return parsed;
}

fn parseBlockResourceBound(comptime resource_bound_options: anytype) BlockResourceBoundSource {
    const ResourceBound = @TypeOf(resource_bound_options);
    switch (@typeInfo(ResourceBound)) {
        .@"struct" => {},
        else => @compileError("Vm block_policy.resource_bound must be a struct literal"),
    }

    if (@hasField(ResourceBound, "gas_derived")) {
        return .{
            .gas_derived = parseGasDerivedBlockResourceBound(resource_bound_options.gas_derived),
        };
    }

    @compileError("Vm block_policy.resource_bound must provide gas_derived");
}

fn parseGasDerivedBlockResourceBound(comptime gas_derived: anytype) GasDerivedBlockResourceBound {
    const GasDerived = @TypeOf(gas_derived);
    switch (@typeInfo(GasDerived)) {
        .@"struct" => {},
        else => @compileError("Vm block_policy.resource_bound.gas_derived must be a struct literal"),
    }

    if (!@hasField(GasDerived, "block_gas_limit")) {
        @compileError("Vm block_policy.resource_bound.gas_derived must provide block_gas_limit");
    }
    if (gas_derived.block_gas_limit == 0) {
        @compileError("Vm block_policy.resource_bound.gas_derived.block_gas_limit must be non-zero");
    }

    return .{ .block_gas_limit = gas_derived.block_gas_limit };
}

const Default = evmz.Evm;

fn expectExecuted(result: Default.TxResult) !TxExecutionResult {
    return switch (result) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}

fn expectRejected(result: Default.TxResult) !transaction.ValidationError {
    return switch (result) {
        .executed => error.UnexpectedExecution,
        .rejected => |err| err,
    };
}

test "Vm exposes protocol verbs and low-level executor field" {
    try std.testing.expect(@hasDecl(Default, "transact"));
    try std.testing.expect(@hasDecl(Default, "beginBlock"));
    try std.testing.expect(@hasDecl(Default.BlockSession, "receipt"));
    try std.testing.expect(@hasDecl(Default, "systemCall"));
    try std.testing.expect(@hasDecl(Default, "logs"));
    try std.testing.expect(@hasDecl(Default, "commit"));
    try std.testing.expect(@hasField(Default, "executor"));
}

test "Vm initializes and exposes empty changeset" {
    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .env = .{ .chain_id = 1 },
    });
    defer vm.deinit();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Vm executor runs low-level standalone call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    const call = Call{
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
    };
    const context_gas_limit = if (vm.env.gas_limit == 0) call.gas else vm.env.gas_limit;
    const result = (try vm.executor.runStandalone(
        vm.env.txContext(call.sender, 0, context_gas_limit, &.{}),
        .{ .call = call },
    )).expectCall();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0), diff.storage_writes.items[0].key);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm executor runs low-level standalone create" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create = Create{
        .sender = sender,
        .init_code = init_code,
        .gas = 100_000,
    };
    const context_gas_limit = if (vm.env.gas_limit == 0) create.gas else vm.env.gas_limit;
    const result = (try vm.executor.runStandalone(
        vm.env.txContext(create.sender, 0, context_gas_limit, &.{}),
        .{ .create = create },
    )).expectCreate();
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.account_updates.items[1].code);
}

test "Vm transact validates and executes call transaction" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try std.testing.expectEqual(result.gas.used, result.gas.block.total);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm transact forwards BLOCKHASH to configured block hash source" {
    const TestBlockHashSource = struct {
        const Self = @This();

        last_number: ?u64 = null,

        fn source(self: *Self) BlockHashSource {
            return .{ .ptr = self, .vtable = &.{
                .getBlockHash = getBlockHash,
            } };
        }

        fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_number = number;
            return if (number == 999) 0xab else null;
        }
    };

    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x61, 0x03, 0xe7, 0x40, 0x5f, 0x55, 0x00 });

    var block_hashes = TestBlockHashSource{};
    var vm = Default.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
        .block_hash_source = block_hashes.source(),
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0xab), diff.storage_writes.items[0].value);
}

test "Vm transact reports successful create address" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .gas_limit = 300_000,
        .input = init_code,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.created_address.?);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.account_updates.items[1].code);
}

test "Vm transact returns rejected validation result" {
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    sender_account.nonce = 7;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = addr(0xbbbb),
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, try expectRejected(result));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "Vm rejected transaction preserves pending overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    const rejected = try vm.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = contract,
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, try expectRejected(rejected));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Vm commit applies changeset and rebases overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .committer = memory.committer(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    try vm.commit();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
}

test "Vm discard drops pending overlay without touching state reader" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    vm.discard();

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Vm read-only commit leaves pending overlay intact" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    try std.testing.expectError(error.ReadOnly, vm.commit());

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Vm transactCommit skips commit for rejected transaction" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(std.testing.allocator, &.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .committer = memory.committer(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    _ = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
    });
    const rejected = try vm.transactCommit(.{
        .sender = sender,
        .nonce = 99,
        .to = contract,
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
}

test "Vm Amsterdam transaction reports gross block gas separately from receipt gas" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(std.testing.allocator, &.{ 0x5f, 0x5f, 0x55, 0x00 });

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.refunded > 0);
    try std.testing.expect(result.gas.block.total > result.gas.used);
}

test "Vm exposes borrowed logs for client receipt builders" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &vm.logs()[0].address);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, vm.logs()[0].topics[0]);
}

test "Vm rejected transaction clears borrowed log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const accepted = try expectExecuted(try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);

    const rejected = try vm.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expectEqual(@as(usize, 0), vm.logs().len);
}

test "Vm preparation uses comptime transaction gas policy" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_prepared = try vm.prepareTransaction(tx);
    switch (default_prepared) {
        .executable => {},
        .rejected => return error.UnexpectedRejection,
    }

    const HighIntrinsicProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const Transaction = struct {
            pub const Value = transaction.Transaction;
            pub const View = transaction.TransactionView;
            pub const ValidationError = transaction.ValidationError;

            pub fn view(value: Value) View {
                return transaction.transactionView(value);
            }

            pub fn prepare(comptime ProtocolType: type, input: transaction.PrepareInput(ProtocolType)) !transaction.PrepareResult(ProtocolType) {
                return transaction.For(ProtocolType).prepare.prepare(input);
            }

            pub fn kindActive(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn allowsContractCreation(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return true;
            }

            pub fn requiresAuthorizationList(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn rejectsNonDelegatingSenderCode(revision: Revision, kind: transaction.TxKind) bool {
                _ = revision;
                _ = kind;
                return false;
            }

            pub fn blobSchedule(revision: Revision) ?transaction.BlobSchedule {
                _ = revision;
                return null;
            }

            pub fn blobVersionedHashActive(revision: Revision, version: u8) bool {
                _ = revision;
                _ = version;
                return false;
            }

            pub fn maxInitcodeSize(revision: Revision) usize {
                _ = revision;
                return std.math.maxInt(usize);
            }

            pub fn intrinsicBaseGas(revision: Revision, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 42_000;
            }

            pub fn createIntrinsicGas(revision: Revision) ?u64 {
                _ = revision;
                return 0;
            }

            pub fn dataByteGas(revision: Revision, byte: u8) u64 {
                _ = revision;
                _ = byte;
                return 0;
            }

            pub fn accessListAddressGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn storageKeyGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn accessListDataGas(revision: Revision, counts: transaction.AccessListCounts) ?u64 {
                _ = revision;
                _ = counts;
                return 0;
            }

            pub fn initCodeWordGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn authorizationIntrinsicGas(revision: Revision) u64 {
                _ = revision;
                return 0;
            }

            pub fn intrinsicStateGas(revision: Revision, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 0;
            }

            pub fn floorGas(revision: Revision, input: []const u8, options: transaction.IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = input;
                _ = options;
                return null;
            }

            pub fn regularGasLimit(revision: Revision, gas_limit: u64) u64 {
                _ = revision;
                return gas_limit;
            }

            pub fn intrinsicRegularGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return null;
            }

            pub fn totalGasLimit(revision: Revision) ?u64 {
                _ = revision;
                return null;
            }
        };

        pub const Settlement = struct {
            pub const Plan = transaction.Settlement;

            pub fn baseFeeActive(revision: Revision) bool {
                _ = revision;
                return true;
            }

            pub fn gasRefundCapDivisor(revision: Revision) u64 {
                _ = revision;
                return 5;
            }

            pub fn usesStateGasAccounting(revision: Revision) bool {
                _ = revision;
                return false;
            }
        };
    };

    const HighIntrinsicVm = Vm(HighIntrinsicProtocol);
    var custom_vm = HighIntrinsicVm.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer custom_vm.deinit();

    const custom_prepared = try custom_vm.prepareTransaction(tx);
    switch (custom_prepared) {
        .executable => try std.testing.expect(false),
        .rejected => |err| try std.testing.expectEqual(transaction.ValidationError.intrinsic_gas_too_low, err),
    }
}

test "Vm preparation accepts custom transaction value" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);

    const CustomProtocol = struct {
        pub const Revision = enum { custom };

        pub const Transaction = struct {
            pub const Value = struct {
                from: Address,
                target: Address,
                amount: u256 = 0,
                gas: u64,
            };
            pub const View = transaction.TransactionView;
            pub const ValidationError = enum { rejected };

            pub fn view(value: Value) View {
                return .{
                    .sender = value.from,
                    .to = value.target,
                    .gas_limit = value.gas,
                    .value = value.amount,
                };
            }

            pub fn prepare(comptime ProtocolType: type, input: transaction.PrepareInput(ProtocolType)) !transaction.PrepareResult(ProtocolType) {
                return .{ .executable = .{
                    .created_address = null,
                    .scope = .{
                        .context = .init(input.env, input.view.sender, 7, input.env.gas_limit, &.{}),
                    },
                    .root = .init(.{
                        .sender = input.view.sender,
                        .to = input.view.to,
                        .gas_limit = input.view.gas_limit,
                        .value = input.view.value,
                    }),
                    .execution_gas = transaction.ExecutionGas.legacy(12_345),
                    .settlement = .{
                        .revision = input.revision,
                        .marker = 9,
                    },
                } };
            }
        };

        pub const Settlement = struct {
            pub const Plan = struct {
                revision: Revision,
                marker: u8,
            };

            pub fn costs(comptime ProtocolType: type, plan: Plan, result: transaction.ExecutionGasResult) !transaction.SettlementCosts {
                _ = ProtocolType;
                _ = plan;
                _ = result;
                return .{
                    .gas = .{},
                    .sender_refund = 0,
                    .coinbase_payment = 0,
                };
            }
        };
    };

    const CustomVm = Vm(CustomProtocol);
    var vm = CustomVm.init(std.testing.allocator, .{
        .revision = .custom,
        .env = .{ .gas_limit = 99_000 },
    });
    defer vm.deinit();

    const prepared = try vm.prepareTransaction(.{
        .from = sender,
        .target = recipient,
        .amount = 5,
        .gas = 50_000,
    });

    const executable = switch (prepared) {
        .rejected => return error.UnexpectedRejection,
        .executable => |value| value,
    };

    try std.testing.expectEqual(@as(u256, 7), executable.scope.context.gas_price);
    try std.testing.expectEqual(@as(u64, 12_345), executable.execution_gas.?.regular_left);
    try std.testing.expectEqual(@as(u8, 9), executable.settlement.marker);
    try std.testing.expectEqual(@as(u64, 50_000), executable.root.gasLimit());
    try std.testing.expectEqual(@as(u256, 5), executable.root.value());
}

test "BlockSession validation rejection skips rollback snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var vm = Default.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    try std.testing.expect((try vm.getAccount(sender)) != null);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var block = vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, try expectRejected(rejected));
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), block.finish().tx_count);
}

test "Vm systemCall uses bound executor protocol" {
    var vm = Default.init(std.testing.allocator, .{
        .revision = .prague,
    });
    defer vm.deinit();

    const result = try vm.systemCall(.{
        .sender = addr(0xaaaa),
        .recipient = addr(0xbbbb),
        .gas = 50_000,
    });

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{}, result.outputData());
}

test "BlockSession accumulates block gas and rolls back overflow transaction" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = 29_000 });
    const accepted = try expectExecuted(try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(u64, 15_000), accepted.gas.block.total);
    try std.testing.expectEqual(@as(u64, 1), block.finish().tx_count);

    try std.testing.expectError(error.BlockGasExceeded, block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    }));
    try std.testing.expectEqual(@as(u64, 1), block.finish().tx_count);

    var diff = try vm.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "BlockSession builds borrowed receipt view with cumulative gas and logs" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Default.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const result = try expectExecuted(try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    }));
    const receipt = block.receipt(result);

    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas.used, receipt.gas_used);
    try std.testing.expectEqual(result.gas.used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, receipt.logs[0].topics[0]);
}
