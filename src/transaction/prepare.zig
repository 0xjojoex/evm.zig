const address = @import("../address.zig");
const gas = @import("./gas.zig");
const settlement = @import("./settlement.zig");
const tx = @import("./types.zig");
const validation = @import("./validation.zig");

pub fn For(comptime Protocol: type) type {
    return struct {
        const gas_protocol = gas.For(Protocol);
        const settlement_protocol = settlement.For(Protocol);
        const validation_protocol = validation.For(Protocol);

        pub fn prepare(input: tx.PrepareInput(Protocol)) !tx.PrepareResult(Protocol) {
            const view = input.view;
            const access_list_counts = gas.accessListCounts(view.access_list);
            const intrinsic_options = gas.IntrinsicGasOptions{
                .authorization_count = view.authorization_count,
                .access_list_counts = access_list_counts,
                .is_create = view.to == null,
                .value = view.value,
                .is_self_transfer = isSelfTransfer(view),
                .creates_account = input.state.value_transfer_creates_account,
            };

            if (validation_protocol.validate(.{
                .revision = input.revision,
                .kind = view.kind,
                .is_create = view.to == null,
                .is_self_transfer = intrinsic_options.is_self_transfer,
                .creates_account = input.state.value_transfer_creates_account,
                .gas_limit = view.gas_limit,
                .input = view.input,
                .value = view.value,
                .gas_price = view.fee.gas_price,
                .base_fee = input.env.base_fee,
                .block_gas_limit = input.env.gas_limit,
                .blob_base_fee = input.env.blob_base_fee,
                .blob_schedule = input.env.blob_schedule,
                .max_fee_per_gas = view.fee.max_fee_per_gas,
                .max_priority_fee_per_gas = view.fee.max_priority_fee_per_gas,
                .max_fee_per_blob_gas = view.fee.max_fee_per_blob_gas,
                .sender_balance = input.state.sender_balance,
                .sender_nonce = input.state.sender_nonce,
                .tx_nonce = view.nonce,
                .sender_code_kind = input.state.sender_code_kind,
                .authorization_count = view.authorization_count,
                .access_list_counts = access_list_counts,
                .blob_hashes = view.blob_hashes,
            })) |err| {
                return .{ .rejected = err };
            }

            const gas_price = tx.effectiveGasPrice(input.env, view);
            const gas_plan = gas_protocol.gasPlan(input.revision, view.input, view.gas_limit, intrinsic_options);
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
                .created_address = if (view.to == null) address.create(view.sender, input.state.sender_nonce) else null,
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
    };
}
