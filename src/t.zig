//! evmz test helper for testing EVM execution.

const std = @import("std");
const evmz = @import("./evm.zig");

const Host = evmz.Host;
const ExecutionContext = evmz.execution.ExecutionContext;
const addr = evmz.addr;
const Address = evmz.Address;
const AddressWord = evmz.AddressWord;

/// Fork revisions this test build compiles exact VMs for, resolved from the
/// `test_forks` preset in build options: `head` = latest, `dev` = the local
/// default workhorse set, `all` = every revision. Options without the field
/// (production module, sibling consumers) enable everything.
pub const enabled_revisions: []const evmz.eth.Revision = resolveEnabledRevisions();

fn resolveEnabledRevisions() []const evmz.eth.Revision {
    const Revision = evmz.eth.Revision;
    const options = @import("build_options");
    if (!@hasDecl(options, "test_forks")) return std.enums.values(Revision);
    const preset = options.test_forks;
    if (std.mem.eql(u8, preset, "all")) return std.enums.values(Revision);
    if (std.mem.eql(u8, preset, "head")) return &.{Revision.latest};
    // prague stays in `dev`: it is the pre-BAL boundary and the fork most
    // amsterdam-lane tests compare against.
    if (std.mem.eql(u8, preset, "dev")) return &.{ .cancun, .prague, Revision.stable, Revision.latest };
    @compileError("unknown test_forks preset '" ++ preset ++ "'");
}

/// Whether this test build compiles the exact VM for `revision`.
///
/// Prefer the fused constructors below; use this directly only when a test
/// needs a gate without constructing an engine. The condition must stay
/// comptime-known: a comptime-true return prunes the rest of the body from
/// analysis and codegen while still reporting SKIP at runtime.
pub fn forkEnabled(comptime revision: evmz.eth.Revision) bool {
    return comptime std.mem.findScalar(evmz.eth.Revision, enabled_revisions, revision) != null;
}

/// Exact test engine for `revision`, or null when the `test_forks` preset
/// excludes it. The only sanctioned way for tests to build a fork engine:
/// `const Berlin = t.Vm(.berlin) orelse return error.SkipZigTest;`
/// The comptime-known null makes the unwrap prune everything after it, so a
/// disabled fork costs no analysis or codegen and still reports SKIP.
pub fn Vm(comptime revision: evmz.eth.Revision) ?type {
    if (comptime !forkEnabled(revision)) return null;
    return evmz.Vm(evmz.eth.specAt(revision));
}

/// Exact test engine with step capture compiled in, gated like `Vm`. Step
/// capture is opt-in (`CompileOptions.step_capture`): each capture engine
/// carries its own 256-handler traced dispatch table, so only tests that
/// read step tapes should pay for one:
/// `const Latest = t.CaptureVm(.latest) orelse return error.SkipZigTest;`
pub fn CaptureVm(comptime revision: evmz.eth.Revision) ?type {
    if (comptime !forkEnabled(revision)) return null;
    return evmz.VmWithOptions(evmz.eth.specAt(revision), .{ .step_capture = true });
}

/// Exact test engine for `specAt(base).extend(patch)`, gated on `base` like
/// `Vm`. Every distinct patch compiles its own full stack, so route custom
/// specs through here to keep that cost visible and gateable:
/// `const Tiny = t.CustomVm(.shanghai, .{ ... }) orelse return error.SkipZigTest;`
pub fn CustomVm(comptime base: evmz.eth.Revision, comptime patch: evmz.eth.Spec.Patch) ?type {
    if (comptime !forkEnabled(base)) return null;
    return evmz.Vm(evmz.eth.specAt(base).extend(patch));
}

/// Exact block-STF namespace for `revision`, gated like `Vm`:
/// `const Stf = t.BlockStf(.frontier) orelse return error.SkipZigTest;`
pub fn BlockStf(comptime revision: evmz.eth.Revision) ?type {
    if (comptime !forkEnabled(revision)) return null;
    return evmz.eth.block_stf.Exact(revision);
}

