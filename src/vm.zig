//! Exact-spec EVM compiler.
//!
//! `Vm(spec)` closes every semantic choice at comptime. Runtime fork selection
//! belongs to the caller; no revision state enters the generated VM.

const std = @import("std");

const address = @import("./address.zig");
const block_hash_source = @import("./BlockHashSource.zig");
const block_program_module = @import("./block_program.zig");
const engine_spec = @import("./spec.zig");
const ethereum_block_program = @import("./block_program/ethereum.zig");
const executor_module = @import("./executor.zig");
const execution = @import("./execution.zig");
const Host = @import("./Host.zig");
const interpreter = @import("./Interpreter.zig");
const state_module = @import("./state.zig");
const block_state = @import("./vm/block_state.zig");
const transaction = @import("./transaction.zig");

const Address = address.Address;

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
/// resolve `Vm.Error` without evaluating the program binder. Welded to the
/// derived program error set inside `VmType`; membership drift fails compilation.
pub const TransactError = executor_module.errors.Error || error{Overflow};

/// Caller input for one Ethereum family transaction. One shared definition
/// serves every compiled VM; each VM re-exports it as `TransactInput`.
const FamilyTransactInput = struct {
    env: Env,
    tx: transaction.Transaction,
    progress: transaction.PreparationBlockProgress = .{},
};

/// Execution payload for a transaction that passed validation and ran.
///
/// `output` is borrowed from the owning Executor and remains valid until its
/// next operation can replace call output.
pub const TxExecutionResult = struct {
    status: TxStatus,
    /// Settled transaction gas: receipt gas, refund gas, and block contribution.
    gas: transaction.ResultGas = .{},
    output: []const u8 = &.{},
    created_address: ?Address = null,
};

/// Borrowed transaction receipt view for client/fixture receipt builders.
///
/// `logs` is borrowed from the owning execution scope and is valid only until
/// its next operation advances or closes that scope. Copy it when constructing
/// owned receipts.
pub const TxReceiptView = struct {
    status: TxStatus,
    /// Receipt gas for this transaction.
    gas_used: u64 = 0,
    /// Receipt cumulative gas across included transactions in this block execution.
    cumulative_gas_used: u64 = 0,
    created_address: ?Address = null,
    logs: state_module.LogBuffer.View = .empty,
};

pub const BlockResult = ethereum_block_program.Result;

/// Read-only account view borrowed from an Executor overlay/state-reader cache.
pub const AccountView = struct {
    nonce: u64,
    balance: u256,
    code: []const u8 = &.{},
};

pub const Call = executor_module.Call;
pub const Create = executor_module.Create;
pub const EvmResult = executor_module.EvmResult;
pub const CompileOptions = executor_module.CompileOptions;

pub const AfterTransactionContext = block_program_module.AfterTransactionContext;
pub const FinalizeBlockContext = block_program_module.FinalizeBlockContext;

/// Compile one complete exact specification into its concrete VM type.
/// Runtime fork selection belongs outside this boundary.
pub fn Vm(comptime spec: engine_spec.Spec) type {
    return VmWithOptions(spec, .{});
}

pub fn VmWithOptions(comptime spec: engine_spec.Spec, comptime options_value: CompileOptions) type {
    return VmType(spec, block_state.Tracked(spec), options_value);
}

pub fn BalStatelessVm(comptime spec: engine_spec.Spec) type {
    return BalStatelessVmWithOptions(spec, .{});
}

pub fn BalStatelessVmWithOptions(
    comptime spec: engine_spec.Spec,
    comptime options_value: CompileOptions,
) type {
    return VmType(spec, block_state.BalStateless, options_value);
}

