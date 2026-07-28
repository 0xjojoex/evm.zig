//! Amsterdam schema `0x1501` wire contract for the stateless zkEVM guest interface.
//! Defines the SSZ-encoded `StatelessInput`/`StatelessValidationResult` types
//! (per tests-zkevm v0.6.2) and the schema-prefixed validate entry points.
//! The two-byte schema id gates decoding; unknown ids are rejected.

const std = @import("std");
const ssz = @import("ssz");
const crypto = @import("../../crypto.zig");
const Revision = @import("../../eth/revision.zig").Revision;
const address = @import("../../address.zig");
const input_mod = @import("../input.zig");
const EthWithdrawal = @import("../../eth/Withdrawal.zig");
const stateless_validate = @import("../validate.zig");
const block_stf = @import("../../eth/block_stf.zig");
const transaction_raw = @import("../../transaction/raw.zig");
const transaction_signing = @import("../../transaction/signing.zig");
const uint256 = @import("../../uint256.zig");
const zisk_profile = @import("stateless_profile");

pub const revision: Revision = .amsterdam;
const AmsterdamValidator = stateless_validate.Exact(revision);
const AmsterdamOneShotValidator = stateless_validate.ExactWithOptions(revision, .{
    .step_capture = false,
});

pub const schema_id: u16 = 0x1501;
pub const schema_id_size = 2;
const max_extra_data_bytes = 32;
const max_withdrawals_per_payload = 16;
const max_transactions_per_payload = 1 << 20;
const max_bytes_per_transaction = 1 << 30;
const max_blob_commitments_per_block = 4096;
const max_deposit_requests_per_payload = 8192;
const max_withdrawal_requests_per_payload = 16;
const max_consolidation_requests_per_payload = 2;
const max_builder_deposit_requests_per_payload = 64;
const max_builder_exit_requests_per_payload = 16;
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
    InvalidPublicKey,
    ExtraDataTooLong,
};

pub const ValidationOptions = struct {};

pub const ProtocolFork = enum(u64) {
    frontier = 0x01,
    homestead = 0x02,
    dao_fork = 0x03,
    tangerine_whistle = 0x04,
    spurious_dragon = 0x05,
    byzantium = 0x06,
    petersburg = 0x07,
    istanbul = 0x08,
    muir_glacier = 0x09,
    berlin = 0x0a,
    london = 0x0b,
    arrow_glacier = 0x0c,
    gray_glacier = 0x0d,
    paris = 0x0e,
    shanghai = 0x0f,
    cancun = 0x10,
    prague = 0x11,
    osaka = 0x12,
    bpo1 = 0x13,
    bpo2 = 0x14,
    amsterdam = 0x15,

    pub fn fromInt(value: u64) Error!ProtocolFork {
        return switch (value) {
            0x01 => .frontier,
            0x02 => .homestead,
            0x03 => .dao_fork,
            0x04 => .tangerine_whistle,
            0x05 => .spurious_dragon,
            0x06 => .byzantium,
            0x07 => .petersburg,
            0x08 => .istanbul,
            0x09 => .muir_glacier,
            0x0a => .berlin,
            0x0b => .london,
            0x0c => .arrow_glacier,
            0x0d => .gray_glacier,
            0x0e => .paris,
            0x0f => .shanghai,
            0x10 => .cancun,
            0x11 => .prague,
            0x12 => .osaka,
            0x13 => .bpo1,
            0x14 => .bpo2,
            0x15 => .amsterdam,
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

pub const ForkConfig = struct {
    activation: ForkActivation,

    pub const Ssz = ssz.Container(@This(), .{});
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
    builder_deposits: []const BuilderDepositRequest = &.{},
    builder_exits: []const BuilderExitRequest = &.{},

    pub const Ssz = ssz.Container(@This(), .{
        .deposits = ssz.List(DepositRequest, max_deposit_requests_per_payload),
        .withdrawals = ssz.List(WithdrawalRequest, max_withdrawal_requests_per_payload),
        .consolidations = ssz.List(ConsolidationRequest, max_consolidation_requests_per_payload),
        .builder_deposits = ssz.List(BuilderDepositRequest, max_builder_deposit_requests_per_payload),
        .builder_exits = ssz.List(BuilderExitRequest, max_builder_exit_requests_per_payload),
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
        if (self.deposits.len == 0 and
            self.withdrawals.len == 0 and
            self.consolidations.len == 0 and
            self.builder_deposits.len == 0 and
            self.builder_exits.len == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |request| allocator.free(request);
            out.deinit(allocator);
        }
        if (self.deposits.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x00, DepositRequest, self.deposits));
        if (self.withdrawals.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x01, WithdrawalRequest, self.withdrawals));
        if (self.consolidations.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x02, ConsolidationRequest, self.consolidations));
        if (self.builder_deposits.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x03, BuilderDepositRequest, self.builder_deposits));
        if (self.builder_exits.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x04, BuilderExitRequest, self.builder_exits));
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

pub const BuilderDepositRequest = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,
};

