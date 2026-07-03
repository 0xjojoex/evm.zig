const std = @import("std");
const evmz = @import("./evm.zig");
const Opcode = @import("./opcode.zig").Opcode;
const Interpreter = @import("./Interpreter.zig");
const addr = evmz.addr;
const Address = evmz.Address;

pub const max_call_depth: u16 = 1024;

pub const Account = struct {
    balance: u256,
};

pub const AccessStatus = enum(u1) {
    cold = 0,
    warm = 1,
};

pub const StorageStatus = enum(u8) {
    assigned,
    added,
    deleted,
    modified,
    deleted_added,
    modified_deleted,
    deleted_restored,
    added_deleted,
    modified_restored,
};

pub const Message = struct {
    depth: u16,
    kind: CallKind,
    gas: i64,
    gas_reservoir: i64 = 0,
    recipient: Address = addr(0),
    sender: Address,
    input_data: []const u8,
    value: u256,
    is_static: bool = false,
    real_sender: Address = addr(0),
    code_address: Address = addr(0),
    create2_salt: u256 = 0,
};

pub const CallResult = struct {
    status: Interpreter.Status,
    output_data: []const u8,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    state_gas_refund: i64 = 0,
};

pub const CreateResult = struct {
    status: Interpreter.Status,
    output_data: []const u8,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    state_gas_refund: i64 = 0,
    address: Address,
};

pub const Result = union(enum) {
    call: CallResult,
    create: CreateResult,

    pub fn fromCall(result: CallResult) Result {
        return .{ .call = result };
    }

    pub fn fromCreate(address: Address, result: CallResult) Result {
        return .{ .create = .{
            .status = result.status,
            .output_data = result.output_data,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .gas_reservoir = result.gas_reservoir,
            .state_gas_spent = result.state_gas_spent,
            .state_gas_from_gas_left = result.state_gas_from_gas_left,
            .state_gas_refund = result.state_gas_refund,
            .address = address,
        } };
    }

    pub fn status(self: Result) Interpreter.Status {
        return switch (self) {
            .call => |result| result.status,
            .create => |result| result.status,
        };
    }

    pub fn outputData(self: Result) []const u8 {
        return switch (self) {
            .call => |result| result.output_data,
            .create => |result| result.output_data,
        };
    }

    pub fn gasLeft(self: Result) i64 {
        return switch (self) {
            .call => |result| result.gas_left,
            .create => |result| result.gas_left,
        };
    }

    pub fn gasRefund(self: Result) i64 {
        return switch (self) {
            .call => |result| result.gas_refund,
            .create => |result| result.gas_refund,
        };
    }

    pub fn gasReservoir(self: Result) i64 {
        return switch (self) {
            .call => |result| result.gas_reservoir,
            .create => |result| result.gas_reservoir,
        };
    }

    pub fn stateGasSpent(self: Result) i64 {
        return switch (self) {
            .call => |result| result.state_gas_spent,
            .create => |result| result.state_gas_spent,
        };
    }

    pub fn stateGasFromGasLeft(self: Result) i64 {
        return switch (self) {
            .call => |result| result.state_gas_from_gas_left,
            .create => |result| result.state_gas_from_gas_left,
        };
    }

    pub fn expectCall(self: Result) CallResult {
        return switch (self) {
            .call => |result| result,
            .create => unreachable,
        };
    }

    pub fn expectCreate(self: Result) CreateResult {
        return switch (self) {
            .call => unreachable,
            .create => |result| result,
        };
    }
};

pub const CallKind = enum(u8) {
    call = 0,
    delegatecall = 1,
    callcode = 2,
    create = 3,
    create2 = 4,
    // eofcreate = 5,

    pub fn fromOpcode(opcode: Opcode) CallKind {
        switch (opcode) {
            Opcode.CALL => return CallKind.call,
            Opcode.STATICCALL => return CallKind.call,
            Opcode.DELEGATECALL => return CallKind.delegatecall,
            Opcode.CALLCODE => return CallKind.callcode,
            Opcode.CREATE => return CallKind.create,
            Opcode.CREATE2 => return CallKind.create2,
            // Opcode.EOFCREATE => return CallKind.eofcreate,
            else => {
                unreachable;
            },
        }
    }
};

