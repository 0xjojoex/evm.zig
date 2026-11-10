//! The evmz C ABI: `include/evmz/evmz.h` over one exact engine per compiled fork.
//!
//! `evmz_h` is that header translated at build time, so every layout, constant,
//! and prototype used here is the header's own. The `comptime` blocks below tie
//! the header's numbering to the engine enums it mirrors; a drift is a compile
//! error, not a silent renumbering.
//!
//! No assert is reachable from caller input: malformed arguments return
//! `EVMZ_INVALID_ARGUMENT` and a misbehaving host returns `EVMZ_HOST_FAILURE`.

const std = @import("std");
const builtin = @import("builtin");
const c = @import("evmz_h");
const evmz = @import("evmz");
const options = @import("c_api_options");

const Allocator = std.mem.Allocator;
const Account = evmz.state.Account;
const AccountEffect = evmz.state.AccountEffect;
const Address = evmz.Address;
const Env = evmz.Env;
const FrameHalt = evmz.execution.FrameHalt;
const Revision = evmz.eth.Revision;
const Transaction = evmz.transaction.Transaction;
const TransactInput = evmz.Evm.TransactInput;
const ValidationError = evmz.Evm.Rejection;
const crypto = evmz.crypto;
const uint256 = evmz.uint256;

/// Sessions and results live on the C heap. Tests swap in the leak-checking
/// allocator.
const gpa: Allocator = if (builtin.is_test) std.testing.allocator else std.heap.c_allocator;

const Status = c.evmz_status;
const ok: Status = c.EVMZ_OK;
const invalid_argument: Status = c.EVMZ_INVALID_ARGUMENT;
const unsupported_fork: Status = c.EVMZ_UNSUPPORTED_FORK;
const pending_result: Status = c.EVMZ_PENDING_RESULT;
const no_pending_result: Status = c.EVMZ_NO_PENDING_RESULT;
const host_failure: Status = c.EVMZ_HOST_FAILURE;
const out_of_memory: Status = c.EVMZ_OUT_OF_MEMORY;
const internal_error: Status = c.EVMZ_INTERNAL_ERROR;

/// Forks compiled into this library, chosen by `-Dc-api-forks`. Each one is a
/// complete engine, so the preset is the archive's size.
const forks: []const Revision = resolveForks();

fn resolveForks() []const Revision {
    const preset = options.forks;
    if (std.mem.eql(u8, preset, "all")) return std.enums.values(Revision);
    if (std.mem.eql(u8, preset, "recent"))
        return &.{ .cancun, .prague, Revision.stable, Revision.latest };
    @compileError("unknown c-api-forks preset '" ++ preset ++ "'");
}

// ---- Header numbering ------------------------------------------------------

/// The header constant named `prefix ++ UPPER(tag)`.
fn headerConstant(comptime prefix: []const u8, comptime tag: []const u8) comptime_int {
    var upper: [tag.len]u8 = undefined;
    _ = std.ascii.upperString(&upper, tag);
    const name = prefix ++ upper;
    if (!@hasDecl(c, name)) @compileError("evmz.h is missing " ++ name);
    return @field(c, name);
}

const account_effect_bits = [_]struct { []const u8, comptime_int }{
    .{ "balance_written", c.EVMZ_ACCOUNT_BALANCE_WRITTEN },
    .{ "nonce_written", c.EVMZ_ACCOUNT_NONCE_WRITTEN },
    .{ "code_written", c.EVMZ_ACCOUNT_CODE_WRITTEN },
    .{ "account_deleted", c.EVMZ_ACCOUNT_DELETED },
    .{ "created_contract", c.EVMZ_ACCOUNT_CREATED_CONTRACT },
    .{ "selfdestruct", c.EVMZ_ACCOUNT_SELFDESTRUCT },
    .{ "storage_wiped", c.EVMZ_ACCOUNT_STORAGE_WIPED },
};

const account_effect_mask: u8 = blk: {
    var mask: u8 = 0;
    for (account_effect_bits) |entry| mask |= entry[1];
    break :blk mask;
};

comptime {
    @setEvalBranchQuota(20_000);
    for (std.enums.values(Revision)) |revision|
        std.debug.assert(headerConstant("EVMZ_FORK_", @tagName(revision)) == @backingInt(revision));
    for (std.enums.values(evmz.transaction.TxKind)) |kind|
        std.debug.assert(headerConstant("EVMZ_TX_", @tagName(kind)) == @backingInt(kind));
    for (std.enums.values(evmz.TxStatus)) |status|
        std.debug.assert(headerConstant("EVMZ_EXECUTION_", @tagName(status)) == @backingInt(status));
    // Zero is EVMZ_REJECTION_NONE, so a rejection is its tag plus one.
    for (std.enums.values(ValidationError)) |rejection|
        std.debug.assert(headerConstant("EVMZ_REJECTION_", @tagName(rejection)) ==
            @as(comptime_int, @backingInt(rejection)) + 1);
    // `accountEffects` reads the packed struct as the header's bit set.
    for (account_effect_bits) |entry|
        std.debug.assert(@as(u8, 1) << @bitOffsetOf(AccountEffect, entry[0]) == entry[1]);
    std.debug.assert(@bitSizeOf(AccountEffect) == 8);
}

fn haltCode(halt: FrameHalt) u32 {
    return switch (halt) {
        .stop => c.EVMZ_HALT_STOP,
        .returned => c.EVMZ_HALT_RETURN,
        .selfdestruct => c.EVMZ_HALT_SELFDESTRUCT,
        .revert => c.EVMZ_HALT_REVERT,
        .out_of_gas => c.EVMZ_HALT_OUT_OF_GAS,
        .invalid_opcode => c.EVMZ_HALT_INVALID_OPCODE,
        .stack_underflow => c.EVMZ_HALT_STACK_UNDERFLOW,
        .stack_overflow => c.EVMZ_HALT_STACK_OVERFLOW,
        .invalid_jump => c.EVMZ_HALT_INVALID_JUMP,
        .write_protection => c.EVMZ_HALT_WRITE_PROTECTION,
        .return_data_out_of_bounds => c.EVMZ_HALT_RETURN_DATA_OUT_OF_BOUNDS,
    };
}

fn accountEffects(effect: AccountEffect) u32 {
    return @as(u8, @bitCast(effect)) & account_effect_mask;
}

// ---- Value conversion ------------------------------------------------------

fn word(value: c.evmz_bytes32) u256 {
    return uint256.fromBytes32(&value.bytes);
}

fn bytes32(value: u256) c.evmz_bytes32 {
    return .{ .bytes = uint256.toBytes32(value) };
}

fn address(value: c.evmz_address) Address {
    return .{ .bytes = value.bytes };
}

fn cAddress(value: Address) c.evmz_address {
    return .{ .bytes = value.bytes };
}

fn hostAccount(value: ?Account) c.evmz_host_account {
    const account = value orelse return std.mem.zeroes(c.evmz_host_account);
    return .{
        .exists = 1,
        .nonce = account.nonce,
        .balance = bytes32(account.balance),
        .code_hash = .{ .bytes = account.code_hash },
    };
}

/// NULL for an empty slice, so a caller never sees an allocator's sentinel.
fn cPointer(comptime T: type, slice: []const T) [*c]const T {
    return if (slice.len == 0) null else slice.ptr;
}

const InputError = error{InvalidArgument};

fn flag(value: u8) InputError!bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => error.InvalidArgument,
    };
}

fn optionalWord(has: u8, value: c.evmz_bytes32) InputError!?u256 {
    return if (try flag(has)) word(value) else null;
}

fn inputSlice(comptime T: type, pointer: [*c]const T, len: usize) InputError![]const T {
    if (len == 0) return &.{};
    if (pointer == null) return error.InvalidArgument;
    return pointer[0..len];
}

fn words(scratch: Allocator, source: []const c.evmz_bytes32) Allocator.Error![]const u256 {
    const out = try scratch.alloc(u256, source.len);
    for (out, source) |*target, value| target.* = word(value);
    return out;
}

fn envFromC(env: *const c.evmz_env) InputError!Env {
    return .{
        .chain_id = word(env.chain_id),
        .coinbase = address(env.coinbase),
        .number = env.number,
        .slot_number = env.slot_number,
        .timestamp = env.timestamp,
        .gas_limit = env.gas_limit,
        .prev_randao = word(env.prev_randao),
        .base_fee = word(env.base_fee),
        .blob_base_fee = word(env.blob_base_fee),
        .blob_params = if (try flag(env.has_blob_params)) .{
            .target = env.blob_params.target,
            .max = env.blob_params.max,
            .base_fee_update_fraction = word(env.blob_params.base_fee_update_fraction),
        } else null,
    };
}

