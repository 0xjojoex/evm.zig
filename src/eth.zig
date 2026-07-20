//! The Ethereum protocol definition.
//!
//! This module owns the independently authored Ethereum execution,
//! transaction, and block definitions. Resolved facts live on `Protocol`,
//! produced by `fork(revision)` or `protocol(window)`.
//!
//! Layer note: most declarations here are protocol *data and derivations*.
//! `eth.block_stf` is the concrete Ethereum block-transition layer above
//! the bound `Vm.BlockProgram`; raw message execution still lives under
//! `executor/` and opcode behavior under `instruction/`.

const std = @import("std");

pub const revision = @import("eth/revision.zig");
pub const config = @import("eth/config.zig");
pub const bal = @import("eth/bal.zig");
pub const bal_recorder = @import("eth/bal_recorder.zig");
pub const instruction = @import("eth/instruction.zig");
pub const transaction = @import("eth/transaction.zig");
pub const transaction_prepare = @import("eth/transaction_prepare.zig");
pub const transaction_validation = @import("eth/transaction_validation.zig");
pub const transition = @import("eth/transition.zig");
pub const authorization = @import("eth/authorization.zig");
pub const settlement = @import("eth/settlement.zig");
pub const precompile = @import("eth/precompile.zig");
pub const system = @import("eth/system.zig");
pub const header = @import("eth/header.zig");
pub const trie = @import("eth/trie.zig");
pub const block_stf = @import("eth/block_stf.zig");
pub const block_program = @import("eth/block_program.zig");
pub const eip6110 = @import("eth/eip/6110.zig");
pub const eip7002 = @import("eth/eip/7002.zig");
pub const eip7702 = @import("eth/eip/7702.zig");
pub const eip7251 = @import("eth/eip/7251.zig");
pub const eip7685 = @import("eth/eip/7685.zig");
pub const eip8282 = @import("eth/eip/8282.zig");
pub const eip8037 = @import("eth/eip/8037.zig");
const definition_mod = @import("definition.zig");
const protocol_mod = @import("protocol.zig");

pub const Revision = revision.Revision;
pub const ExecutionOptions = config.ExecutionOptions;
pub const TransactionOptions = config.TransactionOptions;
pub const BlockOptions = config.BlockOptions;

pub fn defineExecution(comptime options: ExecutionOptions(Revision)) definition_mod.ExecutionDefinition(Revision) {
    return config.execution(options);
}

pub fn defineTransaction(comptime options: TransactionOptions(Revision)) definition_mod.TransactionDefinition(Revision) {
    return config.transaction(options);
}

pub fn defineBlock(comptime options: BlockOptions(Revision)) definition_mod.BlockDefinition(Revision) {
    return config.block(options);
}

pub fn transactionPolicy(comptime options: TransactionOptions(Revision)) definition_mod.TransactionPolicy(Revision) {
    return definition_mod.projectTransactionPolicy(Revision, defineTransaction(options));
}

pub fn blockPolicy(comptime options: BlockOptions(Revision)) definition_mod.BlockPolicy(Revision) {
    return definition_mod.projectBlockPolicy(Revision, defineBlock(options));
}

pub const execution_definition = defineExecution(.{});
pub const transaction_definition = defineTransaction(.{});
pub const block_definition = defineBlock(.{});
pub const transaction_policy = transactionPolicy(.{});
pub const block_policy = blockPolicy(.{});
const Definition = definition_mod.BoundExecution(execution_definition);

pub const ExecutionHeader = header.ExecutionHeader;
pub const Withdrawal = @import("eth/Withdrawal.zig");
pub const BlockSTF = block_stf;
/// The Ethereum protocol chain bound across every supported revision.
pub const Protocol = protocol(.all);

/// Bind the Ethereum execution layer over `support_window` revisions.
pub fn executionProtocol(comptime support_window: Definition.Support) type {
    return protocol_mod.ExecutionProtocol(execution_definition, support_window);
}

/// Bind the Ethereum transaction layer above the execution binding.
pub fn transactionProtocol(comptime support_window: Definition.Support) type {
    return protocol_mod.TransactionProtocol(
        executionProtocol(support_window),
        transaction_definition,
    );
}

/// Bind the full Ethereum layer chain over `support_window` revisions. The
/// returned namespace is the block layer; `TransactionProtocol` and
/// `ExecutionProtocol` reference the layers below it.
pub fn protocol(comptime support_window: Definition.Support) type {
    return protocol_mod.BlockProtocol(
        transactionProtocol(support_window),
        block_definition,
    );
}

/// Bind the Ethereum layer chain pinned to a single `revision_value`.
pub fn fork(comptime revision_value: Revision) type {
    return protocol(Definition.Support.at(revision_value));
}

pub const system_address = system.system_address;
pub const beacon_roots_address = system.beacon_roots_address;
pub const history_storage_address = system.history_storage_address;
pub const deposit_contract_address = system.deposit_contract_address;
pub const withdrawal_request_predeploy_address = system.withdrawal_request_predeploy_address;
pub const consolidation_request_predeploy_address = system.consolidation_request_predeploy_address;
pub const builder_deposit_request_predeploy_address = system.builder_deposit_request_predeploy_address;
pub const builder_exit_request_predeploy_address = system.builder_exit_request_predeploy_address;
pub const deposit_event_signature_hash = system.deposit_event_signature_hash;
pub const deposit_request_type = system.deposit_request_type;
pub const withdrawal_request_type = system.withdrawal_request_type;
pub const consolidation_request_type = system.consolidation_request_type;
pub const builder_deposit_request_type = system.builder_deposit_request_type;
pub const builder_exit_request_type = system.builder_exit_request_type;
pub const value_transfer_log_topic = system.value_transfer_log_topic;
pub const system_call_gas = system.system_call_gas;

test "Ethereum definitions project to runtime policy values" {
    comptime {
        if (@TypeOf(transaction_policy) != definition_mod.TransactionPolicy(Revision))
            @compileError("Ethereum transaction policy type drifted");
        if (@TypeOf(block_policy) != definition_mod.BlockPolicy(Revision))
            @compileError("Ethereum block policy type drifted");
    }

    try std.testing.expectEqual(
        @as(?u64, 20),
        transaction_policy.transaction.calldataGas(.istanbul, &.{ 0, 1 }),
    );
    try std.testing.expectEqual(
        @as(?u64, transaction.max_transaction_gas_limit),
        transaction_policy.transaction.totalGasLimit(.osaka),
    );
    try std.testing.expectEqual(@as(usize, 0), block_policy.beforeBlock(.cancun, .{
        .number = 0,
        .timestamp = 0,
    }).slice().len);
}
