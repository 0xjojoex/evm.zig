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

/// Build the Ethereum transaction program for one bound transaction protocol.
/// `Input` carries the public block environment and progress; `Output` is the
/// family-facing executed transaction result.
pub fn Program(
    comptime TransactionProtocol: type,
    comptime InputType: type,
    comptime Output: type,
) type {
    const PreparedTransaction = transaction.Prepared(TransactionProtocol);
    const Rejection = TransactionProtocol.transaction.ValidationError;
    const Revision = TransactionProtocol.Revision;

    const Transition = struct {
        pub const Input = InputType;

        pub fn For(comptime Context: type) type {
            if (Context.TransactionProtocol != TransactionProtocol)
                @compileError("Ethereum transaction program bound to a different transaction protocol");
            return struct {
                const Settlement = transaction.SettlementRuntime(
                    TransactionProtocol,
                    Context.TransactionPolicy,
                );

                pub const Error = Context.Error || error{
                    BlockGasLimitExceedsBound,
                    InvalidBlockGasLimit,
                    Overflow,
                    SettlementRevisionMismatch,
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
                        executable.execution_gas orelse execution.ExecutionGas.legacy(0),
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
                    const Status = @FieldType(Output, "status");
                    const status: Status = switch (result.status) {
                        .success => .success,
                        .revert => .revert,
                        .invalid => .invalid,
                        .out_of_gas => .out_of_gas,
                    };
                    const created_address = if (result.status == .success)
                        executable.created_address
                    else
                        null;
                    return .{ .completed = .{
                        .status = status,
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
                    try validateSettlementRevision(context, revision, executable.settlement);

                    const sender = executable.message.sender();
                    var execution_gas = executable.execution_gas;
                    const transaction_charged = if (execution_gas != null)
                        try chargeTransactionCosts(context, attempt, sender, executable.settlement)
                    else
                        false;
                    var authorization_gas = protocol.AuthorizationGasAdjustment{};
                    if (transaction_charged) {
                        if (!executable.message.isCreate()) {
                            try attempt.incrementNonce(sender);
                        }
                        try warmAccessList(attempt, executable.scope.access_list);
                        authorization_gas = try applyAuthorizationList(
                            context,
                            attempt,
                            revision,
                            executable.scope.context.chain.chain_id,
                            executable.scope.authorization_list,
                        );
                        authorization_gas.add(malformedAuthorizationGasAdjustment(
                            context,
                            revision,
                            executable.scope,
                        ));
                        if (authorization_gas.state_refund != 0) {
                            if (execution_gas) |current_gas| {
                                execution_gas = .{
                                    .regular_left = current_gas.regular_left,
                                    .reservoir = std.math.add(
                                        u64,
                                        current_gas.reservoir,
                                        authorization_gas.state_refund,
                                    ) catch std.math.maxInt(u64),
                                };
                            }
                        }
                        try warmDelegatedTransactionTarget(context, attempt, revision, executable.message);
                    }

                    var execution_checkpoint = try attempt.checkpoint();
                    defer execution_checkpoint.deinit();

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
                            result = try attempt.executeRequest(transaction.executionRequest(
                                executable.scope.context,
                                executable.message,
                                gas,
                            ));
                        }
                    }
                    const authorization_refund_i64 = std.math.cast(i64, authorization_gas.regular_refund) orelse std.math.maxInt(i64);
                    result.gas_refund = std.math.add(i64, result.gas_refund, authorization_refund_i64) catch std.math.maxInt(i64);
                    if (authorization_gas.state_refund != 0) {
                        const state_refund_i64 = std.math.cast(i64, authorization_gas.state_refund) orelse std.math.maxInt(i64);
                        result.state_gas_spent = std.math.sub(i64, result.state_gas_spent, state_refund_i64) catch std.math.minInt(i64);
                    }

                    if (executionRolledBack(result.status)) {
                        if (executable.message.isCreate() and transaction_charged) {
                            result.refillIntrinsicStateGas(TransactionProtocol.ExecutionProtocol.create.createTransactionRollbackStateGasRefund(revision));
                        }
                        execution_checkpoint.restore() catch |err| return context.infrastructureError(err);
                        if (executable.message.isCreate() and transaction_charged) {
                            try attempt.incrementNonce(sender);
                        }
                    } else {
                        execution_checkpoint.commit() catch |err| return context.infrastructureError(err);
                        try attempt.finalizeState();
                    }

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

                fn validateSettlementRevision(
                    context: *const Context,
                    revision: Revision,
                    settlement: TransactionProtocol.Settlement.Plan,
                ) !void {
                    if (settlementPlanner(context).planRevisionId(settlement) !=
                        protocol.revisionIdForProtocol(TransactionProtocol, revision))
                    {
                        return error.SettlementRevisionMismatch;
                    }
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
                    try attempt.addBalance(settlement.fee_recipient, costs.fee_payment);
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

                fn applyAuthorizationList(
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    revision: Revision,
                    chain_id: u256,
                    authorization_list: []const transaction.AuthorizationTuple,
                ) !protocol.AuthorizationGasAdjustment {
                    if (authorization_list.len == 0) return .{};
                    if (!context.policy().authorization.active(revision)) return .{};
                    var adjustment = protocol.AuthorizationGasAdjustment{};
                    var pre_delegated = std.AutoHashMap(Address, bool).init(try attempt.allocator());
                    defer pre_delegated.deinit();
                    for (authorization_list) |authorization| {
                        adjustment.add(try applyAuthorizationTuple(
                            context,
                            attempt,
                            revision,
                            chain_id,
                            authorization,
                            &pre_delegated,
                        ));
                    }
                    return adjustment;
                }

                fn applyAuthorizationTuple(
                    context: *const Context,
                    attempt: Context.AttemptCapability,
                    revision: Revision,
                    chain_id: u256,
                    authorization: transaction.AuthorizationTuple,
                    pre_delegated_by_authority: *std.AutoHashMap(Address, bool),
                ) !protocol.AuthorizationGasAdjustment {
                    const eip7702 = executor.eip7702;
                    const authorization_policy = &context.policy().authorization;
                    if (!eip7702.authorizationSignatureShapeValid(
                        authorization.y_parity,
                        authorization.legacy_v,
                        authorization.r,
                        authorization.s,
                    )) return authorization_policy.invalidGasAdjustment(revision);
                    if (authorization.chain_id != 0 and authorization.chain_id != chain_id)
                        return authorization_policy.invalidGasAdjustment(revision);
                    if (authorization.nonce == std.math.maxInt(u64))
                        return authorization_policy.invalidGasAdjustment(revision);

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
                            return authorization_policy.invalidGasAdjustment(revision);
                        if (account.nonce != authorization.nonce)
                            return authorization_policy.invalidGasAdjustment(revision);
                    } else if (authorization.nonce != 0) {
                        return authorization_policy.invalidGasAdjustment(revision);
                    }

                    if (std.mem.eql(u8, &authorization.target, &address.zero_address)) {
                        try attempt.clearCode(authorization.signer);
                    } else {
                        var code: [eip7702.delegation_code_len]u8 = undefined;
                        eip7702.writeDelegationCode(&code, authorization.target);
                        try attempt.setCode(authorization.signer, &code);
                    }
                    try attempt.setNonce(authorization.signer, authorization.nonce + 1);
                    return authorization_policy.successGasAdjustment(revision, .{
                        .account_exists = account_exists,
                        .clears_delegation = std.mem.eql(u8, &authorization.target, &address.zero_address),
                        .delegated_before_tuple = currently_delegated,
                        .delegated_before_first_tuple = delegated_before_first,
                    });
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

    return transaction.Program(
        transaction.Transaction,
        Output,
        Rejection,
        Transition,
    );
}
