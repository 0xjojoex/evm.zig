//! The environment interface the interpreter calls back into.
//!
//! `Host` is the boundary between the bytecode interpreter and the outside
//! world — account/storage access, call context, balances, and sub-calls. The
//! executor supplies the concrete implementation.

const std = @import("std");
const evmz = @import("./evm.zig");
const Opcode = @import("./opcode.zig").Opcode;
const addr = evmz.addr;
const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const execution = @import("./execution.zig");
const AccessStatus = execution.AccessStatus;
const ExecutionOutcome = execution.ExecutionOutcome;
const FrameHalt = execution.FrameHalt;
const Status = execution.Status;
const StorageStatus = execution.StorageStatus;
const TerminalCause = execution.TerminalCause;

pub const max_call_depth: u16 = 1024;

pub const StorageLoadResult = struct {
    value: u256,
    access_status: AccessStatus,
};

pub const StorageStoreResult = struct {
    storage_status: StorageStatus,
    access_status: AccessStatus,
};

/// Address fields are `align(8)` for their by-value field copies on the call
/// path. The layout this pins is asserted in `Interpreter.zig`.
pub const Message = struct {
    depth: u16,
    kind: CallKind,
    gas: i64,
    gas_reservoir: i64 = 0,
    recipient: Address align(8) = addr(0),
    sender: Address align(8),
    input_data: []const u8,
    value: u256,
    is_static: bool = false,
    code_address: Address align(8) = addr(0),

    /// Terminal validation already resolved by the opcode handler. The
    /// interpreter still emits the semantic action so call capture observes
    /// the attempt, but no host implementation may execute it.
    precheck_failure: ?TerminalCause = null,

    comptime {
        std.debug.assert(@sizeOf(Message) == 144);
        std.debug.assert(@alignOf(Message) == 16);
    }
};

/// Settlement of a finished child frame, CALL and CREATE alike. The created
/// address is deliberately absent: create targets are computed by the caller
/// before dispatch and travel in `Message.recipient`, so the frame that
/// initiated the create is the authority for the deployed address.
pub const Result = struct {
    outcome: ExecutionOutcome,
    frame_halt: ?FrameHalt = null,
    /// Whether this frame restored its own execution checkpoint. Precheck
    /// rejection and the pre-Homestead code-deposit exception do not.
    checkpoint_reverted: bool = false,
    output_data: []const u8,
    gas_left: i64,
    gas_refund: i64,
    gas_reservoir: i64 = 0,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,

    pub fn fromExecution(
        result: execution.ExecutionResult,
        checkpoint_reverted: bool,
    ) Result {
        return .{
            .outcome = result.outcome,
            .frame_halt = result.frame_halt,
            .checkpoint_reverted = checkpoint_reverted,
            .output_data = result.output_data,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
            .gas_reservoir = result.gas_reservoir,
            .state_gas_spent = result.state_gas_spent,
            .state_gas_from_gas_left = result.state_gas_from_gas_left,
        };
    }

    pub fn status(self: Result) Status {
        return self.outcome.status;
    }

    pub fn terminalCause(self: Result) TerminalCause {
        return self.outcome.cause;
    }

    /// Convert a resolved host result into the engine result boundary. The
    /// caller supplies Executor-owned output because Host output may borrow a
    /// frame or scratch arena that is about to be released.
    pub fn executionResult(self: Result, output_data: []u8) execution.ExecutionResult {
        return .{
            .outcome = self.outcome,
            .frame_halt = self.frame_halt,
            .gas_left = self.gas_left,
            .gas_refund = self.gas_refund,
            .gas_reservoir = self.gas_reservoir,
            .state_gas_spent = self.state_gas_spent,
            .state_gas_from_gas_left = self.state_gas_from_gas_left,
            .output_data = output_data,
        };
    }

    comptime {
        std.debug.assert(@sizeOf(Result) == 64);
        std.debug.assert(@alignOf(Result) == 8);
    }
};

/// Resolve an opcode-local terminal call/create attempt without invoking the
/// host. The supplied child gas is returned in full, matching EVM prechecks.
pub fn precheckResult(msg: Message) ?Result {
    const cause = msg.precheck_failure orelse return null;
    return .{
        .outcome = .{ .status = .invalid, .cause = cause },
        .output_data = &.{},
        .gas_left = msg.gas,
        .gas_refund = 0,
        .gas_reservoir = msg.gas_reservoir,
    };
}

pub const CallKind = enum(u8) {
    call,
    staticcall,
    delegatecall,
    callcode,
    create,
    create2,

    pub fn fromOpcode(opcode: Opcode) CallKind {
        return switch (opcode) {
            .CALL => .call,
            .STATICCALL => .staticcall,
            .DELEGATECALL => .delegatecall,
            .CALLCODE => .callcode,
            .CREATE => .create,
            .CREATE2 => .create2,
            else => unreachable,
        };
    }
};

/// EVM log payload. `topics` and `data` are borrowed by the host callback;
/// implementations that retain logs must copy them.
pub const Log = struct {
    address: Address,
    topics: []const u256,
    data: []const u8,
};

const Self = @This();