/// Block-STF namespace over a step-capture engine, gated like `BlockStf`.
/// Same cost warning as `CaptureVm`: one traced dispatch table per engine.
pub fn CaptureBlockStf(comptime revision: evmz.eth.Revision) ?type {
    if (comptime !forkEnabled(revision)) return null;
    return evmz.eth.block_stf.Bind(
        revision,
        evmz.VmWithOptions(evmz.eth.specAt(revision), .{ .step_capture = true }),
    );
}

/// Decode a comptime hex string literal into a fixed-size byte array.
pub fn hexBytes(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    if (hex.len % 2 != 0) @compileError("hex literal must contain an even number of characters");
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}

/// Assert that `actual` equals the bytes decoded from a comptime hex literal.
pub fn expectHex(actual: []const u8, comptime expected_hex: []const u8) !void {
    const expected = hexBytes(expected_hex);
    try std.testing.expectEqualSlices(u8, &expected, actual);
}

pub fn bytecode(comptime items: anytype) [bytecodeLen(items)]u8 {
    if (@typeInfo(@TypeOf(items)) == .pointer) {
        return bytecode(items.*);
    }

    var bytes: [bytecodeLen(items)]u8 = undefined;
    inline for (items, 0..) |item, i| {
        bytes[i] = bytecodeByte(item);
    }
    return bytes;
}

fn bytecodeLen(comptime items: anytype) comptime_int {
    const T = @TypeOf(items);
    return switch (@typeInfo(T)) {
        .pointer => |pointer| switch (@typeInfo(pointer.child)) {
            .array => |array| array.len,
            .@"struct" => |info| blk: {
                if (!info.is_tuple) @compileError("bytecode pointer items must point to an array or tuple literal");
                break :blk info.fields.len;
            },
            else => @compileError("bytecode pointer items must point to an array or tuple literal"),
        },
        .array => |array| array.len,
        .@"struct" => |info| blk: {
            if (!info.is_tuple) @compileError("bytecode struct items must be a tuple literal");
            break :blk info.fields.len;
        },
        else => @compileError("bytecode items must be an array, pointer to array, or tuple literal"),
    };
}

fn bytecodeByte(comptime item: anytype) u8 {
    const T = @TypeOf(item);
    return switch (@typeInfo(T)) {
        .enum_literal => blk: {
            const opcode: evmz.Opcode = item;
            break :blk opcode.toByte();
        },
        .@"enum" => blk: {
            if (T != evmz.Opcode) @compileError("bytecode enum items must be evmz.Opcode");
            break :blk item.toByte();
        },
        .comptime_int => blk: {
            if (item < 0 or item > std.math.maxInt(u8)) @compileError("bytecode integer items must fit in u8");
            break :blk @intCast(item);
        },
        .int => std.math.cast(u8, item) orelse @compileError("bytecode integer items must fit in u8"),
        else => @compileError("bytecode items must be opcode tags or u8 bytes"),
    };
}

