//! Explicit host-capable native-contract extension.
//!
//! Ethereum precompiles are terminal call targets and never receive this
//! capability. A specification opts addresses into this separate domain, and
//! the embedding supplies a runtime whose lifetime exceeds the executor
//! binding or its next reset.

const std = @import("std");

const Address = @import("../address.zig").Address;
const Host = @import("../Host.zig");
const precompile = @import("../precompile.zig");

/// Default address set for specifications without host-capable native code.
pub const None = struct {
    pub fn active(_: Address) bool {
        return false;
    }
};

/// Runtime service supplied by an embedding that opts into reentrant native
/// contracts. Its callback may synchronously invoke `call.host.call`.
pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, call: Call) anyerror!precompile.Result,
    };

    pub fn execute(self: Runtime, call: Call) !precompile.Result {
        return self.vtable.execute(self.ptr, call);
    }
};

/// Invocation-scoped capability for one reentrant native-contract call.
///
/// Output must be allocated from `allocator`; the executor copies it into
/// retained result storage before this invocation ends. Returning nonempty
/// borrowed output is rejected.
pub const Call = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    message: *const Host.Message,
};
