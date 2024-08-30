const std = @import("std");
const evmz = @import("./evm.zig");

const Host = evmz.Host;
const addr = evmz.addr;
const Address = evmz.Address;
const Bytes = evmz.Bytes;

pub const allocator = std.testing.allocator;
pub var arena = std.heap.ArenaAllocator.init(allocator);

pub const MockCall = struct {
    call_frame: evmz.intrepreter.CallFrame,

    pub fn init(msg: *Host.Message, bytes: Bytes) MockCall {
        return MockCall{
            .call_frame = evmz.intrepreter.CallFrame.init(allocator, MockHost.init(allocator), msg, bytes),
        };
    }
};

pub const MockHost = struct {
    const Self = @This();

    alloc: std.mem.Allocator,
    store: std.AutoHashMap(u256, u256),
    logs: std.ArrayList(Host.Log),
    tx_context: Host.TxContext,
    code: std.AutoHashMap(Address, []u8),
    local_account: std.AutoHashMap(Address, Host.Account),
    removed_account: std.AutoHashMap(Address, bool),

    pub fn init(alloc: std.mem.Allocator, tx_context: ?Host.TxContext) Self {
        return Self{
            .alloc = alloc,
            .store = std.AutoHashMap(u256, u256).init(alloc),
            .logs = std.ArrayList(Host.Log).init(alloc),
            .local_account = std.AutoHashMap(Address, Host.Account).init(alloc),
            .removed_account = std.AutoHashMap(Address, bool).init(alloc),
            .code = std.AutoHashMap(Address, []u8).init(alloc),
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

    fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []u8) !void {
        const self: *Self = @ptrCast(@alignCast(ptr));
        try self.logs.append(.{
            .address = address,
            .topics = topics,
            .data = data,
        });
    }

    fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        try self.store.put(key, value);
        return .assigned;
    }

    fn getStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = address;
        return self.store.get(key);
    }

    fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
        const self: *Self = @ptrCast(@alignCast(ptr));
        _ = number;
        _ = self;
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
            const min = @min(code.len, buffer_data.len);
            @memcpy(buffer_data[0..min], code[code_offset .. code_offset + min]);

            return code.len;
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
        var result: [32]u8 = undefined;
        std.crypto.hash.sha3.Keccak256.hash(code, &result, .{});
        const final_result = @byteSwap(@as(u256, @bitCast(result)));

        return final_result;
    }

    fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
        const self: *Self = @ptrCast(@alignCast(ptr));

        const a = @This();

        const destrucing_balance = try a.getBalance(self, address);
        const recipient_balance = try a.getBalance(self, beneficiary);

        try self.local_account.put(address, .{
            .balance = 0,
        });

        try self.local_account.put(beneficiary, .{
            .balance = destrucing_balance + recipient_balance,
        });

        std.debug.print("sd {x}\n", .{address});

        _ = self.local_account.remove(address);
        _ = try self.removed_account.put(address, true);

        return false;
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
        const local = self.store.get(key);
        if (local) |_| {
            return .warm;
        }
        return .cold;
    }

    fn getTxContext(ptr: *anyopaque) !Host.TxContext {
        const self: *Self = @ptrCast(@alignCast(ptr));
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
        _ = ptr;
        _ = msg;
        return Host.Result{
            .create_address = addr(0),
            .gas_left = 0,
            .gas_refund = 0,
            .output_data = &.{},
            .status = .success,
        };
    }

    fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) ?u256 {
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
            .accessAccount = accessAccount,
            .getTxContext = getTxContext,
            .getTransientStorage = getTransientStorage,
            .setTransientStorage = setTransientStorage,
        } };
    }
};