pub const MockHost = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    store: std.AutoHashMap(u256, u256),
    logs: std.ArrayList(Host.Log),
    execution_context: ExecutionContext,
    original_store: std.AutoHashMap(u256, u256),
    code: Address.HashMap([]u8),
    local_account: Address.HashMap(Host.Account),
    removed_account: Address.HashMap(bool),
    storage_reads: u64,
    access_storage_reads: u64,
    storage_loads: u64,
    storage_stores: u64,
    block_hash_reads: u64,
    last_block_hash_number: ?u256,
    call_error: ?anyerror,

    pub fn init(alloc: std.mem.Allocator, execution_context: ?ExecutionContext) Self {
        return Self{
            .alloc = alloc,
            .store = std.AutoHashMap(u256, u256).init(alloc),
            .logs = .empty,
            .original_store = std.AutoHashMap(u256, u256).init(alloc),
            .local_account = Address.HashMap(Host.Account).init(alloc),
            .removed_account = Address.HashMap(bool).init(alloc),
            .code = Address.HashMap([]u8).init(alloc),
            .storage_reads = 0,
            .access_storage_reads = 0,
            .storage_loads = 0,
            .storage_stores = 0,
            .block_hash_reads = 0,
            .last_block_hash_number = null,
            .call_error = null,
            .execution_context = if (execution_context) |ctx| ctx else ExecutionContext{
                .chain = .{ .chain_id = 0 },
                .transaction = .{ .origin = addr(0) },
            },
        };
    }

    pub fn deinit(self: *Self) void {
        self.store.deinit();
        self.original_store.deinit();
        for (self.logs.items) |event_log| {
            self.alloc.free(event_log.topics);
            self.alloc.free(event_log.data);
        }
        self.logs.deinit(self.alloc);
        self.local_account.deinit();
        self.removed_account.deinit();
        self.code.deinit();
    }

    pub fn seedStorage(self: *Self, key: u256, value: u256) !void {
        if (value == 0) {
            _ = self.store.remove(key);
        } else {
            try self.store.put(key, value);
        }
        try self.original_store.put(key, value);
    }

    pub fn storageValue(self: *Self, key: u256) u256 {
        return self.store.get(key) orelse 0;
    }

    fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const topics_copy = try self.alloc.dupe(u256, topics);
        errdefer self.alloc.free(topics_copy);
        const data_copy = try self.alloc.dupe(u8, data);
        errdefer self.alloc.free(data_copy);
        try self.logs.append(self.alloc, .{
            .address = address,
            .topics = topics_copy,
            .data = data_copy,
        });
    }

    fn setStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !evmz.execution.StorageStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        const original_entry = try self.original_store.getOrPut(key);
        if (!original_entry.found_existing) {
            original_entry.value_ptr.* = self.storageValue(key);
        }
        const status = evmz.state.storageStatus(original_entry.value_ptr.*, self.storageValue(key), value);
        if (value == 0) {
            _ = self.store.remove(key);
        } else {
            try self.store.put(key, value);
        }
        return status;
    }

    fn getStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        self.storage_reads += 1;
        return self.store.get(key) orelse 0;
    }

    fn loadStorage(ptr: *anyopaque, address: AddressWord, key: u256) !Host.StorageLoadResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        self.storage_loads += 1;
        return .{
            .access_status = if (self.store.contains(key)) .warm else .cold,
            .value = self.store.get(key) orelse 0,
        };
    }

    fn storeStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !Host.StorageStoreResult {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.storage_stores += 1;
        const access_status: evmz.execution.AccessStatus = if (self.store.contains(key)) .warm else .cold;
        return .{
            .access_status = access_status,
            .storage_status = try setStorage(ptr, address, key, value),
        };
    }

    fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        self.block_hash_reads += 1;
        self.last_block_hash_number = number;
        return 1;
    }

    fn getCodeBuf(self: Self, address: Address, out: []u8) ![]u8 {
        const removed = self.removed_account.get(address);

        if (removed) |_| {
            return &.{};
        }

        const local = self.code.get(address);

        if (local) |code| {
            @memcpy(out, code);
            return code;
        }

        return &.{};
    }

    pub fn copyCode(ptr: *anyopaque, address_word: AddressWord, code_offset: usize, buffer_data: []u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();

        if (self.removed_account.get(address)) |_| {
            return 0;
        }

        const local = self.code.get(address);

        if (local) |code| {
            if (code_offset >= code.len) return 0;
            const copied = @min(buffer_data.len, code.len - code_offset);
            @memcpy(buffer_data[0..copied], code[code_offset..][0..copied]);

            return copied;
        }

        return 0;
    }

    fn getBalance(ptr: *anyopaque, address_word: AddressWord) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();

        const local = self.local_account.get(address);

        if (local) |account| {
            return account.balance;
        }

        return 0;
    }

    fn getNonce(ptr: *anyopaque, address_word: AddressWord) !u64 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();
        return if (self.local_account.get(address)) |account| account.nonce else 0;
    }

    fn getCodeSize(ptr: *anyopaque, address_word: AddressWord) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var buf: [1024]u8 = undefined;
        const code = try self.getCodeBuf(address_word.address(), &buf);
        return code.len;
    }

    fn getCodeHash(ptr: *anyopaque, address_word: AddressWord) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();
        var buf: [1024]u8 = undefined;
        const a = @This();

        const exist = try a.accountExists(self, address_word);

        if (!exist) {
            return 0;
        }

        const code = try self.getCodeBuf(address, &buf);

        if (code.len == 0) {
            return evmz.uint256.fromBytes32(&evmz.crypto.keccak256_empty);
        }
        const result = evmz.crypto.keccak256(code);
        const final_result = evmz.uint256.fromBytes32(&result);

        return final_result;
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const a = @This();

        const should_refund = !self.removed_account.contains(address);
        const destrucing_balance = try a.getBalance(self, .fromAddress(address));
        const recipient_balance = try a.getBalance(self, .fromAddress(beneficiary));

        try self.local_account.put(address, .{
            .balance = 0,
        });

        try self.local_account.put(beneficiary, .{
            .balance = destrucing_balance + recipient_balance,
        });

        _ = self.local_account.remove(address);
        _ = try self.removed_account.put(address, true);

        return should_refund;
    }

    fn accessAccount(ptr: *anyopaque, address_word: AddressWord) !evmz.execution.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();
        const local = self.local_account.get(address);
        if (local) |_| {
            return .warm;
        }
        return .cold;
    }

    fn accessStorage(ptr: *anyopaque, address: AddressWord, key: u256) !evmz.execution.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        self.access_storage_reads += 1;
        const local = self.store.get(key);
        if (local) |_| {
            return .warm;
        }
        return .cold;
    }

    fn accessDelegatedAccount(ptr: *anyopaque, address: AddressWord) !?evmz.execution.AccessStatus {
        _ = ptr;
        _ = address;
        return null;
    }

    fn accountExists(ptr: *anyopaque, address_word: AddressWord) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const address = address_word.address();
        const local = self.local_account.get(address);
        if (local) |_| {
            return true;
        }

        return false;
    }

    fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
        if (Host.precheckResult(msg)) |result| return result;
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.call_error) |err| return err;
        return Host.Result.fromCall(.{
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = &.{},
            .outcome = .{ .status = .success, .cause = .none },
        });
    }

    fn getTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = address;
        _ = key;
        return 1;
    }

    fn setTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = address;
        _ = key;
        _ = value;
    }

    pub fn host(self: *Self) Host {
        return Host{ .ptr = self, .vtable = &.{
            .call = call,
            .accountExists = accountExists,
            .getBalance = getBalance,
            .getNonce = getNonce,
            .copyCode = copyCode,
            .getCodeSize = getCodeSize,
            .getCodeHash = getCodeHash,
            .getStorage = getStorage,
            .setStorage = setStorage,
            .loadStorage = loadStorage,
            .storeStorage = storeStorage,
            .emitLog = emitLog,
            .getBlockHash = getBlockHash,
            .executionContext = executionContext,
            .selfDestruct = selfDestruct,
            .accessStorage = accessStorage,
            .accessDelegatedAccount = accessDelegatedAccount,
            .accessAccount = accessAccount,
            .getTransientStorage = getTransientStorage,
            .setTransientStorage = setTransientStorage,
        } };
    }

    fn executionContext(ptr: *anyopaque) ?*const ExecutionContext {
        const self: *Self = @ptrCast(@alignCast(ptr));
        return &self.execution_context;
    }
};

