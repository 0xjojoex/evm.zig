const std = @import("std");

pub const address = @import("./address.zig");
pub const BlockHashSource = @import("./BlockHashSource.zig");
pub const code = @import("./code.zig");
pub const crypto = @import("./crypto.zig");
pub const eth = @import("./eth.zig");
pub const execution = @import("./execution.zig");
pub const execution_resources = @import("./execution_resources.zig");
pub const ExecutionConfig = @import("./ExecutionConfig.zig");
pub const executor = @import("./executor.zig");
pub const fixed_buffer_meter = @import("./fixed_buffer_meter.zig");
pub const Host = @import("./Host.zig");
pub const instruction = @import("./instruction.zig");
pub const interpreter = @import("./Interpreter.zig");
pub const mpt = @import("mpt");
pub const opcode = @import("./opcode.zig");
pub const precompile = @import("./precompile.zig");
pub const prepared_code = @import("./prepared_code.zig");
pub const rlp = @import("rlp");
pub const spec = @import("./spec.zig");
pub const state = @import("./state.zig");
pub const stateless = @import("./stateless.zig");
pub const t = @import("./t.zig");
pub const trace = @import("./trace.zig");
pub const transaction = @import("./transaction.zig");
pub const uint256 = @import("./uint256.zig");
const vm = @import("./vm.zig");

/// Compile one complete exact engine specification.
pub const Vm = vm.Vm;

/// The latest exact Ethereum engine — the usual ready-to-use entry point.
pub const Evm = Vm(eth.latest);

// Commonly-used types are flat-aliased here for ergonomics.
pub const addr = address.addr;
pub const Address = address.Address;
pub const Bytecode = code.Bytecode;
pub const Committer = vm.Committer;
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
pub const ExecutionResourcePlan = execution_resources.Plan;
pub const ExecutionResourcePreparer = execution_resources.Preparer;
pub const StateReader = vm.StateReader;
pub const ConcurrentStateReader = state.ConcurrentReader;
pub const ConcurrentBlockHashSource = BlockHashSource.Concurrent;
pub const Transaction = Evm.Transaction;
pub const Executed = Evm.Executed;
pub const Outcome = Evm.Outcome;
pub const TxStatus = Evm.TxStatus;
pub const TxExecutionResult = vm.TxExecutionResult;
pub const AccountView = vm.AccountView;
pub const BlockResult = vm.BlockResult;
pub const AfterTransactionContext = vm.AfterTransactionContext;
pub const FinalizeBlockContext = vm.FinalizeBlockContext;

/// Number of 32-byte EVM words spanning `size` bytes (rounded up).
pub fn calcWordSize(comptime T: type, size: T) T {
    return @divFloor(size + 31, 32);
}

test {
    std.testing.refAllDecls(@This());
    _ = @import("./test.zig");
}
