//! Explicit host-capable native-contract extension.
//!
//! Ethereum precompiles are terminal call targets and never receive this
//! capability. A specification opts addresses into this separate domain, and
//! the embedding supplies a runtime whose lifetime exceeds the executor
//! binding or its next reset.

const std = @import("std");

const Address = @import("../address.zig").Address;
const Host = @import("../Host.zig");
const execution = @import("../execution.zig");
const spec = @import("../spec.zig");
const accounting = @import("accounting.zig");

/// Default address set for specifications without host-capable native code.
pub const None = struct {
    pub fn active(_: Address) bool {
        return false;
    }
};

/// Runtime service supplied by an embedding that opts into native contracts.
/// Its callback may synchronously invoke `call.host.call`.
pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, call: Call) anyerror!Result,
    };

    pub fn execute(self: Runtime, call: Call) !Result {
        return self.vtable.execute(self.ptr, call);
    }
};

/// Semantic result returned by one host-capable native contract.
///
/// The runtime reports the EVM-visible call status, output, and remaining gas.
/// Executor owns checkpoint settlement and converts this value into `Host.Result`.
pub const Result = struct {
    status: execution.Status,
    output_data: []u8,
    gas_left: i64,
    /// Refund accumulated by successful child calls and native execution.
    /// Executor discards it when this invocation fails or reverts.
    gas_refund: i64 = 0,
    /// Remaining reservoir, not a fork-activation flag. Initialize from Message.
    gas_reservoir: i64,
    /// This invocation's ledger before terminal finalization. Executor unwinds
    /// it on failure; do not finalize a returned child's scope a second time.
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,

    pub fn init(message: *const Host.Message) Result {
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = message.gas,
            .gas_reservoir = message.gas_reservoir,
        };
    }

    /// Charge native work using an adapter-selected price. False is terminal;
    /// return this result without issuing further effects.
    pub fn trackGas(self: *Result, gas: i64) bool {
        std.debug.assert(self.status == .success);
        if (gas > self.gas_left) {
            self.status = .out_of_gas;
            self.gas_left = 0;
            return false;
        }
        self.gas_left -= gas;
        return true;
    }

    pub const trackStateGas = accounting.trackStateGas;
    pub const refillStateGas = accounting.refillStateGas;
    pub const settleChild = accounting.settleChild;
};

/// The executor's own pricing rules, borrowed for the invocation. A callback
/// that mimics an EVM effect prices it from here, so it can never disagree
/// with the spec the executor was compiled from, including `Spec.extend`
/// overrides. Chain-specific tariffs stay with the adapter.
pub const Rules = struct {
    storage: *const spec.StorageSpec,
    call: *const spec.CallSpec,
};

/// Invocation-scoped capability for one native-contract call.
///
/// Nonempty output must be allocated from `allocator`; the executor copies it
/// into retained result storage before this invocation ends. Empty output may
/// use `&.{}`.
pub const Call = struct {
    allocator: std.mem.Allocator,
    host: *Host,
    message: *const Host.Message,
    rules: Rules,
};