/// Borrows `input` from the caller; every list is converted into `scratch`.
fn transactionFromC(
    scratch: Allocator,
    tx: *const c.evmz_transaction,
) (InputError || Allocator.Error)!Transaction {
    const kind = std.enums.fromInt(evmz.transaction.TxKind, tx.kind) orelse
        return error.InvalidArgument;

    const c_access_list = try inputSlice(c.evmz_access_list_entry, tx.access_list, tx.access_list_len);
    const access_list = try scratch.alloc(evmz.transaction.AccessListEntry, c_access_list.len);
    for (access_list, c_access_list) |*target, entry| target.* = .{
        .address = address(entry.address),
        .storage_keys = try words(
            scratch,
            try inputSlice(c.evmz_bytes32, entry.storage_keys, entry.storage_keys_len),
        ),
    };

    const c_authorizations = try inputSlice(
        c.evmz_recovered_authorization,
        tx.authorization_list,
        tx.authorization_list_len,
    );
    const authorizations = try scratch.alloc(
        evmz.transaction.RecoveredAuthorization,
        c_authorizations.len,
    );
    for (authorizations, c_authorizations) |*target, authorization| target.* = .{
        .chain_id = word(authorization.chain_id),
        .target = address(authorization.target),
        .signer = address(authorization.signer),
        .nonce = authorization.nonce,
    };
    const authorization_count: ?usize = if (try flag(tx.has_authorization_count)) count: {
        const count = std.math.cast(usize, tx.authorization_count) orelse
            return error.InvalidArgument;
        if (count < authorizations.len) return error.InvalidArgument;
        break :count count;
    } else null;

    return .{
        .kind = kind,
        .sender = address(tx.sender),
        .chain_id = try optionalWord(tx.has_chain_id, tx.chain_id),
        .nonce = if (try flag(tx.has_nonce)) tx.nonce else null,
        .gas_limit = tx.gas_limit,
        .to = if (try flag(tx.has_to)) address(tx.to) else null,
        .value = word(tx.value),
        .input = try inputSlice(u8, tx.input, tx.input_len),
        .gas_price = word(tx.gas_price),
        .max_fee_per_gas = try optionalWord(tx.has_max_fee_per_gas, tx.max_fee_per_gas),
        .max_priority_fee_per_gas = try optionalWord(
            tx.has_max_priority_fee_per_gas,
            tx.max_priority_fee_per_gas,
        ),
        .max_fee_per_blob_gas = try optionalWord(
            tx.has_max_fee_per_blob_gas,
            tx.max_fee_per_blob_gas,
        ),
        .blob_hashes = try words(
            scratch,
            try inputSlice(c.evmz_bytes32, tx.blob_hashes, tx.blob_hashes_len),
        ),
        .access_list = access_list,
        .authorization_list = authorizations,
        .authorization_count = authorization_count,
    };
}

fn progressFromC(progress: ?*const c.evmz_block_progress) evmz.transaction.PreparationBlockProgress {
    const value = progress orelse return .{};
    return .{
        .receipt_gas_used = value.receipt_gas_used,
        .block_gas = .{
            .total = value.block_gas.total,
            .regular = value.block_gas.regular,
            .state = value.block_gas.state,
        },
    };
}

const SystemCall = struct {
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas_limit: u64,
    state_gas: u64,
};

// ---- Result ----------------------------------------------------------------

/// One owned, self-contained copy of an execution's output. Nothing in it
/// points back into the session, which is what lets it outlive one.
const Result = struct {
    arena: std.heap.ArenaAllocator,
    data: c.evmz_result_data,

    const CopyError = Allocator.Error || error{InconsistentState};

    fn create() Allocator.Error!*Result {
        const self = try gpa.create(Result);
        self.* = .{
            .arena = .init(gpa),
            .data = std.mem.zeroes(c.evmz_result_data),
        };
        self.data.struct_size = @sizeOf(c.evmz_result_data);
        return self;
    }

    fn destroy(self: *Result) void {
        self.arena.deinit();
        gpa.destroy(self);
    }

    fn handle(self: *Result) *c.evmz_result {
        return @ptrCast(self);
    }

    fn fromHandle(pointer: *const c.evmz_result) *const Result {
        return @ptrCast(@alignCast(pointer));
    }

    fn rejected(rejection: ValidationError) Allocator.Error!*Result {
        const self = try create();
        self.data.outcome = c.EVMZ_OUTCOME_REJECTED;
        self.data.rejection = @as(u32, @backingInt(rejection)) + 1;
        return self;
    }

    fn setStatus(self: *Result, status: evmz.TxStatus, halt: ?FrameHalt) void {
        self.data.outcome = c.EVMZ_OUTCOME_EXECUTED;
        self.data.status = @backingInt(status);
        if (halt) |value| {
            self.data.has_halt = 1;
            self.data.halt = haltCode(value);
        }
    }

    fn copyOutput(self: *Result, output: []const u8) Allocator.Error!void {
        const copy = try self.arena.allocator().dupe(u8, output);
        self.data.output = cPointer(u8, copy);
        self.data.output_len = copy.len;
    }

    fn copyLogs(self: *Result, logs: evmz.state.LogBuffer.View) Allocator.Error!void {
        const arena = self.arena.allocator();
        const out = try arena.alloc(c.evmz_log, logs.len());
        for (out, 0..) |*target, index| {
            const log = logs.get(index);
            const topics = try arena.alloc(c.evmz_bytes32, log.topics.len);
            for (topics, log.topics) |*topic, value| topic.* = bytes32(value);
            const data = try arena.dupe(u8, log.data);
            target.* = .{
                .address = cAddress(log.address),
                .topics = cPointer(c.evmz_bytes32, topics),
                .topics_len = topics.len,
                .data = cPointer(u8, data),
                .data_len = data.len,
            };
        }
        self.data.logs = cPointer(c.evmz_log, out);
        self.data.logs_len = out.len;
    }

    /// Project one sealed transition: the net changes, each joined to the
    /// observation that holds its pre-execution value.
    ///
    /// `changes` and `observations` are the engine's borrowed views. A change
    /// without its observation, or a new code hash without its bytes, breaks an
    /// engine invariant and is reported rather than asserted, because an abort
    /// would take the embedding process down.
    fn copyState(self: *Result, changes: anytype, observations: anytype) CopyError!void {
        const arena = self.arena.allocator();
        var scratch_state: std.heap.ArenaAllocator = .init(gpa);
        defer scratch_state.deinit();
        const scratch = scratch_state.allocator();

        var account_records: std.AutoHashMapUnmanaged(Address, u32) = .empty;
        try account_records.ensureTotalCapacity(scratch, observations.accounts.len());
        for (0..observations.accounts.len()) |index| account_records.putAssumeCapacity(
            observations.accounts.at(@intCast(index)).address,
            @intCast(index),
        );

        const accounts = try arena.alloc(c.evmz_account_delta, changes.accounts.len());
        var codes: std.ArrayList(c.evmz_code_change) = .empty;
        for (accounts, 0..) |*target, index| {
            const change = changes.accounts.at(@intCast(index));
            const record = observations.accounts.at(
                account_records.get(change.address) orelse return error.InconsistentState,
            );
            target.* = .{
                .address = cAddress(change.address),
                .effects = accountEffects(record.effect),
                .original = hostAccount(record.original),
                .current = hostAccount(change.account),
            };

            // `changes.introducedCode` knows only code the engine created. A
            // host keyed by code hash needs the bytes whenever an account
            // points at a hash it did not point at before, so report those.
            const current = change.account orelse continue;
            const original_hash = if (record.original) |original|
                original.code_hash
            else
                crypto.keccak256_empty;
            if (std.mem.eql(u8, &current.code_hash, &original_hash)) continue;
            if (std.mem.eql(u8, &current.code_hash, &crypto.keccak256_empty)) continue;
            if (containsCode(codes.items, current.code_hash)) continue;
            const code = observations.code(current.code_hash) orelse return error.InconsistentState;
            const bytes = try arena.dupe(u8, code.bytes);
            try codes.append(arena, .{
                .code_hash = .{ .bytes = current.code_hash },
                .code = cPointer(u8, bytes),
                .code_len = bytes.len,
            });
        }

        const StorageKey = struct { address: Address, key: u256 };
        var storage_originals: std.AutoHashMapUnmanaged(StorageKey, u256) = .empty;
        try storage_originals.ensureTotalCapacity(scratch, observations.storage.len());
        for (0..observations.storage.len()) |index| {
            const record = observations.storage.at(@intCast(index));
            storage_originals.putAssumeCapacity(
                .{ .address = record.address, .key = record.key },
                record.original,
            );
        }

        const storage = try arena.alloc(c.evmz_storage_delta, changes.storage_writes.len());
        for (storage, 0..) |*target, index| {
            const change = changes.storage_writes.at(@intCast(index));
            const original = storage_originals.get(.{ .address = change.address, .key = change.key }) orelse
                return error.InconsistentState;
            target.* = .{
                .address = cAddress(change.address),
                .key = bytes32(change.key),
                .original = bytes32(original),
                .current = bytes32(change.value),
            };
        }

        const wipes = try arena.alloc(c.evmz_address, changes.storage_wipes.len());
        for (wipes, 0..) |*target, index|
            target.* = cAddress(changes.storage_wipes.at(@intCast(index)));

        self.data.accounts = cPointer(c.evmz_account_delta, accounts);
        self.data.accounts_len = accounts.len;
        self.data.storage = cPointer(c.evmz_storage_delta, storage);
        self.data.storage_len = storage.len;
        self.data.storage_wipes = cPointer(c.evmz_address, wipes);
        self.data.storage_wipes_len = wipes.len;
        self.data.code_changes = cPointer(c.evmz_code_change, codes.items);
        self.data.code_changes_len = codes.items.len;
    }

    fn containsCode(codes: []const c.evmz_code_change, code_hash: [32]u8) bool {
        for (codes) |code| {
            if (std.mem.eql(u8, &code.code_hash.bytes, &code_hash)) return true;
        }
        return false;
    }
};

// ---- Session ---------------------------------------------------------------

