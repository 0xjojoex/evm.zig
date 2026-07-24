//! Schema `0x0001` wire contract for the stateless zkEVM guest interface.
//! Defines the SSZ-encoded `StatelessInput`/`StatelessValidationResult` types
//! (per tests-zkevm v0.5) and the schema-prefixed validate entry points.
//! The two-byte schema id gates decoding; unknown ids are rejected.

const std = @import("std");
const ssz = @import("ssz");
const crypto = @import("../../crypto.zig");
const Revision = @import("../../eth/revision.zig").Revision;
const eth_spec = @import("../../eth/spec.zig");
const address = @import("../../address.zig");
const input_mod = @import("../input.zig");
const EthWithdrawal = @import("../../eth/Withdrawal.zig");
const stateless_validate = @import("../validate.zig");
const block_stf = @import("../../eth/block_stf.zig");
const transaction = @import("../../transaction.zig");
const uint256 = @import("../../uint256.zig");

pub const schema_id: u16 = 0x0001;
pub const schema_id_size = 2;
const max_extra_data_bytes = 32;
const max_withdrawals_per_payload = 16;
const max_transactions_per_payload = 1 << 20;
const max_bytes_per_transaction = 1 << 30;
const max_blob_commitments_per_block = 4096;
const max_deposit_requests_per_payload = 8192;
const max_withdrawal_requests_per_payload = 16;
const max_consolidation_requests_per_payload = 2;
const max_block_access_list_bytes = max_bytes_per_transaction;
const max_public_keys = 1 << 15;
const public_key_bytes = 65;
const max_witness_nodes = 1 << 22;
const max_witness_codes = 1 << 18;
const max_witness_headers = 256;
const max_bytes_per_witness_node = 1 << 10;
const max_bytes_per_code = 1 << 16;
const max_bytes_per_header = 1 << 10;

pub const Error = std.mem.Allocator.Error || ssz.Error || stateless_validate.Error || error{
    InvalidBool,
    InvalidListLength,
    OffsetsAreNotMonotonic,
    MissingSchemaId,
    UnsupportedSchemaId,
    UnsupportedFork,
    DuplicateKey,
    InvalidRequest,
    MissingParentHeader,
    InvalidHeaderWitness,
    InactiveForkConfig,
    InvalidForkActivation,
    InvalidPayloadForFork,
    UnsupportedBlobScheduleOverride,
    ExtraDataTooLong,
};

pub const ValidationOptions = struct {};

pub const ProtocolFork = enum(u64) {
    frontier = 0,
    homestead = 1,
    dao_fork = 2,
    tangerine_whistle = 3,
    spurious_dragon = 4,
    byzantium = 5,
    petersburg = 6,
    istanbul = 7,
    muir_glacier = 8,
    berlin = 9,
    london = 10,
    arrow_glacier = 11,
    gray_glacier = 12,
    paris = 13,
    shanghai = 14,
    cancun = 15,
    prague = 16,
    osaka = 17,
    bpo1 = 18,
    bpo2 = 19,
    amsterdam = 20,

    pub fn fromInt(value: u64) Error!ProtocolFork {
        return switch (value) {
            0 => .frontier,
            1 => .homestead,
            2 => .dao_fork,
            3 => .tangerine_whistle,
            4 => .spurious_dragon,
            5 => .byzantium,
            6 => .petersburg,
            7 => .istanbul,
            8 => .muir_glacier,
            9 => .berlin,
            10 => .london,
            11 => .arrow_glacier,
            12 => .gray_glacier,
            13 => .paris,
            14 => .shanghai,
            15 => .cancun,
            16 => .prague,
            17 => .osaka,
            18 => .bpo1,
            19 => .bpo2,
            20 => .amsterdam,
            else => error.UnsupportedFork,
        };
    }
};

pub const ForkActivation = struct {
    block_number: ?u64 = null,
    timestamp: ?u64 = null,

    pub const Ssz = ssz.Container(@This(), .{
        .block_number = ssz.OptionalList(u64),
        .timestamp = ssz.OptionalList(u64),
    });
};

pub const BlobSchedule = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u64,
};

pub const ForkConfig = struct {
    fork: ProtocolFork,
    activation: ForkActivation,
    blob_schedule: ?BlobSchedule = null,

    pub const Ssz = ssz.Container(@This(), .{
        .blob_schedule = ssz.OptionalList(BlobSchedule),
    });
};

pub const ChainConfig = struct {
    chain_id: u64,
    active_fork: ForkConfig,

    pub const Ssz = ssz.Container(@This(), .{});
};

pub const ExecutionWitness = struct {
    state: []const []const u8 = &.{},
    codes: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},

    pub const Ssz = ssz.Container(@This(), .{
        .state = ssz.ListOf(ssz.ByteList(max_bytes_per_witness_node), max_witness_nodes),
        .codes = ssz.ListOf(ssz.ByteList(max_bytes_per_code), max_witness_codes),
        .headers = ssz.ListOf(ssz.ByteList(max_bytes_per_header), max_witness_headers),
    });

    pub fn encode(self: ExecutionWitness, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(Ssz, allocator, self);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionWitness {
        return decodeWire(Ssz, allocator, bytes);
    }

    pub fn deinit(self: *ExecutionWitness, allocator: std.mem.Allocator) void {
        Ssz.deinit(allocator, self);
    }
};

pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: address.Address,
    amount: u64,

    fn toEth(self: Withdrawal) EthWithdrawal {
        return .{
            .index = self.index,
            .validator_index = self.validator_index,
            .address = self.address,
            .amount = self.amount,
        };
    }
};