pub const VTable = struct {
    accountExists: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!bool,
    getStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256) anyerror!u256,
    setStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256, value: u256) anyerror!StorageStatus,
    getBalance: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!u256,
    getNonce: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!u64,
    getCodeSize: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!u256,
    getCodeHash: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!u256,
    copyCode: *const fn (ptr: *anyopaque, address: AddressWord, code_offset: usize, buffer_data: []u8) anyerror!usize,
    emitLog: *const fn (ptr: *anyopaque, event_log: Log) anyerror!void,
    getBlockHash: *const fn (ptr: *anyopaque, number: u256) anyerror!u256,
    accessAccount: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!AccessStatus,
    accessStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256) anyerror!AccessStatus,
    accessDelegatedAccount: *const fn (ptr: *anyopaque, address: AddressWord) anyerror!?AccessStatus,
    observeAccountAccess: ?*const fn (ptr: *anyopaque, address: AddressWord, depth: u16) anyerror!void = null,
    call: *const fn (ptr: *anyopaque, msg: Message) anyerror!Result,
    selfDestruct: *const fn (ptr: *anyopaque, address: Address, beneficiary: Address) anyerror!bool,
    getTransientStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256) anyerror!u256,
    setTransientStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256, value: u256) anyerror!void,

    /// Native fused storage operations. Split access/get/set primitives remain
    /// required for gas-ordering paths that may stop before value access.
    loadStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256) anyerror!StorageLoadResult,
    storeStorage: *const fn (ptr: *anyopaque, address: AddressWord, key: u256, value: u256) anyerror!StorageStoreResult,
};

ptr: *anyopaque,
vtable: *const VTable,

comptime {
    // Host adapters are copied into runtime helpers. Execution context remains
    // behind the owner pointer so adding immutable capabilities cannot widen it.
    std.debug.assert(@sizeOf(Self) == 2 * @sizeOf(usize));
    std.debug.assert(@alignOf(Self) == @alignOf(usize));
}

pub fn accountExists(self: *Self, address: AddressWord) !bool {
    return self.vtable.accountExists(self.ptr, address);
}
pub fn getBlockHash(self: *Self, number: u256) !u256 {
    return self.vtable.getBlockHash(self.ptr, number);
}
pub fn accessAccount(self: *Self, address: AddressWord) !AccessStatus {
    return self.vtable.accessAccount(self.ptr, address);
}
pub fn accessStorage(self: *Self, address: AddressWord, key: u256) !AccessStatus {
    return self.vtable.accessStorage(self.ptr, address, key);
}
pub fn accessDelegatedAccount(self: *Self, address: AddressWord) !?AccessStatus {
    return self.vtable.accessDelegatedAccount(self.ptr, address);
}
pub fn observeAccountAccess(self: *Self, address: AddressWord, depth: u16) !void {
    const callback = self.vtable.observeAccountAccess orelse return;
    return callback(self.ptr, address, depth);
}
pub fn copyCode(self: *Self, address: AddressWord, code_offset: usize, buffer_data: []u8) !usize {
    return self.vtable.copyCode(self.ptr, address, code_offset, buffer_data);
}
pub fn getCodeSize(self: *Self, address: AddressWord) !u256 {
    return self.vtable.getCodeSize(self.ptr, address);
}
pub fn getCodeHash(self: *Self, address: AddressWord) !u256 {
    return self.vtable.getCodeHash(self.ptr, address);
}
pub fn getBalance(self: *Self, address: AddressWord) !u256 {
    return self.vtable.getBalance(self.ptr, address);
}
pub fn getNonce(self: *Self, address: AddressWord) !u64 {
    return self.vtable.getNonce(self.ptr, address);
}
pub fn setStorage(self: *Self, address: AddressWord, key: u256, value: u256) !StorageStatus {
    return self.vtable.setStorage(self.ptr, address, key, value);
}
pub fn getStorage(self: *Self, address: AddressWord, key: u256) !u256 {
    return self.vtable.getStorage(self.ptr, address, key);
}
pub fn loadStorage(self: *Self, address: AddressWord, key: u256) !StorageLoadResult {
    return self.vtable.loadStorage(self.ptr, address, key);
}
pub fn storeStorage(self: *Self, address: AddressWord, key: u256, value: u256) !StorageStoreResult {
    return self.vtable.storeStorage(self.ptr, address, key, value);
}
pub fn emitLog(self: *Self, event_log: Log) !void {
    return self.vtable.emitLog(self.ptr, event_log);
}
pub fn selfDestruct(self: *Self, address: Address, beneficiary: Address) !bool {
    return self.vtable.selfDestruct(self.ptr, address, beneficiary);
}
pub fn call(self: *Self, msg: Message) !Result {
    return self.vtable.call(self.ptr, msg);
}
pub fn getTransientStorage(self: *Self, address: AddressWord, key: u256) !u256 {
    return self.vtable.getTransientStorage(self.ptr, address, key);
}
pub fn setTransientStorage(self: *Self, address: AddressWord, key: u256, value: u256) !void {
    return self.vtable.setTransientStorage(self.ptr, address, key, value);
}
