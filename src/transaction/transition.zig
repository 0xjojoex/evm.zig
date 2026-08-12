//! Ethereum transaction state transition bound above one exact specification.
//!
//! This module owns Ethereum transaction preparation, charging, authorization,
//! execution rollback, settlement, and warm-set seeding. Executor lifetime and
//! retain/discard authority remain in the generic transaction program binder.

const std = @import("std");

const address = @import("../address.zig");
const ExactSpec = @import("../spec.zig").Spec;
const execution = @import("../execution.zig");
const executor = @import("../executor.zig");
const transaction = @import("../transaction.zig");
const transaction_prepare = @import("prepare.zig");
const transaction_validation = @import("validation.zig");
const tx_settlement = @import("settlement.zig");

const Address = address.Address;

/// Build the Ethereum transaction implementation for one exact execution spec.
/// The bound Context carries the public block environment and
/// progress; `Output` is the family-facing executed transaction result.
pub fn ImplType(
    comptime spec: ExactSpec,
    comptime ExactExecutor: type,
    comptime ContextType: type,
    comptime OutputType: type,
) type {
    comptime std.debug.assert(ContextType.Executor == ExactExecutor);
    const PreparedTransaction = transaction.Prepared(tx_settlement.DefaultPlan);

    return struct {
        const Settlement = transaction.SettlementRuntime(spec);
        const authorization_spec = spec.authorization;
        const settlement_spec = spec.settlement;

        // Carrier decls the program binder reads; the `transact` signature is
        // welded to them at bind time.
        pub const Context = ContextType;
        pub const Transaction = transaction.Transaction;
        pub const Output = OutputType;
        pub const Rejection = transaction_validation.ValidationError;

        pub const Error = Context.Error || error{
            Overflow,
        };

        /// Private gas capability for Ethereum's ordered pre-execution
        /// phase. It transports the same two pools as ExecutionGas while
        /// retaining the state-gas dimensions Settlement must observe.
        const PreExecutionGas = struct {
            initial: execution.ExecutionGas,
            gas: execution.ExecutionGas,
            regular_refund: u64 = 0,
            state_spent: u64 = 0,
            state_from_regular: u64 = 0,

            fn init(gas: execution.ExecutionGas) @This() {
                return .{ .initial = gas, .gas = gas };
            }

            fn apply(self: *@This(), adjustment: transaction.AuthorizationGasAdjustment) bool {
                // The integrated Amsterdam sequence charges a new
                // authority leaf, its first write, then a new delegation.
                if (!self.chargeState(adjustment.account_state_charge)) return false;
                if (!self.chargeRegular(adjustment.account_write_charge)) return false;
                if (!self.chargeState(adjustment.delegation_state_charge)) return false;
                self.regular_refund = std.math.add(
                    u64,
                    self.regular_refund,
                    adjustment.regular_refund,
                ) catch std.math.maxInt(u64);
                return true;
            }

            fn chargeRegular(self: *@This(), amount: u64) bool {
                if (amount > self.gas.regular_left) return false;
                self.gas.regular_left -= amount;
                return true;
            }

            fn chargeState(self: *@This(), amount: u64) bool {
                const from_reservoir = @min(self.gas.reservoir, amount);
                const from_regular = amount - from_reservoir;
                if (from_regular > self.gas.regular_left) return false;
                self.gas.reservoir -= from_reservoir;
                self.gas.regular_left -= from_regular;
                self.state_spent = std.math.add(u64, self.state_spent, amount) catch std.math.maxInt(u64);
                self.state_from_regular = std.math.add(u64, self.state_from_regular, from_regular) catch std.math.maxInt(u64);
                return true;
            }

            fn foldInto(self: @This(), result: *execution.ExecutionResult) void {
                const regular_refund = std.math.cast(i64, self.regular_refund) orelse std.math.maxInt(i64);
                result.gas_refund = std.math.add(i64, result.gas_refund, regular_refund) catch std.math.maxInt(i64);
                const state_spent = std.math.cast(i64, self.state_spent) orelse std.math.maxInt(i64);
                result.state_gas_spent = std.math.add(i64, result.state_gas_spent, state_spent) catch std.math.maxInt(i64);
                const state_from_regular = std.math.cast(i64, self.state_from_regular) orelse std.math.maxInt(i64);
                result.state_gas_from_gas_left = std.math.add(
                    i64,
                    result.state_gas_from_gas_left,
                    state_from_regular,
                ) catch std.math.maxInt(i64);
            }

            fn includedOutOfGas(self: @This()) execution.ExecutionResult {
                return .{
                    .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                    .gas_left = 0,
                    .gas_refund = 0,
                    // Pre-execution rollback refills all state gas. The
                    // regular pool is consumed by the exceptional halt.
                    .gas_reservoir = std.math.cast(i64, self.initial.reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }
        };

        const AuthorizationTupleOutcome = enum {
            invalid,
            applied,
            out_of_gas,
        };

        const AuthorityState = packed struct {
            written: bool = false,
            pre_delegated_known: bool = false,
            pre_delegated: bool = false,
            delegation_set: bool = false,
        };

        const AuthorityIndex = Address.HashMap(AuthorityState);

        comptime {
            // One authorization-list lifetime owns every fact for an address.
            std.debug.assert(@bitSizeOf(AuthorityState) == 4);
            std.debug.assert(@sizeOf(AuthorityState) == 1);
        }

        fn settlementPlanner(_: *const Context) Settlement {
            return .{};
        }

        pub fn transact(
            context: *Context,
            tx_value: transaction.Transaction,
        ) Error!transaction.TransitionOutcomeType(Output, Rejection) {
            const input_value = context.input();
            const prepared = (transaction_prepare.Runtime(spec){}).prepare(.{
                .tx = tx_value,
                .env = input_value.env,
                .block = input_value.progress,
                .state = context.preparationState(),
            }) catch |err| return context.infrastructureError(err);
            return switch (prepared) {
                .rejected => |reason| .{ .rejected = reason },
                .executable => |executable| try completeExecutable(context, executable),
            };
        }

        fn completeExecutable(
            context: *Context,
            executable: PreparedTransaction,
        ) Error!transaction.TransitionOutcomeType(Output, Rejection) {
            const request = transaction.executionRequest(
                executable.scope.context,
                executable.message,
                executable.execution_gas orelse execution.ExecutionGas.none,
            );
            var initial_accounts: [1]Address = undefined;
            const initial_account_count: usize = if (spec.transaction.warms_coinbase) blk: {
                initial_accounts[0] = executable.scope.context.block.coinbase;
                break :blk 1;
            } else 0;
            const scope_init = execution.ExecutionScopeInit{
                .initial_warm_set = .{
                    .accounts = initial_accounts[0..initial_account_count],
                },
            };
            try context.beginTransaction();
            try context.runPrelude();
            try context.beginExecution(request, scope_init);
            const result = try executePrepared(context, executable);
            const created_address = if (result.status == .success) switch (executable.message) {
                .call => null,
                .create => |create| create.recipient,
            } else null;
            return .{ .completed = .{
                .status = result.status,
                .gas = result.gas,
                .output = result.output_data,
                .created_address = created_address,
            } };
        }

        fn executePrepared(
            context: *Context,
            executable: PreparedTransaction,
        ) Error!struct {
            status: execution.Status,
            gas: transaction.ResultGas,
            output_data: []const u8,
        } {
            const sender = executable.message.sender();
            const execution_gas = executable.execution_gas;
            const transaction_charged = if (execution_gas != null)
                try chargeTransactionCosts(context, sender, executable.settlement)
            else
                false;
            if (transaction_charged) {
                try context.advanceTransactionNonce(executable.message);
                try warmAccessList(context, executable.scope.access_list);
            }

            var result = execution.ExecutionResult{
                .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                .gas_left = 0,
                .gas_refund = 0,
                .output_data = &.{},
            };
            if (execution_gas) |gas| {
                if (!transaction_charged) {
                    result.outcome = .{ .status = .invalid, .cause = .insufficient_balance };
                } else {
                    const has_authorization_phase = authorization_spec.active and
                        executable.scope.authorizationCount() != 0;
                    result = if (has_authorization_phase)
                        try executeAuthorizedPayload(context, executable, gas)
                    else
                        try executePayload(context, executable, gas);
                }
            }

            const result_gas = if (transaction_charged)
                try settleTransactionCosts(context, sender, executable.settlement, result)
            else blk: {
                const settlement_planner = settlementPlanner(context);
                break :blk settlement_planner.planGas(try settlement_planner.planCosts(executable.settlement, .{
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                    .gas_reservoir = result.gas_reservoir,
                    .state_gas_spent = result.state_gas_spent,
                }));
            };
            return .{
                .status = result.outcome.status,
                .gas = result_gas,
                .output_data = result.output_data,
            };
        }

        fn executeAuthorizedPayload(
            context: *Context,
            executable: PreparedTransaction,
            initial_gas: execution.ExecutionGas,
        ) Error!execution.ExecutionResult {
            var preparation_checkpoint = context.checkpoint();
            defer preparation_checkpoint.deinit();

            var gas = PreExecutionGas.init(initial_gas);
            const authorized = try applyAuthorizationList(
                context,
                executable.scope.context.chain.chain_id,
                executable.message,
                executable.scope,
                &gas,
            );
            if (!authorized) {
                preparation_checkpoint.restore();
                return gas.includedOutOfGas();
            }
            try warmDelegatedTransactionTarget(context, executable.message);

            const outcome = try context.runPayload(transaction.executionRequest(
                executable.scope.context,
                executable.message,
                gas.gas,
            ));
            if (outcome.stage == .preparation) {
                preparation_checkpoint.restore();
                return gas.includedOutOfGas();
            }

            var result = outcome.result;
            gas.foldInto(&result);
            preparation_checkpoint.commit();
            if (!executionRolledBack(result.outcome.status)) {
                try context.finalizeState();
            }
            return result;
        }

        fn executePayload(
            context: *Context,
            executable: PreparedTransaction,
            gas: execution.ExecutionGas,
        ) Error!execution.ExecutionResult {
            const outcome = try context.runPayload(transaction.executionRequest(
                executable.scope.context,
                executable.message,
                gas,
            ));
            const result = outcome.result;
            if (!executionRolledBack(result.outcome.status)) {
                try context.finalizeState();
            }
            return result;
        }

        fn chargeTransactionCosts(
            context: *Context,
            sender: Address,
            plan: tx_settlement.DefaultPlan,
        ) !bool {
            const precharge = settlementPlanner(context).planPrecharge(plan);
            const required_balance = @max(precharge.minimum_balance, precharge.upfront_debit);
            if (required_balance == 0) return true;
            const payer = precharge.payer orelse sender;
            const payer_account = try context.accountSummary(payer) orelse return false;
            if (payer_account.balance < required_balance) return false;
            return context.subtractBalance(payer, precharge.upfront_debit);
        }

        fn settleTransactionCosts(
            context: *Context,
            sender: Address,
            plan: tx_settlement.DefaultPlan,
            result: execution.ExecutionResult,
        ) !transaction.ResultGas {
            const settlement_planner = settlementPlanner(context);
            const costs = try settlement_planner.planCosts(plan, .{
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
            });
            try context.addBalance(plan.payer orelse sender, costs.payer_refund);
            if (costs.fee_payment == 0) {
                try context.accountAccess(plan.fee_recipient);
            }
            if (costs.fee_payment == 0 and
                settlement_spec.touches_fee_recipient_on_zero_payment)
            {
                try context.touchAccount(plan.fee_recipient);
            } else {
                try context.addBalance(plan.fee_recipient, costs.fee_payment);
            }
            return settlement_planner.planGas(costs);
        }

        fn warmAccessList(
            context: *Context,
            access_list: []const transaction.AccessListEntry,
        ) !void {
            for (access_list) |entry| {
                try context.warmAccount(entry.address);
                for (entry.storage_keys) |key| {
                    try context.warmStorage(entry.address, key);
                }
            }
        }

        // TODO: perf check
        fn applyAuthorizationList(
            context: *Context,
            chain_id: u256,
            message: execution.Message,
            scope: transaction.TransactionScope,
            gas: *PreExecutionGas,
        ) !bool {
            if (!authorization_spec.active) return true;
            const allocator = try context.allocator();
            var authorities = AuthorityIndex.init(allocator);
            defer authorities.deinit();
            try markWritten(&authorities, message.sender());
            switch (message) {
                .call => |call| if (call.value != 0) try markWritten(&authorities, call.recipient),
                .create => {},
            }
            for (scope.authorization_list) |authorization| {
                const outcome = try applyAuthorizationTuple(
                    context,
                    chain_id,
                    authorization,
                    gas,
                    &authorities,
                );
                if (outcome == .out_of_gas) return false;
            }
            return gas.apply(malformedAuthorizationGasAdjustment(scope));
        }

        fn markWritten(authorities: *AuthorityIndex, account: Address) !void {
            const entry = try authorities.getOrPut(account);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            entry.value_ptr.written = true;
        }

        fn applyAuthorizationTuple(
            context: *Context,
            chain_id: u256,
            tuple: transaction.AuthorizationTuple,
            gas: *PreExecutionGas,
            authorities: *AuthorityIndex,
        ) !AuthorizationTupleOutcome {
            const eip7702 = executor.eip7702;
            if (!eip7702.authorizationSignatureShapeValid(
                tuple.y_parity,
                tuple.legacy_v,
                tuple.r,
                tuple.s,
            )) return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            if (tuple.chain_id != 0 and tuple.chain_id != chain_id)
                return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            if (tuple.nonce == std.math.maxInt(u64))
                return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;

            try context.warmAccount(tuple.signer);
            try context.accountAccess(tuple.signer);
            const existing_account = try context.accountSummary(tuple.signer);
            const account_exists = existing_account != null;
            const existing_code = if (account_exists) try context.code(tuple.signer) else &.{};
            const currently_delegated = eip7702.delegationTarget(existing_code) != null;
            const entry = try authorities.getOrPut(tuple.signer);
            if (!entry.found_existing) entry.value_ptr.* = .{};
            const authority_state = entry.value_ptr;
            if (!authority_state.pre_delegated_known) {
                authority_state.pre_delegated_known = true;
                authority_state.pre_delegated = currently_delegated;
            }
            if (existing_account) |account| {
                if (existing_code.len != 0 and !currently_delegated)
                    return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
                if (account.nonce != tuple.nonce)
                    return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            } else if (tuple.nonce != 0) {
                return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            }

            const clears_delegation = Address.eql(tuple.target, .zero);
            const adjustment = authorization_spec.successGasAdjustment(.{
                .account_exists = account_exists,
                .account_already_written = authority_state.written,
                .clears_delegation = clears_delegation,
                .delegated_before_transaction = authority_state.pre_delegated,
                .delegation_set_before = authority_state.delegation_set,
            });
            if (!gas.apply(adjustment)) return .out_of_gas;

            authority_state.written = true;
            if (!clears_delegation) authority_state.delegation_set = true;
            if (clears_delegation) {
                try context.clearCode(tuple.signer);
            } else {
                var code: [eip7702.delegation_code_len]u8 = undefined;
                eip7702.writeDelegationCode(&code, tuple.target);
                try context.setCode(tuple.signer, &code);
            }
            try context.setNonce(tuple.signer, tuple.nonce + 1);
            return .applied;
        }

        fn malformedAuthorizationGasAdjustment(
            scope: transaction.TransactionScope,
        ) transaction.AuthorizationGasAdjustment {
            const total_count = scope.authorizationCount();
            const parsed_count = scope.authorization_list.len;
            if (total_count <= parsed_count) return .{};
            return authorization_spec.malformedGasAdjustment(total_count - parsed_count);
        }

        fn warmDelegatedTransactionTarget(
            context: *Context,
            message: execution.Message,
        ) !void {
            if (!authorization_spec.warms_delegated_target) return;
            switch (message) {
                .call => |call_tx| {
                    const target = executor.eip7702.delegationTarget(try context.code(call_tx.recipient)) orelse return;
                    try context.warmAccount(target);
                },
                .create => {},
            }
        }

        fn executionRolledBack(status: execution.Status) bool {
            return switch (status) {
                .success => false,
                .revert, .invalid, .out_of_gas => true,
            };
        }
    };
}
