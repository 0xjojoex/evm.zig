//! Concrete instruction-table values consumed by an exact VM.

const std = @import("std");
const execution = @import("../execution.zig");
const opcode_info = @import("../opcode.zig");

const Opcode = opcode_info.Opcode;
const OpInfo = opcode_info.OpInfo;

pub const Target = union(enum) {
    invalid,
    builtin: Opcode,
    custom: type,

    pub fn assertValid(comptime self: Target) void {
        switch (self) {
            .custom => |Handler| {
                if (!std.meta.hasFn(Handler, "execute")) {
                    @compileError("custom instruction handler must declare execute");
                }
            },
            else => {},
        }
    }
};

pub const Entry = struct {
    info: OpInfo,
    active: bool,
    static_gas: i64,
    target: Target,

    pub fn defined(self: Entry) bool {
        return self.info.defined;
    }

    pub fn dispatchTarget(self: Entry) Target {
        if (!self.active) return .invalid;
        return self.target;
    }
};

pub const Table = [256]Entry;

/// Compiled instruction configuration for one exact EVM specification.
pub const Spec = struct {
    table: Table,
    exp_byte_gas: i64,
    account_read_cold_access_gas: ?i64,
    code_account_cold_access_gas: ?i64,
    code_account_warm_access_gas: ?i64,

    pub fn entry(comptime self: Spec, comptime opcode_byte: u8) Entry {
        return self.table[opcode_byte];
    }

    // The mutation helpers below are conveniences for deriving one table
    // value from another; `table` stays a plain value and callers may
    // equally index it directly.

    pub fn activate(self: *Spec, comptime opcodes: []const Opcode) void {
        inline for (opcodes) |opcode| self.table[@intFromEnum(opcode)].active = true;
    }

    pub fn deactivate(self: *Spec, comptime opcodes: []const Opcode) void {
        inline for (opcodes) |opcode| self.table[@intFromEnum(opcode)].active = false;
    }

    /// Activate every byte in the inclusive `[first, last]` range.
    pub fn activateRange(self: *Spec, comptime first: Opcode, comptime last: Opcode) void {
        for (@intFromEnum(first)..@as(usize, @intFromEnum(last)) + 1) |opcode_byte| {
            self.table[opcode_byte].active = true;
        }
    }

    /// Reprice opcodes without touching their semantics.
    pub fn setStaticGas(self: *Spec, comptime opcodes: []const Opcode, gas: i64) void {
        inline for (opcodes) |opcode| self.table[@intFromEnum(opcode)].static_gas = gas;
    }

    /// Repoint dispatch for one byte, keeping its activation and gas.
    pub fn setTarget(self: *Spec, opcode_byte: u8, comptime target: Target) void {
        self.table[opcode_byte].target = target;
    }

    /// Install a fork-new instruction on any byte — typically an unassigned
    /// one: activates the slot, prices it, and points dispatch at `target`.
    pub fn install(self: *Spec, opcode_byte: u8, static_gas: i64, comptime target: Target) void {
        const slot = &self.table[opcode_byte];
        slot.active = true;
        slot.static_gas = static_gas;
        slot.target = target;
    }

    pub fn codeAccountAccessGas(comptime self: Spec, status: execution.AccountAccessStatus) ?i64 {
        return switch (status) {
            .cold => self.code_account_cold_access_gas,
            .warm => self.code_account_warm_access_gas,
        };
    }
};

pub fn validate(comptime table: Table) void {
    // Covers evaluating the full fork-derivation chain when this forces it.
    @setEvalBranchQuota(100_000);
    for (table) |entry| entry.target.assertValid();
}