pub const TxContext = struct {
    chain_id: u256,
    gas_price: u256,
    origin: Address,
    coinbase: Address,
    number: u64,
    slot_number: u64 = 0,
    timestamp: u64,
    gas_limit: u64,
    prev_randao: u256,
    base_fee: u256,
    blob_base_fee: u256,
    blob_hashes: []const u256,
};

// incomplete
pub const Log = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
};

const Self = @This();

ptr: *anyopaque,
vtable: *const struct {
    accountExists: *const fn (ptr: *anyopaque, address: Address) anyerror!bool,
    getStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!u256,
    setStorage: *const fn (ptr: *anyopaque, address: Address, key: u256, value: u256) anyerror!StorageStatus,
    getBalance: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    getCodeSize: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    getCodeHash: *const fn (ptr: *anyopaque, address: Address) anyerror!u256,
    copyCode: *const fn (ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) anyerror!usize,
    emitLog: *const fn (ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) anyerror!void,
    getBlockHash: *const fn (ptr: *anyopaque, number: u256) anyerror!u256,
    getTxContext: *const fn (ptr: *anyopaque) anyerror!TxContext,
    accessAccount: *const fn (ptr: *anyopaque, address: Address) anyerror!AccessStatus,
    accessStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!AccessStatus,
    accessDelegatedAccount: *const fn (ptr: *anyopaque, address: Address) anyerror!?AccessStatus,
    call: *const fn (ptr: *anyopaque, msg: Message) anyerror!Result,
    selfDestruct: *const fn (ptr: *anyopaque, address: Address, beneficiary: Address) anyerror!bool,
    getTransientStorage: *const fn (ptr: *anyopaque, address: Address, key: u256) anyerror!u256,
    setTransientStorage: *const fn (ptr: *anyopaque, address: Address, key: u256, value: u256) anyerror!void,
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
pub fn accessDelegatedAccount(self: *Self, address: Address) !?AccessStatus {
    return self.vtable.accessDelegatedAccount(self.ptr, address);
}
pub fn copyCode(self: *Self, address: Address, code_offset: usize, buffer_data: []u8) !usize {
    return self.vtable.copyCode(self.ptr, address, code_offset, buffer_data);
}
pub fn getCodeSize(self: *Self, address: Address) !u256 {
    return self.vtable.getCodeSize(self.ptr, address);
}
pub fn getCodeHash(self: *Self, address: Address) !u256 {
    return self.vtable.getCodeHash(self.ptr, address);
}
pub fn getBalance(self: *Self, address: Address) !u256 {
    return self.vtable.getBalance(self.ptr, address);
}
pub fn setStorage(self: *Self, address: Address, key: u256, value: u256) !StorageStatus {
    return self.vtable.setStorage(self.ptr, address, key, value);
}
pub fn getStorage(self: *Self, address: Address, key: u256) !u256 {
    return self.vtable.getStorage(self.ptr, address, key);
}
pub fn emitLog(self: *Self, event_log: Log) !void {
    return self.vtable.emitLog(self.ptr, event_log.address, event_log.topics, event_log.data);
}
pub fn selfDestruct(self: *Self, address: Address, beneficiary: Address) !bool {
    return self.vtable.selfDestruct(self.ptr, address, beneficiary);
}
pub fn call(self: *Self, msg: Message) !Result {
    return self.vtable.call(self.ptr, msg);
}
pub fn getTransientStorage(self: *Self, address: Address, key: u256) !u256 {
    return self.vtable.getTransientStorage(self.ptr, address, key);
}
pub fn setTransientStorage(self: *Self, address: Address, key: u256, value: u256) !void {
    return self.vtable.setTransientStorage(self.ptr, address, key, value);
}
