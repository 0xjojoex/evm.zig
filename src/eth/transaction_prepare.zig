const address = @import("../address.zig");
const gas = @import("../transaction/gas.zig");
const settlement = @import("../transaction/settlement.zig");
const tx = @import("../transaction/types.zig");
const validation = @import("transaction_validation.zig");

pub fn For(comptime Protocol: type) type {
    return struct {
        const settlement_protocol = settlement.For(Protocol);
        const validation_protocol = validation.For(Protocol);

        pub fn prepare(input: tx.PrepareInput(Protocol)) !tx.PrepareResult(Protocol) {
            const view = Protocol.Transaction.view(input.tx);
            const access_list_counts = gas.accessListCounts(view.access_list);
            var validation_input = validation_protocol.Input{
                .revision = input.revision,
                .kind = view.kind,
                .is_create = view.to == null,
                .is_self_transfer = isSelfTransfer(view),
                .gas_limit = view.gas_limit,
                .input = view.input,
                .value = view.value,
                .gas_price = view.fee.gas_price,
                .base_fee = input.env.base_fee,
                .block_gas_limit = input.env.gas_limit,
                .block_progress = input.block,
                .blob_base_fee = input.env.blob_base_fee,
                .blob_schedule = input.env.blob_schedule,
                .max_fee_per_gas = view.fee.max_fee_per_gas,
                .max_priority_fee_per_gas = view.fee.max_priority_fee_per_gas,
                .max_fee_per_blob_gas = view.fee.max_fee_per_blob_gas,
                .tx_nonce = view.nonce,
                .authorization_count = view.authorization_count,
                .access_list_counts = access_list_counts,
                .blob_hashes = view.blob_hashes,
            };
            const gas_plan = validation_protocol.gasPlan(validation_input);

            if (validation_protocol.validateBeforeAccount(validation_input, gas_plan)) |err| {
                return .{ .rejected = err };
            }

            const sender_account = try input.state.accountSummary(view.sender);
            if (sender_account) |account| {
                validation_input.sender_balance = account.balance;
                validation_input.sender_nonce = account.nonce;
            }

            if (validation_protocol.validateAfterAccount(validation_input)) |err| {
                return .{ .rejected = err };
            }

            if (sender_account) |account| {
                if (Protocol.Transaction.rejectsNonDelegatingSenderCode(input.revision, view.kind)) {
                    const code = try input.state.code(view.sender, account.code_hash);
                    // The transaction policy must revision-gate EIP-7702's
                    // exception so pre-Prague EIP-3607 still rejects all code.
                    validation_input.sender_code_kind = if (code.len == 0)
                        .empty
                    else if (isDelegationCode(input.revision, code))
                        .delegation
                    else
                        .non_delegating;
                }
            }
            if (validation_protocol.validateSenderCode(validation_input)) |err| {
                return .{ .rejected = err };
            }

            const gas_price = tx.effectiveGasPrice(input.env, view);
            const settlement_plan = settlement_protocol.settlementFromGasPlan(input.revision, view.gas_limit, gas_plan, .{
                .gas_price = gas_price,
                .priority_fee = settlement_protocol.effectivePriorityFee(input.revision, .{
                    .gas_price = gas_price,
                    .base_fee = input.env.base_fee,
                    .max_fee_per_gas = view.fee.max_fee_per_gas,
                    .max_priority_fee_per_gas = view.fee.max_priority_fee_per_gas,
                }),
                .coinbase = input.env.coinbase,
                .payer = view.sender,
                .value = view.value,
                .blob_base_fee = input.env.blob_base_fee,
                .blob_count = view.blob_hashes.len,
                .blob_schedule = input.env.blob_schedule,
            });

            return .{ .executable = .{
                .created_address = if (view.to == null) address.create(view.sender, validation_input.sender_nonce) else null,
                .scope = .{
                    .context = .init(input.env, view.sender, gas_price, input.env.gas_limit, view.blob_hashes),
                    .access_list = view.access_list,
                    .authorization_list = view.authorization_list,
                    .authorization_count = view.authorization_count,
                },
                .root = .init(.{
                    .sender = view.sender,
                    .to = view.to,
                    .input = view.input,
                    .gas_limit = view.gas_limit,
                    .value = view.value,
                }),
                .execution_gas = gas_plan.execution,
                .settlement = settlement_plan,
            } };
        }

        fn isSelfTransfer(view: tx.TransactionView) bool {
            const recipient = view.to orelse return false;
            return @import("std").mem.eql(u8, &view.sender, &recipient);
        }

        fn isDelegationCode(revision: Protocol.Revision, code: []const u8) bool {
            if (comptime @hasDecl(Protocol.Transaction, "isDelegationCode")) {
                return Protocol.Transaction.isDelegationCode(revision, code);
            }
            return false;
        }
    };
}
