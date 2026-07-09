//! evmz test helper for testing EVM execution.

const std = @import("std");
const evmz = @import("./evm.zig");

const Host = evmz.Host;
const addr = evmz.addr;
const Address = evmz.Address;

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
    tx_context: Host.TxContext,
    tx_context_reads: u64,
    original_store: std.AutoHashMap(u256, u256),
    code: std.AutoHashMap(Address, []u8),
    local_account: std.AutoHashMap(Address, Host.Account),
    removed_account: std.AutoHashMap(Address, bool),
    storage_reads: u64,
    access_storage_reads: u64,
    block_hash_reads: u64,
    last_block_hash_number: ?u256,
    tx_context_error: ?anyerror,
    call_error: ?anyerror,

    pub fn init(alloc: std.mem.Allocator, tx_context: ?Host.TxContext) Self {
        return Self{
            .alloc = alloc,
            .store = std.AutoHashMap(u256, u256).init(alloc),
            .logs = .empty,
            .original_store = std.AutoHashMap(u256, u256).init(alloc),
            .local_account = std.AutoHashMap(Address, Host.Account).init(alloc),
            .removed_account = std.AutoHashMap(Address, bool).init(alloc),
            .code = std.AutoHashMap(Address, []u8).init(alloc),
            .tx_context_reads = 0,
            .storage_reads = 0,
            .access_storage_reads = 0,
            .block_hash_reads = 0,
            .last_block_hash_number = null,
            .tx_context_error = null,
            .call_error = null,
            .tx_context = if (tx_context) |ctx| ctx else Host.TxContext{
                .base_fee = 0,
                .gas_limit = 0,
                .gas_price = 0,
                .coinbase = addr(0),
                .origin = addr(0),
                .blob_base_fee = 0,
                .blob_hashes = &.{},
                .chain_id = 0,
                .number = 0,
                .prev_randao = 0,
                .timestamp = 0,
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

    fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
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

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        self.storage_reads += 1;
        return self.store.get(key) orelse 0;
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

    pub fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
        const self: *Self = @ptrCast(@alignCast(ptr));

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

    fn putCode(self: Self, address: Address, code: []u8) !void {
        try self.code.put(address, code);
    }

    fn putAccount(ptr: *anyopaque, address: Address, account: Host.Account) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.local_account.put(address, account);
    }

    fn getBalance(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const local = self.local_account.get(address);

        if (local) |account| {
            return account.balance;
        }

        return 0;
    }

    fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var buf: [1024]u8 = undefined;
        const code = try self.getCodeBuf(address, &buf);
        return code.len;
    }

    fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        var buf: [1024]u8 = undefined;
        const a = @This();

        const exist = try a.accountExists(self, address);

        if (!exist) {
            return 0;
        }

        const code = try self.getCodeBuf(address, &buf);

        if (code.len == 0) {
            return evmz.empty_code_hash;
        }
        const result = evmz.crypto.keccak256(code);
        const final_result = evmz.uint256.fromBytes32(&result);

        return final_result;
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const a = @This();

        const should_refund = !self.removed_account.contains(address);
        const destrucing_balance = try a.getBalance(self, address);
        const recipient_balance = try a.getBalance(self, beneficiary);

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

    fn accessAccount(ptr: *anyopaque, address: Address) !Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const local = self.local_account.get(address);
        if (local) |_| {
            return .warm;
        }
        return .cold;
    }

    fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !Host.AccessStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        self.access_storage_reads += 1;
        const local = self.store.get(key);
        if (local) |_| {
            return .warm;
        }
        return .cold;
    }

    fn accessDelegatedAccount(ptr: *anyopaque, address: Address) !?Host.AccessStatus {
        _ = ptr;
        _ = address;
        return null;
    }

    fn getTxContext(ptr: *anyopaque) !Host.TxContext {
        const self: *Self = @ptrCast(@alignCast(ptr));
        if (self.tx_context_error) |err| return err;
        self.tx_context_reads += 1;
        return self.tx_context;
    }

    fn accountExists(ptr: *anyopaque, address: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));
        const local = self.local_account.get(address);
        if (local) |_| {
            return true;
        }

        return false;
    }

    fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = msg;
        if (self.call_error) |err| return err;
        return Host.Result.fromCall(.{
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = &.{},
            .status = .success,
        });
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = self;
        _ = address;
        _ = key;
        return 1;
    }

    fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
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

