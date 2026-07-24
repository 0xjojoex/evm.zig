pub const evmz = @import("../evm.zig");
pub const address = @import("../address.zig");
pub const executor_module = @import("../executor.zig");
pub const interpreter_module = @import("../Interpreter.zig");
pub const system = @import("../eth/system.zig");
pub const transaction = @import("../transaction.zig");
const vm_module = @import("../vm.zig");

pub const Default = evmz.Evm;
pub const EthValidationError = Default.Rejection;
pub const addr = address.addr;
pub const BlockHashSource = vm_module.BlockHashSource;
pub const BlockResult = vm_module.BlockResult;
pub const Call = vm_module.Call;
pub const Committer = vm_module.Committer;
pub const Create = vm_module.Create;
pub const Env = vm_module.Env;
pub const Log = vm_module.Log;
pub const MemoryStore = evmz.state.MemoryStore;
pub const SystemCall = vm_module.SystemCall;
pub const TxExecutionResult = vm_module.TxExecutionResult;
pub const TxStatus = vm_module.TxStatus;

pub fn transact(
    comptime ExactVm: type,
    executor: *ExactVm.Executor,
    input: ExactVm.TransactInput,
) ExactVm.Error!ExactVm.Outcome {
    var runtime = ExactVm.init(executor);
    return runtime.transact(input);
}

pub fn expectExecuted(result: anytype) !TxExecutionResult {
    if (comptime @hasField(@TypeOf(result), "executed")) {
        return switch (result) {
            .executed => |executed| try executed.retainResult(),
            .rejected => error.UnexpectedRejection,
        };
    }
    @compileError("unsupported transaction result type");
}

pub fn expectRejected(result: anytype) !EthValidationError {
    if (comptime @hasField(@TypeOf(result), "included")) {
        return switch (result) {
            .included => error.UnexpectedExecution,
            .rejected => |err| err,
        };
    }
    if (comptime @hasField(@TypeOf(result), "executed")) {
        return switch (result) {
            .executed => |value| blk: {
                const executed = value;
                defer executed.discardIfCurrent();
                break :blk error.UnexpectedExecution;
            },
            .rejected => |err| err,
        };
    }
    @compileError("unsupported transaction result type");
}
