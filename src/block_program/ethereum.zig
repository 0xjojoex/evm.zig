//! Ethereum sequential block program for one transaction runtime.
//!
//! The VM-owned block binder owns executor claims and retain/discard. This
//! module owns Ethereum inclusion accounting, the receipt/included shapes,
//! and the journaled before-transaction system-call prelude.

const std = @import("std");

const address = @import("../address.zig");
const execution = @import("../execution.zig");
const executor = @import("../executor.zig");
const transaction = @import("../transaction.zig");

/// Summary of included transactions in an Ethereum block fold.
pub const Result = struct {
    /// Cumulative receipt gas.
    gas_used: u64 = 0,
    /// Cumulative block/header gas contribution.
    block_gas: transaction.BlockGas = .{},
    tx_count: u64 = 0,
};

/// Build Ethereum's block fold implementation for one bound transaction
/// runtime. Every carrier is read off the runtime; the block environment is
/// the concrete Ethereum `Env` carried by the input. The standard
/// before-transaction prelude and receipt shape ride as decls.
pub fn ImplType(comptime TransactionRuntime: type) type {
    const EnvType = transaction.Env;
    comptime std.debug.assert(@FieldType(TransactionRuntime.TransactInput, "env") == EnvType);
    const Transaction = TransactionRuntime.Transaction;
    const TransactionInput = TransactionRuntime.TransactInput;
    const TransactionOutput = TransactionRuntime.Output;
    const TransactionLogs = TransactionRuntime.TransactionLogs;

    // Borrowed per-transaction receipt; `logs` is valid only while the
    // owning execution scope stays unresolved.
    const ReceiptType = struct {
        status: execution.Status,
        gas_used: u64 = 0,
        cumulative_gas_used: u64 = 0,
        created_address: ?address.Address = null,
        logs: TransactionLogs = .empty,
    };

    const IncludedTransaction = struct {
        result: TransactionOutput,
        receipt: ReceiptType,
    };

    const BeforeTransactionPrelude = struct {
        env: EnvType,
        transaction_index: u64,

        pub fn run(
            self: *@This(),
            prelude: TransactionRuntime.PreludeContext,
        ) TransactionRuntime.PreludeContext.Error!void {
            try executor.system_contracts.applyBeforeTransactionPrelude(
                prelude,
                self.env.executionContext(.{ .origin = address.addr(0) }),
                .{
                    .number = self.env.number,
                    .timestamp = self.env.timestamp,
                    .transaction_index = self.transaction_index,
                },
            );
        }
    };

    const FoldResult = Result;

    return struct {
        // Carrier decls the block binder reads; init/included/finish
        // signatures are welded to them by the binder's validation.
        pub const Env = EnvType;
        pub const Included = IncludedTransaction;
        pub const Result = FoldResult;
        pub const Receipt = ReceiptType;
        pub const Prelude = BeforeTransactionPrelude;

        pub const State = FoldResult;
        pub const Error = error{ BlockGasExceeded, Overflow };
        pub const PreludeError = error{};
        pub const InclusionPlan = struct { next: State };

        pub fn init(_: Env) State {
            return .{};
        }

        pub fn transactInput(
            env: *const Env,
            state: *const State,
            tx_value: *const Transaction,
        ) TransactionInput {
            return .{
                .env = env.*,
                .tx = tx_value.*,
                .progress = .{
                    .receipt_gas_used = state.gas_used,
                    .block_gas = state.block_gas,
                },
            };
        }

        pub fn planInclude(
            env: *const Env,
            state: *const State,
            _: *const Transaction,
            output: *const TransactionOutput,
            _: TransactionLogs,
        ) Error!InclusionPlan {
            var next = state.*;
            next.gas_used = std.math.add(u64, next.gas_used, output.gas.used) catch return error.BlockGasExceeded;
            next.block_gas = next.block_gas.add(output.gas.block) catch return error.BlockGasExceeded;
            if (!next.block_gas.withinLimit(env.gas_limit)) return error.BlockGasExceeded;
            next.tx_count = std.math.add(u64, next.tx_count, 1) catch return error.Overflow;
            return .{ .next = next };
        }

        pub fn included(
            _: *const Transaction,
            output: *const TransactionOutput,
            logs: TransactionLogs,
            plan: InclusionPlan,
        ) IncludedTransaction {
            return .{
                .result = output.*,
                .receipt = .{
                    .status = output.status,
                    .gas_used = output.gas.used,
                    .cumulative_gas_used = plan.next.gas_used,
                    .created_address = output.created_address,
                    .logs = logs,
                },
            };
        }

        pub fn applyInclude(state: *State, plan: InclusionPlan) void {
            state.* = plan.next;
        }

        pub fn finish(_: *const Env, state: *const State) FoldResult {
            return state.*;
        }
    };
}
