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
pub const Committer = Executor.state_io.Committer;

/// Block/environment values supplied by the caller.
pub const Env = struct {
    chain_id: u256 = 1,
    coinbase: Address = std.mem.zeroes(Address),
    number: u64 = 0,
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
    gas_refunded: u64 = 0,
    output: []const u8 = &.{},
    created_address: ?Address = null,
    validation_error: ?transaction.ValidationError = null,
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
    });
    const gas_plan = transaction.gasPlan(self.executor.spec, tx.input, tx.gas_limit, intrinsicOptions(tx));
    const settlement = transaction.Settlement{
        .spec = self.executor.spec,
        .gas_limit = tx.gas_limit,
        .intrinsic_gas = gas_plan.intrinsic_gas,
        .floor_gas = gas_plan.floor_gas,
        .gas_price = host_context.gas_price,
        .priority_fee = transaction.effectivePriorityFee(self.executor.spec, .{
            .gas_price = host_context.gas_price,
            .base_fee = self.env.base_fee,
            .max_fee_per_gas = tx.max_fee_per_gas,
            .max_priority_fee_per_gas = tx.max_priority_fee_per_gas,
        }),
        .coinbase = self.env.coinbase,
    };

    try self.executor.beginTransactionScope(host_context, normalized_tx);
    errdefer self.executor.closeTransaction();
    const result = try self.executor.runTopLevelTransaction(normalized_tx, .{
        .execution_gas = gas_plan.execution_gas,
        .settlement = settlement,
    });

    const costs = try transaction.settlementCosts(settlement, .{
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
    });
    return .{
        .status = txStatus(result.status),
        .gas_used = costs.gas_used,
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
};

fn validate(executor: *Executor, env: Env, tx: Transaction) !Validation {
    const sender_account = try executor.getAccountOrLoad(tx.sender);
    const sender_balance: u256 = if (sender_account) |account| account.balance else 0;
    const sender_nonce: u64 = if (sender_account) |account| account.nonce else 0;
    const sender_code_kind = if (sender_account) |account| senderCodeKind(account) else transaction.SenderCodeKind.empty;
    const authorization_count = authorizationCount(tx);

    return .{
        .sender_nonce = sender_nonce,
        .err = transaction.validate(.{
            .spec = executor.spec,
            .kind = tx.kind,
            .is_create = tx.to == null,
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
            .access_list_counts = transaction.accessListCounts(tx.access_list),
            .blob_hashes = tx.blob_hashes,
        }),
    };
}

fn senderCodeKind(account: *const AccountState) transaction.SenderCodeKind {
    if (account.code.len == 0) return .empty;
    if (Executor.eip7702.delegationTarget(account.code) != null) return .delegation;
    return .non_delegating;
}

fn intrinsicOptions(tx: Transaction) transaction.IntrinsicGasOptions {
    return .{
        .authorization_count = authorizationCount(tx),
        .access_list_counts = transaction.accessListCounts(tx.access_list),
        .is_create = tx.to == null,
    };
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
    try std.testing.expect(@hasDecl(Vm, "systemCall"));
    try std.testing.expect(@hasDecl(Vm, "commit"));
    try std.testing.expect(@hasField(Vm, "executor"));
    try std.testing.expect(!@hasDecl(Vm, "raw"));
    try std.testing.expect(!@hasDecl(Vm, "executeMessage"));
    try std.testing.expect(!@hasDecl(Vm, "executeCreate"));
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
    sender_account.balance = 1_000_000;
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
    sender_account.balance = 1_000_000;

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
        .gas_limit = 100_000,
    });
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas_used > 21_000);

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
        .gas_limit = 100_000,
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
    sender_account.balance = 1_000_000;
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
        .gas_limit = 100_000,
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
        .gas_limit = 100_000,
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
        .gas_limit = 100_000,
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
        .gas_limit = 100_000,
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
