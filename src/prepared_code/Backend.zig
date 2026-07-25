//! Caller-owned read/write service for prepared execution artifacts.
//!
//! Backends may retain artifacts in memory, hydrate them from durable storage,
//! or decline admission. Returned views expose semantic code backed by the
//! required readable zero tail and remain valid from `beginExecution` through
//! the matching `endExecution` call.
//!
//! Backend allocation, I/O, synchronization, and capacity policy are owned by
//! the embedding and are outside the VM's bounded-runtime resource envelope.
//! An implementation shared by concurrent VMs must synchronize its own state.

const Bytecode = @import("../code/Bytecode.zig");
const JumpDestStrategy = @import("../code/Config.zig").JumpDestStrategy;

const Backend = @This();

ptr: *anyopaque,
vtable: *const VTable,

pub const VTable = struct {
    /// Open an execution scope. Returned views stay valid until the matching
    /// `endExecution`.
    beginExecution: *const fn (ptr: *anyopaque) anyerror!void,
    /// Close the scope opened by `beginExecution`, releasing any artifacts
    /// borrowed during it.
    endExecution: *const fn (ptr: *anyopaque) void,
    /// Return the retained artifact for `code_hash`, or `null` when it has not
    /// been admitted.
    lookup: *const fn (ptr: *anyopaque, code_hash: [32]u8) anyerror!?Bytecode.View,
    /// Prepare and retain `raw_code`, returning the artifact, or `null` when
    /// backend policy declines it. `strategy` chooses only the miss-time
    /// builder; it is not artifact identity.
    admit: *const fn (ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8, strategy: JumpDestStrategy) anyerror!?Bytecode.View,
};

pub fn beginExecution(self: Backend) !void {
    return self.vtable.beginExecution(self.ptr);
}

pub fn endExecution(self: Backend) void {
    self.vtable.endExecution(self.ptr);
}

pub fn lookup(self: Backend, code_hash: [32]u8) !?Bytecode.View {
    return self.vtable.lookup(self.ptr, code_hash);
}

/// Return a retained artifact, or `null` when backend policy declines it.
pub fn admit(self: Backend, code_hash: [32]u8, raw_code: []const u8, strategy: JumpDestStrategy) !?Bytecode.View {
    return self.vtable.admit(self.ptr, code_hash, raw_code, strategy);
}