pub const ExecutionRequests = struct {
    deposits: []const DepositRequest = &.{},
    withdrawals: []const WithdrawalRequest = &.{},
    consolidations: []const ConsolidationRequest = &.{},

    pub const Ssz = ssz.Container(@This(), .{
        .deposits = ssz.List(DepositRequest, max_deposit_requests_per_payload),
        .withdrawals = ssz.List(WithdrawalRequest, max_withdrawal_requests_per_payload),
        .consolidations = ssz.List(ConsolidationRequest, max_consolidation_requests_per_payload),
    });

    pub fn encode(self: ExecutionRequests, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(Ssz, allocator, self);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionRequests {
        return decodeWire(Ssz, allocator, bytes);
    }

    pub fn deinit(self: *ExecutionRequests, allocator: std.mem.Allocator) void {
        Ssz.deinit(allocator, self);
    }

    pub fn hashTreeRoot(self: ExecutionRequests, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(Ssz, self);
    }

    fn typedOpaqueRequests(self: ExecutionRequests, allocator: std.mem.Allocator) Error![]const []const u8 {
        if (self.deposits.len == 0 and self.withdrawals.len == 0 and self.consolidations.len == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |request| allocator.free(request);
            out.deinit(allocator);
        }
        if (self.deposits.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x00, DepositRequest, self.deposits));
        if (self.withdrawals.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x01, WithdrawalRequest, self.withdrawals));
        if (self.consolidations.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x02, ConsolidationRequest, self.consolidations));
        return out.toOwnedSlice(allocator);
    }
};

pub const DepositRequest = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,
    index: u64,
};

pub const WithdrawalRequest = struct {
    source_address: address.Address,
    validator_pubkey: [48]u8,
    amount: u64,
};

pub const ConsolidationRequest = struct {
    source_address: address.Address,
    source_pubkey: [48]u8,
    target_pubkey: [48]u8,
};

const PayloadView = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: [32]u8,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const Withdrawal = &.{},
    blob_gas_used: ?u64 = null,
    excess_blob_gas: ?u64 = null,
    block_access_list: []const u8 = &.{},
    slot_number: u64 = 0,
};

pub const ExecutionPayloadV1 = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8 = &.{},
    base_fee_per_gas: [32]u8,
    block_hash: [32]u8,
    transactions: []const []const u8 = &.{},

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(max_extra_data_bytes),
        .transactions = TransactionsSsz,
    });

    pub fn encode(self: ExecutionPayloadV1, allocator: std.mem.Allocator) Error![]u8 {
        if (self.extra_data.len > 32) return error.ExtraDataTooLong;
        return encodeWire(Ssz, allocator, self);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV1 {
        return decodeWire(Ssz, allocator, bytes);
    }

    pub fn deinit(self: *ExecutionPayloadV1, allocator: std.mem.Allocator) void {
        Ssz.deinit(allocator, self);
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV1, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(Ssz, self);
    }

    fn view(self: ExecutionPayloadV1) PayloadView {
        return .{
            .parent_hash = self.parent_hash,
            .fee_recipient = self.fee_recipient,
            .state_root = self.state_root,
            .receipts_root = self.receipts_root,
            .logs_bloom = self.logs_bloom,
            .prev_randao = self.prev_randao,
            .block_number = self.block_number,
            .gas_limit = self.gas_limit,
            .gas_used = self.gas_used,
            .timestamp = self.timestamp,
            .extra_data = self.extra_data,
            .base_fee_per_gas = self.base_fee_per_gas,
            .block_hash = self.block_hash,
            .transactions = self.transactions,
        };
    }
};

