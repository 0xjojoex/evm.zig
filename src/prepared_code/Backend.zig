//! Caller-owned read/write service for prepared execution artifacts.
//!
//! Backends may retain artifacts in memory, hydrate them from durable storage,
//! or decline admission. Returned pointers are borrowed and remain valid from
//! `beginExecution` through the matching `endExecution` call.
//!
//! Backend allocation, I/O, synchronization, and capacity policy are owned by
//! the embedding and are outside the VM's bounded-runtime resource envelope.
//! An implementation shared by concurrent VMs must synchronize its own state.

const Bytecode = @import("../code/Bytecode.zig");
const ExecutionConfig = @import("../ExecutionConfig.zig");
const RevisionId = @import("../protocol.zig").RevisionId;

pub const PreparationKey = struct {
    revision_id: RevisionId,
    config: ExecutionConfig,
};

const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    beginExecution: *const fn (ptr: *anyopaque, key: PreparationKey) anyerror!void,
    endExecution: *const fn (ptr: *anyopaque) void,
    lookup: *const fn (ptr: *anyopaque, key: PreparationKey, code_hash: [32]u8) anyerror!?*const Bytecode,
    admit: *const fn (ptr: *anyopaque, key: PreparationKey, code_hash: [32]u8, raw_code: []const u8) anyerror!?*const Bytecode,
};

pub fn beginExecution(self: Backend, key: PreparationKey) !void {
    return self.vtable.beginExecution(self.ptr, key);
}

pub fn endExecution(self: Backend) void {
    self.vtable.endExecution(self.ptr);
}

pub fn lookup(self: Backend, key: PreparationKey, code_hash: [32]u8) !?*const Bytecode {
    return self.vtable.lookup(self.ptr, key, code_hash);
}

/// Return a retained artifact, or `null` when backend policy declines it.
pub fn admit(self: Backend, key: PreparationKey, code_hash: [32]u8, raw_code: []const u8) !?*const Bytecode {
    return self.vtable.admit(self.ptr, key, code_hash, raw_code);
}
