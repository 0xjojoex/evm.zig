const std = @import("std");

const Address = @import("../address.zig").Address;

/// One state-growth resource whose charge can be refilled by a later operation.
pub const StateGasResource = union(enum) {
    account: Address,
    code: Address,
    storage: Storage,

    pub const Storage = struct {
        address: Address,
        slot: u256,
    };
};

/// Exact state-gas movement caused by one reached execution operation.
///
/// A transaction-owned meter may attribute the charge to the current root and
/// apply the refill to an earlier owner of the same resource.
pub const StateGasEvent = struct {
    resource: StateGasResource,
    charge: i64 = 0,
    refill: i64 = 0,

    pub fn account(address: Address, charge: i64, refill: i64) StateGasEvent {
        return checked(.{ .resource = .{ .account = address }, .charge = charge, .refill = refill });
    }

    pub fn storage(address: Address, slot: u256, charge: i64, refill: i64) StateGasEvent {
        return checked(.{ .resource = .{ .storage = .{ .address = address, .slot = slot } }, .charge = charge, .refill = refill });
    }

    pub fn code(address: Address, charge: i64) StateGasEvent {
        return checked(.{ .resource = .{ .code = address }, .charge = charge });
    }

    pub fn isEmpty(self: StateGasEvent) bool {
        return self.charge == 0 and self.refill == 0;
    }

    fn checked(event: StateGasEvent) StateGasEvent {
        std.debug.assert(event.charge >= 0);
        std.debug.assert(event.refill >= 0);
        return event;
    }
};

/// Result of applying one event to an independent transaction-owned meter.
/// A charge token identifies the atomic mutation that a failed child CALL or
/// CREATE must cancel after its execution checkpoint has closed. A nonzero
/// charge must return a token no larger than `maxInt(i64)`; refill-only events
/// return null.
pub const StateGasMeterResult = union(enum) {
    exhausted,
    applied: ?usize,
};

/// Parent-frame state-gas charge retained while a child executes. Keep this to
/// one word: positive values are reservoir charges, zero is none, and negative
/// values encode transaction-meter undo tokens.
pub const StateGasCharge = struct {
    encoded: i64 = 0,

    pub fn reservoir(amount: i64) StateGasCharge {
        std.debug.assert(amount > 0);
        return .{ .encoded = amount };
    }

    pub fn metered(token: usize) StateGasCharge {
        std.debug.assert(token <= std.math.maxInt(i64));
        return .{ .encoded = -1 - @as(i64, @intCast(token)) };
    }

    pub fn reservoirOrNone(self: StateGasCharge) ?i64 {
        return if (self.encoded >= 0) self.encoded else null;
    }

    pub fn meterToken(self: StateGasCharge) ?usize {
        return if (self.encoded < 0) @intCast(-(self.encoded + 1)) else null;
    }
};

/// Initial execution gas state consumed by the interpreter.
///
/// `regular_left` is the value visible to the `GAS` opcode. `reservoir` is an
/// additional family-resolved budget, currently used by Amsterdam state gas.
///
/// Three distinct quantities in the spec are all spelled "gas". Keep them apart:
///
///   - `transaction.Env.gas_limit` — the *block's* limit, read by GASLIMIT.
///     Spec `BlockEnvironment.block_gas_limit`.
///   - `transaction.TransactionView.gas_limit` — the signed transaction field.
///     Spec `tx.gas`.
///   - `ExecutionGas.regular_left` — the top frame's *budget*, which is
///     `TransactionView.gas_limit - intrinsic_gas` (see `transaction/gas.zig`
///     `gasPlan`). Spec `TransactionEnvironment.gas`.
///
/// Only the first two are limits, and neither equals this budget. That is why
/// `ExecutionContext` carries no transaction gas field at all: a limit is a
/// caller-supplied constant, a budget decrements as the frame runs.
pub const ExecutionGas = struct {
    regular_left: u64,
    reservoir: u64 = 0,

    /// Scope-opening gas for a transaction included without payload execution.
    pub const none: ExecutionGas = .{ .regular_left = 0 };

    pub fn legacy(regular_left: u64) ExecutionGas {
        return .{ .regular_left = regular_left };
    }
};
