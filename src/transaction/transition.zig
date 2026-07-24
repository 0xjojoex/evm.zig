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
const interpreter = @import("../Interpreter.zig");
const transaction = @import("../transaction.zig");
const transaction_prepare = @import("prepare.zig");
const transaction_validation = @import("validation.zig");
const tx_settlement = @import("settlement.zig");

const Address = address.Address;

/// Build the Ethereum transaction implementation for one exact execution spec.
/// The bound Context carries the public block environment and
/// progress; `Output` is the family-facing executed transaction result.
pub fn bind(
    comptime spec: ExactSpec,
    comptime Context: type,
    comptime Output: type,
) type {
    comptime std.debug.assert(Context.Executor == executor.Executor(spec));
    const PreparedTransaction = transaction.Prepared(tx_settlement.DefaultPlan);
    const Rejection = transaction_validation.ValidationError;

    return struct {
        const Settlement = transaction.SettlementRuntime(spec);
        const authorization_spec = spec.authorization;
        const settlement_spec = spec.settlement;

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

            fn foldInto(self: @This(), result: *interpreter.Result) void {
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

            fn includedOutOfGas(self: @This()) interpreter.Result {
                return .{
                    .status = .out_of_gas,
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

        fn settlementPlanner(_: *const Context) Settlement {
            return .{};
        }

        pub fn transact(
            context: *Context,
            tx_value: transaction.Transaction,
        ) Error!transaction.TransitionOutcome(Output, Rejection) {
            const input_value = context.input();
            const prepared = (transaction_prepare.Runtime(spec){}).prepare(.{
                .tx = tx_value,
                .env = .{
                    .chain_id = input_value.env.chain_id,
                    .coinbase = input_value.env.coinbase,
                    .number = input_value.env.number,
                    .slot_number = input_value.env.slot_number,
                    .timestamp = input_value.env.timestamp,
                    .gas_limit = input_value.env.gas_limit,
                    .prev_randao = input_value.env.prev_randao,
                    .base_fee = input_value.env.base_fee,
                    .blob_base_fee = input_value.env.blob_base_fee,
                    .blob_schedule = input_value.env.blob_schedule,
                },
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
        ) Error!transaction.TransitionOutcome(Output, Rejection) {
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
            const attempt = try context.beginAttempt();
            try context.runPrelude();
            try attempt.beginExecution(request, scope_init);
            const result = try executePrepared(context, attempt, executable);
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
            attempt: Context.AttemptCapability,
            executable: PreparedTransaction,
        ) Error!struct {
            status: interpreter.Status,
            gas: transaction.ResultGas,
            output_data: []const u8,
        } {
            const sender = executable.message.sender();
            const execution_gas = executable.execution_gas;
            const transaction_charged = if (execution_gas != null)
                try chargeTransactionCosts(context, attempt, sender, executable.settlement)
            else
                false;
            var nonce_intent: ?Context.AttemptCapability.TransactionNonceIntent = null;
            if (transaction_charged) {
                nonce_intent = try attempt.advanceTransactionNonce(executable.message);
                try warmAccessList(attempt, executable.scope.access_list);
            }

            var result = interpreter.Result{
                .status = .out_of_gas,
                .gas_left = 0,
                .gas_refund = 0,
                .output_data = &.{},
            };
            if (execution_gas) |gas| {
                if (!transaction_charged) {
                    result.status = .invalid;
                } else {
                    const has_authorization_phase = authorization_spec.active and
                        executable.scope.authorizationCount() != 0;
                    result = if (has_authorization_phase)
                        try executeAuthorizedPayload(context, attempt, executable, gas)
                    else
                        try executePayload(attempt, executable, gas);
                }
            }

            if (nonce_intent) |intent| intent.complete();

            const result_gas = if (transaction_charged)
                try settleTransactionCosts(context, attempt, sender, executable.settlement, result)
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
                .status = result.status,
                .gas = result_gas,
                .output_data = result.output_data,
            };
        }

        fn executeAuthorizedPayload(
            context: *Context,
            attempt: Context.AttemptCapability,
            executable: PreparedTransaction,
            initial_gas: execution.ExecutionGas,
        ) Error!interpreter.Result {
            var preparation_checkpoint = try attempt.checkpoint();
            defer preparation_checkpoint.deinit();

            var gas = PreExecutionGas.init(initial_gas);
            const authorized = try applyAuthorizationList(
                context,
                attempt,
                executable.scope.context.chain.chain_id,
                executable.message,
                executable.scope,
                &gas,
            );
            if (!authorized) {
                preparation_checkpoint.restore() catch |err| return context.infrastructureError(err);
                return gas.includedOutOfGas();
            }
            try warmDelegatedTransactionTarget(attempt, executable.message);

            const outcome = try attempt.runPayload(transaction.executionRequest(
                executable.scope.context,
                executable.message,
                gas.gas,
            ));
            if (outcome.stage == .preparation) {
                preparation_checkpoint.restore() catch |err| return context.infrastructureError(err);
                return gas.includedOutOfGas();
            }

            var result = outcome.result;
            gas.foldInto(&result);
            if (executionRolledBack(result.status)) {
                preparation_checkpoint.commit() catch |err| return context.infrastructureError(err);
            } else {
                preparation_checkpoint.commit() catch |err| return context.infrastructureError(err);
                try attempt.finalizeState();
            }
            return result;
        }

        fn executePayload(
            attempt: Context.AttemptCapability,
            executable: PreparedTransaction,
            gas: execution.ExecutionGas,
        ) Error!interpreter.Result {
            const outcome = try attempt.runPayload(transaction.executionRequest(
                executable.scope.context,
                executable.message,
                gas,
            ));
            const result = outcome.result;
            if (!executionRolledBack(result.status)) {
                try attempt.finalizeState();
            }
            return result;
        }

        fn chargeTransactionCosts(
            context: *const Context,
            attempt: Context.AttemptCapability,
            sender: Address,
            plan: tx_settlement.DefaultPlan,
        ) !bool {
            const precharge = settlementPlanner(context).planPrecharge(plan);
            const required_balance = @max(precharge.minimum_balance, precharge.upfront_debit);
            if (required_balance == 0) return true;
            const payer = precharge.payer orelse sender;
            const payer_account = try attempt.accountSummary(payer) orelse return false;
            if (payer_account.balance < required_balance) return false;
            return attempt.subtractBalance(payer, precharge.upfront_debit);
        }

        fn settleTransactionCosts(
            context: *const Context,
            attempt: Context.AttemptCapability,
            sender: Address,
            plan: tx_settlement.DefaultPlan,
            result: interpreter.Result,
        ) !transaction.ResultGas {
            const settlement_planner = settlementPlanner(context);
            const costs = try settlement_planner.planCosts(plan, .{
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
            });
            try attempt.addBalance(plan.payer orelse sender, costs.payer_refund);
            if (costs.fee_payment == 0) {
                try attempt.accountAccess(plan.fee_recipient);
            }
            if (costs.fee_payment == 0 and
                settlement_spec.touches_fee_recipient_on_zero_payment)
            {
                try attempt.touchAccount(plan.fee_recipient);
            } else {
                try attempt.addBalance(plan.fee_recipient, costs.fee_payment);
            }
            return settlement_planner.planGas(costs);
        }

        fn warmAccessList(
            attempt: Context.AttemptCapability,
            access_list: []const transaction.AccessListEntry,
        ) !void {
            for (access_list) |entry| {
                try attempt.warmAccount(entry.address);
                for (entry.storage_keys) |key| {
                    try attempt.warmStorage(entry.address, key);
                }
            }
        }

        // TODO: perf check
        fn applyAuthorizationList(
            _: *const Context,
            attempt: Context.AttemptCapability,
            chain_id: u256,
            message: execution.Message,
            scope: transaction.TransactionScope,
            gas: *PreExecutionGas,
        ) !bool {
            if (!authorization_spec.active) return true;
            const allocator = try attempt.allocator();
            var written_accounts = std.AutoHashMap(Address, void).init(allocator);
            defer written_accounts.deinit();
            try written_accounts.put(message.sender(), {});
            switch (message) {
                .call => |call| if (call.value != 0) try written_accounts.put(call.recipient, {}),
                .create => {},
            }
            var pre_delegated = std.AutoHashMap(Address, bool).init(allocator);
            defer pre_delegated.deinit();
            var delegation_set_for = std.AutoHashMap(Address, void).init(allocator);
            defer delegation_set_for.deinit();
            for (scope.authorization_list) |authorization| {
                const outcome = try applyAuthorizationTuple(
                    attempt,
                    chain_id,
                    authorization,
                    gas,
                    &written_accounts,
                    &pre_delegated,
                    &delegation_set_for,
                );
                if (outcome == .out_of_gas) return false;
            }
            return gas.apply(malformedAuthorizationGasAdjustment(scope));
        }

        fn applyAuthorizationTuple(
            attempt: Context.AttemptCapability,
            chain_id: u256,
            tuple: transaction.AuthorizationTuple,
            gas: *PreExecutionGas,
            written_accounts: *std.AutoHashMap(Address, void),
            pre_delegated_by_authority: *std.AutoHashMap(Address, bool),
            delegation_set_for: *std.AutoHashMap(Address, void),
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

            try attempt.warmAccount(tuple.signer);
            const existing_account = try attempt.accountSummary(tuple.signer);
            const account_exists = existing_account != null;
            const existing_code = if (account_exists) try attempt.code(tuple.signer) else &.{};
            const currently_delegated = eip7702.delegationTarget(existing_code) != null;
            const delegated_before_first = if (pre_delegated_by_authority.get(tuple.signer)) |delegated|
                delegated
            else blk: {
                try pre_delegated_by_authority.put(tuple.signer, currently_delegated);
                break :blk currently_delegated;
            };
            if (existing_account) |account| {
                if (existing_code.len != 0 and !currently_delegated)
                    return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
                if (account.nonce != tuple.nonce)
                    return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            } else if (tuple.nonce != 0) {
                return if (gas.apply(authorization_spec.invalid_gas_adjustment)) .invalid else .out_of_gas;
            }

            const clears_delegation = std.mem.eql(u8, &tuple.target, &address.zero_address);
            const adjustment = authorization_spec.successGasAdjustment(.{
                .account_exists = account_exists,
                .account_already_written = written_accounts.contains(tuple.signer),
                .clears_delegation = clears_delegation,
                .delegated_before_transaction = delegated_before_first,
                .delegation_set_before = delegation_set_for.contains(tuple.signer),
            });
            if (!gas.apply(adjustment)) return .out_of_gas;

            try written_accounts.put(tuple.signer, {});
            if (!clears_delegation) try delegation_set_for.put(tuple.signer, {});
            if (clears_delegation) {
                try attempt.clearCode(tuple.signer);
            } else {
                var code: [eip7702.delegation_code_len]u8 = undefined;
                eip7702.writeDelegationCode(&code, tuple.target);
                try attempt.setCode(tuple.signer, &code);
            }
            try attempt.setNonce(tuple.signer, tuple.nonce + 1);
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
            attempt: Context.AttemptCapability,
            message: execution.Message,
        ) !void {
            if (!authorization_spec.warms_delegated_target) return;
            switch (message) {
                .call => |call_tx| {
                    const target = executor.eip7702.delegationTarget(try attempt.code(call_tx.recipient)) orelse return;
                    try attempt.warmAccount(target);
                },
                .create => {},
            }
        }

        fn executionRolledBack(status: interpreter.Status) bool {
            return switch (status) {
                .success => false,
                .revert, .invalid, .out_of_gas => true,
            };
        }
    };
}
