//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at gloas.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");
const capella_types = @import("capella.zig");
const deneb_types = @import("deneb.zig");
const electra_types = @import("electra.zig");
const fulu_types = @import("fulu.zig");

pub const AttestationGloasMainnet = struct {
    aggregation_bits: []const bool,
    data: phase0_types.AttestationData,
    signature: [96]u8,
    committee_bits: [64]bool,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true }, .{
        .aggregation_bits = ssz.ProgressiveBitlist,
        .committee_bits = ssz.Bitvector(64),
    });
};

pub const AggregateAndProofGloasMainnet = struct {
    aggregator_index: u64,
    aggregate: AttestationGloasMainnet,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const AttestationGloasMinimal = struct {
    aggregation_bits: []const bool,
    data: phase0_types.AttestationData,
    signature: [96]u8,
    committee_bits: [4]bool,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true }, .{
        .aggregation_bits = ssz.ProgressiveBitlist,
        .committee_bits = ssz.Bitvector(4),
    });
};

pub const AggregateAndProofGloasMinimal = struct {
    aggregator_index: u64,
    aggregate: AttestationGloasMinimal,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const IndexedAttestationGloas = struct {
    attesting_indices: []const u64,
    data: phase0_types.AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true }, .{
        .attesting_indices = ssz.ProgressiveListOf(ssz.Fixed(u64)),
    });
};

pub const AttesterSlashingGloas = struct {
    attestation_1: IndexedAttestationGloas,
    attestation_2: IndexedAttestationGloas,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionPayloadBidGloas = struct {
    parent_block_hash: [32]u8,
    parent_block_root: [32]u8,
    block_hash: [32]u8,
    prev_randao: [32]u8,
    fee_recipient: [20]u8,
    gas_limit: u64,
    builder_index: u64,
    slot: u64,
    value: u64,
    execution_payment: u64,
    blob_kzg_commitments: []const [48]u8,
    execution_requests_root: [32]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .blob_kzg_commitments = ssz.ProgressiveListOf(ssz.ByteVector(48)),
    });
};

pub const SignedExecutionPayloadBidGloas = struct {
    message: ExecutionPayloadBidGloas,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PayloadAttestationData = struct {
    beacon_block_root: [32]u8,
    slot: u64,
    payload_present: bool,
    blob_data_available: bool,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PayloadAttestationGloasMainnet = struct {
    aggregation_bits: []const bool,
    data: PayloadAttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true }, .{
        .aggregation_bits = ssz.Alloc(ssz.Bitvector(512)),
    });
};

pub const BuilderDepositRequest = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BuilderExitRequest = struct {
    source_address: [20]u8,
    pubkey: [48]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionRequestsGloas = struct {
    deposits: []const electra_types.DepositRequest,
    withdrawals: []const electra_types.WithdrawalRequest,
    consolidations: []const electra_types.ConsolidationRequest,
    builder_deposits: []const BuilderDepositRequest,
    builder_exits: []const BuilderExitRequest,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true }, .{
        .deposits = ssz.ProgressiveListOf(electra_types.DepositRequest.Ssz),
        .withdrawals = ssz.ProgressiveListOf(electra_types.WithdrawalRequest.Ssz),
        .consolidations = ssz.ProgressiveListOf(electra_types.ConsolidationRequest.Ssz),
        .builder_deposits = ssz.ProgressiveListOf(BuilderDepositRequest.Ssz),
        .builder_exits = ssz.ProgressiveListOf(BuilderExitRequest.Ssz),
    });
};

pub const BeaconBlockBodyGloasMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const AttesterSlashingGloas,
    attestations: []const AttestationGloasMainnet,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    signed_execution_payload_bid: SignedExecutionPayloadBidGloas,
    payload_attestations: []const PayloadAttestationGloasMainnet,
    parent_execution_requests: ExecutionRequestsGloas,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .proposer_slashings = ssz.ProgressiveListOf(phase0_types.ProposerSlashing.Ssz),
        .attester_slashings = ssz.ProgressiveListOf(AttesterSlashingGloas.Ssz),
        .attestations = ssz.ProgressiveListOf(AttestationGloasMainnet.Ssz),
        .deposits = ssz.ProgressiveListOf(phase0_types.Deposit.Ssz),
        .voluntary_exits = ssz.ProgressiveListOf(phase0_types.SignedVoluntaryExit.Ssz),
        .bls_to_execution_changes = ssz.ProgressiveListOf(capella_types.SignedBLSToExecutionChange.Ssz),
        .payload_attestations = ssz.ProgressiveListOf(PayloadAttestationGloasMainnet.Ssz),
    });
};

pub const PayloadAttestationGloasMinimal = struct {
    aggregation_bits: [16]bool,
    data: PayloadAttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true }, .{
        .aggregation_bits = ssz.Bitvector(16),
    });
};

pub const BeaconBlockBodyGloasMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const AttesterSlashingGloas,
    attestations: []const AttestationGloasMinimal,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    signed_execution_payload_bid: SignedExecutionPayloadBidGloas,
    payload_attestations: []const PayloadAttestationGloasMinimal,
    parent_execution_requests: ExecutionRequestsGloas,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .proposer_slashings = ssz.ProgressiveListOf(phase0_types.ProposerSlashing.Ssz),
        .attester_slashings = ssz.ProgressiveListOf(AttesterSlashingGloas.Ssz),
        .attestations = ssz.ProgressiveListOf(AttestationGloasMinimal.Ssz),
        .deposits = ssz.ProgressiveListOf(phase0_types.Deposit.Ssz),
        .voluntary_exits = ssz.ProgressiveListOf(phase0_types.SignedVoluntaryExit.Ssz),
        .bls_to_execution_changes = ssz.ProgressiveListOf(capella_types.SignedBLSToExecutionChange.Ssz),
        .payload_attestations = ssz.ProgressiveListOf(PayloadAttestationGloasMinimal.Ssz),
    });
};

pub const BeaconBlockGloasMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyGloasMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockGloasMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyGloasMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Builder = struct {
    pubkey: [48]u8,
    version: u8,
    execution_address: [20]u8,
    balance: u64,
    deposit_epoch: u64,
    withdrawable_epoch: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BuilderPendingWithdrawal = struct {
    fee_recipient: [20]u8,
    amount: u64,
    builder_index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BuilderPendingPayment = struct {
    weight: u64,
    withdrawal: BuilderPendingWithdrawal,
    proposer_index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconStateGloasMainnet = struct {
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
    latest_block_hash: [32]u8,
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
    builders: []const Builder,
    next_withdrawal_builder_index: u64,
    execution_payload_availability: []const bool,
    builder_pending_payments: []const BuilderPendingPayment,
    builder_pending_withdrawals: []const BuilderPendingWithdrawal,
    latest_execution_payload_bid: ExecutionPayloadBidGloas,
    payload_expected_withdrawals: []const capella_types.Withdrawal,
    ptc_window: []const []const u64,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(phase0_types.Eth1Data.Ssz, 2048),
        .validators = ssz.ProgressiveListOf(phase0_types.Validator.Ssz),
        .balances = ssz.ProgressiveListOf(ssz.Fixed(u64)),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 65536)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 8192)),
        .previous_epoch_participation = ssz.ProgressiveByteList,
        .current_epoch_participation = ssz.ProgressiveByteList,
        .justification_bits = ssz.Bitvector(4),
        .inactivity_scores = ssz.ProgressiveListOf(ssz.Fixed(u64)),
        .historical_summaries = ssz.ListOf(capella_types.HistoricalSummary.Ssz, 16777216),
        .pending_deposits = ssz.ProgressiveListOf(electra_types.PendingDeposit.Ssz),
        .pending_partial_withdrawals = ssz.ProgressiveListOf(electra_types.PendingPartialWithdrawal.Ssz),
        .pending_consolidations = ssz.ProgressiveListOf(electra_types.PendingConsolidation.Ssz),
        .proposer_lookahead = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 64)),
        .builders = ssz.ProgressiveListOf(Builder.Ssz),
        .execution_payload_availability = ssz.Alloc(ssz.Bitvector(8192)),
        .builder_pending_payments = ssz.Alloc(ssz.VectorOf(BuilderPendingPayment.Ssz, 64)),
        .builder_pending_withdrawals = ssz.ProgressiveListOf(BuilderPendingWithdrawal.Ssz),
        .payload_expected_withdrawals = ssz.ProgressiveListOf(capella_types.Withdrawal.Ssz),
        .ptc_window = ssz.Alloc(ssz.VectorOf(ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 512)), 96)),
    });
};

pub const BeaconStateGloasMinimal = struct {
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
    latest_block_hash: [32]u8,
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
    builders: []const Builder,
    next_withdrawal_builder_index: u64,
    execution_payload_availability: [64]bool,
    builder_pending_payments: []const BuilderPendingPayment,
    builder_pending_withdrawals: []const BuilderPendingWithdrawal,
    latest_execution_payload_bid: ExecutionPayloadBidGloas,
    payload_expected_withdrawals: []const capella_types.Withdrawal,
    ptc_window: []const []const u64,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(phase0_types.Eth1Data.Ssz, 32),
        .validators = ssz.ProgressiveListOf(phase0_types.Validator.Ssz),
        .balances = ssz.ProgressiveListOf(ssz.Fixed(u64)),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 64)),
        .previous_epoch_participation = ssz.ProgressiveByteList,
        .current_epoch_participation = ssz.ProgressiveByteList,
        .justification_bits = ssz.Bitvector(4),
        .inactivity_scores = ssz.ProgressiveListOf(ssz.Fixed(u64)),
        .historical_summaries = ssz.ListOf(capella_types.HistoricalSummary.Ssz, 16777216),
        .pending_deposits = ssz.ProgressiveListOf(electra_types.PendingDeposit.Ssz),
        .pending_partial_withdrawals = ssz.ProgressiveListOf(electra_types.PendingPartialWithdrawal.Ssz),
        .pending_consolidations = ssz.ProgressiveListOf(electra_types.PendingConsolidation.Ssz),
        .proposer_lookahead = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 16)),
        .builders = ssz.ProgressiveListOf(Builder.Ssz),
        .execution_payload_availability = ssz.Bitvector(64),
        .builder_pending_payments = ssz.Alloc(ssz.VectorOf(BuilderPendingPayment.Ssz, 16)),
        .builder_pending_withdrawals = ssz.ProgressiveListOf(BuilderPendingWithdrawal.Ssz),
        .payload_expected_withdrawals = ssz.ProgressiveListOf(capella_types.Withdrawal.Ssz),
        .ptc_window = ssz.Alloc(ssz.VectorOf(ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 16)), 24)),
    });
};

