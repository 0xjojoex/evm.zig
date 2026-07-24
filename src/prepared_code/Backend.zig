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
/// Identifies the representation used to prepare bytecode. Current prepared
/// artifacts depend only on execution preprocessing options; exact fork
/// semantics remain in the VM type and do not enter bytecode storage identity.
pub const PreparationKey = struct {
    config: ExecutionConfig,
};

const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Open an execution scope. Pointers returned by `lookup`/`admit` under
    /// `key` stay valid until the matching `endExecution`.
    beginExecution: *const fn (ptr: *anyopaque, key: PreparationKey) anyerror!void,
    /// Close the scope opened by `beginExecution`, releasing any artifacts
    /// borrowed during it.
    endExecution: *const fn (ptr: *anyopaque) void,
    /// Return the retained artifact for `code_hash` under `key`, or `null` when
    /// it has not been admitted.
    lookup: *const fn (ptr: *anyopaque, key: PreparationKey, code_hash: [32]u8) anyerror!?*const Bytecode,
    /// Prepare and retain `raw_code` under `key`, returning the artifact, or
    /// `null` when backend policy declines it.
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
