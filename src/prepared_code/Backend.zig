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
    /// backend policy declines it.
    admit: *const fn (ptr: *anyopaque, code_hash: [32]u8, raw_code: []const u8) anyerror!?Bytecode.View,
    /// Indexed twin of `lookup`. `index` is the caller's block-stable dense
    /// code index (`state.CodeRef`), allowing direct lookup. Admission may
    /// still use a hash-keyed owner to deduplicate artifacts. An index can
    /// be reassigned to different bytes after a revert, so a hit must also
    /// match `code_hash`. Optional: a backend without it is consulted by
    /// hash as before.
    lookupIndexed: ?*const fn (ptr: *anyopaque, index: u32, code_hash: [32]u8) ?Bytecode.View = null,
    /// Indexed twin of `admit`; same index contract as `lookupIndexed`.
    admitIndexed: ?*const fn (
        ptr: *anyopaque,
        index: u32,
        code_hash: [32]u8,
        raw_code: []const u8,
    ) anyerror!?Bytecode.View = null,
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
pub fn admit(self: Backend, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
    return self.vtable.admit(self.ptr, code_hash, raw_code);
}

/// Whether this backend serves the indexed lane at all.
pub fn supportsIndexed(self: Backend) bool {
    return self.vtable.lookupIndexed != null and self.vtable.admitIndexed != null;
}

/// Indexed lookup; null when the backend has no indexed lane or no hit.
pub fn lookupIndexed(self: Backend, index: u32, code_hash: [32]u8) ?Bytecode.View {
    const lookup_fn = self.vtable.lookupIndexed orelse return null;
    return lookup_fn(self.ptr, index, code_hash);
}

/// Indexed admission; null when the backend has no indexed lane or declines.
pub fn admitIndexed(self: Backend, index: u32, code_hash: [32]u8, raw_code: []const u8) !?Bytecode.View {
    const admit_fn = self.vtable.admitIndexed orelse return null;
    return admit_fn(self.ptr, index, code_hash, raw_code);
}
