//! Concrete instruction-table values consumed by an exact VM.

const std = @import("std");
const execution = @import("../execution.zig");
const opcode_info = @import("../opcode.zig");

const Opcode = opcode_info.Opcode;
const OpInfo = opcode_info.OpInfo;

pub const Target = union(enum) {
    invalid,
    builtin,
    /// The interpreter charges `Entry.info.static_gas` before calling
    /// `Handler.execute(spec, frame)`; the handler owns dynamic gas and behavior.
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
    /// Explicit family-local identity. Ethereum names derive from `Opcode`;
    /// custom definitions retain their open literal only at comptime.
    name: ?@EnumLiteral() = null,
    info: OpInfo,
    active: bool,
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

    pub fn fmt(comptime self: Spec, opcode_byte: u8) Formatter(self) {
        return .{ .opcode_byte = opcode_byte };
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
        inline for (opcodes) |opcode| self.table[@intFromEnum(opcode)].info.static_gas = gas;
    }

    /// Change dispatch for one byte while keeping its activation and metadata.
    /// `.builtin` restores that byte's canonical builtin behavior.
    pub fn setTarget(self: *Spec, opcode_byte: u8, comptime target: Target) void {
        self.table[opcode_byte].target = target;
    }

    /// Install a complete fork-new instruction on any byte — typically an
    /// unassigned one. Installation cannot change bytecode framing: jumpdest
    /// analysis and disassembly skip only PUSH immediates, regardless of the
    /// table. A custom instruction needing an operand must read it from the
    /// code stream in its handler and keep the operand encoding outside
    /// 0x5b..0x7f (EIP-8024-style) so the byte never aliases JUMPDEST or a
    /// PUSH.
    pub fn install(
        self: *Spec,
        comptime name: @EnumLiteral(),
        comptime opcode_byte: u8,
        comptime info: OpInfo,
        comptime target: Target,
    ) void {
        assertNameAvailable(self.*, name, opcode_byte);
        var defined_info = info;
        defined_info.defined = true;
        const slot = &self.table[opcode_byte];
        slot.* = .{
            .name = name,
            .info = defined_info,
            .active = true,
            .target = target,
        };
    }

    pub fn codeAccountAccessGas(comptime self: Spec, status: execution.AccessStatus) ?i64 {
        return switch (status) {
            .cold => self.code_account_cold_access_gas,
            .warm => self.code_account_warm_access_gas,
        };
    }
};

fn Formatter(comptime spec: Spec) type {
    return struct {
        opcode_byte: u8,

        pub fn format(self: @This(), writer: *std.Io.Writer) std.Io.Writer.Error!void {
            return switch (self.opcode_byte) {
                inline 0...255 => |opcode_byte| {
                    if (comptime spec.table[opcode_byte].name) |name| {
                        return writer.writeAll(@tagName(name));
                    }
                    return @as(Opcode, @enumFromInt(opcode_byte)).format(writer);
                },
            };
        }
    };
}

fn assertNameAvailable(comptime spec: Spec, comptime name: @EnumLiteral(), comptime opcode_byte: u8) void {
    @setEvalBranchQuota(10_000);
    if (std.meta.stringToEnum(Opcode, @tagName(name))) |opcode| {
        if (@intFromEnum(opcode) != opcode_byte) {
            @compileError("instruction name already belongs to opcode byte: " ++ @tagName(name));
        }
    }
    for (spec.table, 0..) |entry, index| {
        if (index == opcode_byte) continue;
        if (entry.name) |existing| {
            if (existing == name) {
                @compileError("duplicate custom instruction name: " ++ @tagName(name));
            }
        }
    }
}

pub fn validate(comptime table: Table) void {
    // Covers evaluating the full fork-derivation chain when this forces it.
    @setEvalBranchQuota(100_000);
    for (table, 0..) |entry, source_index| {
        std.debug.assert(!entry.active or entry.defined());
        entry.target.assertValid();
        switch (entry.target) {
            .builtin => {
                const opcode_byte: u8 = @intCast(source_index);
                const canonical = opcode_info.info(opcode_byte);
                std.debug.assert(canonical.defined);
                std.debug.assert(entry.info.stack_in >= canonical.stack_in);
            },
            .invalid, .custom => {},
        }
    }
}
