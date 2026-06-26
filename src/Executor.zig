const std = @import("std");
const evmz = @import("./evm.zig");

const Address = evmz.Address;
const AccountState = evmz.state.AccountState;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JumpDestCache = @import("./jumpdest/Cache.zig");
const StateOverlay = evmz.state.Overlay;
const StorageKey = evmz.state.StorageKey;
const StateBackend = evmz.state.Backend;
const transaction = evmz.transaction;
const uint256 = @import("./uint256.zig");

const Executor = @This();

pub const eip7702 = @import("./executor/eip7702.zig");
pub const system_contracts = @import("./executor/system_contracts.zig");

pub const Snapshot = StateOverlay.Snapshot;
pub const TransientSnapshot = StateOverlay.TransientSnapshot;
pub const code_deposit_gas: i64 = 200;
pub const max_code_size = 0x6000;

pub const AuthorizationTuple = struct {
    chain_id: u256,
    target: Address,
    signer: Address,
    nonce: u64,
    y_parity: u256,
    legacy_v: ?u256,
    r: u256,
    s: u256,
};

allocator: std.mem.Allocator,
state: StateOverlay,
tx_context: Host.TxContext,
spec: evmz.Spec,
jumpdest_cache: JumpDestCache,
last_call_output: []u8 = &.{},

pub fn init(allocator: std.mem.Allocator, tx_context: Host.TxContext, spec: evmz.Spec) Executor {
    return .{
        .allocator = allocator,
        .state = StateOverlay.init(allocator),
        .tx_context = tx_context,
        .spec = spec,
        .jumpdest_cache = JumpDestCache.init(allocator),
    };
}

pub fn initWithBackend(allocator: std.mem.Allocator, tx_context: Host.TxContext, spec: evmz.Spec, backend: StateBackend) Executor {
    return .{
        .allocator = allocator,
        .state = StateOverlay.initWithBackend(allocator, backend),
        .tx_context = tx_context,
        .spec = spec,
        .jumpdest_cache = JumpDestCache.init(allocator),
    };
}

pub fn deinit(self: *Executor) void {
    self.state.deinit();
    self.jumpdest_cache.deinit();
    self.allocator.free(self.last_call_output);
}

fn warmTransactionAccesses(self: *Executor, sender: Address, recipient: ?Address) !void {
    try self.warmAccessListAddress(sender);
    if (recipient) |address| {
        try self.warmAccessListAddress(address);
    }
    if (self.spec.isImpl(.shanghai)) {
        try self.warmAccessListAddress(self.tx_context.coinbase);
    }
}

pub fn beginTransaction(self: *Executor, sender: Address, recipient: Address) !void {
    self.state.beginTransaction();
    try self.warmTransactionAccesses(sender, recipient);
}

pub fn beginCreateTransaction(self: *Executor, sender: Address) !void {
    self.state.beginTransaction();
    try self.warmTransactionAccesses(sender, null);
}

fn beginSystemCall(self: *Executor) !void {
    self.state.beginTransaction();
}

pub fn warmAccessListAddress(self: *Executor, address: Address) !void {
    try self.state.warmAccount(address);
}

pub fn warmAccessListStorage(self: *Executor, address: Address, key: u256) !void {
    try self.state.warmStorage(address, key);
}

pub fn host(self: *Executor) Host {
    return Host{ .ptr = self, .vtable = &.{
        .call = call,
        .accountExists = accountExists,
        .getBalance = getBalance,
        .copyCode = copyCode,
        .getCodeSize = getCodeSize,
        .getCodeHash = getCodeHash,
        .getStorage = getStorage,
        .setStorage = setStorage,
        .emitLog = emitLog,
        .getBlockHash = getBlockHash,
        .selfDestruct = selfDestruct,
        .accessStorage = accessStorage,
        .accessDelegatedAccount = accessDelegatedAccount,
        .accessAccount = accessAccount,
        .getTxContext = getTxContext,
        .getTransientStorage = getTransientStorage,
        .setTransientStorage = setTransientStorage,
    } };
}

pub fn getAccount(self: *Executor, address: Address) ?*AccountState {
    return self.state.getAccount(address);
}

pub fn getAccountOrLoad(self: *Executor, address: Address) !?*AccountState {
    return self.state.getAccountOrLoad(address);
}

