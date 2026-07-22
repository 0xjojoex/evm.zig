//! Ethereum transaction state transition bound above one execution protocol.
//!
//! This module owns Ethereum transaction preparation, charging, authorization,
//! execution rollback, settlement, and warm-set seeding. Executor lifetime and
//! retain/discard authority remain in the generic transaction program binder.

const std = @import("std");

const address = @import("../address.zig");
const execution = @import("../execution.zig");
const executor = @import("../executor.zig");
const interpreter = @import("../Interpreter.zig");
const protocol = @import("../protocol.zig");
const transaction = @import("../transaction.zig");

const Address = address.Address;

/// Build the Ethereum transaction implementation for one bound transaction
/// protocol. The bound Context carries the public block environment and
/// progress; `Output` is the family-facing executed transaction result.
pub fn Implementation(
    comptime TransactionProtocol: type,
    comptime Output: type,
) type {
    const PreparedTransaction = transaction.Prepared(TransactionProtocol);
    const Rejection = TransactionProtocol.Tx.ValidationError;
    const Revision = TransactionProtocol.Revision;

    const Transition = struct {
        pub fn For(comptime Context: type) type {
            comptime std.debug.assert(Context.TransactionProtocol == TransactionProtocol);

            return struct {
                const Settlement = transaction.SettlementRuntime(
                    TransactionProtocol,
                    Context.TransactionPolicy,
                );

                pub const Error = Context.Error || error{
                    BlockGasLimitExceedsBound,
                    InvalidBlockGasLimit,
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

                    fn apply(self: *@This(), adjustment: protocol.AuthorizationGasAdjustment) bool {
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

                fn settlementPlanner(context: *const Context) Settlement {
                    return .{ .policy = context.policy() };
                }

                pub fn transact(
                    context: *Context,
                    tx_value: transaction.Transaction,
                ) Error!transaction.TransitionOutcome(Output, Rejection) {
                    const input_value = context.input();
                    if (context.blockGasLimitBound()) |max_block_gas| {
                        if (input_value.env.gas_limit == 0) return error.InvalidBlockGasLimit;
                        if (input_value.env.gas_limit > max_block_gas)
                            return error.BlockGasLimitExceedsBound;
                    }

                    const prepared = TransactionProtocol.Tx.prepare(TransactionProtocol, context.policy(), .{
                        .revision = context.revision(),
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
                    const initial_account_count: usize = if (context.policy().transaction.transactionWarmsCoinbase(context.revision())) blk: {
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
                    const revision = context.revision();
                    validateSettlementRevision(context, revision, executable.settlement);

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
                            const has_authorization_phase = context.policy().authorization.active(revision) and
                                executable.scope.authorizationCount() != 0;
                            result = if (has_authorization_phase)
                                try executeAuthorizedPayload(context, attempt, revision, executable, gas)
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
                    revision: Revision,
                    executable: PreparedTransaction,
                    initial_gas: execution.ExecutionGas,
                ) Error!interpreter.Result {
                    var preparation_checkpoint = try attempt.checkpoint();
                    defer preparation_checkpoint.deinit();

                    var gas = PreExecutionGas.init(initial_gas);
                    const authorized = try applyAuthorizationList(
                        context,
                        attempt,
                        revision,
                        executable.scope.context.chain.chain_id,
                        executable.message,
                        executable.scope,
                        &gas,
                    );
                    if (!authorized) {
                        preparation_checkpoint.restore() catch |err| return context.infrastructureError(err);
                        return gas.includedOutOfGas();
                    }
                    try warmDelegatedTransactionTarget(context, attempt, revision, executable.message);

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

                fn validateSettlementRevision(
                    context: *const Context,
                    revision: Revision,
                    settlement: TransactionProtocol.Settlement.Plan,
                ) void {
                    std.debug.assert(
                        settlementPlanner(context).planRevisionId(settlement) ==
                            protocol.revisionIdForProtocol(TransactionProtocol, revision),
                    );
                }

                fn chargeTransactionCosts(
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    sender: Address,
                    settlement: TransactionProtocol.Settlement.Plan,
                ) !bool {
                    const precharge = settlementPlanner(context).planPrecharge(settlement);
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
                    settlement: TransactionProtocol.Settlement.Plan,
                    result: interpreter.Result,
                ) !transaction.ResultGas {
                    const settlement_planner = settlementPlanner(context);
                    const costs = try settlement_planner.planCosts(settlement, .{
                        .gas_left = result.gas_left,
                        .gas_refund = result.gas_refund,
                        .gas_reservoir = result.gas_reservoir,
                        .state_gas_spent = result.state_gas_spent,
                    });
                    try attempt.addBalance(settlement.payer orelse sender, costs.payer_refund);
                    if (costs.fee_payment == 0) {
                        try attempt.accountAccess(settlement.fee_recipient);
                    }
                    if (costs.fee_payment == 0 and
                        context.policy().settlement.touchesFeeRecipientOnZeroPayment(context.revision()))
                    {
                        try attempt.touchAccount(settlement.fee_recipient);
                    } else {
                        try attempt.addBalance(settlement.fee_recipient, costs.fee_payment);
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
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    revision: Revision,
                    chain_id: u256,
                    message: execution.Message,
                    scope: transaction.TransactionScope,
                    gas: *PreExecutionGas,
                ) !bool {
                    if (!context.policy().authorization.active(revision)) return true;
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
                            context,
                            attempt,
                            revision,
                            chain_id,
                            authorization,
                            gas,
                            &written_accounts,
                            &pre_delegated,
                            &delegation_set_for,
                        );
                        if (outcome == .out_of_gas) return false;
                    }
                    return gas.apply(malformedAuthorizationGasAdjustment(context, revision, scope));
                }

                fn applyAuthorizationTuple(
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    revision: Revision,
                    chain_id: u256,
                    authorization: transaction.AuthorizationTuple,
                    gas: *PreExecutionGas,
                    written_accounts: *std.AutoHashMap(Address, void),
                    pre_delegated_by_authority: *std.AutoHashMap(Address, bool),
                    delegation_set_for: *std.AutoHashMap(Address, void),
                ) !AuthorizationTupleOutcome {
                    const eip7702 = executor.eip7702;
                    const authorization_policy = &context.policy().authorization;
                    if (!eip7702.authorizationSignatureShapeValid(
                        authorization.y_parity,
                        authorization.legacy_v,
                        authorization.r,
                        authorization.s,
                    )) return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;
                    if (authorization.chain_id != 0 and authorization.chain_id != chain_id)
                        return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;
                    if (authorization.nonce == std.math.maxInt(u64))
                        return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;

                    try attempt.warmAccount(authorization.signer);
                    const existing_account = try attempt.accountSummary(authorization.signer);
                    const account_exists = existing_account != null;
                    const existing_code = if (account_exists) try attempt.code(authorization.signer) else &.{};
                    const currently_delegated = eip7702.delegationTarget(existing_code) != null;
                    const delegated_before_first = if (pre_delegated_by_authority.get(authorization.signer)) |delegated|
                        delegated
                    else blk: {
                        try pre_delegated_by_authority.put(authorization.signer, currently_delegated);
                        break :blk currently_delegated;
                    };
                    if (existing_account) |account| {
                        if (existing_code.len != 0 and !currently_delegated)
                            return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;
                        if (account.nonce != authorization.nonce)
                            return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;
                    } else if (authorization.nonce != 0) {
                        return if (gas.apply(authorization_policy.invalidGasAdjustment(revision))) .invalid else .out_of_gas;
                    }

                    const clears_delegation = std.mem.eql(u8, &authorization.target, &address.zero_address);
                    const adjustment = authorization_policy.successGasAdjustment(revision, .{
                        .account_exists = account_exists,
                        .account_already_written = written_accounts.contains(authorization.signer),
                        .clears_delegation = clears_delegation,
                        .delegated_before_transaction = delegated_before_first,
                        .delegation_set_before = delegation_set_for.contains(authorization.signer),
                    });
                    if (!gas.apply(adjustment)) return .out_of_gas;

                    try written_accounts.put(authorization.signer, {});
                    if (!clears_delegation) try delegation_set_for.put(authorization.signer, {});
                    if (clears_delegation) {
                        try attempt.clearCode(authorization.signer);
                    } else {
                        var code: [eip7702.delegation_code_len]u8 = undefined;
                        eip7702.writeDelegationCode(&code, authorization.target);
                        try attempt.setCode(authorization.signer, &code);
                    }
                    try attempt.setNonce(authorization.signer, authorization.nonce + 1);
                    return .applied;
                }

                fn malformedAuthorizationGasAdjustment(
                    context: *const Context,
                    revision: Revision,
                    scope: transaction.TransactionScope,
                ) protocol.AuthorizationGasAdjustment {
                    const total_count = scope.authorizationCount();
                    const parsed_count = scope.authorization_list.len;
                    if (total_count <= parsed_count) return .{};
                    return context.policy().authorization.malformedGasAdjustment(revision, total_count - parsed_count);
                }

                fn warmDelegatedTransactionTarget(
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    revision: Revision,
                    message: execution.Message,
                ) !void {
                    if (!context.policy().authorization.warmsDelegatedTarget(revision)) return;
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
    };

    return Transition;
}