pub fn VmType(
    comptime spec: engine_spec.Spec,
    comptime BlockStateType: type,
    comptime options_value: CompileOptions,
) type {
    comptime BlockStateType.checkSpec(spec);

    return struct {
        const Self = @This();

        const EthereumTxTransition = Self.Transition(FamilyTransactInput);

        const TransactionRuntime = Self.Program(EthereumTxTransition);

        const BlockExecutionType = TransactionRuntime.Block(ethereum_block_program.ImplType(TransactionRuntime));

        pub const specification = spec;
        pub const compile_options = options_value;
        pub const BlockState = BlockStateType;

        pub const Executor = executor_module.ExecutorType(spec, BlockState, options_value);
        pub const Interpreter = interpreter.Interpreter(spec);
        pub const Transaction = transaction.Transaction;
        pub const TransactionLog = Log;
        pub const TransactionLogs = TransactionRuntime.TransactionLogs;
        pub const TransactInput = FamilyTransactInput;
        pub const Output = TxExecutionResult;
        pub const Rejection = transaction.validation.ValidationError;
        pub const Executed = Executor.Executed(TxExecutionResult);
        pub const Prelude = TransactionRuntime.Prelude;
        pub const PreludeContext = TransactionRuntime.PreludeContext;
        pub const Outcome = transaction.program.TransactOutcomeType(Executed, Rejection);
        pub const Error = TransactError;

        // Public decls above are declared with directly visible arguments so
        // tooling can bind them; these welds keep them identical to what the
        // program binder derives.
        comptime {
            assertSameErrorSet(TransactError, TransactionRuntime.Error);
            std.debug.assert(Executed == TransactionRuntime.Executed);
            std.debug.assert(Outcome == TransactionRuntime.Outcome);
        }
        pub const Gas = transaction.GasRuntime(spec);
        pub const Settlement = transaction.SettlementRuntime(spec);
        pub const BlockExecution = BlockExecutionType;

        transaction_runtime: TransactionRuntime,

        /// Bind this exact VM family to one caller-owned Executor.
        ///
        /// The VM borrows the Executor and owns no independent lifecycle state.
        pub fn init(executor: *Executor) Self {
            return .{ .transaction_runtime = TransactionRuntime.init(executor) };
        }

        /// Validate and execute one family transaction.
        ///
        /// Rejection changes no state. Completion returns the sole unresolved
        /// `Executed` owner, which must be retained or discarded before the
        /// Executor can accept another transaction.
        pub fn transact(self: *Self, input: TransactInput) Error!Outcome {
            return self.transaction_runtime.transact(input);
        }

        /// Borrow a VM facade that records state observations.
        pub fn observe(self: *Self) TransactionRuntime.Instrumented {
            return self.transaction_runtime.observe();
        }

        /// Borrow a VM facade bound to caller-owned passive capture storage.
        pub fn capture(
            self: *Self,
            context: *executor_module.CaptureContext,
        ) TransactionRuntime.Instrumented {
            return self.transaction_runtime.capture(context);
        }

        /// Define the narrow family-authoring context for a custom input type.
        pub fn Context(comptime Input: type) type {
            return transaction.program.ContextType(Executor, Input);
        }

        /// Bind Ethereum transaction stage helpers to a custom input type.
        pub fn Transition(comptime Input: type) type {
            return transaction.transition.ImplType(spec, Executor, Context(Input), TxExecutionResult);
        }

        /// Bind one closed transaction workflow to this VM.
        ///
        /// All carriers are derived from the implementation's `transact`
        /// signature; its authoring context must be this VM's `Context(Input)`.
        pub fn Program(comptime ImplementationType: type) type {
            const Bound = transaction.program.ProgramType(ImplementationType);
            comptime std.debug.assert(Bound.Executor == Executor);
            return Bound;
        }
    };
}

/// Weld a concretely declared error set to its derived source of truth.
/// Both directions are checked so the declaration can neither omit nor invent.
fn assertSameErrorSet(comptime Declared: type, comptime Derived: type) void {
    const declared = @typeInfo(Declared).error_set orelse
        @compileError("declared error set must be closed");
    const derived = @typeInfo(Derived).error_set orelse
        @compileError("derived error set must be closed");
    for (declared) |member| {
        if (!errorSetContains(derived, member.name))
            @compileError("declared error '" ++ member.name ++ "' is not produced by the transaction program");
    }
    for (derived) |member| {
        if (!errorSetContains(declared, member.name))
            @compileError("derived error '" ++ member.name ++ "' is missing from the declared TransactError");
    }
}

fn errorSetContains(comptime set: []const std.builtin.Type.Error, comptime name: []const u8) bool {
    for (set) |member| {
        if (std.mem.eql(u8, member.name, name)) return true;
    }
    return false;
}