pub const ExecutionPayloadV2 = struct {
    v1: ExecutionPayloadV1,
    withdrawals: []const Withdrawal = &.{},

    pub fn encode(self: ExecutionPayloadV2, allocator: std.mem.Allocator) Error![]u8 {
        if (self.v1.extra_data.len > 32) return error.ExtraDataTooLong;
        return encodeWire(ExecutionPayloadV2Wire.Ssz, allocator, payloadV2Wire(self));
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV2 {
        return payloadV2FromWire(try decodeWire(ExecutionPayloadV2Wire.Ssz, allocator, bytes));
    }

    pub fn deinit(self: *ExecutionPayloadV2, allocator: std.mem.Allocator) void {
        self.v1.deinit(allocator);
        WithdrawalsSsz.deinit(allocator, &self.withdrawals);
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV2, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(ExecutionPayloadV2Wire.Ssz, payloadV2Wire(self));
    }

    fn view(self: ExecutionPayloadV2) PayloadView {
        var out = self.v1.view();
        out.withdrawals = self.withdrawals;
        return out;
    }
};

pub const ExecutionPayloadV3 = struct {
    v2: ExecutionPayloadV2,
    blob_gas_used: u64,
    excess_blob_gas: u64,

    pub fn encode(self: ExecutionPayloadV3, allocator: std.mem.Allocator) Error![]u8 {
        if (self.v2.v1.extra_data.len > 32) return error.ExtraDataTooLong;
        return encodeWire(ExecutionPayloadV3Wire.Ssz, allocator, payloadV3Wire(self));
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV3 {
        return payloadV3FromWire(try decodeWire(ExecutionPayloadV3Wire.Ssz, allocator, bytes));
    }

    pub fn deinit(self: *ExecutionPayloadV3, allocator: std.mem.Allocator) void {
        self.v2.deinit(allocator);
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV3, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(ExecutionPayloadV3Wire.Ssz, payloadV3Wire(self));
    }

    fn view(self: ExecutionPayloadV3) PayloadView {
        var out = self.v2.view();
        out.blob_gas_used = self.blob_gas_used;
        out.excess_blob_gas = self.excess_blob_gas;
        return out;
    }
};

pub const ExecutionPayloadV4 = struct {
    v3: ExecutionPayloadV3,
    block_access_list: []const u8 = &.{},
    slot_number: u64,

    pub fn encode(self: ExecutionPayloadV4, allocator: std.mem.Allocator) Error![]u8 {
        if (self.v3.v2.v1.extra_data.len > 32) return error.ExtraDataTooLong;
        return encodeWire(ExecutionPayloadV4Wire.Ssz, allocator, payloadV4Wire(self));
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV4 {
        return payloadV4FromWire(try decodeWire(ExecutionPayloadV4Wire.Ssz, allocator, bytes));
    }

    pub fn deinit(self: *ExecutionPayloadV4, allocator: std.mem.Allocator) void {
        self.v3.deinit(allocator);
        BlockAccessListSsz.deinit(allocator, &self.block_access_list);
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV4, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(ExecutionPayloadV4Wire.Ssz, payloadV4Wire(self));
    }

    fn view(self: ExecutionPayloadV4) PayloadView {
        var out = self.v3.view();
        out.block_access_list = self.block_access_list;
        out.slot_number = self.slot_number;
        return out;
    }
};

pub const NewPayloadRequestBellatrix = struct {
    execution_payload: ExecutionPayloadV1,

    pub fn encode(self: NewPayloadRequestBellatrix, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(NewPayloadRequestBellatrixWire.Ssz, allocator, .{
            .execution_payload = self.execution_payload,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestBellatrix {
        const value = try decodeWire(NewPayloadRequestBellatrixWire.Ssz, allocator, bytes);
        return .{ .execution_payload = value.execution_payload };
    }

    pub fn deinit(self: *NewPayloadRequestBellatrix, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestBellatrix, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestBellatrixWire.Ssz, .{
            .execution_payload = self.execution_payload,
        });
    }
};

pub const NewPayloadRequestCapella = struct {
    execution_payload: ExecutionPayloadV2,

    pub fn encode(self: NewPayloadRequestCapella, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(NewPayloadRequestCapellaWire.Ssz, allocator, .{
            .execution_payload = payloadV2Wire(self.execution_payload),
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestCapella {
        const value = try decodeWire(NewPayloadRequestCapellaWire.Ssz, allocator, bytes);
        return .{ .execution_payload = payloadV2FromWire(value.execution_payload) };
    }

    pub fn deinit(self: *NewPayloadRequestCapella, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestCapella, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestCapellaWire.Ssz, .{
            .execution_payload = payloadV2Wire(self.execution_payload),
        });
    }
};

pub const NewPayloadRequestDeneb = struct {
    execution_payload: ExecutionPayloadV3,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,

    pub fn encode(self: NewPayloadRequestDeneb, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(NewPayloadRequestDenebWire.Ssz, allocator, .{
            .execution_payload = payloadV3Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestDeneb {
        const value = try decodeWire(NewPayloadRequestDenebWire.Ssz, allocator, bytes);
        return .{
            .execution_payload = payloadV3FromWire(value.execution_payload),
            .versioned_hashes = value.versioned_hashes,
            .parent_beacon_block_root = value.parent_beacon_block_root,
        };
    }

    pub fn deinit(self: *NewPayloadRequestDeneb, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
        VersionedHashesSsz.deinit(allocator, &self.versioned_hashes);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestDeneb, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestDenebWire.Ssz, .{
            .execution_payload = payloadV3Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
        });
    }
};

pub const NewPayloadRequestElectraFulu = struct {
    execution_payload: ExecutionPayloadV3,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests = .{},

    pub fn encode(self: NewPayloadRequestElectraFulu, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(NewPayloadRequestElectraFuluWire.Ssz, allocator, .{
            .execution_payload = payloadV3Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
            .execution_requests = self.execution_requests,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestElectraFulu {
        const value = try decodeWire(NewPayloadRequestElectraFuluWire.Ssz, allocator, bytes);
        return .{
            .execution_payload = payloadV3FromWire(value.execution_payload),
            .versioned_hashes = value.versioned_hashes,
            .parent_beacon_block_root = value.parent_beacon_block_root,
            .execution_requests = value.execution_requests,
        };
    }

    pub fn deinit(self: *NewPayloadRequestElectraFulu, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
        VersionedHashesSsz.deinit(allocator, &self.versioned_hashes);
        self.execution_requests.deinit(allocator);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestElectraFulu, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestElectraFuluWire.Ssz, .{
            .execution_payload = payloadV3Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
            .execution_requests = self.execution_requests,
        });
    }
};

pub const NewPayloadRequestAmsterdam = struct {
    execution_payload: ExecutionPayloadV4,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests = .{},

    pub fn encode(self: NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(NewPayloadRequestAmsterdamWire.Ssz, allocator, .{
            .execution_payload = payloadV4Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
            .execution_requests = self.execution_requests,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestAmsterdam {
        const value = try decodeWire(NewPayloadRequestAmsterdamWire.Ssz, allocator, bytes);
        return .{
            .execution_payload = payloadV4FromWire(value.execution_payload),
            .versioned_hashes = value.versioned_hashes,
            .parent_beacon_block_root = value.parent_beacon_block_root,
            .execution_requests = value.execution_requests,
        };
    }

    pub fn deinit(self: *NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
        VersionedHashesSsz.deinit(allocator, &self.versioned_hashes);
        self.execution_requests.deinit(allocator);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestAmsterdamWire.Ssz, .{
            .execution_payload = payloadV4Wire(self.execution_payload),
            .versioned_hashes = self.versioned_hashes,
            .parent_beacon_block_root = self.parent_beacon_block_root,
            .execution_requests = self.execution_requests,
        });
    }
};

pub const NewPayloadRequest = union(enum) {
    bellatrix: NewPayloadRequestBellatrix,
    capella: NewPayloadRequestCapella,
    deneb: NewPayloadRequestDeneb,
    electra_fulu: NewPayloadRequestElectraFulu,
    amsterdam: NewPayloadRequestAmsterdam,

    pub fn encode(self: NewPayloadRequest, allocator: std.mem.Allocator) Error![]u8 {
        return switch (self) {
            .bellatrix => |request| request.encode(allocator),
            .capella => |request| request.encode(allocator),
            .deneb => |request| request.encode(allocator),
            .electra_fulu => |request| request.encode(allocator),
            .amsterdam => |request| request.encode(allocator),
        };
    }

    pub fn decode(allocator: std.mem.Allocator, fork: ProtocolFork, bytes: []const u8) Error!NewPayloadRequest {
        return switch (fork) {
            .paris => .{ .bellatrix = try NewPayloadRequestBellatrix.decode(allocator, bytes) },
            .shanghai => .{ .capella = try NewPayloadRequestCapella.decode(allocator, bytes) },
            .cancun => .{ .deneb = try NewPayloadRequestDeneb.decode(allocator, bytes) },
            .prague, .osaka => .{ .electra_fulu = try NewPayloadRequestElectraFulu.decode(allocator, bytes) },
            .amsterdam => .{ .amsterdam = try NewPayloadRequestAmsterdam.decode(allocator, bytes) },
            // BPO placeholders have no local Revision mapping.
            .bpo1, .bpo2 => error.UnsupportedFork,
            else => error.UnsupportedFork,
        };
    }

    pub fn deinit(self: *NewPayloadRequest, allocator: std.mem.Allocator) void {
        switch (self.*) {
            inline else => |*request| request.deinit(allocator),
        }
    }

    pub fn hashTreeRoot(self: NewPayloadRequest, allocator: std.mem.Allocator) Error![32]u8 {
        return switch (self) {
            .bellatrix => |request| request.hashTreeRoot(allocator),
            .capella => |request| request.hashTreeRoot(allocator),
            .deneb => |request| request.hashTreeRoot(allocator),
            .electra_fulu => |request| request.hashTreeRoot(allocator),
            .amsterdam => |request| request.hashTreeRoot(allocator),
        };
    }

    fn payloadView(self: NewPayloadRequest) PayloadView {
        return switch (self) {
            .bellatrix => |request| request.execution_payload.view(),
            .capella => |request| request.execution_payload.view(),
            .deneb => |request| request.execution_payload.view(),
            .electra_fulu => |request| request.execution_payload.view(),
            .amsterdam => |request| request.execution_payload.view(),
        };
    }

    fn parentBeaconBlockRoot(self: NewPayloadRequest) ?[32]u8 {
        return switch (self) {
            .bellatrix, .capella => null,
            .deneb => |request| request.parent_beacon_block_root,
            .electra_fulu => |request| request.parent_beacon_block_root,
            .amsterdam => |request| request.parent_beacon_block_root,
        };
    }

    fn versionedHashes(self: NewPayloadRequest) []const [32]u8 {
        return switch (self) {
            .bellatrix, .capella => &.{},
            .deneb => |request| request.versioned_hashes,
            .electra_fulu => |request| request.versioned_hashes,
            .amsterdam => |request| request.versioned_hashes,
        };
    }

    fn executionRequests(self: NewPayloadRequest) ?ExecutionRequests {
        return switch (self) {
            .bellatrix, .capella, .deneb => null,
            .electra_fulu => |request| request.execution_requests,
            .amsterdam => |request| request.execution_requests,
        };
    }
};

pub const StatelessInput = struct {
    new_payload_request: NewPayloadRequest,
    witness: ExecutionWitness,
    chain_config: ChainConfig,
    public_keys: []const [public_key_bytes]u8 = &.{},

    pub fn encode(self: StatelessInput, allocator: std.mem.Allocator) Error![]u8 {
        const request = try self.new_payload_request.encode(allocator);
        defer allocator.free(request);
        if (self.public_keys.len > max_public_keys) return error.InvalidListLength;
        return encodeWire(StatelessInputWire.Ssz, allocator, .{
            .new_payload_request = request,
            .witness = self.witness,
            .chain_config = self.chain_config,
            .public_keys = self.public_keys,
        });
    }

    pub fn encodeSchemaPrefixed(self: StatelessInput, allocator: std.mem.Allocator) Error![]u8 {
        const body = try self.encode(allocator);
        defer allocator.free(body);
        const out = try allocator.alloc(u8, schema_id_size + body.len);
        std.mem.writeInt(u16, out[0..schema_id_size], schema_id, .big);
        @memcpy(out[schema_id_size..], body);
        return out;
    }

    pub fn decodeSchemaPrefixed(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessInput {
        if (bytes.len < schema_id_size) return error.MissingSchemaId;
        const actual_schema_id = std.mem.readInt(u16, bytes[0..schema_id_size], .big);
        if (actual_schema_id != schema_id) return error.UnsupportedSchemaId;
        return decode(allocator, bytes[schema_id_size..]);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessInput {
        var value = try decodeWire(StatelessInputWire.Ssz, allocator, bytes);
        var owns_value = true;
        errdefer if (owns_value) StatelessInputWire.Ssz.deinit(allocator, &value);

        const chain_config = value.chain_config;
        var new_payload_request = try NewPayloadRequest.decode(allocator, chain_config.active_fork.fork, value.new_payload_request);
        errdefer new_payload_request.deinit(allocator);
        try validateChainConfig(chain_config, new_payload_request);
        NewPayloadRequestBytesSsz.deinit(allocator, &value.new_payload_request);
        owns_value = false;
        return .{
            .new_payload_request = new_payload_request,
            .witness = value.witness,
            .chain_config = chain_config,
            .public_keys = value.public_keys,
        };
    }

    pub fn deinit(self: *StatelessInput, allocator: std.mem.Allocator) void {
        self.new_payload_request.deinit(allocator);
        self.witness.deinit(allocator);
        PublicKeysSsz.deinit(allocator, &self.public_keys);
    }
};

pub const StatelessValidationResult = struct {
    new_payload_request_root: [32]u8,
    successful_validation: bool,
    chain_config: ChainConfig,

    pub fn encode(self: StatelessValidationResult, allocator: std.mem.Allocator) Error![]u8 {
        return encodeWire(StatelessValidationResultWire.Ssz, allocator, .{
            .new_payload_request_root = self.new_payload_request_root,
            .successful_validation = self.successful_validation,
            .chain_config = self.chain_config,
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessValidationResult {
        const value = try decodeWire(StatelessValidationResultWire.Ssz, allocator, bytes);
        return .{
            .new_payload_request_root = value.new_payload_request_root,
            .successful_validation = value.successful_validation,
            .chain_config = value.chain_config,
        };
    }
};

// Shared across multiple wire containers.
const WithdrawalsSsz = ssz.List(Withdrawal, max_withdrawals_per_payload);
const TransactionsSsz = ssz.ListOf(ssz.ByteList(max_bytes_per_transaction), max_transactions_per_payload);
const VersionedHashesSsz = ssz.List([32]u8, max_blob_commitments_per_block);
const NewPayloadRequestBytesSsz = ssz.ByteList(std.math.maxInt(u32));
const BlockAccessListSsz = ssz.ByteList(max_block_access_list_bytes);
const PublicKeysSsz = ssz.List([public_key_bytes]u8, max_public_keys);

const ExecutionPayloadV2Wire = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: [32]u8,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const Withdrawal,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(max_extra_data_bytes),
        .transactions = TransactionsSsz,
        .withdrawals = WithdrawalsSsz,
    });
};

const ExecutionPayloadV3Wire = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: [32]u8,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const Withdrawal,
    blob_gas_used: u64,
    excess_blob_gas: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(max_extra_data_bytes),
        .transactions = TransactionsSsz,
        .withdrawals = WithdrawalsSsz,
    });
};

const ExecutionPayloadV4Wire = struct {
    parent_hash: [32]u8,
    fee_recipient: address.Address,
    state_root: [32]u8,
    receipts_root: [32]u8,
    logs_bloom: [256]u8,
    prev_randao: [32]u8,
    block_number: u64,
    gas_limit: u64,
    gas_used: u64,
    timestamp: u64,
    extra_data: []const u8,
    base_fee_per_gas: [32]u8,
    block_hash: [32]u8,
    transactions: []const []const u8,
    withdrawals: []const Withdrawal,
    blob_gas_used: u64,
    excess_blob_gas: u64,
    block_access_list: []const u8,
    slot_number: u64,

    pub const Ssz = ssz.Container(@This(), .{
        .extra_data = ssz.ByteList(max_extra_data_bytes),
        .transactions = TransactionsSsz,
        .withdrawals = WithdrawalsSsz,
        .block_access_list = BlockAccessListSsz,
    });
};

const NewPayloadRequestBellatrixWire = struct {
    execution_payload: ExecutionPayloadV1,

    pub const Ssz = ssz.Container(@This(), .{});
};
const NewPayloadRequestCapellaWire = struct {
    execution_payload: ExecutionPayloadV2Wire,

    pub const Ssz = ssz.Container(@This(), .{});
};
const NewPayloadRequestDenebWire = struct {
    execution_payload: ExecutionPayloadV3Wire,
    versioned_hashes: []const [32]u8,
    parent_beacon_block_root: [32]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .versioned_hashes = VersionedHashesSsz,
    });
};
const NewPayloadRequestElectraFuluWire = struct {
    execution_payload: ExecutionPayloadV3Wire,
    versioned_hashes: []const [32]u8,
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests,

    pub const Ssz = ssz.Container(@This(), .{
        .versioned_hashes = VersionedHashesSsz,
    });
};
const NewPayloadRequestAmsterdamWire = struct {
    execution_payload: ExecutionPayloadV4Wire,
    versioned_hashes: []const [32]u8,
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests,

    pub const Ssz = ssz.Container(@This(), .{
        .versioned_hashes = VersionedHashesSsz,
    });
};

const StatelessInputWire = struct {
    new_payload_request: []const u8,
    witness: ExecutionWitness,
    chain_config: ChainConfig,
    public_keys: []const [public_key_bytes]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .new_payload_request = NewPayloadRequestBytesSsz,
        .public_keys = PublicKeysSsz,
    });
};

const StatelessValidationResultWire = struct {
    new_payload_request_root: [32]u8,
    successful_validation: bool,
    chain_config: ChainConfig,

    pub const Ssz = ssz.Container(@This(), .{});
};

fn encodeWire(comptime Codec: type, allocator: std.mem.Allocator, value: Codec.Value) Error![]u8 {
    return ssz.encodeAlloc(Codec, allocator, value) catch |err| return mapSszError(err);
}

fn decodeWire(comptime Codec: type, allocator: std.mem.Allocator, bytes: []const u8) Error!Codec.Value {
    // Wire v1 preflights all nested limits before allocating so malformed late
    // fields cannot force partial materialization or change error precedence.
    Codec.validate(bytes) catch |err| return mapSszError(err);
    return ssz.decodeOwned(Codec, allocator, bytes) catch |err| return mapSszError(err);
}

const Sha256Context = struct {
    pub fn hash64(_: @This(), input: *const [64]u8) [32]u8 {
        return crypto.sha256(input);
    }
};

fn hashWire(comptime Codec: type, value: Codec.Value) Error![32]u8 {
    const merkleizer = ssz.Merkleizer(Sha256Context).init(.{});
    return merkleizer.hashTreeRoot(Codec, value) catch |err| return mapSszError(err);
}

fn mapSszError(err: (ssz.Error || std.mem.Allocator.Error)) Error {
    return switch (err) {
        error.InvalidBoolean => error.InvalidBool,
        error.InvalidEnumValue => error.UnsupportedFork,
        error.ListLimitExceeded => error.InvalidListLength,
        error.OffsetsNotMonotonic => error.OffsetsAreNotMonotonic,
        else => err,
    };
}

fn payloadV2Wire(value: ExecutionPayloadV2) ExecutionPayloadV2Wire {
    const v1 = value.v1;
    return .{
        .parent_hash = v1.parent_hash,
        .fee_recipient = v1.fee_recipient,
        .state_root = v1.state_root,
        .receipts_root = v1.receipts_root,
        .logs_bloom = v1.logs_bloom,
        .prev_randao = v1.prev_randao,
        .block_number = v1.block_number,
        .gas_limit = v1.gas_limit,
        .gas_used = v1.gas_used,
        .timestamp = v1.timestamp,
        .extra_data = v1.extra_data,
        .base_fee_per_gas = v1.base_fee_per_gas,
        .block_hash = v1.block_hash,
        .transactions = v1.transactions,
        .withdrawals = value.withdrawals,
    };
}

fn payloadV2FromWire(value: ExecutionPayloadV2Wire) ExecutionPayloadV2 {
    return .{
        .v1 = .{
            .parent_hash = value.parent_hash,
            .fee_recipient = value.fee_recipient,
            .state_root = value.state_root,
            .receipts_root = value.receipts_root,
            .logs_bloom = value.logs_bloom,
            .prev_randao = value.prev_randao,
            .block_number = value.block_number,
            .gas_limit = value.gas_limit,
            .gas_used = value.gas_used,
            .timestamp = value.timestamp,
            .extra_data = value.extra_data,
            .base_fee_per_gas = value.base_fee_per_gas,
            .block_hash = value.block_hash,
            .transactions = value.transactions,
        },
        .withdrawals = value.withdrawals,
    };
}

fn payloadV3Wire(value: ExecutionPayloadV3) ExecutionPayloadV3Wire {
    const v2 = payloadV2Wire(value.v2);
    return .{
        .parent_hash = v2.parent_hash,
        .fee_recipient = v2.fee_recipient,
        .state_root = v2.state_root,
        .receipts_root = v2.receipts_root,
        .logs_bloom = v2.logs_bloom,
        .prev_randao = v2.prev_randao,
        .block_number = v2.block_number,
        .gas_limit = v2.gas_limit,
        .gas_used = v2.gas_used,
        .timestamp = v2.timestamp,
        .extra_data = v2.extra_data,
        .base_fee_per_gas = v2.base_fee_per_gas,
        .block_hash = v2.block_hash,
        .transactions = v2.transactions,
        .withdrawals = v2.withdrawals,
        .blob_gas_used = value.blob_gas_used,
        .excess_blob_gas = value.excess_blob_gas,
    };
}

fn payloadV3FromWire(value: ExecutionPayloadV3Wire) ExecutionPayloadV3 {
    return .{
        .v2 = payloadV2FromWire(.{
            .parent_hash = value.parent_hash,
            .fee_recipient = value.fee_recipient,
            .state_root = value.state_root,
            .receipts_root = value.receipts_root,
            .logs_bloom = value.logs_bloom,
            .prev_randao = value.prev_randao,
            .block_number = value.block_number,
            .gas_limit = value.gas_limit,
            .gas_used = value.gas_used,
            .timestamp = value.timestamp,
            .extra_data = value.extra_data,
            .base_fee_per_gas = value.base_fee_per_gas,
            .block_hash = value.block_hash,
            .transactions = value.transactions,
            .withdrawals = value.withdrawals,
        }),
        .blob_gas_used = value.blob_gas_used,
        .excess_blob_gas = value.excess_blob_gas,
    };
}

fn payloadV4Wire(value: ExecutionPayloadV4) ExecutionPayloadV4Wire {
    const v3 = payloadV3Wire(value.v3);
    return .{
        .parent_hash = v3.parent_hash,
        .fee_recipient = v3.fee_recipient,
        .state_root = v3.state_root,
        .receipts_root = v3.receipts_root,
        .logs_bloom = v3.logs_bloom,
        .prev_randao = v3.prev_randao,
        .block_number = v3.block_number,
        .gas_limit = v3.gas_limit,
        .gas_used = v3.gas_used,
        .timestamp = v3.timestamp,
        .extra_data = v3.extra_data,
        .base_fee_per_gas = v3.base_fee_per_gas,
        .block_hash = v3.block_hash,
        .transactions = v3.transactions,
        .withdrawals = v3.withdrawals,
        .blob_gas_used = v3.blob_gas_used,
        .excess_blob_gas = v3.excess_blob_gas,
        .block_access_list = value.block_access_list,
        .slot_number = value.slot_number,
    };
}

fn payloadV4FromWire(value: ExecutionPayloadV4Wire) ExecutionPayloadV4 {
    return .{
        .v3 = payloadV3FromWire(.{
            .parent_hash = value.parent_hash,
            .fee_recipient = value.fee_recipient,
            .state_root = value.state_root,
            .receipts_root = value.receipts_root,
            .logs_bloom = value.logs_bloom,
            .prev_randao = value.prev_randao,
            .block_number = value.block_number,
            .gas_limit = value.gas_limit,
            .gas_used = value.gas_used,
            .timestamp = value.timestamp,
            .extra_data = value.extra_data,
            .base_fee_per_gas = value.base_fee_per_gas,
            .block_hash = value.block_hash,
            .transactions = value.transactions,
            .withdrawals = value.withdrawals,
            .blob_gas_used = value.blob_gas_used,
            .excess_blob_gas = value.excess_blob_gas,
        }),
        .block_access_list = value.block_access_list,
        .slot_number = value.slot_number,
    };
}

fn defaultChainConfig() ChainConfig {
    return .{
        .chain_id = 0,
        .active_fork = .{
            .fork = .frontier,
            .activation = .{},
            .blob_schedule = null,
        },
    };
}

fn failureResult(chain_config: ChainConfig) StatelessValidationResult {
    return .{
        .new_payload_request_root = [_]u8{0} ** 32,
        .successful_validation = false,
        .chain_config = chain_config,
    };
}

pub fn validateStatelessBytes(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    return validateStatelessBytesWithOptions(allocator, bytes, .{});
}

pub fn validateStatelessBytesWithOptions(allocator: std.mem.Allocator, bytes: []const u8, options: ValidationOptions) Error![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const input = StatelessInput.decodeSchemaPrefixed(scratch, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(defaultChainConfig()).encode(allocator),
    };
    const result = try validateStatelessWithOptions(scratch, input, options);
    return result.encode(allocator);
}

pub fn validateStatelessStatusBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!block_stf.Status {
    return (try validateStatelessResultBytes(allocator, bytes)).status;
}

pub fn validateStatelessResultBytes(allocator: std.mem.Allocator, bytes: []const u8) Error!block_stf.Result {
    return validateStatelessResultBytesWithCaptureAndOptions(allocator, bytes, null, .{});
}

pub fn validateStatelessResultBytesWithOptions(allocator: std.mem.Allocator, bytes: []const u8, options: ValidationOptions) Error!block_stf.Result {
    return validateStatelessResultBytesWithCaptureAndOptions(allocator, bytes, null, options);
}

pub fn validateStatelessResultBytesWithCapture(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    capture: ?block_stf.ExecutionCapture,
) Error!block_stf.Result {
    return validateStatelessResultBytesWithCaptureAndOptions(allocator, bytes, capture, .{});
}

pub fn validateStatelessResultBytesWithCaptureAndOptions(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    capture: ?block_stf.ExecutionCapture,
    options: ValidationOptions,
) Error!block_stf.Result {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();
    const input = StatelessInput.decodeSchemaPrefixed(scratch, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = .invalid_witness },
    };
    _ = options;
    const normalized = normalize(scratch, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return .{ .status = .invalid_witness },
    };
    return stateless_validate.validateWithCapture(scratch, normalized, capture) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BlockTransitionFailed => return error.BlockTransitionFailed,
        else => .{ .status = .invalid_witness },
    };
}

pub fn validateStateless(allocator: std.mem.Allocator, input: StatelessInput) Error!StatelessValidationResult {
    return validateStatelessWithOptions(allocator, input, .{});
}

pub fn validateStatelessWithOptions(allocator: std.mem.Allocator, input: StatelessInput, options: ValidationOptions) Error!StatelessValidationResult {
    const request_root = input.new_payload_request.hashTreeRoot(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(input.chain_config),
    };
    _ = options;
    const normalized = normalize(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(input.chain_config),
    };
    const native_result = stateless_validate.validate(allocator, normalized) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => block_stf.Result{ .status = .invalid_witness },
    };
    return .{
        .new_payload_request_root = request_root,
        .successful_validation = native_result.status == .valid,
        .chain_config = input.chain_config,
    };
}

/// Converts the immutable v1 wire representation into runtime Ethereum facts.
/// Compatibility hints such as `public_keys` deliberately do not cross this
/// boundary; signed transaction recovery remains authoritative.
/// Returned slices borrow decoded input or storage owned by `allocator`; guest
/// callers should use one block-lifetime arena.
pub fn normalize(allocator: std.mem.Allocator, input: StatelessInput) Error!input_mod.Input {
    try validateChainConfig(input.chain_config, input.new_payload_request);
    const revision = try normalizeRevision(input.chain_config.active_fork.fork);
    const payload = input.new_payload_request.payloadView();
    const withdrawals = try normalizeWithdrawals(allocator, payload.withdrawals);
    const execution_requests = if (input.new_payload_request.executionRequests()) |requests|
        try requests.typedOpaqueRequests(allocator)
    else
        &.{};
    const blob_schedule = if (input.chain_config.active_fork.blob_schedule) |schedule|
        try normalizeBlobSchedule(schedule, revision)
    else
        null;

    _ = input.public_keys;
    return .{
        .revision = revision,
        .chain_id = input.chain_config.chain_id,
        .blob_schedule = blob_schedule,
        .block = .{
            .parent_hash = payload.parent_hash,
            .fee_recipient = payload.fee_recipient,
            .state_root = payload.state_root,
            .receipts_root = payload.receipts_root,
            .logs_bloom = payload.logs_bloom,
            .prev_randao = evmWordFromBytes32(payload.prev_randao),
            .number = payload.block_number,
            .gas_limit = payload.gas_limit,
            .gas_used = payload.gas_used,
            .timestamp = payload.timestamp,
            .extra_data = payload.extra_data,
            .base_fee_per_gas = sszUint256FromBytes(payload.base_fee_per_gas),
            .block_hash = payload.block_hash,
            .transactions = payload.transactions,
            .withdrawals = withdrawals,
            .blob_gas_used = payload.blob_gas_used,
            .excess_blob_gas = payload.excess_blob_gas,
            .versioned_hashes = input.new_payload_request.versionedHashes(),
            .parent_beacon_block_root = input.new_payload_request.parentBeaconBlockRoot(),
            .execution_requests = execution_requests,
            .block_access_list = if (revision.isImpl(.amsterdam)) payload.block_access_list else null,
            .slot_number = payload.slot_number,
        },
        .witness = .{
            .state = input.witness.state,
            .codes = input.witness.codes,
            .headers = input.witness.headers,
        },
    };
}

fn normalizeRevision(fork: ProtocolFork) Error!Revision {
    return switch (fork) {
        .frontier => .frontier,
        .homestead => .homestead,
        .dao_fork => .dao_fork,
        .tangerine_whistle => .tangerine_whistle,
        .spurious_dragon => .spurious_dragon,
        .byzantium => .byzantium,
        .petersburg => .petersburg,
        .istanbul => .istanbul,
        .muir_glacier => .muir_glacier,
        .berlin => .berlin,
        .london => .london,
        .arrow_glacier => .arrow_glacier,
        .gray_glacier => .gray_glacier,
        .paris => .merge,
        .shanghai => .shanghai,
        .cancun => .cancun,
        .prague => .prague,
        .osaka => .osaka,
        .amsterdam => .amsterdam,
        .bpo1, .bpo2 => error.UnsupportedFork,
    };
}

fn validateChainConfig(chain_config: ChainConfig, request: NewPayloadRequest) Error!void {
    const activation = chain_config.active_fork.activation;
    if (activation.block_number == null and activation.timestamp == null) {
        return error.InvalidForkActivation;
    }
    const payload = request.payloadView();
    if (!activationApplies(activation, payload.block_number, payload.timestamp)) {
        return error.InactiveForkConfig;
    }
    if (!requestMatchesFork(request, chain_config.active_fork.fork)) {
        return error.InvalidPayloadForFork;
    }
}

fn requestMatchesFork(request: NewPayloadRequest, fork: ProtocolFork) bool {
    return switch (request) {
        .bellatrix => fork == .paris,
        .capella => fork == .shanghai,
        .deneb => fork == .cancun,
        .electra_fulu => fork == .prague or fork == .osaka,
        .amsterdam => fork == .amsterdam,
    };
}

fn activationApplies(activation: ForkActivation, block_number: u64, timestamp: u64) bool {
    if (activation.block_number) |at| {
        if (block_number < at) return false;
    }
    if (activation.timestamp) |at| {
        if (timestamp < at) return false;
    }
    return true;
}

fn normalizeBlobSchedule(schedule: BlobSchedule, revision: Revision) Error!transaction.BlobSchedule {
    var out = switch (revision) {
        inline else => |exact_revision| eth_spec.specAt(exact_revision).transaction.blob_schedule,
    } orelse return error.UnsupportedBlobScheduleOverride;
    out.target = schedule.target;
    out.max = schedule.max;
    out.base_fee_update_fraction = schedule.base_fee_update_fraction;
    return out;
}

fn normalizeWithdrawals(allocator: std.mem.Allocator, withdrawals: []const Withdrawal) Error![]const EthWithdrawal {
    if (withdrawals.len == 0) return &.{};
    const out = try allocator.alloc(EthWithdrawal, withdrawals.len);
    for (out, withdrawals) |*target, source| target.* = source.toEth();
    return out;
}

fn prefixedFixedStructListBytes(
    allocator: std.mem.Allocator,
    prefix: u8,
    comptime T: type,
    items: []const T,
) Error![]u8 {
    const item_len = comptime ssz.encodedSize(T);
    const ItemSsz = ssz.Fixed(T);
    const out = try allocator.alloc(u8, 1 + item_len * items.len);
    errdefer allocator.free(out);
    out[0] = prefix;
    for (items, 0..) |item, i| {
        _ = try ItemSsz.encode(out[1 + i * item_len ..][0..item_len], item);
    }
    return out;
}

fn sszUint256FromBytes(bytes: [32]u8) u256 {
    return std.mem.readInt(u256, &bytes, .little);
}

fn evmWordFromBytes32(bytes: [32]u8) u256 {
    return uint256.fromBytes32(&bytes);
}
