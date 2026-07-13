//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at fulu.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");
const capella_types = @import("capella.zig");
const deneb_types = @import("deneb.zig");
const electra_types = @import("electra.zig");

pub const BeaconStateFuluMainnet = struct {
    genesis_time: u64,
    genesis_validators_root: [32]u8,
    slot: u64,
    fork: phase0_types.Fork,
    latest_block_header: phase0_types.BeaconBlockHeader,
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,
    historical_roots: []const [32]u8,
    eth1_data: phase0_types.Eth1Data,
    eth1_data_votes: []const phase0_types.Eth1Data,
    eth1_deposit_index: u64,
    validators: []const phase0_types.Validator,
    balances: []const u64,
    randao_mixes: []const [32]u8,
    slashings: []const u64,
    previous_epoch_participation: []const u8,
    current_epoch_participation: []const u8,
    justification_bits: [4]bool,
    previous_justified_checkpoint: phase0_types.Checkpoint,
    current_justified_checkpoint: phase0_types.Checkpoint,
    finalized_checkpoint: phase0_types.Checkpoint,
    inactivity_scores: []const u64,
    current_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    next_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    latest_execution_payload_header: deneb_types.ExecutionPayloadHeaderDeneb,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const capella_types.HistoricalSummary,
    deposit_requests_start_index: u64,
    deposit_balance_to_consume: u64,
    exit_balance_to_consume: u64,
    earliest_exit_epoch: u64,
    consolidation_balance_to_consume: u64,
    earliest_consolidation_epoch: u64,
    pending_deposits: []const electra_types.PendingDeposit,
    pending_partial_withdrawals: []const electra_types.PendingPartialWithdrawal,
    pending_consolidations: []const electra_types.PendingConsolidation,
    proposer_lookahead: []const u64,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(phase0_types.Eth1Data.Ssz, 2048),
        .validators = ssz.ListOf(phase0_types.Validator.Ssz, 1099511627776),
        .balances = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 65536)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 8192)),
        .previous_epoch_participation = ssz.ListOf(ssz.Fixed(u8), 1099511627776),
        .current_epoch_participation = ssz.ListOf(ssz.Fixed(u8), 1099511627776),
        .justification_bits = ssz.Bitvector(4),
        .inactivity_scores = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .historical_summaries = ssz.ListOf(capella_types.HistoricalSummary.Ssz, 16777216),
        .pending_deposits = ssz.ListOf(electra_types.PendingDeposit.Ssz, 134217728),
        .pending_partial_withdrawals = ssz.ListOf(electra_types.PendingPartialWithdrawal.Ssz, 134217728),
        .pending_consolidations = ssz.ListOf(electra_types.PendingConsolidation.Ssz, 262144),
        .proposer_lookahead = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 64)),
    });
};

pub const BeaconStateFuluMinimal = struct {
    genesis_time: u64,
    genesis_validators_root: [32]u8,
    slot: u64,
    fork: phase0_types.Fork,
    latest_block_header: phase0_types.BeaconBlockHeader,
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,
    historical_roots: []const [32]u8,
    eth1_data: phase0_types.Eth1Data,
    eth1_data_votes: []const phase0_types.Eth1Data,
    eth1_deposit_index: u64,
    validators: []const phase0_types.Validator,
    balances: []const u64,
    randao_mixes: []const [32]u8,
    slashings: []const u64,
    previous_epoch_participation: []const u8,
    current_epoch_participation: []const u8,
    justification_bits: [4]bool,
    previous_justified_checkpoint: phase0_types.Checkpoint,
    current_justified_checkpoint: phase0_types.Checkpoint,
    finalized_checkpoint: phase0_types.Checkpoint,
    inactivity_scores: []const u64,
    current_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    next_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    latest_execution_payload_header: deneb_types.ExecutionPayloadHeaderDeneb,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const capella_types.HistoricalSummary,
    deposit_requests_start_index: u64,
    deposit_balance_to_consume: u64,
    exit_balance_to_consume: u64,
    earliest_exit_epoch: u64,
    consolidation_balance_to_consume: u64,
    earliest_consolidation_epoch: u64,
    pending_deposits: []const electra_types.PendingDeposit,
    pending_partial_withdrawals: []const electra_types.PendingPartialWithdrawal,
    pending_consolidations: []const electra_types.PendingConsolidation,
    proposer_lookahead: []const u64,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(phase0_types.Eth1Data.Ssz, 32),
        .validators = ssz.ListOf(phase0_types.Validator.Ssz, 1099511627776),
        .balances = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 64)),
        .previous_epoch_participation = ssz.ListOf(ssz.Fixed(u8), 1099511627776),
        .current_epoch_participation = ssz.ListOf(ssz.Fixed(u8), 1099511627776),
        .justification_bits = ssz.Bitvector(4),
        .inactivity_scores = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .historical_summaries = ssz.ListOf(capella_types.HistoricalSummary.Ssz, 16777216),
        .pending_deposits = ssz.ListOf(electra_types.PendingDeposit.Ssz, 134217728),
        .pending_partial_withdrawals = ssz.ListOf(electra_types.PendingPartialWithdrawal.Ssz, 64),
        .pending_consolidations = ssz.ListOf(electra_types.PendingConsolidation.Ssz, 64),
        .proposer_lookahead = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 16)),
    });
};

pub const DataColumnSidecarFulu = struct {
    index: u64,
    column: []const []const u8,
    kzg_commitments: []const [48]u8,
    kzg_proofs: []const [48]u8,
    signed_block_header: phase0_types.SignedBeaconBlockHeader,
    kzg_commitments_inclusion_proof: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .column = ssz.ListOf(ssz.Alloc(ssz.ByteVector(2048)), 4096),
        .kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
        .kzg_proofs = ssz.ListOf(ssz.ByteVector(48), 4096),
        .kzg_commitments_inclusion_proof = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 4)),
    });
};

pub const DataColumnsByRootIdentifier = struct {
    block_root: [32]u8,
    columns: []const u64,

    pub const Ssz = ssz.Container(@This(), .{
        .columns = ssz.ListOf(ssz.Fixed(u64), 128),
    });
};

pub const MatrixEntry = struct {
    cell: []const u8,
    kzg_proof: [48]u8,
    column_index: u64,
    row_index: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .cell = ssz.Alloc(ssz.ByteVector(2048)),
    });
};

pub const PartialDataColumnGroupIDFulu = struct {
    beacon_block_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PartialDataColumnHeader = struct {
    kzg_commitments: []const [48]u8,
    signed_block_header: phase0_types.SignedBeaconBlockHeader,
    kzg_commitments_inclusion_proof: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
        .kzg_commitments_inclusion_proof = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 4)),
    });
};

pub const PartialDataColumnPartsMetadata = struct {
    available: []const bool,
    requests: []const bool,

    pub const Ssz = ssz.Container(@This(), .{
        .available = ssz.Bitlist(4096),
        .requests = ssz.Bitlist(4096),
    });
};

pub const PartialDataColumnSidecarFulu = struct {
    cells_present_bitmap: []const bool,
    partial_column: []const []const u8,
    kzg_proofs: []const [48]u8,
    header: []const PartialDataColumnHeader,

    pub const Ssz = ssz.Container(@This(), .{
        .cells_present_bitmap = ssz.Bitlist(4096),
        .partial_column = ssz.ListOf(ssz.Alloc(ssz.ByteVector(2048)), 4096),
        .kzg_proofs = ssz.ListOf(ssz.ByteVector(48), 4096),
        .header = ssz.ListOf(PartialDataColumnHeader.Ssz, 1),
    });
};
