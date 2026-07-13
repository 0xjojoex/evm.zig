//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at capella.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");
const bellatrix_types = @import("bellatrix.zig");

pub const BLSToExecutionChange = struct {
    validator_index: u64,
    from_bls_pubkey: [48]u8,
    to_execution_address: [20]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: [20]u8,
    amount: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionPayloadCapellaMainnet = struct {
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
    withdrawals: []const Withdrawal,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ListOf(ssz.ByteList(1073741824), 1048576),
        .withdrawals = ssz.ListOf(Withdrawal.Ssz, 16),
    });
};

pub const SignedBLSToExecutionChange = struct {
    message: BLSToExecutionChange,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockBodyCapellaMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    execution_payload: ExecutionPayloadCapellaMainnet,
    bls_to_execution_changes: []const SignedBLSToExecutionChange,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(SignedBLSToExecutionChange.Ssz, 16),
    });
};

pub const ExecutionPayloadCapellaMinimal = struct {
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
    withdrawals: []const Withdrawal,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ListOf(ssz.ByteList(1073741824), 1048576),
        .withdrawals = ssz.ListOf(Withdrawal.Ssz, 4),
    });
};

pub const BeaconBlockBodyCapellaMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    execution_payload: ExecutionPayloadCapellaMinimal,
    bls_to_execution_changes: []const SignedBLSToExecutionChange,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
        .bls_to_execution_changes = ssz.ListOf(SignedBLSToExecutionChange.Ssz, 16),
    });
};

pub const BeaconBlockCapellaMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyCapellaMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockCapellaMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyCapellaMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionPayloadHeaderCapella = struct {
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

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
    });
};

pub const HistoricalSummary = struct {
    block_summary_root: [32]u8,
    state_summary_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconStateCapellaMainnet = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderCapella,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const HistoricalSummary,

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
        .historical_summaries = ssz.ListOf(HistoricalSummary.Ssz, 16777216),
    });
};

pub const BeaconStateCapellaMinimal = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderCapella,
    next_withdrawal_index: u64,
    next_withdrawal_validator_index: u64,
    historical_summaries: []const HistoricalSummary,

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
        .historical_summaries = ssz.ListOf(HistoricalSummary.Ssz, 16777216),
    });
};

pub const LightClientHeaderCapella = struct {
    beacon: phase0_types.BeaconBlockHeader,
    execution: ExecutionPayloadHeaderCapella,
    execution_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .execution_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 4)),
    });
};

pub const LightClientBootstrapCapellaMainnet = struct {
    header: LightClientHeaderCapella,
    current_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientBootstrapCapellaMinimal = struct {
    header: LightClientHeaderCapella,
    current_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientFinalityUpdateCapellaMainnet = struct {
    attested_header: LightClientHeaderCapella,
    finalized_header: LightClientHeaderCapella,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientFinalityUpdateCapellaMinimal = struct {
    attested_header: LightClientHeaderCapella,
    finalized_header: LightClientHeaderCapella,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientOptimisticUpdateCapellaMainnet = struct {
    attested_header: LightClientHeaderCapella,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientOptimisticUpdateCapellaMinimal = struct {
    attested_header: LightClientHeaderCapella,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientUpdateCapellaMainnet = struct {
    attested_header: LightClientHeaderCapella,
    next_sync_committee: altair_types.SyncCommitteeAltairMainnet,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderCapella,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientUpdateCapellaMinimal = struct {
    attested_header: LightClientHeaderCapella,
    next_sync_committee: altair_types.SyncCommitteeAltairMinimal,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderCapella,
    finality_branch: []const [32]u8,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const SignedBeaconBlockCapellaMainnet = struct {
    message: BeaconBlockCapellaMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockCapellaMinimal = struct {
    message: BeaconBlockCapellaMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