/// The fork-independent half of a session: the host adapters and the dispatch
/// to the engine compiled for the session's fork.
const Session = struct {
    vtable: *const VTable,
    host: c.evmz_host,
    /// Set when a callback fails. The engine folds a reader error it does not
    /// know into `InfrastructureFailure`, so the cause has to be kept here.
    host_failed: bool = false,
    /// The bytes of the last `load_code`. The reader contract lets the reader
    /// own them, and the engine copies them into its code cache before the
    /// next load replaces them.
    code: std.ArrayList(u8) = .empty,
    sink: enum { closed, open, filled, out_of_memory } = .closed,

    const VTable = struct {
        destroy: *const fn (*Session) void,
        execute: *const fn (*Session, *const TransactInput, *?*c.evmz_result) Status,
        executeSystemCall: *const fn (*Session, Env, SystemCall, *?*c.evmz_result) Status,
        accept: *const fn (*Session) Status,
        discard: *const fn (*Session) Status,
        reset: *const fn (*Session) Status,
    };

    fn handle(self: *Session) *c.evmz_session {
        return @ptrCast(self);
    }

    fn fromHandle(pointer: *c.evmz_session) *Session {
        return @ptrCast(@alignCast(pointer));
    }

    fn reader(self: *Session) evmz.state.Reader {
        return .{ .ptr = self, .vtable = &.{
            .loadAccount = loadAccount,
            .loadCode = loadCode,
            .getStorage = getStorage,
        } };
    }

    fn blockHashSource(self: *Session) evmz.block.HashSource {
        return .{ .ptr = self, .vtable = &.{ .getBlockHash = getBlockHash } };
    }

    fn hostFailure(self: *Session) error{HostFailure} {
        self.host_failed = true;
        return error.HostFailure;
    }

    /// The status for an engine error raised during an execute.
    fn failure(self: *const Session, err: anyerror) Status {
        if (err == error.OutOfMemory) return out_of_memory;
        if (self.host_failed) return host_failure;
        return switch (err) {
            // The host's own data disagrees with itself: code that does not
            // hash to its key, or balances that sum past 2^256.
            error.CodeHashMismatch, error.CodeUnavailable, error.BalanceOverflow => host_failure,
            else => internal_error,
        };
    }

    fn loadAccount(context: *anyopaque, account_address: Address) anyerror!?Account {
        const self: *Session = @ptrCast(@alignCast(context));
        const c_address = cAddress(account_address);
        var out = std.mem.zeroes(c.evmz_host_account);
        if (self.host.load_account.?(self.host.context, &c_address, &out) != ok)
            return self.hostFailure();
        if (!(flag(out.exists) catch return self.hostFailure())) return null;
        return .{
            .nonce = out.nonce,
            .balance = word(out.balance),
            .code_hash = out.code_hash.bytes,
        };
    }

    fn loadCode(context: *anyopaque, code_hash: [32]u8) anyerror![]const u8 {
        const self: *Session = @ptrCast(@alignCast(context));
        const c_hash: c.evmz_bytes32 = .{ .bytes = code_hash };
        self.sink = .open;
        const status = self.host.load_code.?(self.host.context, &c_hash, @ptrCast(self));
        const sink = self.sink;
        self.sink = .closed;
        if (sink == .out_of_memory) return error.OutOfMemory;
        if (status != ok or sink != .filled) return self.hostFailure();
        return self.code.items;
    }

    fn getStorage(context: *anyopaque, account_address: Address, key: u256) anyerror!u256 {
        const self: *Session = @ptrCast(@alignCast(context));
        const c_address = cAddress(account_address);
        const c_key = bytes32(key);
        var out = std.mem.zeroes(c.evmz_bytes32);
        if (self.host.get_storage.?(self.host.context, &c_address, &c_key, &out) != ok)
            return self.hostFailure();
        return word(out);
    }

    fn getBlockHash(context: *anyopaque, number: u64) anyerror!?u256 {
        const self: *Session = @ptrCast(@alignCast(context));
        const callback = self.host.get_block_hash orelse return null;
        var out = std.mem.zeroes(c.evmz_bytes32);
        var found: u8 = 0;
        if (callback(self.host.context, number, &out, &found) != ok) return self.hostFailure();
        return if (flag(found) catch return self.hostFailure()) word(out) else null;
    }
};

/// The engine half of a session for one compiled fork.
fn ForkSession(comptime revision: Revision) type {
    const Vm = evmz.Vm(evmz.eth.specAt(revision));

    return struct {
        const Self = @This();

        session: Session,
        executor: Vm.Executor,
        /// The executed transaction awaiting accept or discard.
        pending: ?Vm.Executed = null,

        const vtable: Session.VTable = .{
            .destroy = destroy,
            .execute = execute,
            .executeSystemCall = executeSystemCall,
            .accept = accept,
            .discard = discard,
            .reset = reset,
        };

        /// Heap-allocated because the executor and a pending `Executed` hold
        /// pointers into it.
        fn create(host: c.evmz_host) Allocator.Error!*Session {
            const self = try gpa.create(Self);
            self.* = .{
                .session = .{ .vtable = &vtable, .host = host },
                .executor = undefined,
            };
            self.executor = .init(gpa, .{
                .state = .{ .reader = self.session.reader() },
                .block_hash_source = self.session.blockHashSource(),
            });
            return &self.session;
        }

        fn from(session: *Session) *Self {
            // `create` is the only source of a `Session`, so it is always the
            // field of a `Self` allocated at `Self`'s alignment.
            return @alignCast(@fieldParentPtr("session", session));
        }

        fn destroy(session: *Session) void {
            const self = from(session);
            if (self.pending) |executed| executed.discard();
            self.executor.deinit();
            session.code.deinit(gpa);
            gpa.destroy(self);
        }

        fn execute(session: *Session, input: *const TransactInput, out: *?*c.evmz_result) Status {
            const self = from(session);
            if (self.pending != null) return pending_result;
            session.host_failed = false;
            const outcome = Vm.Advanced.observe(&self.executor).transact(input.*) catch |err|
                return session.failure(err);
            switch (outcome) {
                .rejected => |rejection| {
                    const result = Result.rejected(rejection) catch return out_of_memory;
                    out.* = result.handle();
                },
                .executed => |executed| {
                    const result = copyExecuted(executed) catch |err| {
                        executed.discard();
                        return session.failure(err);
                    };
                    self.pending = executed;
                    out.* = result.handle();
                },
            }
            return ok;
        }

        fn copyExecuted(executed: Vm.Executed) Result.CopyError!*Result {
            const result = try Result.create();
            errdefer result.destroy();
            const output = executed.result();
            result.setStatus(output.status, output.frame_halt);
            try result.copyOutput(output.output);
            result.data.gas = .{
                .used = output.gas.used,
                .execution_refund = output.gas.execution_refund,
                .refunded = output.gas.refunded,
                .block = .{
                    .total = output.gas.block.total,
                    .regular = output.gas.block.regular,
                    .state = output.gas.block.state,
                },
            };
            if (output.created_address) |created| {
                result.data.has_created_address = 1;
                result.data.created_address = cAddress(created);
            }
            try result.copyLogs(executed.logs());
            try result.copyState(executed.changes(), executed.observations());
            return result;
        }

        /// Copies a system call out while the engine still holds it: the call
        /// is retained as soon as the observer returns, and a retained call
        /// cannot be undone on its own. So every allocation happens here, where
        /// a failure still discards the attempt.
        const SystemCallObserver = struct {
            result: *Result,
            executor: *const Vm.Executor,

            pub fn observe(self: SystemCallObserver, observation: Vm.Executor.Observation) !void {
                // The frame's output, which `executeSystemCall` returns as is.
                try self.result.copyOutput(self.executor.lastOutputData());
                try self.result.copyLogs(observation.logs());
                try self.result.copyState(observation.changes(), observation.observations());
            }
        };

        fn executeSystemCall(
            session: *Session,
            env: Env,
            call: SystemCall,
            out: *?*c.evmz_result,
        ) Status {
            const self = from(session);
            if (self.pending != null) return pending_result;
            session.host_failed = false;
            const result = Result.create() catch return out_of_memory;
            const observer: SystemCallObserver = .{ .result = result, .executor = &self.executor };
            const executed = self.executor.observe(observer).executeSystemCall(
                // The origin the block lifecycle gives its own system calls.
                env.executionContext(.{ .origin = evmz.addr(0) }),
                call.sender,
                call.recipient,
                call.input,
                .{ .regular_left = call.gas_limit, .reservoir = call.state_gas },
            ) catch |err| {
                result.destroy();
                // The recipient is a native contract, which only a transaction can reach.
                if (err == error.NativeSystemCallUnsupported) return invalid_argument;
                return session.failure(err);
            };
            result.setStatus(executed.status(), executed.frame_halt);
            result.data.gas.used = call.gas_limit -| std.math.lossyCast(u64, executed.gas_left);
            out.* = result.handle();
            return ok;
        }

        fn accept(session: *Session) Status {
            const self = from(session);
            const executed = self.pending orelse return no_pending_result;
            executed.retain();
            self.pending = null;
            return ok;
        }

        fn discard(session: *Session) Status {
            const self = from(session);
            const executed = self.pending orelse return no_pending_result;
            executed.discard();
            self.pending = null;
            return ok;
        }

        fn reset(session: *Session) Status {
            const self = from(session);
            if (self.pending != null) return pending_result;
            self.executor.discardAccepted();
            return ok;
        }
    };
}

// ---- Exports ---------------------------------------------------------------

export fn evmz_abi_version() u32 {
    return c.EVMZ_ABI_VERSION;
}

export fn evmz_capabilities() u64 {
    return c.EVMZ_CAPABILITY_SYSTEM_CALL;
}

export fn evmz_build_optimize() u32 {
    return switch (builtin.optimize) {
        .debug => c.EVMZ_OPTIMIZE_DEBUG,
        .safe => c.EVMZ_OPTIMIZE_RELEASE_SAFE,
        .fast => c.EVMZ_OPTIMIZE_RELEASE_FAST,
        .small => c.EVMZ_OPTIMIZE_RELEASE_SMALL,
    };
}