pub fn defaultTxContext(origin: Address, gas_limit: u64) Host.TxContext {
    return .{
        .chain_id = 1,
        .gas_price = 0,
        .origin = origin,
        .coinbase = addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = gas_limit,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    };
}

pub const BytecodeResult = struct {
    status: evmz.Interpreter.Status,
    gas_left: i64,
    gas_refund: i64,
    stack_top: ?u256,
};

pub fn runBytecodeWithHost(host: *Host, msg: *const Host.Message, code: []const u8, revision: evmz.eth.Revision) !BytecodeResult {
    var frame = try evmz.Interpreter.OwnedCallFrame(evmz.EthProtocol).init(std.testing.allocator, .{
        .host = host,
        .msg = msg,
        .code = code,
        .revision = revision,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .stack_top = interpreter.call_frame.stack.peek(),
    };
}

pub fn expectBytecodeStatusByRevision(comptime items: anytype, revision: evmz.eth.Revision, expected: evmz.Interpreter.Status) !void {
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

pub fn expectBytecodeStackTopByRevision(comptime items: anytype, revision: evmz.eth.Revision, expected: u256) !void {
    const bytecode_bytes = bytecode(items);
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    const result = try runBytecodeWithHost(&host, &msg, &bytecode_bytes, revision);
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(expected, result.stack_top.?);
}

pub fn expectStackByRevision(code: []const u8, revision: evmz.eth.Revision, expected: []const u256) !void {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    var frame = try evmz.Interpreter.OwnedCallFrame(evmz.EthProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = code,
        .revision = revision,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u256, expected, interpreter.call_frame.stack.asSlice());
}

pub fn expectLatestForkBytecodeStackTop(comptime items: anytype, expected: u256) !void {
    try expectBytecodeStackTopByRevision(items, .latest, expected);
}

test "mock host persists storage writes" {
    try expectBytecodeStackTopByRevision(.{ .PUSH1, 0x2a, .PUSH1, 0x00, .SSTORE, .PUSH1, 0x00, .SLOAD }, .osaka, 0x2a);
}

test "environment opcodes delegate every tx context access to host" {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();

    var frame = try evmz.Interpreter.OwnedCallFrame(evmz.EthProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &bytecode(.{ .ORIGIN, .GASPRICE }),
        .revision = .latest,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);

    try std.testing.expectEqual(@as(u64, 2), mock_host.tx_context_reads);
}

test "host read errors propagate out of bytecode execution" {
    var mock_host = MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    mock_host.tx_context_error = error.DatabaseUnavailable;
    var host = mock_host.host();
    const msg = defaultMessage();
    const code = bytecode(.{.ORIGIN});

    try std.testing.expectError(
        error.DatabaseUnavailable,
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
        .base_fee = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .coinbase = addr(0),
        .origin = addr(0),
        .blob_base_fee = 0,
        .blob_hashes = &.{},
        .chain_id = 0,
        .number = 1000,
        .slot_number = 0x123456789abcdef0,
        .prev_randao = 0,
        .timestamp = 0,
    });
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = defaultMessage();
    const code = bytecode(.{.SLOTNUM});

    const result = try runBytecodeWithHost(&host, &msg, &code, .amsterdam);
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(u256, 0x123456789abcdef0), result.stack_top.?);
    try std.testing.expectEqual(@as(u64, 1), mock_host.tx_context_reads);
}

fn expectBlockhash(number: u16, expected: u256, expected_reads: u64) !void {
    var mock_host = MockHost.init(std.testing.allocator, .{
        .base_fee = 0,
        .gas_limit = 0,
        .gas_price = 0,
        .coinbase = addr(0),
        .origin = addr(0),
        .blob_base_fee = 0,
        .blob_hashes = &.{},
        .chain_id = 0,
        .number = 1000,
        .prev_randao = 0,
        .timestamp = 0,
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
