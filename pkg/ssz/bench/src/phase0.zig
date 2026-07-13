const std = @import("std");
const ssz = @import("ssz");

pub const validator_registry_limit = 1_099_511_627_776;

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

pub const BeaconState = struct {
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
        .historical_roots = ssz.ListOf(ssz.ByteVector(32), 16_777_216),
        .eth1_data_votes = ssz.ListOf(Eth1Data.Ssz, 2048),
        .validators = ssz.ListOf(Validator.Ssz, validator_registry_limit),
        .balances = ssz.ListOf(ssz.Fixed(u64), validator_registry_limit),
        .randao_mixes = ssz.Alloc(ssz.VectorOf(ssz.ByteVector(32), 65_536)),
        .slashings = ssz.Alloc(ssz.VectorOf(ssz.Fixed(u64), 8192)),
        .previous_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 4096),
        .current_epoch_attestations = ssz.ListOf(PendingAttestation.Ssz, 4096),
        .justification_bits = ssz.Bitvector(4),
    });
};

pub const Fixture = struct {
    allocator: std.mem.Allocator,
    state: BeaconState,

    pub fn init(allocator: std.mem.Allocator, validator_count: usize) !Fixture {
        const block_roots = try roots(allocator, 8192, 0);
        errdefer allocator.free(block_roots);
        const state_roots = try roots(allocator, 8192, 10_000);
        errdefer allocator.free(state_roots);
        const historical_roots = try roots(allocator, 16, 20_000);
        errdefer allocator.free(historical_roots);
        const eth1_data_votes = try eth1DataItems(allocator, 16);
        errdefer allocator.free(eth1_data_votes);
        const validators = try validatorItems(allocator, validator_count);
        errdefer allocator.free(validators);
        const balances = try allocator.alloc(u64, validator_count);
        errdefer allocator.free(balances);
        @memset(balances, 32_000_000_000);
        const randao_mixes = try roots(allocator, 65_536, 30_000);
        errdefer allocator.free(randao_mixes);
        const slashings = try allocator.alloc(u64, 8192);
        errdefer allocator.free(slashings);
        @memset(slashings, 0);
        const previous_epoch_attestations = try pendingAttestations(allocator, 16, 0);
        errdefer freePendingAttestations(allocator, previous_epoch_attestations);
        const current_epoch_attestations = try pendingAttestations(allocator, 16, 100);
        errdefer freePendingAttestations(allocator, current_epoch_attestations);

        return .{
            .allocator = allocator,
            .state = .{
                .genesis_time = 1_606_824_023,
                .genesis_validators_root = makeRoot(42),
                .slot = 1000,
                .fork = .{
                    .previous_version = .{ 0, 0, 0, 0 },
                    .current_version = .{ 1, 0, 0, 0 },
                    .epoch = 100,
                },
                .latest_block_header = makeHeader(999),
                .block_roots = block_roots,
                .state_roots = state_roots,
                .historical_roots = historical_roots,
                .eth1_data = makeEth1Data(0),
                .eth1_data_votes = eth1_data_votes,
                .eth1_deposit_index = 1000,
                .validators = validators,
                .balances = balances,
                .randao_mixes = randao_mixes,
                .slashings = slashings,
                .previous_epoch_attestations = previous_epoch_attestations,
                .current_epoch_attestations = current_epoch_attestations,
                .justification_bits = .{ true, true, false, false },
                .previous_justified_checkpoint = makeCheckpoint(99),
                .current_justified_checkpoint = makeCheckpoint(100),
                .finalized_checkpoint = makeCheckpoint(98),
            },
        };
    }

    pub fn deinit(self: *Fixture) void {
        freePendingAttestations(self.allocator, @constCast(self.state.current_epoch_attestations));
        freePendingAttestations(self.allocator, @constCast(self.state.previous_epoch_attestations));
        self.allocator.free(self.state.slashings);
        self.allocator.free(self.state.randao_mixes);
        self.allocator.free(self.state.balances);
        self.allocator.free(self.state.validators);
        self.allocator.free(self.state.eth1_data_votes);
        self.allocator.free(self.state.historical_roots);
        self.allocator.free(self.state.state_roots);
        self.allocator.free(self.state.block_roots);
        self.* = undefined;
    }
};

fn roots(allocator: std.mem.Allocator, count: usize, seed_offset: u64) ![][32]u8 {
    const values = try allocator.alloc([32]u8, count);
    for (values, 0..) |*value, index| value.* = makeRoot(seed_offset +% @as(u64, @intCast(index)));
    return values;
}