fn compiledFork(fork: u32) ?Revision {
    const tag = std.math.cast(@typeInfo(Revision).@"enum".tag_type, fork) orelse return null;
    const revision = std.enums.fromInt(Revision, tag) orelse return null;
    return if (std.mem.findScalar(Revision, forks, revision) != null) revision else null;
}

export fn evmz_fork_supported(fork: u32) c_int {
    return @intFromBool(compiledFork(fork) != null);
}

export fn evmz_code_sink_set(sink: ?*c.evmz_code_sink, ptr: [*c]const u8, len: usize) Status {
    const session: *Session = @ptrCast(@alignCast(sink orelse return invalid_argument));
    if (session.sink != .open) return invalid_argument;
    const bytes = inputSlice(u8, ptr, len) catch return invalid_argument;
    session.code.clearRetainingCapacity();
    session.code.appendSlice(gpa, bytes) catch {
        session.sink = .out_of_memory;
        return out_of_memory;
    };
    session.sink = .filled;
    return ok;
}

export fn evmz_result_get_data(result: ?*const c.evmz_result) [*c]const c.evmz_result_data {
    return &Result.fromHandle(result orelse return null).data;
}

export fn evmz_result_destroy(result: ?*c.evmz_result) void {
    const pointer: *Result = @ptrCast(@alignCast(result orelse return));
    pointer.destroy();
}

export fn evmz_session_create(
    fork: u32,
    host: [*c]const c.evmz_host,
    out: [*c]?*c.evmz_session,
) Status {
    const out_pointer = @as(?*?*c.evmz_session, out) orelse return invalid_argument;
    out_pointer.* = null;
    const host_pointer = @as(?*const c.evmz_host, host) orelse return invalid_argument;
    if (host_pointer.struct_size < @sizeOf(c.evmz_host)) return invalid_argument;
    if (host_pointer.load_account == null or host_pointer.load_code == null or
        host_pointer.get_storage == null) return invalid_argument;

    const revision = compiledFork(fork) orelse return unsupported_fork;
    inline for (forks) |compiled| {
        if (revision == compiled) {
            const session = ForkSession(compiled).create(host_pointer.*) catch return out_of_memory;
            out_pointer.* = session.handle();
            return ok;
        }
    }
    return unsupported_fork;
}

export fn evmz_session_destroy(session: ?*c.evmz_session) void {
    const pointer = Session.fromHandle(session orelse return);
    pointer.vtable.destroy(pointer);
}

export fn evmz_session_execute(
    session: ?*c.evmz_session,
    env: [*c]const c.evmz_env,
    progress: [*c]const c.evmz_block_progress,
    transaction: [*c]const c.evmz_transaction,
    out: [*c]?*c.evmz_result,
) Status {
    const out_pointer = @as(?*?*c.evmz_result, out) orelse return invalid_argument;
    out_pointer.* = null;
    const pointer = Session.fromHandle(session orelse return invalid_argument);
    const env_pointer = @as(?*const c.evmz_env, env) orelse return invalid_argument;
    const tx_pointer = @as(?*const c.evmz_transaction, transaction) orelse return invalid_argument;

    var scratch: std.heap.ArenaAllocator = .init(gpa);
    defer scratch.deinit();
    const input: TransactInput = .{
        .env = envFromC(env_pointer) catch return invalid_argument,
        .tx = transactionFromC(scratch.allocator(), tx_pointer) catch |err| return switch (err) {
            error.InvalidArgument => invalid_argument,
            error.OutOfMemory => out_of_memory,
        },
        .progress = progressFromC(progress),
    };
    return pointer.vtable.execute(pointer, &input, out_pointer);
}

export fn evmz_session_execute_system_call(
    session: ?*c.evmz_session,
    env: [*c]const c.evmz_env,
    call: [*c]const c.evmz_system_call,
    out: [*c]?*c.evmz_result,
) Status {
    const out_pointer = @as(?*?*c.evmz_result, out) orelse return invalid_argument;
    out_pointer.* = null;
    const pointer = Session.fromHandle(session orelse return invalid_argument);
    const env_pointer = @as(?*const c.evmz_env, env) orelse return invalid_argument;
    const call_pointer = @as(?*const c.evmz_system_call, call) orelse return invalid_argument;

    return pointer.vtable.executeSystemCall(
        pointer,
        envFromC(env_pointer) catch return invalid_argument,
        .{
            .sender = address(call_pointer.sender),
            .recipient = address(call_pointer.recipient),
            .input = inputSlice(u8, call_pointer.input, call_pointer.input_len) catch
                return invalid_argument,
            .gas_limit = call_pointer.gas_limit,
            .state_gas = call_pointer.state_gas,
        },
        out_pointer,
    );
}

export fn evmz_session_accept(session: ?*c.evmz_session) Status {
    const pointer = Session.fromHandle(session orelse return invalid_argument);
    return pointer.vtable.accept(pointer);
}

export fn evmz_session_discard(session: ?*c.evmz_session) Status {
    const pointer = Session.fromHandle(session orelse return invalid_argument);
    return pointer.vtable.discard(pointer);
}

export fn evmz_session_reset(session: ?*c.evmz_session) Status {
    const pointer = Session.fromHandle(session orelse return invalid_argument);
    return pointer.vtable.reset(pointer);
}

// Every prototype the header declares is exported here with the same type.
comptime {
    for (.{
        "evmz_abi_version",                 "evmz_capabilities",
        "evmz_build_optimize",              "evmz_fork_supported",
        "evmz_code_sink_set",               "evmz_result_get_data",
        "evmz_result_destroy",              "evmz_session_create",
        "evmz_session_destroy",             "evmz_session_execute",
        "evmz_session_execute_system_call", "evmz_session_accept",
        "evmz_session_discard",             "evmz_session_reset",
    }) |name| {
        if (@TypeOf(@field(@This(), name)) != @TypeOf(@field(c, name)))
            @compileError(name ++ " does not match its prototype in evmz.h");
    }
}

// ---- Tests -----------------------------------------------------------------
//
// These drive the exported functions the way a C host would, against a host
// backed by a `MemoryStore`. Wherever a result is accepted it is applied to
// that store in the order the header prescribes, and the store must then hash
// to the state root the engine's own delta gives.

const testing = std.testing;

const fixture = struct {
    const fork: u32 = @backingInt(Revision.latest);
    const env: Env = .{ .gas_limit = 30_000_000 };
    /// Room for the state gas a new account or slot costs on recent forks.
    const gas_limit = 1_000_000;
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    const contract = evmz.addr(0xcccc);
    const system_sender = evmz.addr(0xfffffffffffffffffffffffffffffffffffffffe);
};

fn span(comptime T: type, pointer: [*c]const T, len: usize) []const T {
    return if (len == 0) &.{} else pointer[0..len];
}

fn addressWord(value: Address) u256 {
    var bytes: [32]u8 = @splat(0);
    @memcpy(bytes[12..], &value.bytes);
    return uint256.fromBytes32(&bytes);
}

/// A host over a `MemoryStore`, written against the C callback types.
const TestHost = struct {
    memory: evmz.state.MemoryStore,
    fail: Failure = .none,
    block_hash_requests: std.ArrayList(u64) = .empty,
    last_sink: ?*c.evmz_code_sink = null,

    const Failure = enum {
        none,
        account,
        /// `exists` is neither 0 nor 1.
        account_flag,
        code,
        /// `load_code` succeeds without handing any code over.
        code_unset,
        /// `load_code` hands over bytes that do not hash to the request.
        code_wrong,
        storage,
        block_hash,
    };

    fn init() TestHost {
        return .{ .memory = .init(testing.allocator) };
    }

    fn deinit(self: *TestHost) void {
        self.block_hash_requests.deinit(testing.allocator);
        self.memory.deinit();
    }

    fn host(self: *TestHost) c.evmz_host {
        return .{
            .struct_size = @sizeOf(c.evmz_host),
            .context = self,
            .load_account = loadAccount,
            .load_code = loadCode,
            .get_storage = getStorage,
            .get_block_hash = getBlockHash,
        };
    }

    fn createSession(self: *TestHost, fork: u32) !*c.evmz_session {
        var session: ?*c.evmz_session = null;
        try testing.expectEqual(ok, evmz_session_create(fork, &self.host(), &session));
        return session.?;
    }

    fn blockHash(number: u64) u256 {
        return (@as(u256, 0xb10c) << 64) | number;
    }

    /// The same hashes for the engine run a test compares against.
    fn hashSource(self: *TestHost) evmz.block.HashSource {
        return .{ .ptr = self, .vtable = &.{ .getBlockHash = engineBlockHash } };
    }

    fn engineBlockHash(_: *anyopaque, number: u64) anyerror!?u256 {
        return blockHash(number);
    }

    fn from(context: ?*anyopaque) *TestHost {
        return @ptrCast(@alignCast(context.?));
    }

    fn loadAccount(
        context: ?*anyopaque,
        account_address: [*c]const c.evmz_address,
        out: [*c]c.evmz_host_account,
    ) callconv(.c) Status {
        const self = from(context);
        if (self.fail == .account) return host_failure;
        out.* = hostAccount(if (self.memory.getAccount(address(account_address.*))) |account|
            account.account
        else
            null);
        if (self.fail == .account_flag) out.*.exists = 2;
        return ok;
    }

    fn loadCode(
        context: ?*anyopaque,
        code_hash: [*c]const c.evmz_bytes32,
        sink: ?*c.evmz_code_sink,
    ) callconv(.c) Status {
        const self = from(context);
        self.last_sink = sink;
        switch (self.fail) {
            .code => return host_failure,
            .code_unset => return ok,
            .code_wrong => return evmz_code_sink_set(sink, &[_]u8{0xfe}, 1),
            else => {},
        }
        const code = self.memory.reader().loadCode(code_hash.*.bytes) catch return host_failure;
        return evmz_code_sink_set(sink, cPointer(u8, code), code.len);
    }

    fn getStorage(
        context: ?*anyopaque,
        account_address: [*c]const c.evmz_address,
        key: [*c]const c.evmz_bytes32,
        out: [*c]c.evmz_bytes32,
    ) callconv(.c) Status {
        const self = from(context);
        if (self.fail == .storage) return host_failure;
        const account = self.memory.getAccount(address(account_address.*));
        out.* = bytes32(if (account) |value| value.getStorage(word(key.*)) else 0);
        return ok;
    }

    fn getBlockHash(
        context: ?*anyopaque,
        number: u64,
        out: [*c]c.evmz_bytes32,
        found: [*c]u8,
    ) callconv(.c) Status {
        const self = from(context);
        if (self.fail == .block_hash) return host_failure;
        self.block_hash_requests.append(testing.allocator, number) catch return out_of_memory;
        out.* = bytes32(blockHash(number));
        found.* = 1;
        return ok;
    }

    /// Apply an accepted result in the order `evmz_result_data` prescribes.
    fn apply(self: *TestHost, data: *const c.evmz_result_data) !void {
        for (span(c.evmz_address, data.storage_wipes, data.storage_wipes_len)) |wiped| {
            if (self.memory.getAccount(address(wiped))) |account|
                account.storage.clearRetainingCapacity();
        }
        for (span(c.evmz_storage_delta, data.storage, data.storage_len)) |row| {
            const value = word(row.current);
            if (value != 0) {
                const account = try self.memory.getOrCreateAccount(address(row.address));
                try account.storage.put(word(row.key), value);
            } else if (self.memory.getAccount(address(row.address))) |account| {
                _ = account.storage.remove(word(row.key));
            }
        }
        for (span(c.evmz_account_delta, data.accounts, data.accounts_len)) |row| {
            if (row.current.exists == 0) {
                _ = self.memory.removeAccount(address(row.address));
                continue;
            }
            const account = try self.memory.getOrCreateAccount(address(row.address));
            account.account.nonce = row.current.nonce;
            account.account.balance = word(row.current.balance);
            const code_hash = row.current.code_hash.bytes;
            if (std.mem.eql(u8, &account.account.code_hash, &code_hash)) continue;
            if (std.mem.eql(u8, &code_hash, &crypto.keccak256_empty)) {
                account.clearCode();
            } else {
                const code = codeChange(data, code_hash) orelse return error.MissingCodeChange;
                try account.setCode(span(u8, code.code, code.code_len));
                try testing.expectEqualSlices(u8, &code_hash, &account.account.code_hash);
            }
        }
    }
};