pub fn defaultMessage() Host.Message {
    return .{
        .depth = 0,
        .sender = addr(0),
        .gas = 100_000,
        .kind = Host.CallKind.call,
        .recipient = addr(0),
        .value = 0,
        .input_data = &.{},
    };
}

pub fn defaultExecutionContext(origin: Address, gas_limit: u64) ExecutionContext {
    return .{
        .chain = .{ .chain_id = 1 },
        .block = .{ .gas_limit = gas_limit },
        .transaction = .{ .origin = origin },
    };
}

pub const MemoryAccountSeed = struct {
    nonce: u64 = 0,
    balance: u256 = 0,
    code: []const u8 = &.{},
};

pub fn seedExecutorAccount(executor: anytype, address: Address, seed: MemoryAccountSeed) !void {
    var account = evmz.state.MemoryAccount.init(executor.allocator);
    account.account.nonce = seed.nonce;
    account.account.balance = seed.balance;
    if (seed.code.len != 0) {
        account.setCode(seed.code) catch |err| {
            account.deinit();
            return err;
        };
    }
    return executor.state.seedAccount(address, account);
}

pub fn seedStoreAccount(store: anytype, address: Address, seed: MemoryAccountSeed) !void {
    var account = try store.getOrCreateAccount(address);
    account.account.nonce = seed.nonce;
    account.account.balance = seed.balance;
    if (seed.code.len != 0) try account.setCode(seed.code);
}