pub fn getOrCreateAccount(self: *Executor, address: Address) !*AccountState {
    return self.state.getOrCreateAccount(address);
}

pub fn snapshot(self: *Executor) !Snapshot {
    return self.state.snapshot();
}

pub fn restore(self: *Executor, snapshot_state: *Snapshot) !void {
    try self.state.restore(snapshot_state);
}

pub fn restoreRevertible(self: *Executor, snapshot_state: *Snapshot) !void {
    try self.state.restoreRevertible(snapshot_state);
}

pub fn finalizeTransaction(self: *Executor) !void {
    try self.state.finalizeTransaction(self.spec);
}

pub fn getCode(self: *Executor, address: Address) ![]const u8 {
    return self.state.getCode(address);
}

pub fn dupeExecutionCode(self: *Executor, address: Address) ![]u8 {
    const code = try self.getCode(address);
    if (eip7702.delegationTarget(code)) |target| {
        return self.allocator.dupe(u8, try self.getCode(target));
    }
    return self.allocator.dupe(u8, code);
}

pub fn executeCallTransaction(
    self: *Executor,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    value: u256,
) !Interpreter.Result {
    self.clearLastOutput();
    if (!try self.transferValue(sender, recipient, value)) {
        return .{
            .status = .invalid,
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = &.{},
        };
    }

    var host_iface = self.host();
    const code = try self.dupeExecutionCode(recipient);
    defer self.allocator.free(code);
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64),
        .recipient = recipient,
        .sender = sender,
        .input_data = input,
        .value = value,
        .code_address = recipient,
    };

    var interpreter: Interpreter = undefined;
    try interpreter.init(self.allocator, .{
        .host = &host_iface,
        .msg = &message,
        .code = code,
        .spec = self.spec,
        .jumpdest_cache = &self.jumpdest_cache,
    });
    defer interpreter.deinit();

    const result = interpreter.execute();
    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, result.output_data);
    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = self.last_call_output,
    };
}

pub fn executeCreateTransaction(
    self: *Executor,
    sender: Address,
    init_code: []const u8,
    gas: u64,
    value: u256,
) !Host.Result {
    self.clearLastOutput();
    return self.createContract(.{
        .depth = 0,
        .kind = .create,
        .gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64),
        .sender = sender,
        .input_data = init_code,
        .value = value,
    });
}

pub fn executeSystemCall(
    self: *Executor,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
) !Interpreter.Result {
    try self.beginSystemCall();
    defer self.state.transient_storage.clearRetainingCapacity();

    self.clearLastOutput();
    var pre_call_state = try self.snapshot();
    defer pre_call_state.deinit(self.allocator);

    var host_iface = self.host();
    const code = try self.dupeExecutionCode(recipient);
    defer self.allocator.free(code);
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = std.math.cast(i64, gas) orelse std.math.maxInt(i64),
        .recipient = recipient,
        .sender = sender,
        .input_data = input,
        .value = 0,
        .code_address = recipient,
    };

    var interpreter: Interpreter = undefined;
    try interpreter.init(self.allocator, .{
        .host = &host_iface,
        .msg = &message,
        .code = code,
        .spec = self.spec,
        .jumpdest_cache = &self.jumpdest_cache,
    });
    defer interpreter.deinit();

    const result = interpreter.execute();
    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, result.output_data);

    if (executionRolledBack(result.status)) {
        try self.restoreRevertible(&pre_call_state);
    } else {
        try self.finalizeTransaction();
    }

    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = self.last_call_output,
    };
}

pub fn transferValue(self: *Executor, sender: Address, recipient: Address, value: u256) !bool {
    if (value == 0) return true;
    const sender_account = try self.state.getAccountOrLoad(sender) orelse return false;
    if (!try self.hasBalance(sender, value)) return false;
    sender_account.balance -= value;
    const recipient_account = try self.getOrCreateAccount(recipient);
    recipient_account.balance += value;
    return true;
}

fn hasBalance(self: *Executor, address: Address, value: u256) !bool {
    const account = try self.state.getAccountOrLoad(address) orelse return value == 0;
    return account.balance >= value;
}

pub fn incrementNonce(self: *Executor, address: Address) !void {
    const account = try self.getOrCreateAccount(address);
    account.nonce = std.math.add(u64, account.nonce, 1) catch std.math.maxInt(u64);
}

