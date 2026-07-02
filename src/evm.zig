const std = @import("std");

pub const address = @import("./address.zig");
pub const Interpreter = @import("./Interpreter.zig");
pub const Config = @import("./Config.zig");
pub const code = @import("./code.zig");
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
pub const trace = @import("./trace.zig");
pub const executor = @import("./executor.zig");
pub const Vm = @import("./vm.zig");
pub const eip7702 = executor.eip7702;
pub const StateReader = Vm.StateReader;
pub const Env = Vm.Env;
pub const Transaction = Vm.Transaction;
pub const TxStatus = Vm.TxStatus;
pub const TxResult = Vm.TxResult;
pub const SystemCall = Vm.SystemCall;
pub const Committer = Vm.Committer;
pub const AccountView = Vm.AccountView;
pub const c_api = @import("./c_api.zig");
const opcode = @import("./opcode.zig");

pub const Bytecode = code.Bytecode;
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
    _ = @import("./test.zig");
}
