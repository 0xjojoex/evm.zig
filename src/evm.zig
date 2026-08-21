//! evmz — a composable EVM execution engine.
//!
//! The public surface has three tiers of "something to execute", matching
//! Ethereum's own ontology; each tier strips concerns the next never sees:
//!
//! - `Transaction` — what a user submits: the unvalidated protocol object,
//!   carrying fees, access lists, and authorizations. Run it with
//!   `Vm.transact`, which owns the lifecycle: validation, intrinsic gas,
//!   warm sets, fee accounting, receipts.
//! - `Message` — what the EVM runs once transaction accounting is stripped:
//!   the root `call | create` identity. Run it with
//!   `Executor.executeMessage` inside an open scope, or `executeStandalone`
//!   for the managed lifecycle. The union lives at this tier
//!   only, because this is where call and create still disagree (init code
//!   and salt, computed vs given recipient).
//! - `Host.Message` — engine-internal: the sub-computation request one call
//!   frame runs, flat because preparation already resolved everything the
//!   root tier's union expresses.
//!
//! `Vm(spec)` compiles one exact engine per specification; `Evm` is the
//! ready-to-use latest-Ethereum engine.

const std = @import("std");

pub const address = @import("./address.zig");
pub const block = @import("./block.zig");
pub const BlockHashSource = @import("./BlockHashSource.zig");
pub const code = @import("./code.zig");
pub const crypto = @import("./crypto.zig");
pub const eth = @import("./eth.zig");
pub const execution = @import("./execution.zig");
pub const execution_resources = execution.resources;
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
/// Coherent Ethereum execution-state and block-lifecycle choices.
pub const state_domain = @import("./eth/state_domain.zig");
pub const stateless = @import("./stateless.zig");
pub const Backend = @import("./backend.zig").Backend;
pub const t = @import("./t.zig");
pub const trace = @import("./trace.zig");
pub const transaction = @import("./transaction.zig");
pub const uint256 = @import("./uint256.zig");
const vm = @import("./vm.zig");

/// Compile one complete exact engine specification.
pub const Vm = vm.Vm;
pub const VmWithOptions = vm.VmWithOptions;
pub const VmType = vm.VmType;
pub const Engine = vm.Engine;
pub const EngineWithOptions = vm.EngineWithOptions;
pub const EngineType = vm.EngineType;
pub const BalStatelessEngine = vm.BalStatelessEngine;
pub const BalStatelessEngineWithOptions = vm.BalStatelessEngineWithOptions;
pub const BalStatelessVm = vm.BalStatelessVm;
pub const BalStatelessVmWithOptions = vm.BalStatelessVmWithOptions;

/// The latest exact Ethereum engine — the usual ready-to-use entry point.
pub const Evm = Vm(eth.latest);

// Commonly-used types are flat-aliased here for ergonomics.
pub const addr = address.addr;
pub const Address = address.Address;
pub const AddressWord = address.AddressWord;
pub const Bytecode = code.Bytecode;
pub const Spec = spec.Spec;
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
pub const RootProvider = state.RootProvider;
pub const StateReader = vm.StateReader;
pub const Transaction = Evm.Transaction;
pub const Executed = Evm.Executed;
pub const Outcome = Evm.Outcome;
pub const TxStatus = vm.TxStatus;
pub const TxExecutionResult = vm.TxExecutionResult;
pub const AccountView = vm.AccountView;
pub const BlockResult = vm.BlockResult;
pub const AfterTransactionContext = vm.AfterTransactionContext;
pub const FinalizeBlockContext = vm.FinalizeBlockContext;

test {
    std.testing.refAllDecls(@This());
    _ = @import("./test.zig");
}