pub fn chargeTransactionCosts(self: *Executor, sender: Address, gas_limit: u64, value: u256) !bool {
    const upfront_cost = transaction.prepaymentCost(
        gas_limit,
        self.tx_context.gas_price,
        self.tx_context.blob_base_fee,
        self.tx_context.blob_hashes.len,
    ) orelse return false;
    const required_balance = uint256.checkedAdd(upfront_cost, value) orelse return false;
    const sender_account = try self.state.getAccountOrLoad(sender) orelse return false;
    if (sender_account.balance < required_balance) return false;
    sender_account.balance -= upfront_cost;
    return true;
}

pub fn applyAuthorizationTuple(self: *Executor, auth: AuthorizationTuple) !void {
    if (!self.spec.isImpl(.prague)) return;
    if (!eip7702.authorizationSignatureShapeValid(auth.y_parity, auth.legacy_v, auth.r, auth.s)) return;
    if (auth.chain_id != 0 and auth.chain_id != self.tx_context.chain_id) return;

    try self.state.warmAccount(auth.signer);

    if (try self.state.getAccountOrLoad(auth.signer)) |existing| {
        if (existing.code.len != 0 and eip7702.delegationTarget(existing.code) == null) return;
        if (existing.nonce != auth.nonce) return;
    } else if (auth.nonce != 0) {
        return;
    }

    const account = try self.getOrCreateAccount(auth.signer);
    if (account.nonce == std.math.maxInt(u64)) return;

    if (std.mem.eql(u8, &auth.target, &evmz.address.zero_address)) {
        account.clearCode(self.allocator);
    } else {
        var code: [eip7702.delegation_code_len]u8 = undefined;
        eip7702.writeDelegationCode(&code, auth.target);
        try account.setCode(self.allocator, &code);
    }
    account.nonce += 1;
}

pub fn snapshotTransient(self: *Executor) !TransientSnapshot {
    return self.state.snapshotTransient();
}

pub fn restoreTransient(self: *Executor, snapshot_state: *TransientSnapshot) !void {
    try self.state.restoreTransient(snapshot_state);
}

pub fn executionRolledBack(status: Interpreter.Status) bool {
    return switch (status) {
        .success => false,
        .revert, .invalid, .out_of_gas => true,
    };
}

pub fn clearLastOutput(self: *Executor) void {
    self.allocator.free(self.last_call_output);
    self.last_call_output = &.{};
}

fn resolvedCodeAddress(self: *Executor, address: Address) !struct { address: Address, delegated: bool } {
    const code = try self.getCode(address);
    if (eip7702.delegationTarget(code)) |target| {
        return .{ .address = target, .delegated = true };
    }
    return .{ .address = address, .delegated = false };
}

fn accountExists(ptr: *anyopaque, address: Address) !bool {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.accountExists(address);
}

fn getBalance(ptr: *anyopaque, address: Address) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.getBalance(address);
}

fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.getStorage(address, key);
}

fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.setStorage(address, key, value);
}

fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return (try self.getCode(address)).len;
}

fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const account = try self.state.getAccountOrLoad(address) orelse {
        if (evmz.precompile.activeAt(self.spec, address) != null) return evmz.empty_code_hash;
        return 0;
    };
    if (account.code.len == 0) return evmz.empty_code_hash;
    var result: [32]u8 = undefined;
    std.crypto.hash.sha3.Keccak256.hash(account.code, &result, .{});
    return std.mem.readInt(u256, &result, .big);
}

fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const code = try self.getCode(address);
    if (code_offset >= code.len) return 0;
    const size = @min(buffer_data.len, code.len - code_offset);
    @memcpy(buffer_data[0..size], code[code_offset .. code_offset + size]);
    return size;
}

fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    try self.state.logs.append(self.allocator, .{
        .address = address,
        .topics = topics,
        .data = data,
    });
}

fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
    _ = ptr;
    _ = number;
    return 0;
}

fn getTxContext(ptr: *anyopaque) !Host.TxContext {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.tx_context;
}

fn accessAccount(ptr: *anyopaque, address: Address) !Host.AccessStatus {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    if (evmz.precompile.activeAt(self.spec, address) != null) return .warm;
    if (self.state.warm_accounts.contains(address)) return .warm;
    try self.state.warmAccount(address);
    return .cold;
}

fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !Host.AccessStatus {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const storage_key = StorageKey{ .address = address, .key = key };
    if (self.state.warm_storage.contains(storage_key)) return .warm;
    try self.state.warmStorage(address, key);
    return .cold;
}

fn accessDelegatedAccount(ptr: *anyopaque, address: Address) !?Host.AccessStatus {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const target = eip7702.delegationTarget(try self.getCode(address)) orelse return null;
    return try accessAccount(ptr, target);
}

fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    self.clearLastOutput();

    if (msg.depth > 1024) {
        return switch (msg.kind) {
            .create, .create2 => self.createFailure(evmz.addr(0), msg.gas, .invalid),
            else => Host.Result.fromCall(.{
                .status = .invalid,
                .output_data = &.{},
                .gas_left = msg.gas,
                .gas_refund = 0,
            }),
        };
    }

    if (msg.kind == .create or msg.kind == .create2) {
        return self.createContract(msg);
    }

    var pre_call_state = try self.snapshot();
    defer pre_call_state.deinit(self.allocator);

    if (msg.value > 0 and (msg.kind == .call or msg.kind == .callcode)) {
        const value_ok = if (msg.kind == .call)
            try self.transferValue(msg.sender, msg.recipient, msg.value)
        else
            try self.hasBalance(msg.recipient, msg.value);
        if (!value_ok) {
            return Host.Result.fromCall(.{
                .status = .invalid,
                .output_data = &.{},
                .gas_left = msg.gas,
                .gas_refund = 0,
            });
        }
    }

    const resolved = try self.resolvedCodeAddress(msg.code_address);
    if (!resolved.delegated and evmz.precompile.activeAt(self.spec, msg.code_address) != null) {
        const precompile_result = evmz.precompile.execute(
            self.allocator,
            self.spec,
            msg.code_address,
            msg.input_data,
            msg.gas,
        ) catch |err| switch (err) {
            error.NotImplemented => return Host.Result.fromCall(.{
                .status = .invalid,
                .output_data = &.{},
                .gas_left = 0,
                .gas_refund = 0,
            }),
            else => return err,
        };
        if (precompile_result) |result| {
            self.last_call_output = result.output_data;
            if (result.status != .success) {
                try self.restoreRevertible(&pre_call_state);
            }
            return Host.Result.fromCall(.{
                .status = switch (result.status) {
                    .success => .success,
                    .failure => .invalid,
                    .out_of_gas => .out_of_gas,
                },
                .output_data = self.last_call_output,
                .gas_left = if (result.status == .success) result.gas_left else 0,
                .gas_refund = 0,
            });
        }
    }

    var host_iface = self.host();
    const code = try self.allocator.dupe(u8, try self.getCode(resolved.address));
    defer self.allocator.free(code);
    const interpreter = try self.allocator.create(Interpreter);
    defer self.allocator.destroy(interpreter);
    try interpreter.init(self.allocator, .{
        .host = &host_iface,
        .msg = &msg,
        .code = code,
        .spec = self.spec,
        .jumpdest_cache = &self.jumpdest_cache,
    });
    defer interpreter.deinit();
    const result = interpreter.execute();

    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, result.output_data);
    if (result.status != .success) {
        try self.restoreRevertible(&pre_call_state);
    }
    return Host.Result.fromCall(.{
        .status = result.status,
        .output_data = self.last_call_output,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
    });
}

