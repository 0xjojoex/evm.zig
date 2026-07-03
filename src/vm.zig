//! Public runtime VM facade.
//!
//! `Vm` is the object an integration holds across blocks. It owns the low-level
//! `executor`, current environment, and optional commit sink. Protocol
//! transactions go through `transact`; diagnostics, benchmarks, and fixtures can
//! drive `executor` directly when they need raw execution control.

const std = @import("std");

const evmz = @import("evm.zig");
const address = @import("./address.zig");
const Executor = @import("./executor.zig");
const Host = @import("./Host.zig");
const Interpreter = @import("./Interpreter.zig");
const transaction = @import("./transaction.zig");

const Address = address.Address;
const addr = address.addr;
const Changeset = evmz.state.Changeset;
const AccountState = evmz.state.Account;
const MemoryStore = evmz.state.MemoryStore;

const Vm = @This();

/// Low-level execution substrate for diagnostics, fixtures, and benchmarks.
executor: Executor,
/// Current block/environment values used to build transaction host contexts.
env: Env,
/// Optional sink used by `commit` to persist the overlay diff.
committer: ?Committer,

pub const StateReader = Executor.state_io.StateReader;
pub const BlockHashSource = evmz.BlockHashSource;
pub const Committer = Executor.state_io.Committer;
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

pub const Init = struct {
    spec: evmz.Spec,
    state_reader: ?StateReader = null,
    block_hash_source: ?BlockHashSource = null,
    committer: ?Committer = null,
    env: Env = .{},
    config: evmz.Config = .base,
    trace_sink: ?*evmz.trace.Sink = null,
};

/// Protocol-level transaction input for `Vm.transact`.
pub const Transaction = struct {
    kind: transaction.TxKind = .legacy,
    sender: Address,
    nonce: ?u64 = null,
    gas_limit: u64,
    to: ?Address = null,
    value: u256 = 0,
    input: []const u8 = &.{},
    gas_price: u256 = 0,
    max_fee_per_gas: ?u256 = null,
    max_priority_fee_per_gas: ?u256 = null,
    max_fee_per_blob_gas: ?u256 = null,
    blob_hashes: []const u256 = &.{},
    access_list: []const transaction.AccessListEntry = &.{},
    authorization_list: []const transaction.AuthorizationTuple = &.{},
    authorization_count: ?usize = null,
};

pub const TxStatus = enum {
    success,
    revert,
    invalid,
    out_of_gas,
    rejected,
};

/// Result of `Vm.transact`.
///
/// `output` is borrowed from the VM and remains valid until the next VM call
/// that can replace call output.
pub const TxResult = struct {
    status: TxStatus,
    gas_used: u64 = 0,
    block_gas_used: u64 = 0,
    gas_refunded: u64 = 0,
    output: []const u8 = &.{},
    created_address: ?Address = null,
    validation_error: ?transaction.ValidationError = null,
};

/// Borrowed transaction receipt view for client/fixture receipt builders.
///
/// `logs` is borrowed from the VM and is invalidated by the next transaction,
/// discard, commit, or VM teardown. Copy it when constructing owned receipts.
pub const TxReceiptView = struct {
    status: TxStatus,
    gas_used: u64 = 0,
    block_gas_used: u64 = 0,
    cumulative_gas_used: u64 = 0,
    created_address: ?Address = null,
    logs: []const Log = &.{},
};

pub const BlockResult = struct {
    gas_used: u64 = 0,
    block_gas_used: u64 = 0,
    tx_count: u64 = 0,
};

