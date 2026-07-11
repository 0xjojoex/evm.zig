//! The Ethereum protocol definition.
//!
//! This module is the concrete `Definition` for mainnet Ethereum: it wires the
//! per-domain spec tables (`eth/*.zig`, `eth/eip/*.zig`) into a single value and
//! exposes its catalog and authoring surface. `define` builds the default
//! definition; pass partial `Options` overrides to fork the rules for a custom
//! chain. Resolved facts live on `Protocol`, produced by `fork(revision)` or
//! `protocol(window)`.
//!
//! Layer note: everything here is protocol *data and derivations*. Runtime
//! behavior lives under `executor/` and `instruction/`.

pub const revision = @import("eth/revision.zig");
pub const config = @import("eth/config.zig");
pub const bal = @import("eth/bal.zig");
pub const bal_recorder = @import("eth/bal_recorder.zig");
pub const instruction = @import("eth/instruction.zig");
pub const transaction = @import("eth/transaction.zig");
pub const settlement = @import("eth/settlement.zig");
pub const precompile = @import("eth/precompile.zig");
pub const system = @import("eth/system.zig");
pub const eip7702 = @import("eth/eip/7702.zig");
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
pub const value_transfer_log_topic = system.value_transfer_log_topic;
pub const system_call_gas = system.system_call_gas;