fn createContract(self: *Executor, msg: Host.Message) !Host.Result {
    const caller_address = msg.sender;
    const caller = try self.getOrCreateAccount(msg.sender);
    const create_address = switch (msg.kind) {
        .create => evmz.address.create(msg.sender, caller.nonce),
        .create2 => evmz.address.create2(msg.sender, msg.create2_salt, msg.input_data),
        else => unreachable,
    };
    if (self.spec.isImpl(.berlin)) {
        try self.warmAccessListAddress(create_address);
    }

    caller.nonce = std.math.add(u64, caller.nonce, 1) catch return self.createFailure(create_address, msg.gas, .invalid);
    const caller_balance = caller.balance;

    if (caller.balance < msg.value) {
        return self.createFailure(create_address, msg.gas, .invalid);
    }
    if (try self.createCollision(create_address)) {
        return self.createFailure(create_address, 0, .invalid);
    }

    const was_created_in_tx = self.state.created_contracts.contains(create_address);
    var previous_created = if (try self.state.getAccountOrLoad(create_address)) |account| try account.clone(self.allocator) else null;
    defer if (previous_created) |*account| account.deinit(self.allocator);

    caller.balance -= msg.value;
    const created = try self.getOrCreateAccount(create_address);
    created.balance += msg.value;
    created.nonce = if (self.spec.isImpl(.spurious_dragon)) 1 else 0;
    created.clearCode(self.allocator);
    try self.state.created_contracts.put(create_address, {});

    var host_iface = self.host();
    const child_msg = Host.Message{
        .depth = msg.depth,
        .kind = .call,
        .gas = msg.gas,
        .recipient = create_address,
        .sender = msg.sender,
        .input_data = &.{},
        .value = msg.value,
        .is_static = msg.is_static,
        .code_address = create_address,
    };
    const interpreter = try self.allocator.create(Interpreter);
    defer self.allocator.destroy(interpreter);
    try interpreter.init(self.allocator, .{
        .host = &host_iface,
        .msg = &child_msg,
        .code = msg.input_data,
        .spec = self.spec,
        .jumpdest_cache = &self.jumpdest_cache,
    });
    defer interpreter.deinit();

    const result = interpreter.execute();
    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, result.output_data);

    if (result.status != .success) {
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return Host.Result.fromCreate(create_address, .{
            .status = result.status,
            .output_data = self.last_call_output,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
        });
    }

    if (self.spec.isImpl(.spurious_dragon) and self.last_call_output.len > max_code_size) {
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return self.createFailure(create_address, 0, .out_of_gas);
    }
    if (self.spec.isImpl(.london) and self.last_call_output.len > 0 and self.last_call_output[0] == 0xef) {
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return self.createFailure(create_address, 0, .invalid);
    }

    const runtime_size = std.math.cast(i64, self.last_call_output.len) orelse {
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return self.createFailure(create_address, 0, .out_of_gas);
    };
    const deposit_cost = std.math.mul(i64, runtime_size, code_deposit_gas) catch {
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return self.createFailure(create_address, 0, .out_of_gas);
    };
    if (result.gas_left < deposit_cost) {
        if (!self.spec.isImpl(.homestead)) {
            return Host.Result.fromCreate(create_address, .{
                .status = .success,
                .output_data = self.last_call_output,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        }
        try self.restoreCreateAttempt(caller_address, caller_balance, create_address, &previous_created, was_created_in_tx);
        return self.createFailure(create_address, 0, .out_of_gas);
    }

    const installed = (try self.state.getAccountOrLoad(create_address)).?;
    try installed.setCode(self.allocator, self.last_call_output);

    return Host.Result.fromCreate(create_address, .{
        .status = .success,
        .output_data = self.last_call_output,
        .gas_left = result.gas_left - deposit_cost,
        .gas_refund = result.gas_refund,
    });
}

fn restoreCreateAttempt(
    self: *Executor,
    caller_address: Address,
    caller_balance: u256,
    create_address: Address,
    previous_created: *?AccountState,
    was_created_in_tx: bool,
) !void {
    if (try self.state.getAccountOrLoad(caller_address)) |caller| {
        caller.balance = caller_balance;
    }
    if (self.state.accounts.fetchRemove(create_address)) |removed| {
        var account = removed.value;
        account.deinit(self.allocator);
    }
    if (previous_created.*) |account| {
        _ = self.state.deleted_accounts.remove(create_address);
        try self.state.accounts.put(create_address, account);
        previous_created.* = null;
    }
    if (!was_created_in_tx) {
        _ = self.state.created_contracts.remove(create_address);
    }
}

fn createFailure(self: *Executor, create_address: Address, gas_left: i64, status: Interpreter.Status) Host.Result {
    self.clearLastOutput();
    return Host.Result.fromCreate(create_address, .{
        .status = status,
        .output_data = &.{},
        .gas_left = gas_left,
        .gas_refund = 0,
    });
}

fn createCollision(self: *Executor, address: Address) !bool {
    if (evmz.precompile.activeAt(self.spec, address) != null) return true;
    const account = try self.state.getAccountOrLoad(address) orelse return false;
    return account.nonce != 0 or account.code.len != 0 or try self.state.accountHasStorage(address);
}

fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const balance = try getBalance(ptr, address);
    const same_address = std.mem.eql(u8, &address, &beneficiary);
    if (balance > 0) {
        if (!same_address) {
            const beneficiary_account = try self.getOrCreateAccount(beneficiary);
            beneficiary_account.balance += balance;
        }
        if (try self.state.getAccountOrLoad(address)) |account| {
            if (!same_address or !self.spec.isImpl(.cancun) or self.state.created_contracts.contains(address)) {
                account.balance = 0;
            }
        }
    }
    try self.state.selfdestructed_accounts.put(address, {});
    return false;
}

fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.getTransientStorage(address, key);
}

fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    try self.state.setTransientStorage(address, key, value);
}

test "executor executes top-level create transaction" {
    const sender = evmz.addr(0xaaaa);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = sender,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .berlin);
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);

    try executor.beginCreateTransaction(sender);
    const result = (try executor.executeCreateTransaction(sender, init_code, 100_000, 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);
    try std.testing.expectEqual(@as(u64, 1), executor.getAccount(sender).?.nonce);
    try std.testing.expectEqualSlices(u8, &.{0x00}, executor.getAccount(create_address).?.code);
}

test "create warms created address from Berlin" {
    const sender = evmz.addr(0xaaaa);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = sender,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .berlin);
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    try executor.beginCreateTransaction(sender);

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, init_code, 100_000, 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(executor.state.warm_accounts.contains(create_address));
}

test "callcode with insufficient balance fails without executing target code" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = caller,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .berlin);
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 0;
    try executor.state.accounts.put(caller, caller_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{ 0x60, 0x11, 0x60, 0x64, 0x55, 0x00 });
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(caller, caller);
    const result = (try call(&executor, .{
        .depth = 1,
        .kind = .callcode,
        .gas = 100_000,
        .recipient = caller,
        .sender = caller,
        .input_data = &.{},
        .value = 1,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 100_000), result.gas_left);
    try std.testing.expectEqual(@as(u256, 0), executor.getAccount(caller).?.getStorage(0x64));
}

test "exceptional child call burns forwarded gas" {
    const caller = evmz.addr(0xaaaa);
    const target = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = caller,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .berlin);
    defer executor.deinit();

    var caller_account = AccountState.init(std.testing.allocator);
    caller_account.balance = 1_000_000;
    try executor.state.accounts.put(caller, caller_account);

    var target_account = AccountState.init(std.testing.allocator);
    try target_account.setCode(std.testing.allocator, &.{0xfe});
    try executor.state.accounts.put(target, target_account);

    try executor.beginTransaction(caller, caller);
    const result = (try call(&executor, .{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = target,
        .sender = caller,
        .input_data = &.{},
        .value = 0,
        .code_address = target,
    })).expectCall();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
}

test "contract creation rejects EF-prefixed runtime code from London" {
    const sender = evmz.addr(0xaaaa);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = sender,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .london);
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    try executor.beginCreateTransaction(sender);

    const init_code = &.{ 0x60, 0xef, 0x60, 0x00, 0x53, 0x60, 0x10, 0x60, 0x00, 0xf3 };
    const create_address = evmz.address.create(sender, 0);
    const result = (try executor.executeCreateTransaction(sender, init_code, 100_000, 0)).expectCreate();

    try std.testing.expectEqual(Interpreter.Status.invalid, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expect(executor.getAccount(create_address) == null);
}

test "selfdestruct charges new-account cost for nonzero balance" {
    const sender = evmz.addr(0xaaaa);
    const contract = evmz.addr(0xbbbb);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = sender,
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .cancun);
    defer executor.deinit();

    var sender_account = AccountState.init(std.testing.allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    var contract_account = AccountState.init(std.testing.allocator);
    contract_account.balance = 1;
    try contract_account.setCode(std.testing.allocator, &.{ 0x5f, 0xff });
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(sender, contract);
    const result = try executor.executeCallTransaction(sender, contract, &.{}, 100_000, 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 69_998), result.gas_left);
}

test "active precompiles are warm but not existing state accounts" {
    const precompile_address = evmz.addr(2);
    var executor = Executor.init(std.testing.allocator, .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = evmz.addr(0),
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, .berlin);
    defer executor.deinit();

    var host_iface = executor.host();
    try std.testing.expect(!try host_iface.accountExists(precompile_address));
    try std.testing.expectEqual(Host.AccessStatus.warm, try host_iface.accessAccount(precompile_address));
}

test {
    std.testing.refAllDecls(@This());
}