fn dataOf(result: *const c.evmz_result) *const c.evmz_result_data {
    return evmz_result_get_data(result);
}

fn accountRow(data: *const c.evmz_result_data, target: Address) ?c.evmz_account_delta {
    for (span(c.evmz_account_delta, data.accounts, data.accounts_len)) |row| {
        if (address(row.address).eql(target)) return row;
    }
    return null;
}

fn storageRow(data: *const c.evmz_result_data, target: Address, key: u256) ?c.evmz_storage_delta {
    for (span(c.evmz_storage_delta, data.storage, data.storage_len)) |row| {
        if (address(row.address).eql(target) and word(row.key) == key) return row;
    }
    return null;
}

fn codeChange(data: *const c.evmz_result_data, code_hash: [32]u8) ?c.evmz_code_change {
    for (span(c.evmz_code_change, data.code_changes, data.code_changes_len)) |code| {
        if (std.mem.eql(u8, &code.code_hash.bytes, &code_hash)) return code;
    }
    return null;
}

fn listsWipe(data: *const c.evmz_result_data, target: Address) bool {
    for (span(c.evmz_address, data.storage_wipes, data.storage_wipes_len)) |wiped| {
        if (address(wiped).eql(target)) return true;
    }
    return false;
}

fn hasEffect(row: c.evmz_account_delta, bit: u32) bool {
    return row.effects & bit != 0;
}

/// `testing.expectEqual` for the header's `uint32_t` codes, whose constants
/// translate as `c_int`.
fn expectCode(expected: u32, actual: u32) !void {
    try testing.expectEqual(expected, actual);
}

fn cEnv(env: Env) c.evmz_env {
    var out = std.mem.zeroes(c.evmz_env);
    out.chain_id = bytes32(env.chain_id);
    out.coinbase = cAddress(env.coinbase);
    out.number = env.number;
    out.slot_number = env.slot_number;
    out.timestamp = env.timestamp;
    out.gas_limit = env.gas_limit;
    out.prev_randao = bytes32(env.prev_randao);
    out.base_fee = bytes32(env.base_fee);
    out.blob_base_fee = bytes32(env.blob_base_fee);
    return out;
}

/// The C form of `tx`, with its lists allocated in `arena`. Blob hashes are
/// not carried; no test here sends a blob transaction.
fn cTransaction(arena: Allocator, tx: Transaction) !c.evmz_transaction {
    var out = std.mem.zeroes(c.evmz_transaction);
    out.kind = @backingInt(tx.kind);
    out.sender = cAddress(tx.sender);
    if (tx.chain_id) |value| {
        out.has_chain_id = 1;
        out.chain_id = bytes32(value);
    }
    if (tx.nonce) |value| {
        out.has_nonce = 1;
        out.nonce = @intCast(value);
    }
    out.gas_limit = tx.gas_limit;
    if (tx.to) |value| {
        out.has_to = 1;
        out.to = cAddress(value);
    }
    out.value = bytes32(tx.value);
    out.input = cPointer(u8, tx.input);
    out.input_len = tx.input.len;
    out.gas_price = bytes32(tx.gas_price);
    if (tx.max_fee_per_gas) |value| {
        out.has_max_fee_per_gas = 1;
        out.max_fee_per_gas = bytes32(value);
    }
    if (tx.max_priority_fee_per_gas) |value| {
        out.has_max_priority_fee_per_gas = 1;
        out.max_priority_fee_per_gas = bytes32(value);
    }

    const access_list = try arena.alloc(c.evmz_access_list_entry, tx.access_list.len);
    for (access_list, tx.access_list) |*target, entry| {
        const keys = try arena.alloc(c.evmz_bytes32, entry.storage_keys.len);
        for (keys, entry.storage_keys) |*key, value| key.* = bytes32(value);
        target.* = .{
            .address = cAddress(entry.address),
            .storage_keys = cPointer(c.evmz_bytes32, keys),
            .storage_keys_len = keys.len,
        };
    }
    out.access_list = cPointer(c.evmz_access_list_entry, access_list);
    out.access_list_len = access_list.len;

    const authorizations = try arena.alloc(
        c.evmz_recovered_authorization,
        tx.authorization_list.len,
    );
    for (authorizations, tx.authorization_list) |*target, authorization| target.* = .{
        .chain_id = bytes32(authorization.chain_id),
        .target = cAddress(authorization.target),
        .signer = cAddress(authorization.signer),
        .nonce = authorization.nonce,
    };
    out.authorization_list = cPointer(c.evmz_recovered_authorization, authorizations);
    out.authorization_list_len = authorizations.len;
    if (tx.authorization_count) |count| {
        out.has_authorization_count = 1;
        out.authorization_count = count;
    }
    return out;
}

fn executeTransaction(
    session: ?*c.evmz_session,
    env: Env,
    progress: ?*const c.evmz_block_progress,
    tx: Transaction,
    out: *?*c.evmz_result,
) !Status {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const c_env = cEnv(env);
    const c_tx = try cTransaction(arena.allocator(), tx);
    return evmz_session_execute(session, &c_env, progress, &c_tx, out);
}

fn systemCall(
    session: ?*c.evmz_session,
    env: Env,
    call: SystemCall,
    out: *?*c.evmz_result,
) Status {
    const c_env = cEnv(env);
    const c_call: c.evmz_system_call = .{
        .sender = cAddress(call.sender),
        .recipient = cAddress(call.recipient),
        .input = cPointer(u8, call.input),
        .input_len = call.input.len,
        .gas_limit = call.gas_limit,
        .state_gas = call.state_gas,
    };
    return evmz_session_execute_system_call(session, &c_env, &c_call, out);
}

const EngineRun = struct {
    root: [32]u8,
    gas_used: u64,
    execution_refund: u64,
    refunded: u64,
    block_gas: [3]u64,
    logs: usize,
};

/// What the engine makes of `tx` on the host's current state, without the C
/// ABI in between: the root after its own delta, the gas it charged and the
/// number of logs it emitted.
fn engineRun(host: *TestHost, env: Env, tx: Transaction) !EngineRun {
    const Latest = evmz.t.Vm(.latest).?;
    var executor: Latest.Executor = .init(testing.allocator, .{
        .state = .{ .reader = host.memory.reader() },
        .block_hash_source = host.hashSource(),
    });
    defer executor.deinit();
    const outcome = try Latest.Advanced.observe(&executor).transact(.{ .env = env, .tx = tx });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discard();
    var delta: evmz.state.StateDelta = try .init(testing.allocator, executed.changes());
    defer delta.deinit();
    const gas = executed.result().gas;
    return .{
        .root = try host.memory.stateRootAfterChanges(testing.allocator, delta.view()),
        .gas_used = gas.used,
        .execution_refund = gas.execution_refund,
        .refunded = gas.refunded,
        .block_gas = .{ gas.block.total, gas.block.regular, gas.block.state },
        .logs = executed.logs().len(),
    };
}