pub const BlockSession = struct {
    vm: *Vm,
    gas_used: u64 = 0,
    block_gas_used: u64 = 0,
    tx_count: u64 = 0,

    pub fn transact(self: *BlockSession, tx: Transaction) !TxResult {
        var pre_tx = try self.vm.executor.snapshot();
        defer pre_tx.deinit(self.vm.executor.allocator);

        const result = try self.vm.transact(tx);
        if (result.status == .rejected) return result;

        const next_block_gas = std.math.add(u64, self.block_gas_used, result.block_gas_used) catch {
            try self.vm.executor.restore(&pre_tx);
            return .{
                .status = .rejected,
                .validation_error = .gas_allowance_exceeded,
            };
        };
        if (self.vm.env.gas_limit != 0 and next_block_gas > self.vm.env.gas_limit) {
            try self.vm.executor.restore(&pre_tx);
            return .{
                .status = .rejected,
                .validation_error = .gas_allowance_exceeded,
            };
        }

        self.gas_used += result.gas_used;
        self.block_gas_used = next_block_gas;
        self.tx_count += 1;
        return result;
    }

    pub fn receipt(self: *const BlockSession, result: TxResult) TxReceiptView {
        return .{
            .status = result.status,
            .gas_used = result.gas_used,
            .block_gas_used = result.block_gas_used,
            .cumulative_gas_used = self.gas_used,
            .created_address = result.created_address,
            .logs = if (result.status == .rejected) &.{} else self.vm.logs(),
        };
    }

    pub fn transactReceipt(self: *BlockSession, tx: Transaction) !TxReceiptView {
        const result = try self.transact(tx);
        return self.receipt(result);
    }

    pub fn systemCall(self: *BlockSession, call: SystemCall) !EvmResult {
        return self.vm.systemCall(call);
    }

    pub fn finish(self: *const BlockSession) BlockResult {
        return .{
            .gas_used = self.gas_used,
            .block_gas_used = self.block_gas_used,
            .tx_count = self.tx_count,
        };
    }
};

/// Read-only account view borrowed from the VM overlay/state-reader cache.
pub const AccountView = struct {
    nonce: u64,
    balance: u256,
    code: []const u8 = &.{},
};

pub const Call = Executor.Call;
pub const Create = Executor.Create;
pub const Message = Executor.Message;
pub const EvmResult = Executor.EvmResult;

/// Explicit non-transaction system call for block-hook style operations.
pub const SystemCall = struct {
    sender: Address,
    recipient: Address,
    input: []const u8 = &.{},
    gas: u64,
};

pub fn init(allocator: std.mem.Allocator, options: Init) Vm {
    return .{
        .executor = Executor.init(allocator, .{
            .spec = options.spec,
            .state_reader = options.state_reader,
            .block_hash_source = options.block_hash_source,
            .config = options.config,
            .trace_sink = options.trace_sink,
        }),
        .env = options.env,
        .committer = options.committer,
    };
}

pub fn deinit(self: *Vm) void {
    self.executor.deinit();
}

pub fn setEnv(self: *Vm, env: Env) void {
    self.env = env;
}

pub fn beginBlock(self: *Vm, env: Env) BlockSession {
    self.setEnv(env);
    return .{ .vm = self };
}

pub fn getAccount(self: *Vm, address_value: Address) !?AccountView {
    const account = try self.executor.getAccountOrLoad(address_value) orelse return null;
    return .{
        .nonce = account.nonce,
        .balance = account.balance,
        .code = account.code,
    };
}

pub fn getStorage(self: *Vm, address_value: Address, key: u256) !u256 {
    return self.executor.getStorage(address_value, key);
}

/// Borrow logs emitted by the most recent transaction/system-call scope.
///
/// Receipt builders can copy these immediately after `transact`; the slice is
/// invalidated by the next transaction, discard, commit, or VM teardown.
pub fn logs(self: *const Vm) []const Log {
    return self.executor.logs();
}

