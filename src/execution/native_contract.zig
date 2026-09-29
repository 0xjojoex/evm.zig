//! Explicit host-capable native-contract extension.
//!
//! Ethereum precompiles are terminal call targets and never receive this
//! capability. A specification opts addresses into this separate domain, and
//! the embedding supplies a runtime whose lifetime exceeds the executor
//! binding or its next reset.
//!
//! A native activation is a suspendable frame. Each entry returns a `Step`: done,
//! or one child call that the executor runs, prices and settles into the ledger
//! before entering the native again. The native never holds the EVM while a child
//! runs, so `Host.call` is unavailable inside an entry.

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
pub const Runtime = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        execute: *const fn (ptr: *anyopaque, call: Call) anyerror!Step,
    };

    pub fn execute(self: Runtime, call: Call) !Step {
        return self.vtable.execute(self.ptr, call);
    }
};

/// Gas accounting for one activation. The executor owns it, settles children
/// into it and normalizes it once when the activation ends.
pub const Ledger = struct {
    gas_left: i64,
    /// Discarded unless the activation succeeds.
    gas_refund: i64 = 0,
    gas_reservoir: i64,
    state_gas_spent: i64 = 0,
    state_gas_from_gas_left: i64 = 0,
    /// Terminal: the activation ends out of gas whatever the entry returns.
    out_of_gas: bool = false,

    pub fn init(message: *const Host.Message) Ledger {
        return .{ .gas_left = message.gas, .gas_reservoir = message.gas_reservoir };
    }

    /// Charge native work using an adapter-selected price. False is terminal.
    pub fn trackGas(self: *Ledger, gas: i64) bool {
        std.debug.assert(!self.out_of_gas);
        if (gas > self.gas_left) {
            self.out_of_gas = true;
            self.gas_left = 0;
            return false;
        }
        self.gas_left -= gas;
        return true;
    }

    pub const trackStateGas = accounting.trackStateGas;
    pub const refillStateGas = accounting.refillStateGas;
};

pub const Step = union(enum) {
    /// End the activation. Invalid and out-of-gas discard output.
    done: Done,
    /// Suspend until the executor has run and settled this child.
    call: ChildRequest,
};

pub const Done = struct {
    status: execution.Status = .success,
    /// Nonempty output must be allocated from `Call.allocator`.
    output_data: []u8 = &.{},
};

/// One CALL-family child. The executor derives depth and staticness, forwards
/// `gas` through `CallSpec.childGas` and adds the value stipend exactly as the
/// CALL opcode does. Access, value and tariff charges stay with the native.
pub const ChildRequest = struct {
    kind: Kind,
    recipient: Address,
    code_address: Address,
    sender: Address,
    value: u256 = 0,
    /// Borrowed until the child returns; allocate from `Call.allocator`.
    input_data: []const u8 = &.{},
    gas: i64,
    /// Returned unchanged in `Call.continuation` on the next entry.
    continuation: ?*anyopaque = null,

    /// CREATE is not a call: it would need address derivation, salt and
    /// creation pricing, so a native that creates gets its own step.
    pub const Kind = enum {
        call,
        staticcall,
        delegatecall,
        callcode,

        pub fn callKind(self: Kind) Host.CallKind {
            return switch (self) {
                .call => .call,
                .staticcall => .staticcall,
                .delegatecall => .delegatecall,
                .callcode => .callcode,
            };
        }
    };
};

/// The executor's own pricing rules, borrowed for the invocation. A callback
/// that mimics an EVM effect prices it from here, so it can never disagree
/// with the spec the executor was compiled from, including `Spec.extend`
/// overrides. Chain-specific tariffs stay with the adapter.
pub const Rules = struct {
    storage: *const spec.StorageSpec,
    call: *const spec.CallSpec,
};

/// One entry into a native activation.
pub const Call = struct {
    /// Activation-scoped: valid until the activation ends.
    allocator: std.mem.Allocator,
    host: *Host,
    message: *const Host.Message,
    rules: Rules,
    ledger: *Ledger,
    /// Null on the first entry, then the settled result of the previous child.
    /// Its output lives in `allocator`, valid until the activation ends.
    child: ?*const Host.Result = null,
    continuation: ?*anyopaque = null,
};