pub fn expectExecuted(outcome: evmz.Evm.Outcome) !evmz.Evm.Executed {
    return switch (outcome) {
        .executed => |executed| executed,
        .rejected => error.UnexpectedRejection,
    };
}

pub fn testAuthorization(signer: Address, target: Address) evmz.transaction.AuthorizationTuple {
    return .{
        .chain_id = 0,
        .target = target,
        .signer = signer,
        .nonce = 0,
        .y_parity = 0,
        .legacy_v = null,
        .r = 1,
        .s = 1,
    };
}

pub fn CaptureFixture(comptime ExecutorType: type) type {
    return struct {
        const Self = @This();

        executor: *ExecutorType = undefined,
        context: evmz.executor.CaptureContext = undefined,
        open: bool = false,
        bound: bool = false,

        pub fn init(
            self: *Self,
            executor: *ExecutorType,
            state_target: ?evmz.executor.CaptureStateTarget,
        ) !void {
            self.* = .{
                .executor = executor,
                .context = evmz.executor.CaptureContext.init(executor.allocator, null, state_target),
            };
            executor.setCaptureContext(&self.context);
            self.bound = true;
            errdefer {
                executor.setCaptureContext(null);
                self.bound = false;
                self.context.deinit();
            }
            try self.context.begin();
            self.open = true;
        }

        pub fn finish(self: *Self) !void {
            _ = try self.context.finish();
            self.open = false;
            self.executor.setCaptureContext(null);
            self.bound = false;
        }

        pub fn deinit(self: *Self) void {
            if (self.open) {
                self.context.abort() catch |err| @panic(@errorName(err));
                self.open = false;
            }
            if (self.bound) self.executor.setCaptureContext(null);
            self.context.deinit();
            self.* = undefined;
        }
    };
}

pub const BytecodeResult = struct {
    status: evmz.Interpreter.Status,
    gas_left: i64,
    gas_refund: i64,
    stack_top: ?u256,
};

pub fn runBytecodeWithHost(host: *Host, msg: *const Host.Message, code: []const u8, comptime revision: evmz.eth.Revision) !BytecodeResult {
    if (comptime !forkEnabled(revision)) return error.SkipZigTest;
    const Exact = evmz.Vm(evmz.eth.specAt(revision));
    var frame = try Exact.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = host,
        .msg = msg,
        .source = .{ .code = code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    return .{
        .status = result.status(),
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .stack_top = interpreter.call_frame.stack.peek(),
    };
}

pub fn expectBytecodeStatusByRevision(comptime items: anytype, comptime revision: evmz.eth.Revision, expected: evmz.Interpreter.Status) !void {
    const bytecode_bytes = bytecode(items);
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    const result = try runBytecodeWithHost(&host, &msg, &bytecode_bytes, revision);
    try std.testing.expectEqual(expected, result.status);
}

pub fn expectLatestForkBytecodeStatus(comptime items: anytype, expected: evmz.Interpreter.Status) !void {
    try expectBytecodeStatusByRevision(items, .latest, expected);
}

pub fn expectBytecodeStackTopByRevision(comptime items: anytype, comptime revision: evmz.eth.Revision, expected: u256) !void {
    const bytecode_bytes = bytecode(items);
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    const result = try runBytecodeWithHost(&host, &msg, &bytecode_bytes, revision);
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected, result.stack_top.?);
}

