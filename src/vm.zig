//! Exact-spec EVM compiler.
//!
//! `Vm(spec)` closes every semantic choice at comptime. Runtime fork selection
//! belongs to the caller; no revision state enters the generated VM.

const std = @import("std");

const block_hash_source = @import("./BlockHashSource.zig");
const block_program_module = @import("./block_program.zig");
const engine_spec = @import("./spec.zig");
const ethereum_block_execution = @import("./vm/block_execution.zig");
const executor_module = @import("./executor.zig");
const execution = @import("./execution.zig");
const Host = @import("./Host.zig");
const interpreter = @import("./Interpreter.zig");
const state_domain = @import("./eth/state_domain.zig");
const transaction = @import("./transaction.zig");
const transaction_result = @import("./transaction/result.zig");

pub const StateReader = executor_module.state_io.StateReader;
pub const BlockHashSource = block_hash_source;
pub const Committer = executor_module.state_io.Committer;
pub const Log = Host.Log;

/// Block/environment values supplied by the caller.
///
/// The engine has exactly one of these. Transaction preparation reads the same
/// type the caller fills in, so there is nothing to copy between the two.
pub const Env = transaction.Env;

/// Terminal status of a transaction that reached execution.
pub const TxStatus = execution.Status;

/// Complete `Vm.transact` error surface, declared concretely so tooling can
/// resolve `Vm.Error` without evaluating the program binder.
pub const TransactError = executor_module.errors.Error || error{Overflow};

/// Caller input for one Ethereum family transaction. One shared definition
/// serves every compiled VM; each VM re-exports it as `TransactInput`.
const FamilyTransactInput = struct {
    env: Env,
    tx: transaction.Transaction,
    progress: transaction.PreparationBlockProgress = .{},
};

pub const TxExecutionResult = transaction_result.Execution;
pub const TxReceiptView = transaction_result.Receipt;

pub const BlockResult = ethereum_block_execution.Result;

/// Read-only account view borrowed from an Executor overlay/state-reader cache.
pub const AccountView = struct {
    nonce: u64,
    balance: u256,
    code: []const u8 = &.{},
};

pub const Call = executor_module.Call;
pub const Create = executor_module.Create;
pub const Result = executor_module.Result;
pub const CompileOptions = executor_module.CompileOptions;

pub const AfterTransactionContext = block_program_module.AfterTransactionContext;
pub const FinalizeBlockContext = block_program_module.FinalizeBlockContext;

/// Compile one complete exact specification into its concrete VM type.
/// Runtime fork selection belongs outside this boundary.
pub fn Vm(comptime spec: engine_spec.Spec) type {
    return VmWithOptions(spec, .{});
}

/// Compile the exact execution engine used to author a transaction family.
/// `Vm(spec)` adds Ethereum's transaction program and runtime storage.
pub fn Engine(comptime spec: engine_spec.Spec) type {
    return EngineWithOptions(spec, .{});
}

pub fn EngineWithOptions(
    comptime spec: engine_spec.Spec,
    comptime options_value: CompileOptions,
) type {
    return EngineType(spec, state_domain.Tracked.Execution, options_value);
}

pub fn VmWithOptions(comptime spec: engine_spec.Spec, comptime options_value: CompileOptions) type {
    return VmType(spec, state_domain.Tracked, options_value);
}

pub fn BalStatelessVm(comptime spec: engine_spec.Spec) type {
    return BalStatelessVmWithOptions(spec, .{});
}

pub fn BalStatelessEngine(comptime spec: engine_spec.Spec) type {
    return BalStatelessEngineWithOptions(spec, .{});
}

pub fn BalStatelessEngineWithOptions(
    comptime spec: engine_spec.Spec,
    comptime options_value: CompileOptions,
) type {
    return EngineType(spec, state_domain.BalStateless.Execution, options_value);
}

pub fn BalStatelessVmWithOptions(
    comptime spec: engine_spec.Spec,
    comptime options_value: CompileOptions,
) type {
    return VmType(spec, state_domain.BalStateless, options_value);
}

pub fn VmType(
    comptime specification: engine_spec.Spec,
    comptime StateDomainType: type,
    comptime options_value: CompileOptions,
) type {
    return struct {
        const Self = @This();
        pub const spec = specification;
        pub const compile_options = options_value;

        const ExactEngine = EngineType(spec, StateDomainType.Execution, options_value);
        const Family = ExactEngine.EthereumTransition(FamilyTransactInput);
        const Program = ExactEngine.Program(
            FamilyTransactInput,
            TxExecutionResult,
            transaction.validation.ValidationError,
            TransactError,
            Family,
        );
        const BlockExecutionType = ethereum_block_execution.ExecutionType(Program);
        // pub const compile_options = options_value;
        pub const StateDomain = StateDomainType;
        pub const Executor = ExactEngine.Executor;
        pub const Init = Executor.Init;
        pub const Interpreter = interpreter.Interpreter(spec);
        pub const Transaction = transaction.Transaction;
        pub const TransactInput = FamilyTransactInput;
        pub const Output = TxExecutionResult;
        pub const Rejection = transaction.validation.ValidationError;
        pub const Executed = Executor.Executed(TxExecutionResult);
        pub const Outcome = transaction.program.TransactOutcomeType(Executed, Rejection);
        pub const Error = TransactError;
        pub const BlockExecution = BlockExecutionType;

        /// Executor-level entry points for callers that manage the Executor
        /// themselves (BlockSTF, differential lanes). Same ownership contract
        /// as the method forms below.
        pub const Advanced = struct {
            pub const transact = Program.transact;
            pub const observe = Program.observe;
            pub const capture = Program.capture;
        };

        executor: Executor,

        pub fn init(allocator: std.mem.Allocator, options: Init) Self {
            return .{ .executor = Executor.init(allocator, options) };
        }

        pub fn deinit(self: *Self) void {
            self.executor.deinit();
        }

        /// Execute one Ethereum transaction.
        ///
        /// Rejection changes no state. Completion returns the sole
        /// rollback-armed `Executed` owner, which the caller must retain or
        /// discard before reusing this VM.
        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return Program.transact(&self.executor, input);
        }

        /// Borrow a transaction facade that records state observations.
        pub fn observe(self: *Self) Program.Instrumented {
            return Program.observe(&self.executor);
        }

        /// Borrow a transaction facade bound to caller-owned capture storage.
        pub fn capture(
            self: *Self,
            context: *executor_module.CaptureContext,
        ) Program.Instrumented {
            return Program.capture(&self.executor, context);
        }
    };
}

/// Compile one exact execution engine. Every transaction-layer type derives
/// from this root instead of accepting the same dependency in several forms.
pub fn EngineType(
    comptime spec: engine_spec.Spec,
    comptime ExecutionState: type,
    comptime compile_options: CompileOptions,
) type {
    return struct {
        pub const Executor = executor_module.ExecutorType(spec, ExecutionState, compile_options);

        pub fn Context(comptime Input: type) type {
            return transaction.program.ContextType(
                spec,
                ExecutionState,
                compile_options,
                Input,
            );
        }

        pub fn EthereumTransition(comptime Input: type) type {
            return transaction.transition.ImplType(
                spec,
                ExecutionState,
                compile_options,
                Input,
            );
        }

        pub fn Program(
            comptime Input: type,
            comptime Output: type,
            comptime Rejection: type,
            comptime Error: type,
            comptime Family: type,
        ) type {
            return transaction.program.ProgramType(
                spec,
                ExecutionState,
                compile_options,
                Input,
                Output,
                Rejection,
                Error,
                Family,
            );
        }
    };
}
