const execution = @import("execution.zig");
const types = @import("types.zig");
const opcode_info = @import("../opcode.zig");
const support = @import("support.zig");

pub const AccountAccessStatus = types.AccountAccessStatus;

pub const Context = union(enum) {
    byte: u8,
    custom: struct {
        first_byte: u8,
    },

    pub fn firstByte(self: Context) u8 {
        return switch (self) {
            .byte => |opcode_byte| opcode_byte,
            .custom => |custom| custom.first_byte,
        };
    }

    pub fn inheritedByte(self: Context) ?u8 {
        return switch (self) {
            .byte => |opcode_byte| opcode_byte,
            .custom => null,
        };
    }
};

pub fn Value(comptime Definition: type) type {
    return Definition.Instruction.Value;
}

pub fn fromByte(comptime Definition: type, comptime opcode_byte: u8) Value(Definition) {
    return Definition.Instruction.fromByte(opcode_byte);
}

pub fn context(comptime Definition: type, comptime value: Value(Definition)) Context {
    return Definition.Instruction.context(value);
}

pub fn info(comptime Definition: type, comptime value: Value(Definition)) opcode_info.OpInfo {
    return Definition.Instruction.info(value);
}

pub fn availability(comptime Definition: type, comptime value: Value(Definition)) Definition.Availability {
    return Definition.Instruction.availability(value);
}

pub fn tier(comptime Definition: type, comptime value: Value(Definition)) support.OpcodeTier {
    return Definition.Instruction.tier(value);
}

pub fn executionTarget(comptime Definition: type, comptime value: Value(Definition)) execution.ExecutionTarget {
    return Definition.Instruction.executionTarget(value);
}

pub fn For(comptime Definition: type, comptime support_window: Definition.Support) type {
    const ValueType = Value(Definition);
    const ContextType = Context;
    return struct {
        pub const Value = ValueType;
        pub const Context = ContextType;

        pub fn fromByte(comptime opcode_byte: u8) ValueType {
            return Definition.Instruction.fromByte(opcode_byte);
        }

        pub fn context(comptime value: ValueType) ContextType {
            return Definition.Instruction.context(value);
        }

        pub fn info(comptime value: ValueType) opcode_info.OpInfo {
            return Definition.Instruction.info(value);
        }

        pub fn rawAvailability(comptime value: ValueType) Definition.Availability {
            return Definition.Instruction.availability(value);
        }

        pub fn availability(comptime value: ValueType) support.Resolution {
            return Definition.resolveAvailability(rawAvailability(value), support_window);
        }

        pub fn tier(comptime value: ValueType) support.OpcodeTier {
            return Definition.Instruction.tier(value);
        }

        pub fn executionTarget(comptime value: ValueType) execution.ExecutionTarget {
            return Definition.Instruction.executionTarget(value);
        }

        pub fn expByteGas(revision: Definition.Revision) i64 {
            return Definition.Instruction.expByteGas(revision);
        }

        pub fn accountReadColdAccessGas(revision: Definition.Revision) ?i64 {
            return Definition.Instruction.accountReadColdAccessGas(revision);
        }

        pub fn codeAccountAccessGas(revision: Definition.Revision, status: AccountAccessStatus) ?i64 {
            return Definition.Instruction.codeAccountAccessGas(revision, status);
        }
    };
}