/// Execute an explicit non-transaction system call.
pub fn systemCall(self: *Vm, call: SystemCall) !EvmResult {
    const context_gas_limit = if (self.env.gas_limit == 0) call.gas else self.env.gas_limit;
    const result = try self.executor.executeSystemCall(
        self.env.txContext(call.sender, 0, context_gas_limit, &.{}),
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
pub fn transact(self: *Vm, tx: Transaction) !TxResult {
    self.executor.clearLogs();
    const validation = try validate(&self.executor, self.env, tx);
    if (validation.err) |err| {
        return .{
            .status = .rejected,
            .validation_error = err,
        };
    }

    const created_address = if (tx.to == null) address.create(tx.sender, validation.sender_nonce) else null;
    const host_context = self.env.txContext(tx.sender, effectiveGasPrice(self.env, tx), self.env.gas_limit, tx.blob_hashes);
    const normalized_tx = transaction.normalizedTransaction(.{
        .sender = tx.sender,
        .to = tx.to,
        .input = tx.input,
        .gas_limit = tx.gas_limit,
        .value = tx.value,
        .access_list = tx.access_list,
        .authorization_list = tx.authorization_list,
        .authorization_count = tx.authorization_count,
    });
    const gas_plan = transaction.gasPlan(self.executor.spec, tx.input, tx.gas_limit, validation.intrinsic_options);
    const settlement = transaction.settlementFromGasPlan(self.executor.spec, tx.gas_limit, gas_plan, .{
        .gas_price = host_context.gas_price,
        .priority_fee = transaction.effectivePriorityFee(self.executor.spec, .{
            .gas_price = host_context.gas_price,
            .base_fee = self.env.base_fee,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
        }),
        .coinbase = self.env.coinbase,
    });

    try self.executor.beginTransactionScope(host_context, normalized_tx);
    errdefer self.executor.closeTransaction();
    const result = try self.executor.runTopLevelTransaction(normalized_tx, .{
        .execution = gas_plan.execution,
        .settlement = settlement,
    });

    const costs = try transaction.settlementCosts(settlement, .{
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .gas_reservoir = result.gas_reservoir,
        .state_gas_spent = result.state_gas_spent,
    });
    return .{
        .status = txStatus(result.status),
        .gas_used = costs.gas_used,
        .block_gas_used = costs.block_gas_used,
        .gas_refunded = costs.refunded_gas,
        .output = result.output_data,
        .created_address = if (result.status == .success) created_address else null,
    };
}

/// Convenience for one-off callers. Block executors should usually call
/// `transact` many times, then one `commit`.
pub fn transactCommit(self: *Vm, tx: Transaction) !TxResult {
    const result = try self.transact(tx);
    if (result.status == .rejected) return result;
    try self.commit();
    return result;
}

const Validation = struct {
    err: ?transaction.ValidationError = null,
    sender_nonce: u64 = 0,
    intrinsic_options: transaction.IntrinsicGasOptions = .{},
};

fn validate(executor: *Executor, env: Env, tx: Transaction) !Validation {
    const sender_account = try executor.getAccountOrLoad(tx.sender);
    const sender_balance: u256 = if (sender_account) |account| account.balance else 0;
    const sender_nonce: u64 = if (sender_account) |account| account.nonce else 0;
    const sender_code_kind = if (sender_account) |account| senderCodeKind(account) else transaction.SenderCodeKind.empty;
    const authorization_count = authorizationCount(tx);
    const creates_account = try valueTransferCreatesAccount(executor, tx);
    const intrinsic_options = intrinsicOptions(tx, creates_account);

    return .{
        .sender_nonce = sender_nonce,
        .intrinsic_options = intrinsic_options,
        .err = transaction.validate(.{
            .spec = executor.spec,
            .kind = tx.kind,
            .is_create = tx.to == null,
            .is_self_transfer = isSelfTransfer(tx),
            .creates_account = creates_account,
            .gas_limit = tx.gas_limit,
            .input = tx.input,
            .value = tx.value,
            .gas_price = tx.gas_price,
            .base_fee = env.base_fee,
            .block_gas_limit = env.gas_limit,
            .blob_base_fee = env.blob_base_fee,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
            .max_fee_per_blob_gas = tx.max_fee_per_blob_gas,
            .sender_balance = sender_balance,
            .sender_nonce = sender_nonce,
            .tx_nonce = tx.nonce,
            .sender_code_kind = sender_code_kind,
            .authorization_count = authorization_count,
            .access_list_counts = intrinsic_options.access_list_counts,
            .blob_hashes = tx.blob_hashes,
        }),
    };
}

fn senderCodeKind(account: *const AccountState) transaction.SenderCodeKind {
    if (account.code.len == 0) return .empty;
    if (Executor.eip7702.delegationTarget(account.code) != null) return .delegation;
    return .non_delegating;
}

fn intrinsicOptions(tx: Transaction, creates_account: bool) transaction.IntrinsicGasOptions {
    return .{
        .authorization_count = authorizationCount(tx),
        .access_list_counts = transaction.accessListCounts(tx.access_list),
        .is_create = tx.to == null,
        .value = tx.value,
        .is_self_transfer = isSelfTransfer(tx),
        .creates_account = creates_account,
    };
}

fn isSelfTransfer(tx: Transaction) bool {
    const recipient = tx.to orelse return false;
    return std.mem.eql(u8, &tx.sender, &recipient);
}

fn valueTransferCreatesAccount(executor: *Executor, tx: Transaction) !bool {
    if (tx.value == 0 or tx.to == null or isSelfTransfer(tx)) return false;
    return (try executor.getAccountOrLoad(tx.to.?)) == null;
}

fn authorizationCount(tx: Transaction) usize {
    return tx.authorization_count orelse tx.authorization_list.len;
}

fn effectiveGasPrice(env: Env, tx: Transaction) u256 {
    return switch (tx.kind) {
        .legacy, .access_list => tx.gas_price,
        .dynamic_fee, .blob, .set_code => blk: {
            const max_fee = tx.max_fee_per_gas orelse return tx.gas_price;
            const priority_fee = tx.max_priority_fee_per_gas orelse 0;
            const capped_priority = std.math.add(u256, env.base_fee, priority_fee) catch std.math.maxInt(u256);
            break :blk @min(max_fee, capped_priority);
        },
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

/// Return the current pending state diff without persisting it.
pub fn changeset(self: *Vm) !Changeset {
    return self.executor.changeset();
}

/// Drop pending overlay changes without writing them to the commit sink.
pub fn discard(self: *Vm) void {
    self.executor.discardChanges();
}

/// Persist the current overlay diff, then rebase the VM to the updated state reader.
///
/// The committer is expected to write to the same canonical state observed by
/// the reader. After a successful commit, the in-memory overlay is cleared so
/// the same VM can process the next block.
pub fn commit(self: *Vm) !void {
    const committer = self.committer orelse return error.ReadOnly;
    var diff = try self.executor.changeset();
    defer diff.deinit(self.executor.allocator);
    try committer.commit(&diff);
    self.executor.discardChanges();
}

test "Vm exposes protocol verbs and low-level executor field" {
    try std.testing.expect(@hasDecl(Vm, "transact"));
    try std.testing.expect(@hasDecl(Vm, "beginBlock"));
    try std.testing.expect(@hasDecl(BlockSession, "receipt"));
    try std.testing.expect(@hasDecl(BlockSession, "transactReceipt"));
    try std.testing.expect(@hasDecl(Vm, "systemCall"));
    try std.testing.expect(@hasDecl(Vm, "logs"));
    try std.testing.expect(@hasDecl(Vm, "commit"));
    try std.testing.expect(@hasField(Vm, "executor"));
}

test "Vm initializes and exposes empty changeset" {
    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .berlin,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas_used > 21_000);
    try std.testing.expectEqual(result.gas_used, result.block_gas_used);

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
    var vm = Vm.init(std.testing.allocator, .{
        .spec = .prague,
        .state_reader = memory.reader(),
        .block_hash_source = block_hashes.source(),
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 300_000,
    });
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .berlin,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try vm.transact(.{
        .sender = sender,
        .gas_limit = 300_000,
        .input = init_code,
    });
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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
    try std.testing.expectEqual(TxStatus.rejected, result.status);
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, result.validation_error.?);

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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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
    try std.testing.expectEqual(TxStatus.rejected, rejected.status);
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, rejected.validation_error.?);

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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .osaka,
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
    try std.testing.expectEqual(TxStatus.rejected, rejected.status);
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas_refunded > 0);
    try std.testing.expect(result.block_gas_used > result.gas_used);
}

