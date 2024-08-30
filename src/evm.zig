pub const address = @import("./address.zig");
pub const intrepreter = @import("./interpreter.zig");
pub const instruction = @import("./instruction.zig");
pub const t = @import("./t.zig");
pub const Host = @import("./Host.zig");
pub const easm = @import("./easm.zig");
const opcode = @import("./opcode.zig");
pub const Opcode = opcode.Opcode;
pub const Address = address.Address;
pub const addr = address.addr;

pub const Bytes = []u8;
pub const Hash = [32]u8; // or u256

pub const empty_code_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

pub fn calcWordSize(comptime T: type, size: T) T {
    return @divFloor(size + 31, 32);
}

pub const Spec = spec.Spec;
pub const spec = @import("./spec.zig");

pub fn EvmFromSpec(evm_spec: Spec) type {
    const instruction_table = instruction.InstructionTable(evm_spec);
    const Intrepreter = intrepreter.Interpreter(instruction_table);
    return Intrepreter;
}

pub const Evm = EvmFromSpec(.cancun);