pub fn expectStackByRevision(code: []const u8, comptime revision: evmz.eth.Revision, expected: []const u256) !void {
    if (comptime !forkEnabled(revision)) return error.SkipZigTest;
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    const Exact = evmz.Vm(evmz.eth.specAt(revision));
    var frame = try Exact.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = code },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u256, expected, interpreter.call_frame.stack.asSlice());
}

pub fn expectLatestForkBytecodeStackTop(comptime items: anytype, expected: u256) !void {
    try expectBytecodeStackTopByRevision(items, .latest, expected);
}

test "mock host persists storage writes" {
    try expectBytecodeStackTopByRevision(.{ .PUSH1, 0x2a, .PUSH1, 0x00, .SSTORE, .PUSH1, 0x00, .SLOAD }, .osaka, 0x2a);
}

test "ORIGIN and GASPRICE read the borrowed transaction context" {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();
    try std.testing.expect((try host.executionContext()) == &mock_host.execution_context);

    var frame = try evmz.Evm.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &bytecode(.{ .ORIGIN, .GASPRICE }) },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u256, &.{ 0, 0 }, interpreter.call_frame.stack.asSlice());
}

test "missing execution context fails environment opcodes" {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const Missing = struct {
        fn missing(_: *anyopaque) ?*const ExecutionContext {
            return null;
        }
    };
    var missing_vtable = host.vtable.*;
    missing_vtable.executionContext = Missing.missing;
    host.vtable = &missing_vtable;
    const msg = defaultMessage();
    const code = bytecode(.{.ORIGIN});

    try std.testing.expectError(
        error.MissingExecutionContext,
        runBytecodeWithHost(&host, &msg, &code, .latest),
    );
}

test "host action errors propagate out of CALL execution" {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    mock_host.call_error = error.DatabaseUnavailable;
    var host = mock_host.host();
    const msg = defaultMessage();
    const code = bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH1, 0x01,   .PUSH2,
        0x27,   0x10,   .CALL,
    });

    try std.testing.expectError(
        error.DatabaseUnavailable,
        runBytecodeWithHost(&host, &msg, &code, .latest),
    );
}

test "SLOTNUM pushes the transaction context slot number" {
    var mock_host = MockHost.init(std.testing.allocator, .{
        .chain = .{ .chain_id = 0 },
        .block = .{
            .number = 1000,
            .slot_number = 0x123456789abcdef0,
        },
        .transaction = .{ .origin = addr(0) },
    });
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();
    const code = bytecode(.{.SLOTNUM});

    const result = try runBytecodeWithHost(&host, &msg, &code, .amsterdam);
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x123456789abcdef0), result.stack_top.?);
}

fn expectBlockhash(number: u16, expected: u256, expected_reads: u64) !void {
    var mock_host = MockHost.init(std.testing.allocator, .{
        .chain = .{ .chain_id = 0 },
        .block = .{ .number = 1000 },
        .transaction = .{ .origin = addr(0) },
    });
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();
    const code = [_]u8{
        evmz.Opcode.PUSH2.toByte(),
        @as(u8, @intCast(number >> 8)),
        @as(u8, @truncate(number)),
        evmz.Opcode.BLOCKHASH.toByte(),
    };

    const result = try runBytecodeWithHost(&host, &msg, &code, .latest);
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected, result.stack_top.?);
    try std.testing.expectEqual(expected_reads, mock_host.block_hash_reads);
    if (expected_reads > 0) {
        try std.testing.expectEqual(@as(u256, number), mock_host.last_block_hash_number.?);
    }
}

test "BLOCKHASH only queries host for the 256 most recent complete blocks" {
    try expectBlockhash(999, 1, 1);
    try expectBlockhash(744, 1, 1);
    try expectBlockhash(1000, 0, 0);
    try expectBlockhash(1001, 0, 0);
    try expectBlockhash(743, 0, 0);
}