/// Execute through the C ABI on the latest fork, accept, and apply the result
/// the way a host would. The caller destroys the result.
fn executeAccepted(
    host: *TestHost,
    session: *c.evmz_session,
    env: Env,
    tx: Transaction,
) !*c.evmz_result {
    const engine = try engineRun(host, env, tx);
    var out: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, env, null, tx, &out));
    const result = out.?;
    errdefer evmz_result_destroy(result);
    const data = dataOf(result);
    try expectCode(c.EVMZ_OUTCOME_EXECUTED, data.outcome);
    try testing.expectEqual(engine.gas_used, data.gas.used);
    try testing.expectEqual(engine.execution_refund, data.gas.execution_refund);
    try testing.expectEqual(engine.refunded, data.gas.refunded);
    try testing.expectEqual(
        engine.block_gas,
        [3]u64{ data.gas.block.total, data.gas.block.regular, data.gas.block.state },
    );
    try testing.expectEqual(engine.logs, data.logs_len);
    try testing.expectEqual(ok, evmz_session_accept(session));
    try host.apply(data);
    try testing.expectEqualSlices(u8, &engine.root, &try host.memory.stateRoot(testing.allocator));
    return result;
}

fn transfer(nonce: ?u256) Transaction {
    return .{
        .sender = fixture.sender,
        .to = fixture.recipient,
        .value = 7,
        .nonce = nonce,
        .gas_limit = fixture.gas_limit,
    };
}

test "the library reports what it was built as" {
    try expectCode(c.EVMZ_ABI_VERSION, evmz_abi_version());
    try testing.expect(evmz_capabilities() & c.EVMZ_CAPABILITY_SYSTEM_CALL != 0);
    try expectCode(switch (builtin.mode) {
        .Debug => c.EVMZ_OPTIMIZE_DEBUG,
        .ReleaseSafe => c.EVMZ_OPTIMIZE_RELEASE_SAFE,
        .ReleaseFast => c.EVMZ_OPTIMIZE_RELEASE_FAST,
        .ReleaseSmall => c.EVMZ_OPTIMIZE_RELEASE_SMALL,
    }, evmz_build_optimize());
}

test "every compiled fork runs a transfer and no other fork opens a session" {
    for (std.enums.values(Revision)) |revision| {
        var host: TestHost = .init();
        defer host.deinit();
        try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });

        const fork: u32 = @backingInt(revision);
        const compiled = std.mem.findScalar(Revision, forks, revision) != null;
        try testing.expectEqual(@as(c_int, @intFromBool(compiled)), evmz_fork_supported(fork));

        var session: ?*c.evmz_session = null;
        const status = evmz_session_create(fork, &host.host(), &session);
        defer evmz_session_destroy(session);
        if (!compiled) {
            try testing.expectEqual(unsupported_fork, status);
            try testing.expect(session == null);
            continue;
        }
        try testing.expectEqual(ok, status);

        var out: ?*c.evmz_result = null;
        try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &out));
        defer evmz_result_destroy(out);
        const data = dataOf(out.?);
        try expectCode(c.EVMZ_OUTCOME_EXECUTED, data.outcome);
        try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
        try testing.expectEqual(7, word(accountRow(data, fixture.recipient).?.current.balance));
    }

    const unknown: u32 = @as(u32, @backingInt(Revision.latest)) + 1;
    var host: TestHost = .init();
    defer host.deinit();
    var session: ?*c.evmz_session = null;
    try testing.expectEqual(0, evmz_fork_supported(unknown));
    try testing.expectEqual(0, evmz_fork_supported(std.math.maxInt(u32)));
    try testing.expectEqual(unsupported_fork, evmz_session_create(unknown, &host.host(), &session));
    try testing.expect(session == null);
}

test "a transfer applies to the host's state root" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });

    const result = result: {
        const session = try host.createSession(fixture.fork);
        defer evmz_session_destroy(session);
        break :result try executeAccepted(&host, session, fixture.env, transfer(0));
    };
    defer evmz_result_destroy(result);

    // The result is a copy, so it is read here after its session is gone.
    const data = dataOf(result);
    try expectCode(@sizeOf(c.evmz_result_data), data.struct_size);
    try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
    try expectCode(c.EVMZ_REJECTION_NONE, data.rejection);
    try testing.expectEqual(fixture.gas_limit - data.gas.used, data.gas.refunded);

    const sent = accountRow(data, fixture.sender).?;
    try testing.expectEqual(0, sent.original.nonce);
    try testing.expectEqual(1, sent.current.nonce);
    try testing.expectEqual(1_000_000, word(sent.original.balance));
    try testing.expectEqual(1_000_000 - 7, word(sent.current.balance));
    try testing.expect(hasEffect(sent, c.EVMZ_ACCOUNT_NONCE_WRITTEN));

    const received = accountRow(data, fixture.recipient).?;
    try testing.expectEqual(0, received.original.exists);
    try testing.expectEqual(1, received.current.exists);
    try testing.expectEqual(7, word(received.current.balance));
    try testing.expectEqualSlices(u8, &crypto.keccak256_empty, &received.current.code_hash.bytes);
    try testing.expect(hasEffect(received, c.EVMZ_ACCOUNT_BALANCE_WRITTEN));

    try testing.expectEqual(0, data.storage_len);
    try testing.expectEqual(0, data.code_changes_len);
    try testing.expectEqual(7, host.memory.getAccount(fixture.recipient).?.account.balance);
}

test "a storage write reports the value before the execution, and logs are copied" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    try evmz.t.seedStoreAccount(&host.memory, fixture.contract, .{ .code = &evmz.t.bytecode(.{
        .PUSH1, 0x2a,  .PUSH0, .SSTORE,
        .PUSH1, 0xab,  .PUSH0, .MSTORE8,
        .PUSH1, 0x11,  .PUSH1, 1,
        .PUSH0, .LOG1, .STOP,
    }) });
    try host.memory.getAccount(fixture.contract).?.storage.put(0, 7);

    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);
    const result = try executeAccepted(&host, session, fixture.env, .{
        .sender = fixture.sender,
        .to = fixture.contract,
        .gas_limit = fixture.gas_limit,
    });
    defer evmz_result_destroy(result);
    const data = dataOf(result);

    try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
    try testing.expectEqual(1, data.has_halt);
    try expectCode(c.EVMZ_HALT_STOP, data.halt);

    const slot = storageRow(data, fixture.contract, 0).?;
    try testing.expectEqual(7, word(slot.original));
    try testing.expectEqual(0x2a, word(slot.current));
    try testing.expectEqual(1, data.storage_len);
    try testing.expectEqual(0, data.storage_wipes_len);

    const logs = span(c.evmz_log, data.logs, data.logs_len);
    try testing.expectEqual(1, logs.len);
    try testing.expect(address(logs[0].address).eql(fixture.contract));
    try testing.expectEqual(1, logs[0].topics_len);
    try testing.expectEqual(0x11, word(logs[0].topics[0]));
    try testing.expectEqualSlices(u8, &.{0xab}, span(u8, logs[0].data, logs[0].data_len));
}

test "one executed result is pending until it is accepted or discarded" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    try testing.expectEqual(no_pending_result, evmz_session_accept(session));
    try testing.expectEqual(no_pending_result, evmz_session_discard(session));

    var first: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &first));
    defer evmz_result_destroy(first);

    var refused: ?*c.evmz_result = null;
    try testing.expectEqual(
        pending_result,
        try executeTransaction(session, fixture.env, null, transfer(0), &refused),
    );
    try testing.expectEqual(pending_result, systemCall(session, fixture.env, .{
        .sender = fixture.system_sender,
        .recipient = fixture.contract,
        .input = &.{},
        .gas_limit = fixture.gas_limit,
        .state_gas = 0,
    }, &refused));
    try testing.expectEqual(pending_result, evmz_session_reset(session));
    try testing.expect(refused == null);
    try testing.expectEqual(ok, evmz_session_discard(session));

    // The discard rolled the nonce back: the same transaction runs again and
    // charges the same.
    const second = try executeAccepted(&host, session, fixture.env, transfer(0));
    defer evmz_result_destroy(second);
    try testing.expectEqual(dataOf(first.?).gas.used, dataOf(second).gas.used);

    // Accepted, so the session now holds nonce 1 and nonce 0 is stale.
    var stale: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &stale));
    defer evmz_result_destroy(stale);
    const rejected = dataOf(stale.?);
    try expectCode(c.EVMZ_OUTCOME_REJECTED, rejected.outcome);
    try expectCode(c.EVMZ_REJECTION_NONCE_TOO_LOW, rejected.rejection);
    try testing.expectEqual(0, rejected.accounts_len);
    // A rejection is not pending.
    try testing.expectEqual(no_pending_result, evmz_session_accept(session));

    const third = try executeAccepted(&host, session, fixture.env, transfer(1));
    defer evmz_result_destroy(third);
    try testing.expectEqual(14, host.memory.getAccount(fixture.recipient).?.account.balance);
    try testing.expectEqual(7, word(accountRow(dataOf(third), fixture.recipient).?.original.balance));
}

test "destroying a session discards its pending result" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    const session = try host.createSession(fixture.fork);

    var out: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &out));
    defer evmz_result_destroy(out);
    evmz_session_destroy(session);
    try expectCode(c.EVMZ_EXECUTION_SUCCESS, dataOf(out.?).status);
}

test "a rejected transaction changes nothing" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 6 });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    var out: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &out));
    defer evmz_result_destroy(out);
    const data = dataOf(out.?);
    try expectCode(c.EVMZ_OUTCOME_REJECTED, data.outcome);
    try expectCode(c.EVMZ_REJECTION_INSUFFICIENT_ACCOUNT_FUNDS, data.rejection);
    try testing.expectEqual(0, data.accounts_len);
    try testing.expectEqual(0, data.gas.used);
    try testing.expectEqual(no_pending_result, evmz_session_discard(session));
}

