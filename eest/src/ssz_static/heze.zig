//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at heze.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");
const capella_types = @import("capella.zig");
const deneb_types = @import("deneb.zig");
const electra_types = @import("electra.zig");
const fulu_types = @import("fulu.zig");
const gloas_types = @import("gloas.zig");

pub const ExecutionPayloadBidHeze = struct {
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
    inclusion_list_bits: [16]bool,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .blob_kzg_commitments = ssz.ProgressiveListOf(ssz.ByteVector(48)),
        .inclusion_list_bits = ssz.Bitvector(16),
    });
};

pub const SignedExecutionPayloadBidHeze = struct {
    message: ExecutionPayloadBidHeze,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockBodyHezeMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const gloas_types.AttesterSlashingGloas,
    attestations: []const gloas_types.AttestationGloasMainnet,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    signed_execution_payload_bid: SignedExecutionPayloadBidHeze,
    payload_attestations: []const gloas_types.PayloadAttestationGloasMainnet,
    parent_execution_requests: gloas_types.ExecutionRequestsGloas,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .proposer_slashings = ssz.ProgressiveListOf(phase0_types.ProposerSlashing.Ssz),
        .attester_slashings = ssz.ProgressiveListOf(gloas_types.AttesterSlashingGloas.Ssz),
        .attestations = ssz.ProgressiveListOf(gloas_types.AttestationGloasMainnet.Ssz),
        .deposits = ssz.ProgressiveListOf(phase0_types.Deposit.Ssz),
        .voluntary_exits = ssz.ProgressiveListOf(phase0_types.SignedVoluntaryExit.Ssz),
        .bls_to_execution_changes = ssz.ProgressiveListOf(capella_types.SignedBLSToExecutionChange.Ssz),
        .payload_attestations = ssz.ProgressiveListOf(gloas_types.PayloadAttestationGloasMainnet.Ssz),
    });
};

pub const BeaconBlockBodyHezeMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const gloas_types.AttesterSlashingGloas,
    attestations: []const gloas_types.AttestationGloasMinimal,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    bls_to_execution_changes: []const capella_types.SignedBLSToExecutionChange,
    signed_execution_payload_bid: SignedExecutionPayloadBidHeze,
    payload_attestations: []const gloas_types.PayloadAttestationGloasMinimal,
    parent_execution_requests: gloas_types.ExecutionRequestsGloas,

    pub const Ssz = ssz.ProgressiveContainer(@This(), [_]bool{ true, true, true, true, true, true, true, true, true, true, true, true, true }, .{
        .proposer_slashings = ssz.ProgressiveListOf(phase0_types.ProposerSlashing.Ssz),
        .attester_slashings = ssz.ProgressiveListOf(gloas_types.AttesterSlashingGloas.Ssz),
        .attestations = ssz.ProgressiveListOf(gloas_types.AttestationGloasMinimal.Ssz),
        .deposits = ssz.ProgressiveListOf(phase0_types.Deposit.Ssz),
        .voluntary_exits = ssz.ProgressiveListOf(phase0_types.SignedVoluntaryExit.Ssz),
        .bls_to_execution_changes = ssz.ProgressiveListOf(capella_types.SignedBLSToExecutionChange.Ssz),
        .payload_attestations = ssz.ProgressiveListOf(gloas_types.PayloadAttestationGloasMinimal.Ssz),
    });
};

pub const BeaconBlockHezeMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyHezeMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockHezeMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyHezeMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconStateHezeMainnet = struct {
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
    builders: []const gloas_types.Builder,
    next_withdrawal_builder_index: u64,
    execution_payload_availability: []const bool,
    builder_pending_payments: []const gloas_types.BuilderPendingPayment,
    builder_pending_withdrawals: []const gloas_types.BuilderPendingWithdrawal,
    latest_execution_payload_bid: ExecutionPayloadBidHeze,
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
        .builders = ssz.ProgressiveListOf(gloas_types.Builder.Ssz),
        .execution_payload_availability = ssz.Alloc(ssz.Bitvector(8192)),
        .builder_pending_payments = ssz.Alloc(ssz.VectorOf(gloas_types.BuilderPendingPayment.Ssz, 64)),
        .builder_pending_withdrawals = ssz.ProgressiveListOf(gloas_types.BuilderPendingWithdrawal.Ssz),
        .payload_expected_withdrawals = ssz.ProgressiveListOf(capella_types.Withdrawal.Ssz),
        .ptc_window = ssz.Alloc(ssz.VectorOf(ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 512)), 96)),
    });
};

pub const BeaconStateHezeMinimal = struct {
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
    builders: []const gloas_types.Builder,
    next_withdrawal_builder_index: u64,
    execution_payload_availability: [64]bool,
    builder_pending_payments: []const gloas_types.BuilderPendingPayment,
    builder_pending_withdrawals: []const gloas_types.BuilderPendingWithdrawal,
    latest_execution_payload_bid: ExecutionPayloadBidHeze,
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
        .builders = ssz.ProgressiveListOf(gloas_types.Builder.Ssz),
        .execution_payload_availability = ssz.Bitvector(64),
        .builder_pending_payments = ssz.Alloc(ssz.VectorOf(gloas_types.BuilderPendingPayment.Ssz, 16)),
        .builder_pending_withdrawals = ssz.ProgressiveListOf(gloas_types.BuilderPendingWithdrawal.Ssz),
        .payload_expected_withdrawals = ssz.ProgressiveListOf(capella_types.Withdrawal.Ssz),
        .ptc_window = ssz.Alloc(ssz.VectorOf(ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 16)), 24)),
    });
};

pub const InclusionList = struct {
    slot: u64,
    validator_index: u64,
    inclusion_list_committee_root: [32]u8,
    transactions: []const []const u8,

    pub const Ssz = ssz.Container(@This(), .{
        .transactions = ssz.ProgressiveListOf(ssz.ProgressiveByteList),
    });
};

pub const SignedBeaconBlockHezeMainnet = struct {
    message: BeaconBlockHezeMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockHezeMinimal = struct {
    message: BeaconBlockHezeMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedInclusionList = struct {
    message: InclusionList,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
