const std = @import("std");

pub const Address = [20]u8;
pub const zero_address: Address = [_]u8{0} ** 20;

pub const Bytes = []u8;

pub const Contract = struct {
    input: Bytes,
    bytecode: Bytes,
    target_address: Address,
    bytecode_address: ?Address,
    caller: Address,
    call_value: u256,
};

// incomplete
pub const Log = struct {
    address: Address,
    topics: []u256,
    data: u256,
};

pub const BlockContext = struct {
    base_fee: u256,
    coinbase: Address,
    timestamp: u256,
    number: u256,
    prev_randao: u256,
    gas_limit: u256,

    // evm cfg
    chain_id: u64,

    pub fn mock() BlockContext {
        return BlockContext{
            .base_fee = 0,
            .coinbase = zero_address,
            .timestamp = 0,
            .number = 0,
            .prev_randao = 0,
            .gas_limit = 0,
            .chain_id = 0,
        };
    }
};

pub const Account = struct {
    balance: u256,
};

pub const StateContext = struct {
    ptr: *anyopaque,
    vtable: *const struct {
        getBalance: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
        getCode: *const fn (ptr: *anyopaque, address: Address) anyerror!Bytes,
        putCode: *const fn (ptr: *anyopaque, address: Address, code: Bytes) anyerror!void,
        putAccount: *const fn (ptr: *anyopaque, address: Address, account: Account) anyerror!void,
        sstore: *const fn (ptr: *anyopaque, address: Address, key: u256, value: u256) anyerror!void,
        sload: *const fn (ptr: *anyopaque, address: Address, key: u256) ?u256,
        emitLog: *const fn (ptr: *anyopaque, event_log: Log) anyerror!void,
        selfDestruct: *const fn (ptr: *anyopaque, address: Address) anyerror!void,
    },
    pub fn getCode(self: *StateContext, address: Address) !Bytes {
        return self.vtable.getCode(self.ptr, address);
    }
    pub fn putCode(self: *StateContext, address: Address, code: Bytes) !void {
        return self.vtable.putCode(self.ptr, address, code);
    }
    pub fn getBalance(self: *StateContext, address: Address) !u256 {
        return self.vtable.getBalance(self.ptr, address);
    }
    pub fn putAccount(self: *StateContext, address: Address, account: Account) !void {
        return self.vtable.putAccount(self.ptr, address, account);
    }
    pub fn sstore(self: *StateContext, address: Address, key: u256, value: u256) !void {
        return self.vtable.sstore(self.ptr, address, key, value);
    }
    pub fn sload(self: *StateContext, address: Address, key: u256) ?u256 {
        return self.vtable.sload(self.ptr, address, key);
    }
    pub fn emitLog(self: *StateContext, event_log: Log) !void {
        return self.vtable.emitLog(self.ptr, event_log);
    }
    pub fn selfDestruct(self: *StateContext, address: Address) !void {
        return self.vtable.selfDestruct(self.ptr, address);
    }
};

pub const TransactionContext = struct {
    origin: Address,
    to: Address,
    from: Address,
    value: u256,
    gas_price: u256,
    data: []u8,

    pub fn mock() TransactionContext {
        return TransactionContext{
            .origin = zero_address,
            .to = zero_address,
            .from = zero_address,
            .value = 0,
            .gas_price = 0,
            .data = undefined,
        };
    }
};

pub const Status = enum(u8) { success, invalid, running, revert };

pub fn bytesToU256(bytes: []const u8) u256 {
    var result: u256 = 0;

    for (bytes) |byte| {
        result = (result << 8) | byte;
    }

    return result;
}

test bytesToU256 {
    const t = [_]u8{0};
    try std.testing.expectEqual(bytesToU256(t[0..]), 0);
}