test "Vm exposes borrowed logs for client receipt builders" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const result = try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);
    try std.testing.expectEqualSlices(u8, &Executor.system_contracts.system_address, &vm.logs()[0].address);
    try std.testing.expectEqual(Executor.transfer_logs.transfer_topic, vm.logs()[0].topics[0]);
}

test "Vm rejected transaction clears borrowed log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .amsterdam,
        .state_reader = memory.reader(),
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer vm.deinit();

    const accepted = try vm.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), vm.logs().len);

    const rejected = try vm.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    try std.testing.expectEqual(TxStatus.rejected, rejected.status);
    try std.testing.expectEqual(transaction.ValidationError.nonce_mismatch, rejected.validation_error.?);
    try std.testing.expectEqual(@as(usize, 0), vm.logs().len);
}

test "BlockSession accumulates block gas and rolls back overflow transaction" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = 29_000 });
    const accepted = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    });
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(u64, 15_000), accepted.block_gas_used);
    try std.testing.expectEqual(@as(u64, 1), block.finish().tx_count);

    const rejected = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    });
    try std.testing.expectEqual(TxStatus.rejected, rejected.status);
    try std.testing.expectEqual(transaction.ValidationError.gas_allowance_exceeded, rejected.validation_error.?);
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

    var vm = Vm.init(std.testing.allocator, .{
        .spec = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer vm.deinit();

    var block = vm.beginBlock(.{ .gas_limit = 1_000_000 });
    const result = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    });
    const receipt = block.receipt(result);

    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas_used, receipt.gas_used);
    try std.testing.expectEqual(result.block_gas_used, receipt.block_gas_used);
    try std.testing.expectEqual(result.gas_used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    try std.testing.expectEqual(Executor.transfer_logs.transfer_topic, receipt.logs[0].topics[0]);
}
