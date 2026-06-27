const std = @import("std");

pub const address = @import("./address.zig");
pub const Interpreter = @import("./Interpreter.zig");
pub const Config = @import("./Config.zig");
pub const code = struct {
    pub const Analysis = @import("./code/Analysis.zig");
    pub const JumpDestMap = @import("./code/JumpDestMap.zig");
    pub const State = @import("./code/State.zig");
};
pub const JumpDestMap = code.JumpDestMap;
pub const CodeAnalysis = code.Analysis;
pub const CodeAnalysisState = code.State;
pub const instruction = @import("./instruction.zig");
pub const t = @import("./t.zig");
pub const Host = @import("./Host.zig");
pub const easm = @import("./easm.zig");
pub const precompile = @import("./precompile.zig");
pub const transaction = @import("./transaction.zig");
pub const transaction_envelope = @import("./transaction_envelope.zig");
pub const uint256 = @import("./uint256.zig");
pub const rlp = @import("./rlp.zig");
pub const state = @import("./state.zig");
pub const Executor = @import("./Executor.zig");
pub const c_api = struct {
    pub const common = @import("./c_api/common.zig");
    pub const evmc = common.evmc;
    pub const host2c = @import("./c_api/host2c.zig");
};
const opcode = @import("./opcode.zig");

pub const Opcode = opcode.Opcode;
pub const Address = address.Address;
pub const addr = address.addr;

pub const empty_code_hash = 0xc5d2460186f7233c927e7db2dcc703c0e500b653ca82273b7bfad8045d85a470;

pub fn calcWordSize(comptime T: type, size: T) T {
    return @divFloor(size + 31, 32);
}

pub const Spec = spec.Spec;
pub const spec = @import("./spec.zig");

test {
    std.testing.refAllDecls(@This());
}
