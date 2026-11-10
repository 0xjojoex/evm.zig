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
const transaction_result = @import("result.zig");
const transaction_validation = @import("validation.zig");
const tx_settlement = @import("settlement.zig");
const frames = @import("frames.zig");

const Address = address.Address;

/// Build Ethereum's transaction transition from source dependencies. Executor
/// and Context are derived here instead of becoming additional type roots.
pub fn ImplType(
    comptime spec: ExactSpec,
    comptime World: type,
    comptime compile_options: executor.CompileOptions,
    comptime InputType: type,
) type {
    const ExactContext = transaction.program.ContextType(
        spec,
        World,
        compile_options,
        InputType,
    );
    const PreparedTransaction = transaction.Prepared(tx_settlement.DefaultPlan);

    return struct {
        const Settlement = transaction.SettlementRuntime(spec);
        const authorization_spec = spec.authorization;
        const settlement_spec = spec.settlement;

        // The `transact` signature is the contract; these aliases only keep
        // the implementation readable.
        const Context = ExactContext;
        pub const Input = InputType;
        pub const Output = transaction_result.Execution;
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
                self.regular_refund +|= adjustment.regular_refund;
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
                self.state_spent +|= amount;
                self.state_from_regular +|= from_regular;
                return true;
            }

            fn foldInto(self: @This(), result: *execution.ExecutionResult) void {
                const regular_refund = std.math.lossyCast(i64, self.regular_refund);
                result.gas_refund +|= regular_refund;
                const state_spent = std.math.lossyCast(i64, self.state_spent);
                result.state_gas_spent +|= state_spent;
                const state_from_regular = std.math.lossyCast(i64, self.state_from_regular);
                result.state_gas_from_gas_left +|= state_from_regular;
            }

            fn includedOutOfGas(self: @This()) execution.ExecutionResult {
                return .{
                    .outcome = .{ .status = .out_of_gas, .cause = .out_of_gas },
                    .gas_left = 0,
                    .gas_refund = 0,
                    // Pre-execution rollback refills all state gas. The
                    // regular pool is consumed by the exceptional halt.
                    .gas_reservoir = std.math.lossyCast(i64, self.initial.reservoir),
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

        /// The prepared value `transact` completes. Exposed so a wrapping
        /// family may adjust the settlement plan between `prepare` and
        /// `transactPrepared` — an OP-style family widens `upfront_debit`
        /// and `minimum_balance` with rollup fees the way op-revm folds its
        /// L1 cost into one caller deduction.
        pub const Executable = PreparedTransaction;

        pub fn transact(
            context: *Context,
            tx_value: transaction.Transaction,
        ) Error!transaction.TransitionOutcomeType(Output, Rejection) {
            return switch (try prepare(context, tx_value)) {
                .rejected => |reason| .{ .rejected = reason },
                .executable => |executable| try transactPrepared(context, executable),
            };
        }

        /// Validate and plan one transaction without touching state. A widened
        /// plan is the caller's responsibility to keep affordable: preparation
        /// validated only the unwidened requirement, so re-check the payer
        /// balance before completing or the shortfall becomes an
        /// included-invalid result instead of a rejection.
        pub fn prepare(
            context: *Context,
            tx_value: transaction.Transaction,
        ) Error!transaction.PrepareResult(tx_settlement.DefaultPlan, Rejection) {
            if (comptime frames_active) {
                if (tx_value.kind == .frame) return prepareFrame(context, tx_value);
            }
            const input_value = context.input();
            return (transaction_prepare.Runtime(spec){}).prepare(.{
                .tx = tx_value,
                .env = input_value.env,
                .block = input_value.progress,
                .state = context.preparationState(),
            }) catch |err| return context.infrastructureError(err);
        }

        /// Open the transaction lifetime and complete a prepared transaction.
        pub fn transactPrepared(
            context: *Context,
            executable: PreparedTransaction,
        ) Error!transaction.TransitionOutcomeType(Output, Rejection) {
            if (comptime frames_active) {
                if (executable.frame) |frame| return completeFrames(context, executable.scope, frame);
            }
            return completeExecutable(context, executable);
        }

        // EIP-8141 frame transactions. Compiled only when the spec activates
        // them; every other kind takes the paths above unchanged.

        const frames_active = spec.transaction.framesActive();
        const frame_params = if (frames_active) spec.transaction.frame.? else undefined;

        /// Static checks, the gas and fee plan, chain id, and the nonce. No
        /// balance is reserved: payment is collected when a frame approves it.
        fn prepareFrame(
            context: *Context,
            tx_value: transaction.Transaction,
        ) Error!transaction.PrepareResult(tx_settlement.DefaultPlan, Rejection) {
            const input_value = context.input();
            const env = input_value.env;
            if (tx_value.chain_id) |chain_id| {
                if (chain_id != env.chain_id) return .{ .rejected = .invalid_chain_id };
            }
            const gas_plan = switch (frames.plan(
                frame_params,
                spec.transaction.blob_schedule,
                tx_value,
                env,
                input_value.progress,
            )) {
                .rejected => |reason| return .{ .rejected = reason },
                .planned => |value| value,
            };
            if (try checkFrameNonce(context, tx_value)) |reason| return .{ .rejected = reason };
            return .{ .executable = .{
                .scope = .{ .context = env.executionContext(.{
                    .origin = frame_params.entry_point,
                    .gas_price = gas_plan.gas_price,
                    .blob_hashes = tx_value.blob_hashes,
                }) },
                .message = .{ .call = .{ .sender = tx_value.sender, .recipient = tx_value.sender } },
                .execution_gas = null,
                .settlement = .{
                    .gas_limit = gas_plan.max_gas,
                    .intrinsic_gas = gas_plan.intrinsic_gas,
                    .floor_gas = gas_plan.calldata_floor_gas,
                    .gas_price = gas_plan.gas_price,
                    .priority_fee = 0,
                    .fee_recipient = env.coinbase,
                },
                .frame = .{ .transaction = tx_value, .plan = gas_plan },
            } };
        }

        /// The transaction's nonce domain against state: the account nonce, or
        /// with EIP-8250 keys every selected key's sequence. `plan` has
        /// already bounded the encoded nonce.
        fn checkFrameNonce(context: *Context, tx_value: transaction.Transaction) Error!?Rejection {
            const keys = tx_value.nonce_keys orelse &.{};
            if (keys.len == 0) {
                const sender_account = context.preparationState().accountSummary(tx_value.sender) catch |err|
                    return context.infrastructureError(err);
                const sender_nonce = if (sender_account) |account| account.nonce else 0;
                const nonce: u64 = @intCast(tx_value.nonce orelse 0);
                if (nonce < sender_nonce) return .nonce_too_low;
                if (nonce > sender_nonce) return .nonce_too_high;
                return null;
            }
            const keyed = frame_params.keyed_nonces.?;
            const nonce_seq: u64 = @intCast(tx_value.nonce orelse 0);
            for (keys) |key| {
                const current = try context.getStorage(keyed.nonce_manager, frames.nonceSlot(tx_value.sender, key));
                if (nonce_seq == frames.max_nonce_seq) {
                    if (current != 0) return .nonce_too_low;
                } else {
                    if (current > nonce_seq) return .nonce_too_low;
                    if (current < nonce_seq) return .nonce_too_high;
                }
            }
            return null;
        }

        /// Validate signatures, run every frame as a root of one session, and
        /// settle against the frame receipts.
        fn completeFrames(
            context: *Context,
            scope: transaction.TransactionScope,
            prepared: frames.Prepared,
        ) Error!transaction.TransitionOutcomeType(Output, Rejection) {
            const tx_value = prepared.transaction;
            const gas_plan = prepared.plan;
            try context.beginTransaction();
            try context.runPrelude();

            const allocator = try context.allocator();
            const sig_hash = frames.signatureHash(allocator, tx_value) catch |err|
                return context.infrastructureError(err);
            if (frames.signatureError(tx_value, sig_hash)) |reason| return .{ .rejected = reason };

            const journal = context.frameJournal();
            journal.reset(@intCast(tx_value.frames.len));
            const sender_account = try context.accountSummary(tx_value.sender);
            const frame_transaction: frames.Context = .{
                .transaction = &prepared.transaction,
                .signature_hash = sig_hash,
                .max_cost = gas_plan.max_cost,
                .legacy_nonce = if (sender_account) |account| account.nonce else 0,
                .receipts = journal.frameReceipts(),
            };
            var session = scope;
            session.context.transaction.frame_transaction = &frame_transaction;
            const coinbase = scope.context.block.coinbase;
            const initially_warm = [_]Address{ tx_value.sender, coinbase };
            const warm_count: usize = if (spec.transaction.warms_coinbase) 2 else 1;
            try context.beginRootSession(session.context, .{
                .initial_warm_set = .{ .accounts = initially_warm[0..warm_count] },
            });

            var refund_counter: u64 = 0;
            var index: usize = 0;
            while (index < tx_value.frames.len) {
                if (tx_value.frames[index].flags.atomic_batch) {
                    var end = index;
                    while (tx_value.frames[end].flags.atomic_batch) end += 1;
                    if (try runAtomicBatch(context, session, &frame_transaction, index, end, &refund_counter)) |reason|
                        return .{ .rejected = reason };
                    index = end + 1;
                } else {
                    if (try runFrame(context, session, &frame_transaction, index, &refund_counter)) |reason|
                        return .{ .rejected = reason };
                    index += 1;
                }
            }
            const payer = journal.payer orelse return .{ .rejected = .type_6_invalid_frame_execution };
            try context.finalizeExecution();

            const amounts = frames.settle(
                gas_plan,
                tx_value.frames,
                journal.frameReceipts(),
                refund_counter,
                settlement_spec.gas_refund_cap_divisor,
            );
            try context.addBalance(payer, amounts.payer_refund);
            if (amounts.priority_fee_paid == 0)
                try context.accountAccess(coinbase)
            else
                try context.addBalance(coinbase, amounts.priority_fee_paid);
            return .{ .completed = .{
                .status = .success,
                .gas = .{
                    .used = amounts.gas_used,
                    .refunded = amounts.applied_refund,
                    .block = .fromDimensions(amounts.block_execution_gas, amounts.state_gas),
                },
                .frame = .{
                    .payer = payer,
                    .receipts = journal.frameReceipts(),
                    .settlement = amounts,
                },
            } };
        }

        /// Run frames `first..end` as one atomic batch: the first failure rolls
        /// all of them back and skips the rest.
        fn runAtomicBatch(
            context: *Context,
            scope: transaction.TransactionScope,
            frame_transaction: *const frames.Context,
            first: usize,
            end: usize,
            refund_counter: *u64,
        ) Error!?Rejection {
            const journal = context.frameJournal();
            var checkpoint = context.checkpoint();
            defer checkpoint.deinit();
            const refund_before = refund_counter.*;
            for (first..end + 1) |index| {
                if (try runFrame(context, scope, frame_transaction, index, refund_counter)) |reason| return reason;
                if (journal.receipts[index].status != .failure) continue;

                // Restoring the journal zeroes the batch's attributed state gas;
                // executed frames keep their status and execution gas.
                checkpoint.restore();
                refund_counter.* = refund_before;
                for (journal.receipts[first .. index + 1]) |*receipt| receipt.log_range = .{};
                for (journal.receipts[index + 1 .. end + 1]) |*receipt| receipt.* = .{ .status = .skipped };
                return null;
            }
            checkpoint.commit();
            return null;
        }

        /// Run one frame and close its receipt. A rejection makes the whole
        /// transaction invalid.
        fn runFrame(
            context: *Context,
            scope: transaction.TransactionScope,
            frame_transaction: *const frames.Context,
            index: usize,
            refund_counter: *u64,
        ) Error!?Rejection {
            const tx_value = frame_transaction.transaction.*;
            const frame = tx_value.frames[index];
            const journal = context.frameJournal();
            if (frame.mode == .sender and !journal.sender_approved) return .type_6_invalid_frame_execution;

            const target = frame.resolvedTarget(tx_value.sender);
            const origin = if (frame.mode == .sender) tx_value.sender else frame_params.entry_point;
            const default_code = !spec.precompile.active(target) and (try context.code(target)).len == 0;
            var frame_context = scope.context;
            frame_context.transaction.origin = origin;
            frame_context.transaction.frame_index = @intCast(index);

            var checkpoint = context.checkpoint();
            defer checkpoint.deinit();
            const outcome = try context.runRoot(.{
                .context = frame_context,
                .message = .{ .call = .{
                    .sender = origin,
                    .recipient = target,
                    .input = frame.data,
                    .value = frame.value,
                } },
                .gas = .{ .regular_left = frame.limits.execution, .reservoir = frame.limits.state },
            }, .{ .access = .charge_call_target, .is_static = frame.mode == .verify });

            const result = outcome.result;
            var succeeded = outcome.stage == .payload and result.outcome.status == .success;
            var execution_gas_used = frame.limits.execution - @as(u64, @intCast(@max(result.gas_left, 0)));
            var state_gas_left: u64 = @intCast(@max(result.gas_reservoir, 0));
            std.debug.assert(state_gas_left <= frame.limits.state or !succeeded);

            if (succeeded and default_code and frame.mode == .verify) {
                const allowed = frame.flags.allowedScope();
                if (!frames.defaultCodeApproves(tx_value, target, allowed)) {
                    succeeded = false;
                } else switch (try context.frameApprove(frame_transaction, @intCast(index), allowed, state_gas_left)) {
                    .approved => |state_gas| state_gas_left -= state_gas,
                    .reverted => succeeded = false,
                    .out_of_gas => {
                        succeeded = false;
                        execution_gas_used = frame.limits.execution;
                    },
                }
            }

            if (succeeded) {
                checkpoint.commit();
                refund_counter.* +|= @intCast(@max(result.gas_refund, 0));
            } else {
                checkpoint.restore();
            }
            try journal.closeFrame(try context.allocator(), @intCast(index), .{
                .status = if (succeeded) .success else .failure,
                .execution_gas_used = execution_gas_used,
                .state_gas_used = if (succeeded) frame.limits.state - state_gas_left else 0,
                .log_range = if (succeeded) outcome.log_range else .{},
            });
            if (frame.mode == .verify and !succeeded) return .type_6_invalid_frame_execution;
            return null;
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
                    else blk: {
                        try warmDelegatedTransactionTarget(context, executable.message);
                        break :blk try executePayload(context, executable, gas);
                    };
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
                try context.finalizeExecution();
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
                try context.finalizeExecution();
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
