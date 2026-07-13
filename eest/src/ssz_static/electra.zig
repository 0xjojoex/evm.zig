//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at electra.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");
const capella_types = @import("capella.zig");
const deneb_types = @import("deneb.zig");

pub const AttestationElectraMainnet = struct {
    aggregation_bits: []const bool,
    data: phase0_types.AttestationData,
    signature: [96]u8,
    committee_bits: [64]bool,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitlist(131072),
        .committee_bits = ssz.Bitvector(64),
    });
};

pub const AggregateAndProofElectraMainnet = struct {
    aggregator_index: u64,
    aggregate: AttestationElectraMainnet,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const AttestationElectraMinimal = struct {
    aggregation_bits: []const bool,
    data: phase0_types.AttestationData,
    signature: [96]u8,
    committee_bits: [4]bool,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitlist(8192),
        .committee_bits = ssz.Bitvector(4),
    });
};

pub const AggregateAndProofElectraMinimal = struct {
    aggregator_index: u64,
    aggregate: AttestationElectraMinimal,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const IndexedAttestationElectraMainnet = struct {
    attesting_indices: []const u64,
    data: phase0_types.AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .attesting_indices = ssz.ListOf(ssz.Fixed(u64), 131072),
    });
};

pub const AttesterSlashingElectraMainnet = struct {
    attestation_1: IndexedAttestationElectraMainnet,
    attestation_2: IndexedAttestationElectraMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const IndexedAttestationElectraMinimal = struct {
    attesting_indices: []const u64,
    data: phase0_types.AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .attesting_indices = ssz.ListOf(ssz.Fixed(u64), 8192),
    });
};

pub const AttesterSlashingElectraMinimal = struct {
    attestation_1: IndexedAttestationElectraMinimal,
    attestation_2: IndexedAttestationElectraMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const DepositRequest = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,
    index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const WithdrawalRequest = struct {
    source_address: [20]u8,
    validator_pubkey: [48]u8,
    amount: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ConsolidationRequest = struct {
    source_address: [20]u8,
    source_pubkey: [48]u8,
    target_pubkey: [48]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionRequestsElectra = struct {
    deposits: []const DepositRequest,
    withdrawals: []const WithdrawalRequest,
    consolidations: []const ConsolidationRequest,

    pub const Ssz = ssz.Container(@This(), .{
        .deposits = ssz.ListOf(DepositRequest.Ssz, 8192),
        .withdrawals = ssz.ListOf(WithdrawalRequest.Ssz, 16),
        .consolidations = ssz.ListOf(ConsolidationRequest.Ssz, 2),
    });
};

pub const BeaconBlockBodyElectraMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const AttesterSlashingElectraMainnet,
    attestations: []const AttestationElectraMainnet,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    execution_payload: deneb_types.ExecutionPayloadDenebMainnet,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    blob_kzg_commitments: []const [48]u8,
    execution_requests: ExecutionRequestsElectra,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(AttesterSlashingElectraMainnet.Ssz, 1),
        .attestations = ssz.ListOf(AttestationElectraMainnet.Ssz, 8),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(capella_types.SignedBLSToExecutionChange.Ssz, 16),
        .blob_kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
    });
};

pub const BeaconBlockBodyElectraMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const AttesterSlashingElectraMinimal,
    attestations: []const AttestationElectraMinimal,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    execution_payload: deneb_types.ExecutionPayloadDenebMinimal,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    blob_kzg_commitments: []const [48]u8,
    execution_requests: ExecutionRequestsElectra,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(AttesterSlashingElectraMinimal.Ssz, 1),
        .attestations = ssz.ListOf(AttestationElectraMinimal.Ssz, 8),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(capella_types.SignedBLSToExecutionChange.Ssz, 16),
        .blob_kzg_commitments = ssz.ListOf(ssz.ByteVector(48), 4096),
    });
};

pub const BeaconBlockElectraMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyElectraMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockElectraMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyElectraMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PendingDeposit = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,
    slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PendingPartialWithdrawal = struct {
    validator_index: u64,
    amount: u64,
    withdrawable_epoch: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PendingConsolidation = struct {
    source_index: u64,
    target_index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconStateElectraMainnet = struct {
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
    pending_deposits: []const PendingDeposit,
    pending_partial_withdrawals: []const PendingPartialWithdrawal,
    pending_consolidations: []const PendingConsolidation,

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
        .pending_deposits = ssz.ListOf(PendingDeposit.Ssz, 134217728),
        .pending_partial_withdrawals = ssz.ListOf(PendingPartialWithdrawal.Ssz, 134217728),
        .pending_consolidations = ssz.ListOf(PendingConsolidation.Ssz, 262144),
    });
};

pub const BeaconStateElectraMinimal = struct {
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
    pending_deposits: []const PendingDeposit,
    pending_partial_withdrawals: []const PendingPartialWithdrawal,
    pending_consolidations: []const PendingConsolidation,

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
        .pending_deposits = ssz.ListOf(PendingDeposit.Ssz, 134217728),
        .pending_partial_withdrawals = ssz.ListOf(PendingPartialWithdrawal.Ssz, 64),
        .pending_consolidations = ssz.ListOf(PendingConsolidation.Ssz, 64),
    });
};

pub const LightClientBootstrapElectraMainnet = struct {
    header: deneb_types.LightClientHeaderDeneb,
    current_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientBootstrapElectraMinimal = struct {
    header: deneb_types.LightClientHeaderDeneb,
    current_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientFinalityUpdateElectraMainnet = struct {
    attested_header: deneb_types.LightClientHeaderDeneb,
    finalized_header: deneb_types.LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 7)),
    });
};

pub const LightClientFinalityUpdateElectraMinimal = struct {
    attested_header: deneb_types.LightClientHeaderDeneb,
    finalized_header: deneb_types.LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 7)),
    });
};

pub const LightClientUpdateElectraMainnet = struct {
    attested_header: deneb_types.LightClientHeaderDeneb,
    next_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: deneb_types.LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 7)),
    });
};

pub const LightClientUpdateElectraMinimal = struct {
    attested_header: deneb_types.LightClientHeaderDeneb,
    next_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: deneb_types.LightClientHeaderDeneb,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 7)),
    });
};

pub const SignedAggregateAndProofElectraMainnet = struct {
    message: AggregateAndProofElectraMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedAggregateAndProofElectraMinimal = struct {
    message: AggregateAndProofElectraMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockElectraMainnet = struct {
    message: BeaconBlockElectraMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockElectraMinimal = struct {
    message: BeaconBlockElectraMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SingleAttestation = struct {
    committee_index: u64,
    attester_index: u64,
    data: phase0_types.AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
