//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at deneb.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");
const capella_types = @import("capella.zig");

pub const ExecutionPayloadDenebMainnet = struct {
    parent_hash: [32]u8,
    fee_recipient: [20]u8,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: u256,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const capella_types.Withdrawal,
    blob_gas_used: u64,
    excess_blob_gas: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ListOf(ssz.ByteList(1073741824), 1048576),
        .withdrawals = ssz.ListOf(capella_types.Withdrawal.Ssz, 16),
    });
};

pub const BeaconBlockBodyDenebMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    execution_payload: ExecutionPayloadDenebMainnet,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    blob_kzg_commitments: []const [48]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(capella_types.SignedBLSToExecutionChange.Ssz, 16),
        .blob_kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
    });
};

pub const ExecutionPayloadDenebMinimal = struct {
    parent_hash: [32]u8,
    fee_recipient: [20]u8,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: u256,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const capella_types.Withdrawal,
    blob_gas_used: u64,
    excess_blob_gas: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ListOf(ssz.ByteList(1073741824), 1048576),
        .withdrawals = ssz.ListOf(capella_types.Withdrawal.Ssz, 4),
    });
};

pub const BeaconBlockBodyDenebMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    execution_payload: ExecutionPayloadDenebMinimal,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    blob_kzg_commitments: []const [48]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(capella_types.SignedBLSToExecutionChange.Ssz, 16),
        .blob_kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
    });
};

pub const BeaconBlockDenebMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyDenebMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockDenebMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyDenebMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionPayloadHeaderDeneb = struct {
    parent_hash: [32]u8,
    fee_recipient: [20]u8,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: u256,
    block_hash: [32]u8,
    transactions_root: [32]u8,
    withdrawals_root: [32]u8,
    blob_gas_used: u64,
    excess_blob_gas: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
    });
};

pub const BeaconStateDenebMainnet = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderDeneb,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const capella_types.HistoricalSummary,

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
    });
};

pub const BeaconStateDenebMinimal = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderDeneb,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const capella_types.HistoricalSummary,

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
    });
};

pub const BlobIdentifier = struct {
    block_root: [32]u8,
    index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BlobSidecar = struct {
    index: u64,
    blob: []const u8,
    kzg_commitment: [48]u8,
    kzg_proof: [48]u8,
    signed_block_header: phase0_types.SignedBeaconBlockHeader,
    kzg_commitment_inclusion_proof: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .blob = ssz.Alloc(ssz.ByteVector(131072)),
        .kzg_commitment_inclusion_proof = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 17)),
    });
};

pub const LightClientHeaderDeneb = struct {
    beacon: phase0_types.BeaconBlockHeader,
    execution: ExecutionPayloadHeaderDeneb,
    execution_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .execution_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 4)),
    });
};

pub const LightClientBootstrapDenebMainnet = struct {
    header: LightClientHeaderDeneb,
    current_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientBootstrapDenebMinimal = struct {
    header: LightClientHeaderDeneb,
    current_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientFinalityUpdateDenebMainnet = struct {
    attested_header: LightClientHeaderDeneb,
    finalized_header: LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientFinalityUpdateDenebMinimal = struct {
    attested_header: LightClientHeaderDeneb,
    finalized_header: LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientOptimisticUpdateDenebMainnet = struct {
    attested_header: LightClientHeaderDeneb,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientOptimisticUpdateDenebMinimal = struct {
    attested_header: LightClientHeaderDeneb,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientUpdateDenebMainnet = struct {
    attested_header: LightClientHeaderDeneb,
    next_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientUpdateDenebMinimal = struct {
    attested_header: LightClientHeaderDeneb,
    next_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const SignedBeaconBlockDenebMainnet = struct {
    message: BeaconBlockDenebMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockDenebMinimal = struct {
    message: BeaconBlockDenebMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