fn eth1DataItems(allocator: std.mem.Allocator, count: usize) ![]Eth1Data {
    const values = try allocator.alloc(Eth1Data, count);
    for (values, 0..) |*value, index| value.* = makeEth1Data(@intCast(index));
    return values;
}

fn validatorItems(allocator: std.mem.Allocator, count: usize) ![]Validator {
    const values = try allocator.alloc(Validator, count);
    for (values, 0..) |*value, index| value.* = makeValidator(@intCast(index));
    return values;
}

fn pendingAttestations(allocator: std.mem.Allocator, count: usize, seed_offset: u64) ![]PendingAttestation {
    const values = try allocator.alloc(PendingAttestation, count);
    var initialized: usize = 0;
    errdefer {
        for (values[0..initialized]) |value| allocator.free(value.aggregation_bits);
        allocator.free(values);
    }
    for (values, 0..) |*value, index| {
        const bits = try allocator.alloc(bool, 2048);
        for (bits, 0..) |*bit, bit_index| bit.* = bit_index % 3 == 0;
        const seed = seed_offset +% @as(u64, @intCast(index));
        value.* = .{
            .aggregation_bits = bits,
            .data = makeAttestationData(seed),
            .inclusion_delay = seed +% 1,
            .proposer_index = seed *% 7,
        };
        initialized += 1;
    }
    return values;
}

fn freePendingAttestations(allocator: std.mem.Allocator, values: []PendingAttestation) void {
    for (values) |value| allocator.free(value.aggregation_bits);
    allocator.free(values);
}

fn makeValidator(seed: u64) Validator {
    var pubkey: [48]u8 = undefined;
    for (0..6) |index| {
        std.mem.writeInt(u64, pubkey[index * 8 ..][0..8], seed +% @as(u64, @intCast(index)), .little);
    }
    var withdrawal_credentials: [32]u8 = undefined;
    for (0..4) |index| {
        std.mem.writeInt(
            u64,
            withdrawal_credentials[index * 8 ..][0..8],
            seed *% 31 +% @as(u64, @intCast(index)),
            .little,
        );
    }
    return .{
        .pubkey = pubkey,
        .withdrawal_credentials = withdrawal_credentials,
        .effective_balance = 32_000_000_000,
        .slashed = @as(u8, @truncate(seed)) & 1 == 1,
        .activation_eligibility_epoch = seed,
        .activation_epoch = seed +% 1,
        .exit_epoch = std.math.maxInt(u64),
        .withdrawable_epoch = std.math.maxInt(u64),
    };
}

pub fn makeHeader(seed: u64) BeaconBlockHeader {
    return .{
        .slot = seed,
        .proposer_index = seed *% 3,
        .parent_root = makeRoot(seed),
        .state_root = makeRoot(seed *% 7),
        .body_root = makeRoot(seed *% 13),
    };
}

fn makeCheckpoint(seed: u64) Checkpoint {
    return .{ .epoch = seed, .root = makeRoot(seed *% 17) };
}

fn makeEth1Data(seed: u64) Eth1Data {
    return .{
        .deposit_root = makeRoot(seed *% 11),
        .deposit_count = seed *% 5,
        .block_hash = makeRoot(seed *% 23),
    };
}

fn makeAttestationData(seed: u64) AttestationData {
    return .{
        .slot = seed,
        .index = seed *% 3,
        .beacon_block_root = makeRoot(seed *% 29),
        .source = makeCheckpoint(seed),
        .target = makeCheckpoint(seed +% 1),
    };
}

fn makeRoot(seed: u64) [32]u8 {
    var value: [32]u8 = undefined;
    for (0..4) |index| {
        std.mem.writeInt(u64, value[index * 8 ..][0..8], seed +% @as(u64, @intCast(index)), .little);
    }
    return value;
}

test "Phase 0 BeaconState fixture round trips owned fields" {
    var fixture = try Fixture.init(std.testing.allocator, 4);
    defer fixture.deinit();

    const len = try BeaconState.Ssz.encodedLen(fixture.state);
    const encoded = try std.testing.allocator.alloc(u8, len);
    defer std.testing.allocator.free(encoded);
    _ = try BeaconState.Ssz.encode(encoded, fixture.state);

    var decoded = try BeaconState.Ssz.decodeAlloc(std.testing.allocator, encoded);
    defer BeaconState.Ssz.deinit(std.testing.allocator, &decoded);
    try std.testing.expectEqual(@as(usize, 4), decoded.validators.len);
    try std.testing.expectEqual(@as(usize, 4), decoded.balances.len);
    try std.testing.expectEqual(@as(usize, 2048), decoded.previous_epoch_attestations[0].aggregation_bits.len);
    try std.testing.expectEqual(fixture.state.finalized_checkpoint, decoded.finalized_checkpoint);
}
