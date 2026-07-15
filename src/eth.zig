//! The Ethereum protocol definition.
//!
//! This module is the concrete `Definition` for mainnet Ethereum: it wires the
//! per-domain spec tables (`eth/*.zig`, `eth/eip/*.zig`) into a single value and
//! exposes its catalog and authoring surface. `define` builds the default
//! definition; pass partial `Options` overrides to fork the rules for a custom
//! chain. Resolved facts live on `Protocol`, produced by `fork(revision)` or
//! `protocol(window)`.
//!
//! Layer note: most declarations here are protocol *data and derivations*.
//! `eth.block_stf` is the concrete Ethereum block-transition layer above
//! `Vm.BlockSession`; raw message execution still lives under `executor/` and
//! opcode behavior under `instruction/`.

pub const revision = @import("eth/revision.zig");
pub const config = @import("eth/config.zig");
pub const bal = @import("eth/bal.zig");
pub const bal_recorder = @import("eth/bal_recorder.zig");
pub const instruction = @import("eth/instruction.zig");
pub const transaction = @import("eth/transaction.zig");
pub const transaction_prepare = @import("eth/transaction_prepare.zig");
pub const transaction_validation = @import("eth/transaction_validation.zig");
pub const settlement = @import("eth/settlement.zig");
pub const precompile = @import("eth/precompile.zig");
pub const system = @import("eth/system.zig");
pub const header = @import("eth/header.zig");
pub const trie = @import("eth/trie.zig");
pub const block_stf = @import("eth/block_stf.zig");
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
pub const DefinitionOptions = config.Options;

/// Build an Ethereum `Definition`, applying any `options` over the mainnet defaults.
pub fn define(comptime options: DefinitionOptions(Revision)) definition_mod.Definition(Revision) {
    return config.define(options);
}

/// `define` for a caller-supplied revision enum `R` instead of the built-in `Revision`.
pub fn defineFor(comptime R: type, comptime options: DefinitionOptions(R)) definition_mod.Definition(R) {
    return config.defineFor(R, options);
}

/// The default mainnet Ethereum definition value.
pub const definition = define(.{});
const Definition = definition_mod.Bound(definition);

pub const ExecutionHeader = header.ExecutionHeader;
pub const Withdrawal = @import("eth/Withdrawal.zig");
pub const BlockSTF = block_stf;
/// The Ethereum protocol bound across every supported revision.
pub const Protocol = protocol(.all);

/// Bind the Ethereum definition into a `Protocol` type over `support_window` revisions.
pub fn protocol(comptime support_window: Definition.Support) type {
    return protocol_mod.Protocol(definition, support_window);
}

/// Bind the Ethereum `Protocol` pinned to a single `revision_value`.
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
