//! Runtime capability for definition-owned stateful precompiles.
//!
//! These handles are deliberately separate from the data-only request. An
//! executor stores copies of the handles across requests, so their `ptr` and
//! `vtable` targets must outlive that executor binding or its next `reset`.
//! The `host` and `message` inside `PrecompileCall` are invocation-scoped.

const std = @import("std");

const Host = @import("../Host.zig");
const precompile = @import("../precompile.zig");

/// Distinguishes ordinary precompile completion from a runtime-service failure.
/// Built-in catalog failures remain in `precompile.Error`.
pub const PrecompileOutcome = union(enum) {
    result: precompile.Result,
    service_error: anyerror,
};

/// Optional family runtime used by definition-owned precompile entries.
///
/// The definition remains responsible for address activation and entry
/// selection. A selected entry may delegate here when it needs family state or
/// metadata that does not belong in `ExecutionContext`.
pub const PrecompileRuntime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, call: PrecompileCall) anyerror!precompile.Result,
    };

    pub fn execute(self: PrecompileRuntime, call: PrecompileCall) !precompile.Result {
        return self.vtable.execute(self.ptr, call);
    }
};

/// Complete runtime input for one resolved precompile invocation.
pub const PrecompileCall = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    message: *const Host.Message,
    output_buffer: ?[]u8 = null,
    runtime: ?PrecompileRuntime = null,

    /// Delegate this definition-owned entry to the supplied family runtime.
    ///
    /// Owned output must come from `allocator`. Non-owned nonempty output must
    /// alias a prefix of `output_buffer`; the executor validates that contract.
    pub fn executeRuntime(self: PrecompileCall) PrecompileOutcome {
        const runtime = self.runtime orelse return .{ .service_error = error.MissingPrecompileRuntime };
        var delegated = self;
        delegated.runtime = null;
        const result = runtime.execute(delegated) catch |err| return .{ .service_error = err };
        return .{ .result = result };
    }
};
