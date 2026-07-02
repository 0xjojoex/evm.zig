const std = @import("std");
const evmz = @import("../evm.zig");
const Executor = @import("../executor.zig");
const call_runtime = @import("./call_runtime.zig");
const eip7702 = @import("./eip7702.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const StorageKey = evmz.state.StorageKey;

pub fn host(self: *Executor) Host {
    return Host{ .ptr = self, .vtable = &.{
        .call = call,
        .accountExists = accountExists,
        .getBalance = getBalance,
        .copyCode = copyCode,
        .getCodeSize = getCodeSize,
        .getCodeHash = getCodeHash,
        .getStorage = hostGetStorage,
        .setStorage = setStorage,
        .emitLog = emitLog,
        .getBlockHash = getBlockHash,
        .selfDestruct = selfDestruct,
        .accessStorage = accessStorage,
        .accessDelegatedAccount = accessDelegatedAccount,
        .accessAccount = accessAccount,
        .getTxContext = call_runtime.getTxContext,
        .getTransientStorage = getTransientStorage,
        .setTransientStorage = setTransientStorage,
    } };
}

fn accountExists(ptr: *anyopaque, address: Address) !bool {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.accountExists(address);
}

fn getBalance(ptr: *anyopaque, address: Address) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.getBalance(address);
}

fn hostGetStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
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
    const account = try self.state.getAccountOrLoad(address) orelse return 0;
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
    try self.state.emitLog(.{
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
    return call_runtime.call(self, msg);
}

fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    const balance = try getBalance(ptr, address);
    const same_address = std.mem.eql(u8, &address, &beneficiary);
    const should_refund = !self.state.selfdestructed_accounts.contains(address);
    if (balance > 0) {
        if (!same_address) {
            try self.state.addBalance(beneficiary, balance);
        }
        if (!same_address or !self.spec.isImpl(.cancun) or self.state.created_contracts.contains(address)) {
            try self.state.setBalance(address, 0);
        }
    }
    try self.state.markSelfdestructed(address);
    return should_refund;
}

fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    return self.state.getTransientStorage(address, key);
}

fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
    const self: *Executor = @ptrCast(@alignCast(ptr));
    try self.state.setTransientStorage(address, key, value);
}