pub const DataColumnSidecarGloas = struct {
    index: u64,
    column: []const []const u8,
    kzg_proofs: []const [48]u8,
    slot: u64,
    beacon_block_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .column = ssz.ProgressiveListOf(ssz.Alloc(ssz.ByteVector(2048))),
        .kzg_proofs = ssz.ProgressiveListOf(ssz.ByteVector(48)),
    });
};

pub const ExecutionPayloadGloas = struct {
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
    block_access_list: []const u8,
    slot_number: u64,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ProgressiveListOf(ssz.ProgressiveByteList),
        .withdrawals = ssz.ProgressiveListOf(capella_types.Withdrawal.Ssz),
        .block_access_list = ssz.ProgressiveByteList,
    });
};

pub const ExecutionPayloadEnvelope = struct {
    payload: ExecutionPayloadGloas,
    execution_requests: ExecutionRequestsGloas,
    builder_index: u64,
    beacon_block_root: [32]u8,
    parent_beacon_block_root: [32]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true }, .{});
};

pub const IndexedPayloadAttestationGloasMainnet = struct {
    attesting_indices: []const u64,
    data: PayloadAttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true }, .{
        .attesting_indices = ssz.ListOf(ssz.Fixed(u64), 512),
    });
};

pub const IndexedPayloadAttestationGloasMinimal = struct {
    attesting_indices: []const u64,
    data: PayloadAttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true }, .{
        .attesting_indices = ssz.ListOf(ssz.Fixed(u64), 16),
    });
};

pub const LightClientHeaderGloas = struct {
    beacon: phase0_types.BeaconBlockHeader,
    execution_block_hash: [32]u8,
    execution_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .execution_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 11)),
    });
};

pub const LightClientBootstrapGloasMainnet = struct {
    header: LightClientHeaderGloas,
    current_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 11)),
    });
};

pub const LightClientBootstrapGloasMinimal = struct {
    header: LightClientHeaderGloas,
    current_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 11)),
    });
};

pub const LightClientFinalityUpdateGloasMainnet = struct {
    attested_header: LightClientHeaderGloas,
    finalized_header: LightClientHeaderGloas,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 9)),
    });
};

pub const LightClientFinalityUpdateGloasMinimal = struct {
    attested_header: LightClientHeaderGloas,
    finalized_header: LightClientHeaderGloas,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 9)),
    });
};

pub const LightClientOptimisticUpdateGloasMainnet = struct {
    attested_header: LightClientHeaderGloas,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientOptimisticUpdateGloasMinimal = struct {
    attested_header: LightClientHeaderGloas,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientUpdateGloasMainnet = struct {
    attested_header: LightClientHeaderGloas,
    next_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderGloas,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 11)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 9)),
    });
};

pub const LightClientUpdateGloasMinimal = struct {
    attested_header: LightClientHeaderGloas,
    next_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderGloas,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 11)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 9)),
    });
};

pub const PartialDataColumnGroupIDGloas = struct {
    beacon_block_root: [32]u8,
    slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PartialDataColumnSidecarGloas = struct {
    cells_present_bitmap: []const bool,
    partial_column: []const []const u8,
    kzg_proofs: []const [48]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .cells_present_bitmap = ssz.ProgressiveBitlist,
        .partial_column = ssz.ProgressiveListOf(ssz.Alloc(ssz.ByteVector(2048))),
        .kzg_proofs = ssz.ProgressiveListOf(ssz.ByteVector(48)),
    });
};

pub const PayloadAttestationMessage = struct {
    validator_index: u64,
    data: PayloadAttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ProposerPreferences = struct {
    dependent_root: [32]u8,
    proposal_slot: u64,
    validator_index: u64,
    fee_recipient: [20]u8,
    target_gas_limit: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedAggregateAndProofGloasMainnet = struct {
    message: AggregateAndProofGloasMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedAggregateAndProofGloasMinimal = struct {
    message: AggregateAndProofGloasMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockGloasMainnet = struct {
    message: BeaconBlockGloasMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockGloasMinimal = struct {
    message: BeaconBlockGloasMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedExecutionPayloadEnvelope = struct {
    message: ExecutionPayloadEnvelope,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedProposerPreferences = struct {
    message: ProposerPreferences,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
