const std = @import("std");

pub const address = @import("./address.zig");
pub const BlockHashSource = @import("./BlockHashSource.zig");
pub const c_api = @import("./c_api.zig");
pub const code = @import("./code.zig");
pub const crypto = @import("./crypto.zig");
pub const definition = @import("./definition.zig");
pub const easm = @import("./easm.zig");
pub const eth = @import("./eth.zig");
pub const execution = @import("./execution.zig");
pub const ExecutionConfig = @import("./ExecutionConfig.zig");
pub const executor = @import("./executor.zig");
pub const fixed_buffer_meter = @import("./fixed_buffer_meter.zig");
pub const Host = @import("./Host.zig");
pub const instruction = @import("./instruction.zig");
pub const interpreter = @import("./Interpreter.zig");
pub const mpt = @import("./mpt.zig");
pub const opcode = @import("./opcode.zig");
pub const precompile = @import("./precompile.zig");
pub const prepared_code = @import("./prepared_code.zig");
pub const protocol = @import("./protocol.zig");
pub const rlp = @import("./rlp.zig");
pub const state = @import("./state.zig");
pub const stateless = @import("./stateless.zig");
pub const t = @import("./t.zig");
pub const trace = @import("./trace.zig");
pub const transaction = @import("./transaction.zig");
pub const uint256 = @import("./uint256.zig");
pub const vm = @import("./vm.zig");

/// Compose a concrete VM type from a Definition and typed options.
pub const Vm = vm.Vm;
/// The Ethereum-mainnet VM — the usual ready-to-use entry point.
pub const Evm = Vm(eth.Revision, eth.definition, .{});

/// Derive an Ethereum VM with typed support and dispatch options.
pub fn EvmWith(comptime options: vm.OptionsFor(eth.definition)) type {
    return Vm(eth.Revision, eth.definition, options);
}

// Commonly-used types are flat-aliased here for ergonomics.
pub const addr = address.addr;
pub const Address = address.Address;
pub const Bytecode = code.Bytecode;
pub const Committer = vm.Committer;
pub const Definition = definition.Definition;
pub const eip7702 = executor.eip7702;
pub const Env = vm.Env;
pub const Executor = Evm.Executor;
pub const Interpreter = Evm.Interpreter;
pub const Log = vm.Log;
pub const Message = execution.Message;
pub const Opcode = opcode.Opcode;
pub const OpcodeInfo = opcode.OpInfo;
pub const PreparedCodeBackend = prepared_code.Backend;
pub const InMemoryPreparedPool = prepared_code.InMemoryPreparedPool;
pub const RevisionConfig = definition.RevisionConfig;
pub const RevisionModel = definition.RevisionModel;
pub const StateReader = vm.StateReader;
pub const Transaction = Evm.Transaction;
pub const PendingTransaction = Evm.PendingTransaction;
pub const TransactResult = Evm.TransactResult;
pub const TxResult = Evm.TxResult;
pub const TxStatus = Evm.TxStatus;

/// Number of 32-byte EVM words spanning `size` bytes (rounded up).
pub fn calcWordSize(comptime T: type, size: T) T {
    return @divFloor(size + 31, 32);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("./eth/config.zig");
    _ = @import("./test.zig");
}
