//! Ethereum sequential block program for one transaction runtime.
//!
//! The VM-owned block binder owns executor claims and retain/discard. This
//! module owns Ethereum inclusion accounting and the journaled
//! before-transaction system-call prelude.

const std = @import("std");

const address = @import("../address.zig");
const executor = @import("../executor.zig");

/// Build Ethereum's block fold implementation and transaction prelude for one
/// bound transaction runtime.
pub fn bind(
    comptime TransactionRuntime: type,
    comptime Environment: type,
    comptime IncludedTransaction: type,
    comptime BlockResult: type,
) type {
    const Transaction = TransactionRuntime.Transaction;
    const TransactionInput = TransactionRuntime.TransactInput;
    const TransactionOutput = TransactionRuntime.Output;
    const TransactionLogs = TransactionRuntime.TransactionLogs;

    const BeforeTransactionPrelude = struct {
        env: Environment,
        transaction_index: u64,

        pub fn run(
            self: *@This(),
            prelude: TransactionRuntime.PreludeContext,
        ) TransactionRuntime.PreludeContext.Error!void {
            try executor.system_contracts.applyBeforeTransactionPrelude(
                prelude,
                self.env.txContext(address.addr(0), 0, self.env.gas_limit, &.{}),
                .{
                    .number = self.env.number,
                    .timestamp = self.env.timestamp,
                    .transaction_index = self.transaction_index,
                },
            );
        }
    };

    const ImplementationType = struct {
        pub const State = BlockResult;
        pub const Error = error{ BlockGasExceeded, Overflow };
        pub const PreludeError = error{};
        pub const InclusionPlan = struct { next: State };

        pub fn init(_: Environment) State {
            return .{};
        }

        pub fn transactInput(
            env: *const Environment,
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
            env: *const Environment,
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

        pub fn finish(_: *const Environment, state: *const State) BlockResult {
            return state.*;
        }
    };

    return struct {
        pub const Prelude = BeforeTransactionPrelude;
        pub const Implementation = ImplementationType;
    };
}