test "block progress counts against the block gas limit" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    const full: c.evmz_block_progress = .{
        .receipt_gas_used = fixture.env.gas_limit,
        .block_gas = .{
            .total = fixture.env.gas_limit,
            .regular = fixture.env.gas_limit,
            .state = 0,
        },
    };
    var out: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, &full, transfer(0), &out));
    defer evmz_result_destroy(out);
    try expectCode(c.EVMZ_OUTCOME_REJECTED, dataOf(out.?).outcome);
    try expectCode(c.EVMZ_REJECTION_GAS_ALLOWANCE_EXCEEDED, dataOf(out.?).rejection);

    // The same transaction fits an empty block.
    const result = try executeAccepted(&host, session, fixture.env, transfer(0));
    defer evmz_result_destroy(result);

    // Progress summed from that result, as the header tells the host to, leaves
    // room for the next transaction.
    const gas = dataOf(result).gas;
    const one: c.evmz_block_progress = .{ .receipt_gas_used = gas.used, .block_gas = gas.block };
    var next: ?*c.evmz_result = null;
    try testing.expectEqual(
        ok,
        try executeTransaction(session, fixture.env, &one, transfer(1), &next),
    );
    defer evmz_result_destroy(next);
    try expectCode(c.EVMZ_OUTCOME_EXECUTED, dataOf(next.?).outcome);
}

test "a create reports its code and wipes storage the host still holds" {
    const runtime = evmz.t.bytecode(.{ .PUSH0, .STOP });
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 0x2a,                                              .PUSH0, .SSTORE,
        .PUSH1, @as(comptime_int, @backingInt(evmz.Opcode.PUSH0)), .PUSH0, .MSTORE8,
        .PUSH1, @as(comptime_int, runtime.len),                    .PUSH0, .RETURN,
    });
    const created = evmz.address.create(fixture.sender, 0);

    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    // Storage with no account in front of it. The engine cannot see it, since
    // a reader answers one slot at a time, so only the wipe removes it.
    try (try host.memory.getOrCreateAccount(created)).storage.put(5, 9);

    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);
    const result = try executeAccepted(&host, session, fixture.env, .{
        .sender = fixture.sender,
        .input = &init_code,
        .gas_limit = fixture.gas_limit,
    });
    defer evmz_result_destroy(result);
    const data = dataOf(result);

    try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
    try testing.expectEqual(1, data.has_created_address);
    try testing.expect(address(data.created_address).eql(created));

    const row = accountRow(data, created).?;
    try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_CREATED_CONTRACT));
    try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_CODE_WRITTEN));
    // Listed as a wipe because it was created, not because it self-destructed.
    try testing.expect(listsWipe(data, created));
    try testing.expect(!hasEffect(row, c.EVMZ_ACCOUNT_STORAGE_WIPED));

    const code_hash = crypto.keccak256(&runtime);
    try testing.expectEqualSlices(u8, &code_hash, &row.current.code_hash.bytes);
    try testing.expectEqual(1, data.code_changes_len);
    const code = codeChange(data, code_hash).?;
    try testing.expectEqualSlices(u8, &runtime, span(u8, code.code, code.code_len));

    try testing.expectEqual(0x2a, word(storageRow(data, created, 0).?.current));
    try testing.expect(storageRow(data, created, 5) == null);
    const stored = host.memory.getAccount(created).?;
    try testing.expectEqual(1, stored.storage.count());
    try testing.expectEqualSlices(u8, &runtime, stored.code);
}

test "a contract that self-destructs in its creating transaction leaves no account" {
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 1,    .PUSH0, .SSTORE,
        .PUSH2, 0xbb, 0xbb,   .SELFDESTRUCT,
    });
    const created = evmz.address.create(fixture.sender, 0);

    // With and without ether already sitting at the address to be created.
    for ([_]u256{ 0, 5 }) |prefund| {
        var host: TestHost = .init();
        defer host.deinit();
        try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
        if (prefund != 0)
            try evmz.t.seedStoreAccount(&host.memory, created, .{ .balance = prefund });

        const session = try host.createSession(fixture.fork);
        defer evmz_session_destroy(session);
        const result = try executeAccepted(&host, session, fixture.env, .{
            .sender = fixture.sender,
            .value = 3,
            .input = &init_code,
            .gas_limit = fixture.gas_limit,
        });
        defer evmz_result_destroy(result);
        const data = dataOf(result);

        try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
        try expectCode(c.EVMZ_HALT_SELFDESTRUCT, data.halt);

        const row = accountRow(data, created).?;
        try testing.expectEqual(@intFromBool(prefund != 0), row.original.exists);
        try testing.expectEqual(prefund, word(row.original.balance));
        try testing.expectEqual(0, row.current.exists);
        try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_SELFDESTRUCT));
        try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_CREATED_CONTRACT));
        try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_STORAGE_WIPED));

        try testing.expect(listsWipe(data, created));
        try testing.expect(storageRow(data, created, 0) == null);
        try testing.expectEqual(0, data.code_changes_len);
        try testing.expectEqual(
            prefund + 3,
            word(accountRow(data, fixture.recipient).?.current.balance),
        );
        try testing.expect(host.memory.getAccount(created) == null);
    }
}

test "BLOCKHASH asks the host only for numbers inside the window" {
    const env: Env = .{ .gas_limit = fixture.env.gas_limit, .number = 1000 };
    const tx: Transaction = .{
        .sender = fixture.sender,
        .to = fixture.contract,
        .gas_limit = fixture.gas_limit,
    };

    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    // slot 0 = BLOCKHASH(999), slot 1 = BLOCKHASH(5): the second is 995 blocks back.
    try evmz.t.seedStoreAccount(&host.memory, fixture.contract, .{ .code = &evmz.t.bytecode(.{
        .PUSH2, 0x03, 0xe7,       .BLOCKHASH, .PUSH0, .SSTORE,
        .PUSH1, 5,    .BLOCKHASH, .PUSH1,     1,      .SSTORE,
        .STOP,
    }) });

    {
        // A host without the callback has no hashes at all.
        var callbacks = host.host();
        callbacks.get_block_hash = null;
        var session: ?*c.evmz_session = null;
        try testing.expectEqual(ok, evmz_session_create(fixture.fork, &callbacks, &session));
        defer evmz_session_destroy(session);
        var out: ?*c.evmz_result = null;
        try testing.expectEqual(ok, try executeTransaction(session, env, null, tx, &out));
        defer evmz_result_destroy(out);
        try expectCode(c.EVMZ_EXECUTION_SUCCESS, dataOf(out.?).status);
        if (storageRow(dataOf(out.?), fixture.contract, 0)) |slot|
            try testing.expectEqual(0, word(slot.current));
    }

    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);
    const result = try executeAccepted(&host, session, env, tx);
    defer evmz_result_destroy(result);
    try testing.expectEqual(
        TestHost.blockHash(999),
        word(storageRow(dataOf(result), fixture.contract, 0).?.current),
    );
    try testing.expectEqual(0, host.memory.getAccount(fixture.contract).?.getStorage(1));
    try testing.expectEqualSlices(u64, &.{999}, host.block_hash_requests.items);
}

test "access lists and authorizations reach the engine" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{
        .balance = 1_000_000_000_000,
    });
    const target = evmz.addr(0xdddd);
    const authority = evmz.addr(0xeeee);
    try evmz.t.seedStoreAccount(&host.memory, target, .{ .code = &evmz.t.bytecode(.{.STOP}) });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    // `executeAccepted` holds each run to the gas the engine charges for the
    // same transaction, so a list lost in conversion shows up as a difference.
    const keys = [_]u256{ 1, 2 };
    const access_list = [_]evmz.transaction.AccessListEntry{
        .{ .address = fixture.contract, .storage_keys = &keys },
    };
    const plain = try executeAccepted(&host, session, fixture.env, .{
        .kind = .access_list,
        .sender = fixture.sender,
        .to = evmz.addr(0xb1),
        .value = 1,
        .gas_limit = fixture.gas_limit,
    });
    defer evmz_result_destroy(plain);
    const listed = try executeAccepted(&host, session, fixture.env, .{
        .kind = .access_list,
        .sender = fixture.sender,
        .to = evmz.addr(0xb2),
        .value = 1,
        .gas_limit = fixture.gas_limit,
        .access_list = &access_list,
    });
    defer evmz_result_destroy(listed);
    try testing.expect(dataOf(listed).gas.used > dataOf(plain).gas.used);

    const authorizations = [_]evmz.transaction.RecoveredAuthorization{
        evmz.t.testAuthorization(authority, target),
    };
    const delegated = try executeAccepted(&host, session, fixture.env, .{
        .kind = .set_code,
        .sender = fixture.sender,
        .to = authority,
        .gas_limit = fixture.gas_limit,
        .max_fee_per_gas = 1,
        .max_priority_fee_per_gas = 0,
        .authorization_list = &authorizations,
        // One more tuple was signed and dropped at recovery.
        .authorization_count = 2,
    });
    defer evmz_result_destroy(delegated);
    const data = dataOf(delegated);
    try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);

    const designation = [_]u8{ 0xef, 0x01, 0x00 } ++ target.bytes;
    const row = accountRow(data, authority).?;
    try testing.expectEqual(1, row.current.nonce);
    try testing.expect(hasEffect(row, c.EVMZ_ACCOUNT_CODE_WRITTEN));
    const code = codeChange(data, row.current.code_hash.bytes).?;
    try testing.expectEqualSlices(u8, &designation, span(u8, code.code, code.code_len));
}

