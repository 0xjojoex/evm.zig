const alias = @import("./alias.zig");
const Address = alias.Address;
const Bytes = alias.Bytes;

pub const Account = struct {
    balance: u256,
};

pub const AccessStatus = enum(u1) {
    cold = 0,
    warm = 1,
};

pub const TxContext = struct {
    gas_price: u256,
    origin: Address,
    coinbase: Address,
    number: u64,
    timestamp: u64,
    gas_limit: u64,
    prev_randao: u256,
    base_fee: u256,
    blob_base: u256,
};

// incomplete
pub const Log = struct {
    address: Address,
    topics: []u256,
    data: Bytes,
};

const Self = @This();

ptr: *anyopaque,
vtable: *const struct {
    accountExists: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
    getStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!u256,
    setStorage: *const fn (ptr: *anyopaque, address: Address, key: u256, value: u256) anyerror!void,
    getBalance: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    getCodeSize: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    getCodeHash: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    getCode: *const fn (ptr: *anyopaque, address: Address) anyerror!Bytes,
    putCode: *const fn (ptr: *anyopaque, address: Address, code: Bytes) anyerror!void,
    putAccount: *const fn (ptr: *anyopaque, address: Address, account: Account) anyerror!void,
    emitLog: *const fn (ptr: *anyopaque, address: Address, topics: []u256, data: Bytes) anyerror!void,
    getBlockHash: *const fn (ptr: *anyopaque, number: u256) anyerror!u256,
    getTxContext: *const fn (ptr: *anyopaque) anyerror!TxContext,
    accessAccount: *const fn (ptr: *anyopaque, address: Address) anyerror!AccessStatus,
    accessStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!AccessStatus,
    selfDestruct: *const fn (ptr: *anyopaque, address: Address) anyerror!void,
},

pub fn accountExists(self: *Self, address: Address) !bool {
    return self.vtable.accountExists(self.ptr, address);
}
pub fn getTxContext(self: *Self) !TxContext {
    return self.vtable.getTxContext(self.ptr);
}
pub fn getBlockHash(self: *Self, number: u256) !u256 {
    return self.vtable.getBlockHash(self.ptr, number);
}
pub fn accessAccount(self: *Self, address: Address) !AccessStatus {
    return self.vtable.accessAccount(self.ptr, address);
}
pub fn accessStorage(self: *Self, address: Address, key: u256) !AccessStatus {
    return self.vtable.accessStorage(self.ptr, address, key);
}
pub fn getCode(self: *Self, address: Address) !Bytes {
    return self.vtable.getCode(self.ptr, address);
}
pub fn getCodeSize(self: *Self, address: Address) !u256 {
    return self.vtable.getCodeSize(self.ptr, address);
}
pub fn getCodeHash(self: *Self, address: Address) !u256 {
    return self.vtable.getCodeHash(self.ptr, address);
}
pub fn putCode(self: *Self, address: Address, code: Bytes) !void {
    return self.vtable.putCode(self.ptr, address, code);
}
pub fn getBalance(self: *Self, address: Address) !u256 {
    return self.vtable.getBalance(self.ptr, address);
}
pub fn putAccount(self: *Self, address: Address, account: Account) !void {
    return self.vtable.putAccount(self.ptr, address, account);
}
pub fn setStorage(self: *Self, address: Address, key: u256, value: u256) !void {
    return self.vtable.setStorage(self.ptr, address, key, value);
}
pub fn getStorage(self: *Self, address: Address, key: u256) ?u256 {
    return self.vtable.getStorage(self.ptr, address, key);
}
pub fn emitLog(self: *Self, event_log: Log) !void {
    return self.vtable.emitLog(self.ptr, event_log);
}
pub fn selfDestruct(self: *Self, address: Address) !void {
    return self.vtable.selfDestruct(self.ptr, address);
}
