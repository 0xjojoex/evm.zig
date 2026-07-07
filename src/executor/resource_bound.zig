//! Source-neutral resource-bound envelope for bounded execution.
//!
//! Producers can derive this from conservative gas formulas or from declared
//! block/witness/BAL inputs. Executor wiring should consume this envelope rather
//! than source-specific planner shapes.

const StateOverlay = @import("../state/Overlay.zig");

pub const Source = enum {
    gas_derived,
    declared,
};

pub const LogResources = StateOverlay.LogResources;
pub const AccessResources = StateOverlay.AccessResources;
pub const StateResources = StateOverlay.StateResources;

pub const empty_logs: LogResources = .{
    .entries = 0,
    .data_bytes = 0,
};

pub const empty_access: AccessResources = .{
    .accounts = 0,
    .storage_keys = 0,
};

pub const BlockResources = struct {
    state: StateResources = .{},
};

pub const TransactionResources = struct {
    max_live_frames: usize,
    logs: LogResources = empty_logs,
    journal_entries: usize = 0,
    access: AccessResources = empty_access,
    state: StateResources = .{},
    transient_storage_entries: usize = 0,
};

pub const Envelope = struct {
    source: Source,
    block: BlockResources = .{},
    transaction: TransactionResources,
};