test "a system call is accepted at once and seen by the next execute" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    // slot 0 = CALLER, then return the first calldata word.
    try evmz.t.seedStoreAccount(&host.memory, fixture.contract, .{ .code = &evmz.t.bytecode(.{
        .CALLER, .PUSH0,        .SSTORE,
        .PUSH0,  .CALLDATALOAD, .PUSH0,
        .MSTORE, .PUSH1,        0x20,
        .PUSH0,  .RETURN,
    }) });
    const reverting = evmz.addr(0xdddd);
    try evmz.t.seedStoreAccount(&host.memory, reverting, .{ .code = &evmz.t.bytecode(.{
        .PUSH1, 1,    .PUSH0, .SSTORE,
        .PUSH1, 0xab, .PUSH0, .MSTORE8,
        .PUSH1, 1,    .PUSH0, .REVERT,
    }) });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    const input = uint256.toBytes32(0x2a);
    var call: SystemCall = .{
        .sender = fixture.system_sender,
        .recipient = evmz.addr(1),
        .input = &input,
        .gas_limit = 30_000_000,
        .state_gas = 0,
    };

    // ecrecover: a precompile has no bytecode frame for a system call to enter.
    var out: ?*c.evmz_result = null;
    try testing.expectEqual(invalid_argument, systemCall(session, fixture.env, call, &out));
    try testing.expect(out == null);

    call.recipient = fixture.contract;
    try testing.expectEqual(ok, systemCall(session, fixture.env, call, &out));
    defer evmz_result_destroy(out);
    const data = dataOf(out.?);
    try expectCode(c.EVMZ_OUTCOME_EXECUTED, data.outcome);
    try expectCode(c.EVMZ_EXECUTION_SUCCESS, data.status);
    try expectCode(c.EVMZ_HALT_RETURN, data.halt);
    try testing.expectEqualSlices(u8, &input, span(u8, data.output, data.output_len));
    try testing.expect(data.gas.used > 0 and data.gas.used < call.gas_limit);
    try testing.expectEqual(
        addressWord(fixture.system_sender),
        word(storageRow(data, fixture.contract, 0).?.current),
    );
    // Nothing to accept: the call already is.
    try testing.expectEqual(no_pending_result, evmz_session_accept(session));
    try host.apply(data);

    // A transaction now runs on top of the call. Its `original` is the value
    // the call left, and the host that applied the call agrees on the root.
    const next = try executeAccepted(&host, session, fixture.env, .{
        .sender = fixture.sender,
        .to = fixture.contract,
        .gas_limit = fixture.gas_limit,
    });
    defer evmz_result_destroy(next);
    const slot = storageRow(dataOf(next), fixture.contract, 0).?;
    try testing.expectEqual(addressWord(fixture.system_sender), word(slot.original));
    try testing.expectEqual(addressWord(fixture.sender), word(slot.current));

    // A failed call reports how it failed and leaves the state alone.
    const root = try host.memory.stateRoot(testing.allocator);
    call.recipient = reverting;
    var failed: ?*c.evmz_result = null;
    try testing.expectEqual(ok, systemCall(session, fixture.env, call, &failed));
    defer evmz_result_destroy(failed);
    const failure = dataOf(failed.?);
    try expectCode(c.EVMZ_EXECUTION_REVERT, failure.status);
    try expectCode(c.EVMZ_HALT_REVERT, failure.halt);
    try testing.expectEqualSlices(u8, &.{0xab}, span(u8, failure.output, failure.output_len));
    try testing.expectEqual(0, failure.storage_len);
    try host.apply(failure);
    try testing.expectEqualSlices(u8, &root, &try host.memory.stateRoot(testing.allocator));
}

test "reset drops what the session read, so the host is read again" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);

    // Accepted in the session, never applied to the host.
    var accepted: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(0), &accepted));
    defer evmz_result_destroy(accepted);
    try testing.expectEqual(ok, evmz_session_accept(session));

    // The host moves the sender on behind the session's back.
    host.memory.getAccount(fixture.sender).?.account.nonce = 5;
    var early: ?*c.evmz_result = null;
    try testing.expectEqual(ok, try executeTransaction(session, fixture.env, null, transfer(5), &early));
    defer evmz_result_destroy(early);
    try expectCode(c.EVMZ_REJECTION_NONCE_TOO_HIGH, dataOf(early.?).rejection);

    try testing.expectEqual(ok, evmz_session_reset(session));
    const result = try executeAccepted(&host, session, fixture.env, transfer(5));
    defer evmz_result_destroy(result);
    // The accepted transfer went with the overlay: this is the first 7 to land.
    try testing.expectEqual(0, accountRow(dataOf(result), fixture.recipient).?.original.exists);
    try testing.expectEqual(7, host.memory.getAccount(fixture.recipient).?.account.balance);
}

test "a failing host aborts the execute and leaves the session usable" {
    const env: Env = .{ .gas_limit = fixture.env.gas_limit, .number = 100 };
    const tx: Transaction = .{
        .sender = fixture.sender,
        .to = fixture.contract,
        .nonce = 0,
        .gas_limit = fixture.gas_limit,
    };

    for (std.enums.values(TestHost.Failure)) |failure| {
        if (failure == .none) continue;
        var host: TestHost = .init();
        defer host.deinit();
        try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });
        // One read through each callback.
        try evmz.t.seedStoreAccount(&host.memory, fixture.contract, .{
            .code = &evmz.t.bytecode(.{
                .PUSH0, .SLOAD,  .POP,
                .PUSH1, 99,      .BLOCKHASH,
                .PUSH0, .SSTORE, .STOP,
            }),
        });
        const session = try host.createSession(fixture.fork);
        defer evmz_session_destroy(session);

        host.fail = failure;
        var out: ?*c.evmz_result = null;
        try testing.expectEqual(host_failure, try executeTransaction(session, env, null, tx, &out));
        try testing.expect(out == null);
        try testing.expectEqual(no_pending_result, evmz_session_accept(session));

        host.fail = .none;
        const result = try executeAccepted(&host, session, env, tx);
        defer evmz_result_destroy(result);
        try testing.expectEqual(
            TestHost.blockHash(99),
            host.memory.getAccount(fixture.contract).?.getStorage(0),
        );
        // The sink died with the `load_code` call it was passed to.
        try testing.expectEqual(invalid_argument, evmz_code_sink_set(host.last_sink, null, 0));
    }
}

test "malformed arguments are refused and change nothing" {
    var host: TestHost = .init();
    defer host.deinit();
    try evmz.t.seedStoreAccount(&host.memory, fixture.sender, .{ .balance = 1_000_000 });

    var created: ?*c.evmz_session = null;
    try testing.expectEqual(invalid_argument, evmz_session_create(fixture.fork, null, &created));
    try testing.expectEqual(
        invalid_argument,
        evmz_session_create(fixture.fork, &host.host(), null),
    );
    var callbacks = host.host();
    callbacks.struct_size -= 1;
    try testing.expectEqual(
        invalid_argument,
        evmz_session_create(fixture.fork, &callbacks, &created),
    );
    callbacks = host.host();
    callbacks.load_code = null;
    try testing.expectEqual(
        invalid_argument,
        evmz_session_create(fixture.fork, &callbacks, &created),
    );
    try testing.expect(created == null);

    evmz_session_destroy(null);
    evmz_result_destroy(null);
    try testing.expect(evmz_result_get_data(null) == null);
    try testing.expectEqual(invalid_argument, evmz_session_accept(null));
    try testing.expectEqual(invalid_argument, evmz_session_discard(null));
    try testing.expectEqual(invalid_argument, evmz_session_reset(null));
    try testing.expectEqual(invalid_argument, evmz_code_sink_set(null, null, 0));

    const session = try host.createSession(fixture.fork);
    defer evmz_session_destroy(session);
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const env = cEnv(fixture.env);
    const good = try cTransaction(arena.allocator(), transfer(0));
    var out: ?*c.evmz_result = null;

    try testing.expectEqual(invalid_argument, evmz_session_execute(null, &env, null, &good, &out));
    try testing.expectEqual(
        invalid_argument,
        evmz_session_execute(session, null, null, &good, &out),
    );
    try testing.expectEqual(invalid_argument, evmz_session_execute(session, &env, null, null, &out));
    try testing.expectEqual(
        invalid_argument,
        evmz_session_execute(session, &env, null, &good, null),
    );
    try testing.expectEqual(
        invalid_argument,
        evmz_session_execute_system_call(session, &env, null, &out),
    );

    var bad_env = env;
    bad_env.has_blob_params = 2;
    try testing.expectEqual(
        invalid_argument,
        evmz_session_execute(session, &bad_env, null, &good, &out),
    );

    const two_authorizations: [2]c.evmz_recovered_authorization =
        @splat(std.mem.zeroes(c.evmz_recovered_authorization));
    var malformed: [6]c.evmz_transaction = @splat(good);
    malformed[0].kind = 99;
    malformed[1].has_to = 2;
    malformed[2].input = null;
    malformed[2].input_len = 1;
    malformed[3].access_list = null;
    malformed[3].access_list_len = 1;
    malformed[4].has_max_fee_per_gas = 0xff;
    // Fewer tuples signed than recovered.
    malformed[5].authorization_list = &two_authorizations;
    malformed[5].authorization_list_len = two_authorizations.len;
    malformed[5].has_authorization_count = 1;
    malformed[5].authorization_count = 1;
    for (&malformed) |*tx| {
        try testing.expectEqual(
            invalid_argument,
            evmz_session_execute(session, &env, null, tx, &out),
        );
        try testing.expect(out == null);
    }

    // None of it consumed the nonce or left a result pending.
    const result = try executeAccepted(&host, session, fixture.env, transfer(0));
    defer evmz_result_destroy(result);
}
