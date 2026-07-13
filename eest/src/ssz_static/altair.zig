//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at altair.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");

pub const SyncAggregateAltairMainnet = struct {
    sync_committee_bits: []const bool,
    sync_committee_signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .sync_committee_bits = ssz.Alloc(ssz.Bitvector(512)),
    });
};

pub const BeaconBlockBodyAltairMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: SyncAggregateAltairMainnet,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
    });
};

pub const BeaconBlockAltairMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyAltairMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SyncAggregateAltairMinimal = struct {
    sync_committee_bits: [32]bool,
    sync_committee_signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .sync_committee_bits = ssz.Bitvector(32),
    });
};

pub const BeaconBlockBodyAltairMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: SyncAggregateAltairMinimal,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
    });
};

pub const BeaconBlockAltairMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyAltairMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SyncCommitteeAltairMainnet = struct {
    pubkeys: []const [48]u8,
    aggregate_pubkey: [48]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .pubkeys = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(48), 512)),
    });
};

pub const BeaconStateAltairMainnet = struct {
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
    current_sync_committee: SyncCommitteeAltairMainnet,
    next_sync_committee: SyncCommitteeAltairMainnet,

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
    });
};

pub const SyncCommitteeAltairMinimal = struct {
    pubkeys: []const [48]u8,
    aggregate_pubkey: [48]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .pubkeys = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(48), 32)),
    });
};

pub const BeaconStateAltairMinimal = struct {
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
    current_sync_committee: SyncCommitteeAltairMinimal,
    next_sync_committee: SyncCommitteeAltairMinimal,

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
    });
};

pub const SyncCommitteeContributionAltairMainnet = struct {
    slot: u64,
    beacon_block_root: [32]u8,
    subcommittee_index: u64,
    aggregation_bits: [128]bool,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitvector(128),
    });
};

pub const ContributionAndProofAltairMainnet = struct {
    aggregator_index: u64,
    contribution: SyncCommitteeContributionAltairMainnet,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SyncCommitteeContributionAltairMinimal = struct {
    slot: u64,
    beacon_block_root: [32]u8,
    subcommittee_index: u64,
    aggregation_bits: [8]bool,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitvector(8),
    });
};

pub const ContributionAndProofAltairMinimal = struct {
    aggregator_index: u64,
    contribution: SyncCommitteeContributionAltairMinimal,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientHeaderAltair = struct {
    beacon: phase0_types.BeaconBlockHeader,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientBootstrapAltairMainnet = struct {
    header: LightClientHeaderAltair,
    current_sync_committee: SyncCommitteeAltairMainnet,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientBootstrapAltairMinimal = struct {
    header: LightClientHeaderAltair,
    current_sync_committee: SyncCommitteeAltairMinimal,
    current_sync_committee_branch: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .current_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
    });
};

pub const LightClientFinalityUpdateAltairMainnet = struct {
    attested_header: LightClientHeaderAltair,
    finalized_header: LightClientHeaderAltair,
    finality_branch: []const [32]u8,
    sync_aggregate: SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientFinalityUpdateAltairMinimal = struct {
    attested_header: LightClientHeaderAltair,
    finalized_header: LightClientHeaderAltair,
    finality_branch: []const [32]u8,
    sync_aggregate: SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientOptimisticUpdateAltairMainnet = struct {
    attested_header: LightClientHeaderAltair,
    sync_aggregate: SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientOptimisticUpdateAltairMinimal = struct {
    attested_header: LightClientHeaderAltair,
    sync_aggregate: SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const LightClientUpdateAltairMainnet = struct {
    attested_header: LightClientHeaderAltair,
    next_sync_committee: SyncCommitteeAltairMainnet,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderAltair,
    finality_branch: []const [32]u8,
    sync_aggregate: SyncAggregateAltairMainnet,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const LightClientUpdateAltairMinimal = struct {
    attested_header: LightClientHeaderAltair,
    next_sync_committee: SyncCommitteeAltairMinimal,
    next_sync_committee_branch: []const [32]u8,
    finalized_header: LightClientHeaderAltair,
    finality_branch: []const [32]u8,
    sync_aggregate: SyncAggregateAltairMinimal,
    signature_slot: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .next_sync_committee_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 5)),
        .finality_branch = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 6)),
    });
};

pub const SignedBeaconBlockAltairMainnet = struct {
    message: BeaconBlockAltairMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockAltairMinimal = struct {
    message: BeaconBlockAltairMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedContributionAndProofAltairMainnet = struct {
    message: ContributionAndProofAltairMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedContributionAndProofAltairMinimal = struct {
    message: ContributionAndProofAltairMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SyncAggregatorSelectionData = struct {
    slot: u64,
    subcommittee_index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SyncCommitteeMessage = struct {
    slot: u64,
    beacon_block_root: [32]u8,
    validator_index: u64,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
