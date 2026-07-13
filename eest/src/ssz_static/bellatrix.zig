//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at bellatrix.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");
const phase0_types = @import("phase0.zig");
const altair_types = @import("altair.zig");

pub const ExecutionPayloadBellatrix = struct {
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

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
        .transactions = ssz.ListOf(ssz.ByteList(1073741824), 1048576),
    });
};

pub const BeaconBlockBodyBellatrixMainnet = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMainnet,
    execution_payload: ExecutionPayloadBellatrix,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
    });
};

pub const BeaconBlockBellatrixMainnet = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyBellatrixMainnet,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockBodyBellatrixMinimal = struct {
    randao_reveal: [96]u8,
    eth1_data: phase0_types.Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const phase0_types.ProposerSlashing,
    attester_slashings: []const phase0_types.AttesterSlashingPhase0,
    attestations: []const phase0_types.AttestationPhase0,
    deposits: []const phase0_types.Deposit,
    voluntary_exits: []const phase0_types.SignedVoluntaryExit,
    sync_aggregate: altair_types.SyncAggregateAltairMinimal,
    execution_payload: ExecutionPayloadBellatrix,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(phase0_types.ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(phase0_types.AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(phase0_types.AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(phase0_types.Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(phase0_types.SignedVoluntaryExit.Ssz, 16),
    });
};

pub const BeaconBlockBellatrixMinimal = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyBellatrixMinimal,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionPayloadHeaderBellatrix = struct {
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

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(32),
    });
};

pub const BeaconStateBellatrixMainnet = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderBellatrix,

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

pub const BeaconStateBellatrixMinimal = struct {
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
    latest_execution_payload_header: ExecutionPayloadHeaderBellatrix,

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

pub const PowBlock = struct {
    block_hash: [32]u8,
    parent_hash: [32]u8,
    total_difficulty: u256,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockBellatrixMainnet = struct {
    message: BeaconBlockBellatrixMainnet,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockBellatrixMinimal = struct {
    message: BeaconBlockBellatrixMinimal,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