pub const BuilderExitRequest = struct {
    source_address: address.Address,
    pubkey: [48]u8,
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
        return encodeWire(NewPayloadRequestAmsterdamWire.Ssz, allocator, amsterdamRequestWire(self));
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestAmsterdam {
        const value = try decodeWire(NewPayloadRequestAmsterdamWire.Ssz, allocator, bytes);
        return amsterdamRequestFromWire(value);
    }

    pub fn deinit(self: *NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) void {
        self.execution_payload.deinit(allocator);
        VersionedHashesSsz.deinit(allocator, &self.versioned_hashes);
        self.execution_requests.deinit(allocator);
    }

    pub fn hashTreeRoot(self: NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) Error![32]u8 {
        _ = allocator;
        return hashWire(NewPayloadRequestAmsterdamWire.Ssz, amsterdamRequestWire(self));
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
        const request = switch (self.new_payload_request) {
            .amsterdam => |value| amsterdamRequestWire(value),
            else => return error.UnsupportedFork,
        };
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

    fn decodeSchemaPrefixedBorrowed(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessInput {
        if (bytes.len < schema_id_size) return error.MissingSchemaId;
        const actual_schema_id = std.mem.readInt(u16, bytes[0..schema_id_size], .big);
        if (actual_schema_id != schema_id) return error.UnsupportedSchemaId;
        return decodeBorrowed(allocator, bytes[schema_id_size..]);
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessInput {
        var value = try decodeWire(StatelessInputWire.Ssz, allocator, bytes);
        var owns_value = true;
        errdefer if (owns_value) StatelessInputWire.Ssz.deinit(allocator, &value);

        const chain_config = value.chain_config;
        const new_payload_request = NewPayloadRequest{ .amsterdam = amsterdamRequestFromWire(value.new_payload_request) };
        owns_value = false;
        return .{
            .new_payload_request = new_payload_request,
            .witness = value.witness,
            .chain_config = chain_config,
            .public_keys = value.public_keys,
        };
    }

    fn decodeBorrowed(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessInput {
        const value = try decodeWire(BorrowedStatelessInputSsz, allocator, bytes);
        return .{
            .new_payload_request = .{ .amsterdam = amsterdamRequestFromWire(value.new_payload_request) },
            .witness = value.witness,
            .chain_config = value.chain_config,
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
const BlockAccessListSsz = ssz.ByteList(max_block_access_list_bytes);
const PublicKeysSsz = ssz.List([public_key_bytes]u8, max_public_keys);

const BorrowedTransactionsSsz = ssz.ListOf(
    ssz.Borrowed(ssz.ByteList(max_bytes_per_transaction)),
    max_transactions_per_payload,
);
const BorrowedExecutionWitnessSsz = ssz.Container(ExecutionWitness, .{
    .state = ssz.ListOf(ssz.Borrowed(ssz.ByteList(max_bytes_per_witness_node)), max_witness_nodes),
    .codes = ssz.ListOf(ssz.Borrowed(ssz.ByteList(max_bytes_per_code)), max_witness_codes),
    .headers = ssz.ListOf(ssz.Borrowed(ssz.ByteList(max_bytes_per_header)), max_witness_headers),
});

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

fn amsterdamRequestWire(value: NewPayloadRequestAmsterdam) NewPayloadRequestAmsterdamWire {
    return .{
        .execution_payload = payloadV4Wire(value.execution_payload),
        .versioned_hashes = value.versioned_hashes,
        .parent_beacon_block_root = value.parent_beacon_block_root,
        .execution_requests = value.execution_requests,
    };
}

fn amsterdamRequestFromWire(value: NewPayloadRequestAmsterdamWire) NewPayloadRequestAmsterdam {
    return .{
        .execution_payload = payloadV4FromWire(value.execution_payload),
        .versioned_hashes = value.versioned_hashes,
        .parent_beacon_block_root = value.parent_beacon_block_root,
        .execution_requests = value.execution_requests,
    };
}

const StatelessInputWire = struct {
    new_payload_request: NewPayloadRequestAmsterdamWire,
    witness: ExecutionWitness,
    chain_config: ChainConfig,
    public_keys: []const [public_key_bytes]u8,

    pub const Ssz = ssz.Container(@This(), .{
        .public_keys = PublicKeysSsz,
    });
};

const BorrowedExecutionPayloadV4Ssz = ssz.Container(ExecutionPayloadV4Wire, .{
    .extra_data = ssz.Borrowed(ssz.ByteList(max_extra_data_bytes)),
    .transactions = BorrowedTransactionsSsz,
    .withdrawals = WithdrawalsSsz,
    .block_access_list = ssz.Borrowed(ssz.ByteList(max_block_access_list_bytes)),
});
const BorrowedNewPayloadRequestAmsterdamSsz = ssz.Container(NewPayloadRequestAmsterdamWire, .{
    .execution_payload = BorrowedExecutionPayloadV4Ssz,
    .versioned_hashes = VersionedHashesSsz,
});
const BorrowedStatelessInputSsz = ssz.Container(StatelessInputWire, .{
    .new_payload_request = BorrowedNewPayloadRequestAmsterdamSsz,
    .witness = BorrowedExecutionWitnessSsz,
    .public_keys = PublicKeysSsz,
});

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
            .activation = .{},
        },
    };
}

fn failureResult(chain_config: ChainConfig, request_root: [32]u8) StatelessValidationResult {
    return .{
        .new_payload_request_root = request_root,
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
    return validateStatelessBytesUsingScratch(false, arena.allocator(), allocator, bytes, options);
}

/// Validates one invocation whose scratch and result allocations share a
/// caller-owned lifetime. Reusable callers must use `validateStatelessBytes`.
pub fn validateStatelessBytesOneShot(allocator: std.mem.Allocator, bytes: []const u8) Error![]u8 {
    return validateStatelessBytesUsingScratch(true, allocator, allocator, bytes, .{});
}

fn validateStatelessBytesUsingScratch(
    comptime reuse_scratch: bool,
    scratch: std.mem.Allocator,
    result_allocator: std.mem.Allocator,
    bytes: []const u8,
    options: ValidationOptions,
) Error![]u8 {
    zisk_profile.begin(.ssz_decode);
    const input = StatelessInput.decodeSchemaPrefixedBorrowed(scratch, bytes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(defaultChainConfig(), [_]u8{0} ** 32).encode(result_allocator),
    };
    zisk_profile.end(.ssz_decode);
    const result = if (comptime reuse_scratch)
        try validateStatelessWithOptionsImpl(AmsterdamOneShotValidator, true, scratch, input, options)
    else
        try validateStatelessWithOptionsImpl(AmsterdamValidator, false, scratch, input, options);
    if (comptime zisk_profile.enabled) {
        zisk_profile.begin(.result_encode);
        const encoded = try result.encode(result_allocator);
        zisk_profile.end(.result_encode);
        return encoded;
    }
    return result.encode(result_allocator);
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
    return AmsterdamValidator.validateWithCapture(scratch, normalized, capture) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.BlockTransitionFailed => return error.BlockTransitionFailed,
        else => .{ .status = .invalid_witness },
    };
}

pub fn validateStateless(allocator: std.mem.Allocator, input: StatelessInput) Error!StatelessValidationResult {
    return validateStatelessWithOptions(allocator, input, .{});
}

pub fn validateStatelessWithOptions(allocator: std.mem.Allocator, input: StatelessInput, options: ValidationOptions) Error!StatelessValidationResult {
    return validateStatelessWithOptionsImpl(AmsterdamValidator, false, allocator, input, options);
}

fn validateStatelessWithOptionsImpl(
    comptime Validator: type,
    comptime reuse_scratch: bool,
    allocator: std.mem.Allocator,
    input: StatelessInput,
    options: ValidationOptions,
) Error!StatelessValidationResult {
    zisk_profile.begin(.request_root);
    const request_root = input.new_payload_request.hashTreeRoot(allocator) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(input.chain_config, [_]u8{0} ** 32),
    };
    zisk_profile.end(.request_root);
    _ = options;
    zisk_profile.begin(.normalize);
    const normalized = normalize(allocator, input) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return failureResult(input.chain_config, request_root),
    };
    zisk_profile.end(.normalize);
    zisk_profile.begin(.execute);
    const native_result = (if (comptime reuse_scratch)
        Validator.validateOneShot(allocator, normalized)
    else
        Validator.validate(allocator, normalized)) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => block_stf.Result{ .status = .invalid_witness },
    };
    zisk_profile.end(.execute);
    return .{
        .new_payload_request_root = request_root,
        .successful_validation = native_result.status == .valid,
        .chain_config = input.chain_config,
    };
}

/// Converts the immutable v1 wire representation into runtime Ethereum facts.
/// Supplied public keys are authenticated against each signed payload
/// transaction before they are discarded from the normalized execution input.
/// EIP-8025 requires rejecting a key that is not the signer's, including a
/// well-formed opposite-parity point, so the hint cannot simply be ignored.
/// Recovery also authenticates the sender used by the decoded transaction, so
/// execution reuses that prepared value instead of recovering a second time.
/// Returned slices borrow decoded input or storage owned by `allocator`; guest
/// callers should use one block-lifetime arena.
pub fn normalize(allocator: std.mem.Allocator, input: StatelessInput) Error!input_mod.Input {
    try validateChainConfig(input.chain_config, input.new_payload_request);
    const payload = input.new_payload_request.payloadView();
    const transactions = try normalizeTransactions(
        allocator,
        payload.transactions,
        input.public_keys,
    );
    const withdrawals = try normalizeWithdrawals(allocator, payload.withdrawals);
    const execution_requests = if (input.new_payload_request.executionRequests()) |requests|
        try requests.typedOpaqueRequests(allocator)
    else
        &.{};
    return .{
        .chain_id = input.chain_config.chain_id,
        .blob_schedule = null,
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
            .transactions = transactions,
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

fn normalizeTransactions(
    allocator: std.mem.Allocator,
    transactions: []const []const u8,
    public_keys: []const [public_key_bytes]u8,
) Error![]const block_stf.TransactionInput {
    if (public_keys.len != transactions.len) return error.InvalidPublicKey;
    if (transactions.len == 0) return &.{};

    const normalized = try allocator.alloc(block_stf.TransactionInput, transactions.len);
    errdefer allocator.free(normalized);
    for (normalized, transactions, public_keys) |*target, encoded, expected| {
        const recovered = transaction_signing.recoverSender(allocator, encoded) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.InvalidPublicKey,
        };
        if (!std.mem.eql(u8, &recovered.public_key, &expected)) return error.InvalidPublicKey;
        target.* = block_stf.TransactionInput.initAssumeDecoded(
            try transaction_raw.decodeRawAssumeSender(allocator, encoded, recovered.sender),
            encoded,
        );
    }
    return normalized;
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

test "borrowed witness decoding keeps byte lists in the wire input" {
    const state = [_][]const u8{"node"};
    const encoded = try encodeWire(ExecutionWitness.Ssz, std.testing.allocator, .{ .state = &state });
    defer std.testing.allocator.free(encoded);

    var decoded = try decodeWire(BorrowedExecutionWitnessSsz, std.testing.allocator, encoded);
    defer BorrowedExecutionWitnessSsz.deinit(std.testing.allocator, &decoded);

    try std.testing.expectEqual(@as(usize, 1), decoded.state.len);
    try std.testing.expectEqualSlices(u8, "node", decoded.state[0]);
    const borrowed_start = @intFromPtr(decoded.state[0].ptr);
    const input_start = @intFromPtr(encoded.ptr);
    try std.testing.expect(borrowed_start >= input_start);
    try std.testing.expect(borrowed_start + decoded.state[0].len <= input_start + encoded.len);
}
