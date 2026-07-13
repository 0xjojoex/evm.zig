//! Generated from consensus-specs v1.7.0-alpha.12 resolved pyspec.
//! Unique named schema shapes first required at phase0.
//! Regenerate with scripts/generate-consensus-ssz-schemas.py.

const ssz = @import("ssz");

pub const Checkpoint = struct {
    epoch: u64,
    root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const AttestationData = struct {
    slot: u64,
    index: u64,
    beacon_block_root: [32]u8,
    source: Checkpoint,
    target: Checkpoint,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const AttestationPhase0 = struct {
    aggregation_bits: []const bool,
    data: AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitlist(2048),
    });
};

pub const AggregateAndProofPhase0 = struct {
    aggregator_index: u64,
    aggregate: AttestationPhase0,
    selection_proof: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const IndexedAttestationPhase0 = struct {
    attesting_indices: []const u64,
    data: AttestationData,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .attesting_indices = ssz.ListOf(ssz.Fixed(u64), 2048),
    });
};

pub const AttesterSlashingPhase0 = struct {
    attestation_1: IndexedAttestationPhase0,
    attestation_2: IndexedAttestationPhase0,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Eth1Data = struct {
    deposit_root: [32]u8,
    deposit_count: u64,
    block_hash: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockHeader = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockHeader = struct {
    message: BeaconBlockHeader,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ProposerSlashing = struct {
    signed_header_1: SignedBeaconBlockHeader,
    signed_header_2: SignedBeaconBlockHeader,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const DepositData = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Deposit = struct {
    proof: []const [32]u8,
    data: DepositData,

    pub const Ssz = ssz.Container(@This(), .{
        .proof = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 33)),
    });
};

pub const VoluntaryExit = struct {
    epoch: u64,
    validator_index: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedVoluntaryExit = struct {
    message: VoluntaryExit,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const BeaconBlockBodyPhase0 = struct {
    randao_reveal: [96]u8,
    eth1_data: Eth1Data,
    graffiti: [32]u8,
    proposer_slashings: []const ProposerSlashing,
    attester_slashings: []const AttesterSlashingPhase0,
    attestations: []const AttestationPhase0,
    deposits: []const Deposit,
    voluntary_exits: []const SignedVoluntaryExit,

    pub const Ssz = ssz.Container(@This(), .{
        .proposer_slashings = ssz.ListOf(ProposerSlashing.Ssz, 16),
        .attester_slashings = ssz.ListOf(AttesterSlashingPhase0.Ssz, 2),
        .attestations = ssz.ListOf(AttestationPhase0.Ssz, 128),
        .deposits = ssz.ListOf(Deposit.Ssz, 16),
        .voluntary_exits = ssz.ListOf(SignedVoluntaryExit.Ssz, 16),
    });
};

pub const BeaconBlockPhase0 = struct {
    slot: u64,
    proposer_index: u64,
    parent_root: [32]u8,
    state_root: [32]u8,
    body: BeaconBlockBodyPhase0,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Fork = struct {
    previous_version: [4]u8,
    current_version: [4]u8,
    epoch: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Validator = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    effective_balance: u64,
    slashed: bool,
    activation_eligibility_epoch: u64,
    activation_epoch: u64,
    exit_epoch: u64,
    withdrawable_epoch: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const PendingAttestation = struct {
    aggregation_bits: []const bool,
    data: AttestationData,
    inclusion_delay: u64,
    proposer_index: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .aggregation_bits = ssz.Bitlist(2048),
    });
};

pub const BeaconStatePhase0Mainnet = struct {
    genesis_time: u64,
    genesis_validators_root: [32]u8,
    slot: u64,
    fork: Fork,
    latest_block_header: BeaconBlockHeader,
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,
    historical_roots: []const [32]u8,
    eth1_data: Eth1Data,
    eth1_data_votes: []const Eth1Data,
    eth1_deposit_index: u64,
    validators: []const Validator,
    balances: []const u64,
    randao_mixes: []const [32]u8,
    slashings: []const u64,
    previous_epoch_attestations: []const PendingAttestation,
    current_epoch_attestations: []const PendingAttestation,
    justification_bits: [4]bool,
    previous_justified_checkpoint: Checkpoint,
    current_justified_checkpoint: Checkpoint,
    finalized_checkpoint: Checkpoint,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(Eth1Data.Ssz, 2048),
        .validators = ssz.ListOf(Validator.Ssz, 1099511627776),
        .balances = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 65536)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 8192)),
        .previous_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 4096),
        .current_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 4096),
        .justification_bits = ssz.Bitvector(4),
    });
};

pub const BeaconStatePhase0Minimal = struct {
    genesis_time: u64,
    genesis_validators_root: [32]u8,
    slot: u64,
    fork: Fork,
    latest_block_header: BeaconBlockHeader,
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,
    historical_roots: []const [32]u8,
    eth1_data: Eth1Data,
    eth1_data_votes: []const Eth1Data,
    eth1_deposit_index: u64,
    validators: []const Validator,
    balances: []const u64,
    randao_mixes: []const [32]u8,
    slashings: []const u64,
    previous_epoch_attestations: []const PendingAttestation,
    current_epoch_attestations: []const PendingAttestation,
    justification_bits: [4]bool,
    previous_justified_checkpoint: Checkpoint,
    current_justified_checkpoint: Checkpoint,
    finalized_checkpoint: Checkpoint,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16777216),
        .eth1_data_votes = ssz.ListOf(Eth1Data.Ssz, 32),
        .validators = ssz.ListOf(Validator.Ssz, 1099511627776),
        .balances = ssz.ListOf(ssz.Fixed(u64), 1099511627776),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 64)),
        .previous_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 1024),
        .current_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 1024),
        .justification_bits = ssz.Bitvector(4),
    });
};

pub const DepositMessage = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const Eth1Block = struct {
    timestamp: u64,
    deposit_root: [32]u8,
    deposit_count: u64,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ForkData = struct {
    current_version: [4]u8,
    genesis_validators_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const HistoricalBatchPhase0Mainnet = struct {
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 8192)),
    });
};

pub const HistoricalBatchPhase0Minimal = struct {
    block_roots: []const [32]u8,
    state_roots: []const [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .block_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
        .state_roots = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 64)),
    });
};

pub const SignedAggregateAndProofPhase0 = struct {
    message: AggregateAndProofPhase0,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SignedBeaconBlockPhase0 = struct {
    message: BeaconBlockPhase0,
    signature: [96]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const SigningData = struct {
    object_root: [32]u8,
    domain: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{});
};
