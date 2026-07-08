//! The Ethereum protocol definition.
//!
//! This module is the concrete `Definition` for mainnet Ethereum: it wires the
//! per-domain spec tables (`eth/*.zig`, `eth/eip/*.zig`) into a single value and
//! exposes the derived surface the rest of the engine binds against. `define`
//! builds the default definition; pass partial `Options` overrides to fork the
//! rules for a custom chain. `fork(revision)` / `protocol(window)` produce the
//! bound `Protocol` type a `Vm`/`Executor` runs on.
//!
//! Layer note: everything here is protocol *data and derivations*. Runtime
//! behavior lives under `executor/` and `instruction/`.

pub const revision = @import("eth/revision.zig");
pub const config = @import("eth/config.zig");
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
pub const RevisionOptions = config.RevisionOptions;

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

pub const name = Definition.name;
pub const revisions = Definition.revisions;
pub const latest = Definition.latest;
pub const stable = Definition.stable;
pub const isImpl = Definition.isImpl;
pub const Availability = Definition.Availability;
pub const Support = Definition.Support;
pub const resolveAvailability = Definition.resolveAvailability;
pub const StaticGasSource = Definition.StaticGasSource;

pub const Instruction = Definition.Instruction;
pub const Transaction = Definition.Transaction;
pub const Settlement = Definition.Settlement;
pub const Authorization = Definition.Authorization;
pub const Block = Definition.Block;
pub const Call = Definition.Call;
pub const Create = Definition.Create;
pub const SelfDestruct = Definition.SelfDestruct;
pub const Storage = Definition.Storage;
pub const Precompile = Definition.Precompile;

/// The Ethereum protocol bound across every supported revision.
pub const Protocol = protocol(.all);

/// Bind the Ethereum definition into a `Protocol` type over `support_window` revisions.
pub fn protocol(comptime support_window: Support) type {
    return protocol_mod.Protocol(definition, .{ .support = support_window });
}

/// Bind the Ethereum `Protocol` pinned to a single `revision_value`.
pub fn fork(comptime revision_value: Revision) type {
    return protocol(Support.at(revision_value));
}

pub const system_address = system.system_address;
pub const beacon_roots_address = system.beacon_roots_address;
pub const history_storage_address = system.history_storage_address;
pub const value_transfer_log_topic = system.value_transfer_log_topic;
pub const system_call_gas = system.system_call_gas;

pub const opcodeInfoByte = Definition.opcodeInfoByte;
pub const opcodeInfo = Definition.opcodeInfo;
pub const opcodeAvailabilityByte = Definition.opcodeAvailabilityByte;
pub const opcodeAvailability = Definition.opcodeAvailability;
pub const opcodeTierByte = Definition.opcodeTierByte;
pub const opcodeTier = Definition.opcodeTier;
pub const staticGasForRevisionByte = Definition.staticGasForRevisionByte;
pub const staticGasForRevision = Definition.staticGasForRevision;
