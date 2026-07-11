//! Schema `0x0001` wire contract for the stateless zkEVM guest interface.
//! Defines the SSZ-encoded `StatelessInput`/`StatelessValidationResult` types
//! (per tests-zkevm v0.5) and the schema-prefixed validate entry points.
//! The two-byte schema id gates decoding; unknown ids are rejected.

const std = @import("std");

const Revision = @import("../../eth/revision.zig").Revision;
const EthTransaction = @import("../../eth/transaction.zig").Transaction;
const address = @import("../../address.zig");
const input_mod = @import("../input.zig");
const mpt = @import("../../mpt.zig");
const ssz = @import("../ssz.zig");
const stateless_validate = @import("../validate.zig");
const block_stf = @import("../../eth/block_stf.zig");
const transaction = @import("../../transaction.zig");
const trace = @import("../../trace.zig");
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

    pub fn encode(self: ForkActivation, allocator: std.mem.Allocator) Error![]u8 {
        const block_number = try encodeOptionalU64List(allocator, self.block_number);
        defer allocator.free(block_number);
        const timestamp = try encodeOptionalU64List(allocator, self.timestamp);
        defer allocator.free(timestamp);
        return ssz.encodeContainer(allocator, 2, .{
            .{ .variable = block_number },
            .{ .variable = timestamp },
        });
    }

    pub fn decode(bytes: []const u8) Error!ForkActivation {
        const fields = try ssz.splitVariableFields(2, bytes);
        return .{
            .block_number = try decodeOptionalU64List(fields[0]),
            .timestamp = try decodeOptionalU64List(fields[1]),
        };
    }
};

pub const BlobSchedule = struct {
    target: u64,
    max: u64,
    base_fee_update_fraction: u64,

    fn encodeInto(self: BlobSchedule, out: *[24]u8) void {
        std.mem.writeInt(u64, out[0..8], self.target, .little);
        std.mem.writeInt(u64, out[8..16], self.max, .little);
        std.mem.writeInt(u64, out[16..24], self.base_fee_update_fraction, .little);
    }

    fn decode(bytes: []const u8) Error!BlobSchedule {
        if (bytes.len != 24) return error.InvalidByteLength;
        return .{
            .target = try ssz.readU64(bytes[0..8]),
            .max = try ssz.readU64(bytes[8..16]),
            .base_fee_update_fraction = try ssz.readU64(bytes[16..24]),
        };
    }
};

pub const ForkConfig = struct {
    fork: ProtocolFork,
    activation: ForkActivation,
    blob_schedule: ?BlobSchedule = null,

    pub fn encode(self: ForkConfig, allocator: std.mem.Allocator) Error![]u8 {
        var fork_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &fork_bytes, @intFromEnum(self.fork), .little);
        const activation = try self.activation.encode(allocator);
        defer allocator.free(activation);
        const blob_schedule = try encodeBlobScheduleList(allocator, self.blob_schedule);
        defer allocator.free(blob_schedule);
        return ssz.encodeContainer(allocator, 3, .{
            .{ .fixed = &fork_bytes },
            .{ .variable = activation },
            .{ .variable = blob_schedule },
        });
    }

    pub fn decode(bytes: []const u8) Error!ForkConfig {
        if (bytes.len < 16) return error.InvalidByteLength;
        const activation_offset = readOffset(bytes[8..12]);
        const blob_schedule_offset = readOffset(bytes[12..16]);
        if (activation_offset != 16) return error.InvalidFirstOffset;
        if (blob_schedule_offset < activation_offset) return error.OffsetsAreNotMonotonic;
        if (blob_schedule_offset > bytes.len) return error.OffsetOutOfBounds;
        return .{
            .fork = try ProtocolFork.fromInt(try ssz.readU64(bytes[0..8])),
            .activation = try ForkActivation.decode(bytes[activation_offset..blob_schedule_offset]),
            .blob_schedule = try decodeBlobScheduleList(bytes[blob_schedule_offset..]),
        };
    }
};

pub const ChainConfig = struct {
    chain_id: u64,
    active_fork: ForkConfig,

    pub fn encode(self: ChainConfig, allocator: std.mem.Allocator) Error![]u8 {
        var chain_id_bytes: [8]u8 = undefined;
        std.mem.writeInt(u64, &chain_id_bytes, self.chain_id, .little);
        const active_fork = try self.active_fork.encode(allocator);
        defer allocator.free(active_fork);
        return ssz.encodeContainer(allocator, 2, .{
            .{ .fixed = &chain_id_bytes },
            .{ .variable = active_fork },
        });
    }

    pub fn decode(bytes: []const u8) Error!ChainConfig {
        if (bytes.len < 12) return error.InvalidByteLength;
        const active_fork_offset = readOffset(bytes[8..12]);
        if (active_fork_offset != 12) return error.InvalidFirstOffset;
        if (active_fork_offset > bytes.len) return error.OffsetOutOfBounds;
        return .{
            .chain_id = try ssz.readU64(bytes[0..8]),
            .active_fork = try ForkConfig.decode(bytes[active_fork_offset..]),
        };
    }
};

pub const ExecutionWitness = struct {
    state: []const []const u8 = &.{},
    codes: []const []const u8 = &.{},
    headers: []const []const u8 = &.{},

    pub fn encode(self: ExecutionWitness, allocator: std.mem.Allocator) Error![]u8 {
        const state = try encodeBoundedByteListList(allocator, self.state, max_witness_nodes, max_bytes_per_witness_node);
        defer allocator.free(state);
        const codes = try encodeBoundedByteListList(allocator, self.codes, max_witness_codes, max_bytes_per_code);
        defer allocator.free(codes);
        const headers = try encodeBoundedByteListList(allocator, self.headers, max_witness_headers, max_bytes_per_header);
        defer allocator.free(headers);
        return ssz.encodeContainer(allocator, 3, .{
            .{ .variable = state },
            .{ .variable = codes },
            .{ .variable = headers },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionWitness {
        const fields = try ssz.splitVariableFields(3, bytes);
        return .{
            .state = try decodeBoundedByteListList(allocator, fields[0], max_witness_nodes, max_bytes_per_witness_node),
            .codes = try decodeBoundedByteListList(allocator, fields[1], max_witness_codes, max_bytes_per_code),
            .headers = try decodeBoundedByteListList(allocator, fields[2], max_witness_headers, max_bytes_per_header),
        };
    }
};

pub const Withdrawal = struct {
    index: u64,
    validator_index: u64,
    address: address.Address,
    amount: u64,

    const fixed_len = 44;

    fn encodeInto(self: Withdrawal, out: *[fixed_len]u8) void {
        std.mem.writeInt(u64, out[0..8], self.index, .little);
        std.mem.writeInt(u64, out[8..16], self.validator_index, .little);
        @memcpy(out[16..36], &self.address);
        std.mem.writeInt(u64, out[36..44], self.amount, .little);
    }

    fn decode(bytes: []const u8) Error!Withdrawal {
        if (bytes.len != fixed_len) return error.InvalidByteLength;
        return .{
            .index = try ssz.readU64(bytes[0..8]),
            .validator_index = try ssz.readU64(bytes[8..16]),
            .address = bytes[16..36].*,
            .amount = try ssz.readU64(bytes[36..44]),
        };
    }

    fn hashTreeRoot(self: Withdrawal, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            ssz.uint64Root(self.index),
            ssz.uint64Root(self.validator_index),
            ssz.fixedBytesRoot(&self.address),
            ssz.uint64Root(self.amount),
        };
        return ssz.containerRoot(allocator, &roots);
    }

    fn toMpt(self: Withdrawal) mpt.Withdrawal {
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

    pub fn encode(self: ExecutionRequests, allocator: std.mem.Allocator) Error![]u8 {
        const deposits = try encodeFixedStructList(allocator, DepositRequest, DepositRequest.fixed_len, self.deposits);
        defer allocator.free(deposits);
        const withdrawals = try encodeFixedStructList(allocator, WithdrawalRequest, WithdrawalRequest.fixed_len, self.withdrawals);
        defer allocator.free(withdrawals);
        const consolidations = try encodeFixedStructList(allocator, ConsolidationRequest, ConsolidationRequest.fixed_len, self.consolidations);
        defer allocator.free(consolidations);
        return ssz.encodeContainer(allocator, 3, .{
            .{ .variable = deposits },
            .{ .variable = withdrawals },
            .{ .variable = consolidations },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionRequests {
        const fields = try ssz.splitVariableFields(3, bytes);
        try validateBoundedFixedStructList(DepositRequest.fixed_len, fields[0], max_deposit_requests_per_payload);
        try validateBoundedFixedStructList(WithdrawalRequest.fixed_len, fields[1], max_withdrawal_requests_per_payload);
        try validateBoundedFixedStructList(ConsolidationRequest.fixed_len, fields[2], max_consolidation_requests_per_payload);
        return .{
            .deposits = try decodeBoundedFixedStructList(allocator, DepositRequest, DepositRequest.fixed_len, fields[0], max_deposit_requests_per_payload),
            .withdrawals = try decodeBoundedFixedStructList(allocator, WithdrawalRequest, WithdrawalRequest.fixed_len, fields[1], max_withdrawal_requests_per_payload),
            .consolidations = try decodeBoundedFixedStructList(allocator, ConsolidationRequest, ConsolidationRequest.fixed_len, fields[2], max_consolidation_requests_per_payload),
        };
    }

    pub fn hashTreeRoot(self: ExecutionRequests, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            try fixedStructListRoot(allocator, DepositRequest, self.deposits, max_deposit_requests_per_payload),
            try fixedStructListRoot(allocator, WithdrawalRequest, self.withdrawals, max_withdrawal_requests_per_payload),
            try fixedStructListRoot(allocator, ConsolidationRequest, self.consolidations, max_consolidation_requests_per_payload),
        };
        return ssz.containerRoot(allocator, &roots);
    }

    fn typedOpaqueRequests(self: ExecutionRequests, allocator: std.mem.Allocator) Error![]const []const u8 {
        if (self.deposits.len == 0 and self.withdrawals.len == 0 and self.consolidations.len == 0) return &.{};
        var out: std.ArrayList([]const u8) = .empty;
        errdefer {
            for (out.items) |request| allocator.free(request);
            out.deinit(allocator);
        }
        if (self.deposits.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x00, DepositRequest, DepositRequest.fixed_len, self.deposits));
        if (self.withdrawals.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x01, WithdrawalRequest, WithdrawalRequest.fixed_len, self.withdrawals));
        if (self.consolidations.len > 0) try out.append(allocator, try prefixedFixedStructListBytes(allocator, 0x02, ConsolidationRequest, ConsolidationRequest.fixed_len, self.consolidations));
        return out.toOwnedSlice(allocator);
    }
};

pub const DepositRequest = struct {
    pubkey: [48]u8,
    withdrawal_credentials: [32]u8,
    amount: u64,
    signature: [96]u8,
    index: u64,

    const fixed_len = 192;

    fn encodeInto(self: DepositRequest, out: *[fixed_len]u8) void {
        @memcpy(out[0..48], &self.pubkey);
        @memcpy(out[48..80], &self.withdrawal_credentials);
        std.mem.writeInt(u64, out[80..88], self.amount, .little);
        @memcpy(out[88..184], &self.signature);
        std.mem.writeInt(u64, out[184..192], self.index, .little);
    }

    fn decode(bytes: []const u8) Error!DepositRequest {
        if (bytes.len != fixed_len) return error.InvalidByteLength;
        return .{
            .pubkey = bytes[0..48].*,
            .withdrawal_credentials = bytes[48..80].*,
            .amount = try ssz.readU64(bytes[80..88]),
            .signature = bytes[88..184].*,
            .index = try ssz.readU64(bytes[184..192]),
        };
    }

    fn hashTreeRoot(self: DepositRequest, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            try ssz.bytesVectorRoot(allocator, &self.pubkey),
            self.withdrawal_credentials,
            ssz.uint64Root(self.amount),
            try ssz.bytesVectorRoot(allocator, &self.signature),
            ssz.uint64Root(self.index),
        };
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const WithdrawalRequest = struct {
    source_address: address.Address,
    validator_pubkey: [48]u8,
    amount: u64,

    const fixed_len = 76;

    fn encodeInto(self: WithdrawalRequest, out: *[fixed_len]u8) void {
        @memcpy(out[0..20], &self.source_address);
        @memcpy(out[20..68], &self.validator_pubkey);
        std.mem.writeInt(u64, out[68..76], self.amount, .little);
    }

    fn decode(bytes: []const u8) Error!WithdrawalRequest {
        if (bytes.len != fixed_len) return error.InvalidByteLength;
        return .{
            .source_address = bytes[0..20].*,
            .validator_pubkey = bytes[20..68].*,
            .amount = try ssz.readU64(bytes[68..76]),
        };
    }

    fn hashTreeRoot(self: WithdrawalRequest, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            ssz.fixedBytesRoot(&self.source_address),
            try ssz.bytesVectorRoot(allocator, &self.validator_pubkey),
            ssz.uint64Root(self.amount),
        };
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const ConsolidationRequest = struct {
    source_address: address.Address,
    source_pubkey: [48]u8,
    target_pubkey: [48]u8,

    const fixed_len = 116;

    fn encodeInto(self: ConsolidationRequest, out: *[fixed_len]u8) void {
        @memcpy(out[0..20], &self.source_address);
        @memcpy(out[20..68], &self.source_pubkey);
        @memcpy(out[68..116], &self.target_pubkey);
    }

    fn decode(bytes: []const u8) Error!ConsolidationRequest {
        if (bytes.len != fixed_len) return error.InvalidByteLength;
        return .{
            .source_address = bytes[0..20].*,
            .source_pubkey = bytes[20..68].*,
            .target_pubkey = bytes[68..116].*,
        };
    }

    fn hashTreeRoot(self: ConsolidationRequest, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            ssz.fixedBytesRoot(&self.source_address),
            try ssz.bytesVectorRoot(allocator, &self.source_pubkey),
            try ssz.bytesVectorRoot(allocator, &self.target_pubkey),
        };
        return ssz.containerRoot(allocator, &roots);
    }
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

    const fixed_len = 508;

    pub fn encode(self: ExecutionPayloadV1, allocator: std.mem.Allocator) Error![]u8 {
        if (self.extra_data.len > 32) return error.ExtraDataTooLong;
        var block_number: [8]u8 = undefined;
        var gas_limit: [8]u8 = undefined;
        var gas_used: [8]u8 = undefined;
        var timestamp: [8]u8 = undefined;
        std.mem.writeInt(u64, &block_number, self.block_number, .little);
        std.mem.writeInt(u64, &gas_limit, self.gas_limit, .little);
        std.mem.writeInt(u64, &gas_used, self.gas_used, .little);
        std.mem.writeInt(u64, &timestamp, self.timestamp, .little);

        const transactions = try encodeBoundedByteListList(allocator, self.transactions, max_transactions_per_payload, max_bytes_per_transaction);
        defer allocator.free(transactions);
        return ssz.encodeContainer(allocator, 14, .{
            .{ .fixed = &self.parent_hash },
            .{ .fixed = &self.fee_recipient },
            .{ .fixed = &self.state_root },
            .{ .fixed = &self.receipts_root },
            .{ .fixed = &self.logs_bloom },
            .{ .fixed = &self.prev_randao },
            .{ .fixed = &block_number },
            .{ .fixed = &gas_limit },
            .{ .fixed = &gas_used },
            .{ .fixed = &timestamp },
            .{ .variable = self.extra_data },
            .{ .fixed = &self.base_fee_per_gas },
            .{ .fixed = &self.block_hash },
            .{ .variable = transactions },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV1 {
        if (bytes.len < fixed_len) return error.InvalidByteLength;
        const extra_data_offset = readOffset(bytes[436..440]);
        const transactions_offset = readOffset(bytes[504..508]);
        if (extra_data_offset != fixed_len) return error.InvalidFirstOffset;
        if (transactions_offset < extra_data_offset) return error.OffsetsAreNotMonotonic;
        if (transactions_offset > bytes.len) return error.OffsetOutOfBounds;
        const extra_data = bytes[extra_data_offset..transactions_offset];
        if (extra_data.len > 32) return error.ExtraDataTooLong;

        return .{
            .parent_hash = bytes[0..32].*,
            .fee_recipient = bytes[32..52].*,
            .state_root = bytes[52..84].*,
            .receipts_root = bytes[84..116].*,
            .logs_bloom = bytes[116..372].*,
            .prev_randao = bytes[372..404].*,
            .block_number = try ssz.readU64(bytes[404..412]),
            .gas_limit = try ssz.readU64(bytes[412..420]),
            .gas_used = try ssz.readU64(bytes[420..428]),
            .timestamp = try ssz.readU64(bytes[428..436]),
            .extra_data = extra_data,
            .base_fee_per_gas = bytes[440..472].*,
            .block_hash = bytes[472..504].*,
            .transactions = try decodeBoundedByteListList(allocator, bytes[transactions_offset..], max_transactions_per_payload, max_bytes_per_transaction),
        };
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV1, allocator: std.mem.Allocator) Error![32]u8 {
        var field_roots: [13][32]u8 = undefined;
        field_roots[0] = self.parent_hash;
        field_roots[1] = ssz.fixedBytesRoot(&self.fee_recipient);
        field_roots[2] = self.state_root;
        field_roots[3] = self.receipts_root;
        field_roots[4] = try ssz.bytesVectorRoot(allocator, &self.logs_bloom);
        field_roots[5] = self.prev_randao;
        field_roots[6] = ssz.uint64Root(self.block_number);
        field_roots[7] = ssz.uint64Root(self.gas_limit);
        field_roots[8] = ssz.uint64Root(self.gas_used);
        field_roots[9] = ssz.uint64Root(self.timestamp);
        field_roots[10] = try ssz.bytesListRootLimit(allocator, self.extra_data, max_extra_data_bytes);
        field_roots[11] = self.base_fee_per_gas;
        field_roots[12] = self.block_hash;

        var roots = try allocator.alloc([32]u8, field_roots.len + 1);
        defer allocator.free(roots);
        @memcpy(roots[0..field_roots.len], &field_roots);
        roots[13] = try byteListListRoot(allocator, self.transactions);
        return ssz.containerRoot(allocator, roots);
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

    const fixed_len = 512;

    pub fn encode(self: ExecutionPayloadV2, allocator: std.mem.Allocator) Error![]u8 {
        const transactions = try encodeBoundedByteListList(allocator, self.v1.transactions, max_transactions_per_payload, max_bytes_per_transaction);
        defer allocator.free(transactions);
        const withdrawals = try encodeFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, self.withdrawals);
        defer allocator.free(withdrawals);
        return encodePayloadContainer(allocator, self.v1, 15, .{
            .{ .variable = self.v1.extra_data },
            .{ .fixed = &self.v1.base_fee_per_gas },
            .{ .fixed = &self.v1.block_hash },
            .{ .variable = transactions },
            .{ .variable = withdrawals },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV2 {
        if (bytes.len < fixed_len) return error.InvalidByteLength;
        const extra_data_offset = readOffset(bytes[436..440]);
        const transactions_offset = readOffset(bytes[504..508]);
        const withdrawals_offset = readOffset(bytes[508..512]);
        try validatePayloadOffsets(bytes.len, fixed_len, &.{ extra_data_offset, transactions_offset, withdrawals_offset });
        try validateBoundedFixedStructList(Withdrawal.fixed_len, bytes[withdrawals_offset..], max_withdrawals_per_payload);
        return .{
            .v1 = try decodePayloadV1Fields(allocator, bytes, extra_data_offset, transactions_offset, withdrawals_offset),
            .withdrawals = try decodeBoundedFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, bytes[withdrawals_offset..], max_withdrawals_per_payload),
        };
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV2, allocator: std.mem.Allocator) Error![32]u8 {
        var roots = try payloadV1FieldRoots(allocator, self.v1);
        roots[13] = try byteListListRoot(allocator, self.v1.transactions);
        const all_roots = try allocator.alloc([32]u8, 15);
        defer allocator.free(all_roots);
        @memcpy(all_roots[0..14], &roots);
        all_roots[14] = try fixedStructListRoot(allocator, Withdrawal, self.withdrawals, max_withdrawals_per_payload);
        return ssz.containerRoot(allocator, all_roots);
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

    const fixed_len = 528;

    pub fn encode(self: ExecutionPayloadV3, allocator: std.mem.Allocator) Error![]u8 {
        var blob_gas_used: [8]u8 = undefined;
        var excess_blob_gas: [8]u8 = undefined;
        std.mem.writeInt(u64, &blob_gas_used, self.blob_gas_used, .little);
        std.mem.writeInt(u64, &excess_blob_gas, self.excess_blob_gas, .little);
        const transactions = try encodeBoundedByteListList(allocator, self.v2.v1.transactions, max_transactions_per_payload, max_bytes_per_transaction);
        defer allocator.free(transactions);
        const withdrawals = try encodeFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, self.v2.withdrawals);
        defer allocator.free(withdrawals);
        return encodePayloadContainer(allocator, self.v2.v1, 17, .{
            .{ .variable = self.v2.v1.extra_data },
            .{ .fixed = &self.v2.v1.base_fee_per_gas },
            .{ .fixed = &self.v2.v1.block_hash },
            .{ .variable = transactions },
            .{ .variable = withdrawals },
            .{ .fixed = &blob_gas_used },
            .{ .fixed = &excess_blob_gas },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV3 {
        if (bytes.len < fixed_len) return error.InvalidByteLength;
        const extra_data_offset = readOffset(bytes[436..440]);
        const transactions_offset = readOffset(bytes[504..508]);
        const withdrawals_offset = readOffset(bytes[508..512]);
        try validatePayloadOffsets(bytes.len, fixed_len, &.{ extra_data_offset, transactions_offset, withdrawals_offset });
        try validateBoundedFixedStructList(Withdrawal.fixed_len, bytes[withdrawals_offset..], max_withdrawals_per_payload);
        return .{
            .v2 = .{
                .v1 = try decodePayloadV1Fields(allocator, bytes, extra_data_offset, transactions_offset, withdrawals_offset),
                .withdrawals = try decodeBoundedFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, bytes[withdrawals_offset..], max_withdrawals_per_payload),
            },
            .blob_gas_used = try ssz.readU64(bytes[512..520]),
            .excess_blob_gas = try ssz.readU64(bytes[520..528]),
        };
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV3, allocator: std.mem.Allocator) Error![32]u8 {
        var v1_roots = try payloadV1FieldRoots(allocator, self.v2.v1);
        v1_roots[13] = try byteListListRoot(allocator, self.v2.v1.transactions);
        const roots = try allocator.alloc([32]u8, 17);
        defer allocator.free(roots);
        @memcpy(roots[0..14], &v1_roots);
        roots[14] = try fixedStructListRoot(allocator, Withdrawal, self.v2.withdrawals, max_withdrawals_per_payload);
        roots[15] = ssz.uint64Root(self.blob_gas_used);
        roots[16] = ssz.uint64Root(self.excess_blob_gas);
        return ssz.containerRoot(allocator, roots);
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

    const fixed_len = 540;

    pub fn encode(self: ExecutionPayloadV4, allocator: std.mem.Allocator) Error![]u8 {
        var blob_gas_used: [8]u8 = undefined;
        var excess_blob_gas: [8]u8 = undefined;
        var slot_number: [8]u8 = undefined;
        std.mem.writeInt(u64, &blob_gas_used, self.v3.blob_gas_used, .little);
        std.mem.writeInt(u64, &excess_blob_gas, self.v3.excess_blob_gas, .little);
        std.mem.writeInt(u64, &slot_number, self.slot_number, .little);
        const transactions = try encodeBoundedByteListList(allocator, self.v3.v2.v1.transactions, max_transactions_per_payload, max_bytes_per_transaction);
        defer allocator.free(transactions);
        const withdrawals = try encodeFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, self.v3.v2.withdrawals);
        defer allocator.free(withdrawals);
        return encodePayloadContainer(allocator, self.v3.v2.v1, 19, .{
            .{ .variable = self.v3.v2.v1.extra_data },
            .{ .fixed = &self.v3.v2.v1.base_fee_per_gas },
            .{ .fixed = &self.v3.v2.v1.block_hash },
            .{ .variable = transactions },
            .{ .variable = withdrawals },
            .{ .fixed = &blob_gas_used },
            .{ .fixed = &excess_blob_gas },
            .{ .variable = self.block_access_list },
            .{ .fixed = &slot_number },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!ExecutionPayloadV4 {
        if (bytes.len < fixed_len) return error.InvalidByteLength;
        const extra_data_offset = readOffset(bytes[436..440]);
        const transactions_offset = readOffset(bytes[504..508]);
        const withdrawals_offset = readOffset(bytes[508..512]);
        const block_access_list_offset = readOffset(bytes[528..532]);
        try validatePayloadOffsets(bytes.len, fixed_len, &.{ extra_data_offset, transactions_offset, withdrawals_offset, block_access_list_offset });
        try validateBoundedFixedStructList(Withdrawal.fixed_len, bytes[withdrawals_offset..block_access_list_offset], max_withdrawals_per_payload);
        return .{
            .v3 = .{
                .v2 = .{
                    .v1 = try decodePayloadV1Fields(allocator, bytes, extra_data_offset, transactions_offset, withdrawals_offset),
                    .withdrawals = try decodeBoundedFixedStructList(allocator, Withdrawal, Withdrawal.fixed_len, bytes[withdrawals_offset..block_access_list_offset], max_withdrawals_per_payload),
                },
                .blob_gas_used = try ssz.readU64(bytes[512..520]),
                .excess_blob_gas = try ssz.readU64(bytes[520..528]),
            },
            .block_access_list = bytes[block_access_list_offset..],
            .slot_number = try ssz.readU64(bytes[532..540]),
        };
    }

    pub fn hashTreeRoot(self: ExecutionPayloadV4, allocator: std.mem.Allocator) Error![32]u8 {
        var v1_roots = try payloadV1FieldRoots(allocator, self.v3.v2.v1);
        v1_roots[13] = try byteListListRoot(allocator, self.v3.v2.v1.transactions);
        const roots = try allocator.alloc([32]u8, 19);
        defer allocator.free(roots);
        @memcpy(roots[0..14], &v1_roots);
        roots[14] = try fixedStructListRoot(allocator, Withdrawal, self.v3.v2.withdrawals, max_withdrawals_per_payload);
        roots[15] = ssz.uint64Root(self.v3.blob_gas_used);
        roots[16] = ssz.uint64Root(self.v3.excess_blob_gas);
        roots[17] = try ssz.bytesListRootLimit(allocator, self.block_access_list, max_block_access_list_bytes);
        roots[18] = ssz.uint64Root(self.slot_number);
        return ssz.containerRoot(allocator, roots);
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
        const payload = try self.execution_payload.encode(allocator);
        defer allocator.free(payload);
        return ssz.encodeContainer(allocator, 1, .{.{ .variable = payload }});
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestBellatrix {
        const fields = try ssz.splitVariableFields(1, bytes);
        return .{ .execution_payload = try ExecutionPayloadV1.decode(allocator, fields[0]) };
    }

    pub fn hashTreeRoot(self: NewPayloadRequestBellatrix, allocator: std.mem.Allocator) Error![32]u8 {
        const payload_root = try self.execution_payload.hashTreeRoot(allocator);
        const roots = [_][32]u8{payload_root};
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const NewPayloadRequestCapella = struct {
    execution_payload: ExecutionPayloadV2,

    pub fn encode(self: NewPayloadRequestCapella, allocator: std.mem.Allocator) Error![]u8 {
        const payload = try self.execution_payload.encode(allocator);
        defer allocator.free(payload);
        return ssz.encodeContainer(allocator, 1, .{.{ .variable = payload }});
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestCapella {
        const fields = try ssz.splitVariableFields(1, bytes);
        return .{ .execution_payload = try ExecutionPayloadV2.decode(allocator, fields[0]) };
    }

    pub fn hashTreeRoot(self: NewPayloadRequestCapella, allocator: std.mem.Allocator) Error![32]u8 {
        const payload_root = try self.execution_payload.hashTreeRoot(allocator);
        const roots = [_][32]u8{payload_root};
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const NewPayloadRequestDeneb = struct {
    execution_payload: ExecutionPayloadV3,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,

    pub fn encode(self: NewPayloadRequestDeneb, allocator: std.mem.Allocator) Error![]u8 {
        const payload = try self.execution_payload.encode(allocator);
        defer allocator.free(payload);
        const versioned_hashes = try ssz.encodeFixedList(allocator, 32, self.versioned_hashes);
        defer allocator.free(versioned_hashes);
        return ssz.encodeContainer(allocator, 3, .{
            .{ .variable = payload },
            .{ .variable = versioned_hashes },
            .{ .fixed = &self.parent_beacon_block_root },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestDeneb {
        if (bytes.len < 40) return error.InvalidByteLength;
        const payload_offset = readOffset(bytes[0..4]);
        const versioned_hashes_offset = readOffset(bytes[4..8]);
        if (payload_offset != 40) return error.InvalidFirstOffset;
        if (versioned_hashes_offset < payload_offset) return error.OffsetsAreNotMonotonic;
        if (versioned_hashes_offset > bytes.len) return error.OffsetOutOfBounds;
        return .{
            .execution_payload = try ExecutionPayloadV3.decode(allocator, bytes[payload_offset..versioned_hashes_offset]),
            .versioned_hashes = try decodeHashList(allocator, bytes[versioned_hashes_offset..]),
            .parent_beacon_block_root = bytes[8..40].*,
        };
    }

    pub fn hashTreeRoot(self: NewPayloadRequestDeneb, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            try self.execution_payload.hashTreeRoot(allocator),
            try hashListRoot(allocator, self.versioned_hashes),
            self.parent_beacon_block_root,
        };
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const NewPayloadRequestElectraFulu = struct {
    execution_payload: ExecutionPayloadV3,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests = .{},

    pub fn encode(self: NewPayloadRequestElectraFulu, allocator: std.mem.Allocator) Error![]u8 {
        const payload = try self.execution_payload.encode(allocator);
        defer allocator.free(payload);
        const versioned_hashes = try ssz.encodeFixedList(allocator, 32, self.versioned_hashes);
        defer allocator.free(versioned_hashes);
        const execution_requests = try self.execution_requests.encode(allocator);
        defer allocator.free(execution_requests);
        return ssz.encodeContainer(allocator, 4, .{
            .{ .variable = payload },
            .{ .variable = versioned_hashes },
            .{ .fixed = &self.parent_beacon_block_root },
            .{ .variable = execution_requests },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestElectraFulu {
        if (bytes.len < 44) return error.InvalidByteLength;
        const payload_offset = readOffset(bytes[0..4]);
        const versioned_hashes_offset = readOffset(bytes[4..8]);
        const execution_requests_offset = readOffset(bytes[40..44]);
        try validatePayloadOffsets(bytes.len, 44, &.{ payload_offset, versioned_hashes_offset, execution_requests_offset });
        return .{
            .execution_payload = try ExecutionPayloadV3.decode(allocator, bytes[payload_offset..versioned_hashes_offset]),
            .versioned_hashes = try decodeHashList(allocator, bytes[versioned_hashes_offset..execution_requests_offset]),
            .parent_beacon_block_root = bytes[8..40].*,
            .execution_requests = try ExecutionRequests.decode(allocator, bytes[execution_requests_offset..]),
        };
    }

    pub fn hashTreeRoot(self: NewPayloadRequestElectraFulu, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            try self.execution_payload.hashTreeRoot(allocator),
            try hashListRoot(allocator, self.versioned_hashes),
            self.parent_beacon_block_root,
            try self.execution_requests.hashTreeRoot(allocator),
        };
        return ssz.containerRoot(allocator, &roots);
    }
};

pub const NewPayloadRequestAmsterdam = struct {
    execution_payload: ExecutionPayloadV4,
    versioned_hashes: []const [32]u8 = &.{},
    parent_beacon_block_root: [32]u8,
    execution_requests: ExecutionRequests = .{},

    pub fn encode(self: NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) Error![]u8 {
        const payload = try self.execution_payload.encode(allocator);
        defer allocator.free(payload);
        const versioned_hashes = try ssz.encodeFixedList(allocator, 32, self.versioned_hashes);
        defer allocator.free(versioned_hashes);
        const execution_requests = try self.execution_requests.encode(allocator);
        defer allocator.free(execution_requests);
        return ssz.encodeContainer(allocator, 4, .{
            .{ .variable = payload },
            .{ .variable = versioned_hashes },
            .{ .fixed = &self.parent_beacon_block_root },
            .{ .variable = execution_requests },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!NewPayloadRequestAmsterdam {
        if (bytes.len < 44) return error.InvalidByteLength;
        const payload_offset = readOffset(bytes[0..4]);
        const versioned_hashes_offset = readOffset(bytes[4..8]);
        const execution_requests_offset = readOffset(bytes[40..44]);
        try validatePayloadOffsets(bytes.len, 44, &.{ payload_offset, versioned_hashes_offset, execution_requests_offset });
        return .{
            .execution_payload = try ExecutionPayloadV4.decode(allocator, bytes[payload_offset..versioned_hashes_offset]),
            .versioned_hashes = try decodeHashList(allocator, bytes[versioned_hashes_offset..execution_requests_offset]),
            .parent_beacon_block_root = bytes[8..40].*,
            .execution_requests = try ExecutionRequests.decode(allocator, bytes[execution_requests_offset..]),
        };
    }

    pub fn hashTreeRoot(self: NewPayloadRequestAmsterdam, allocator: std.mem.Allocator) Error![32]u8 {
        const roots = [_][32]u8{
            try self.execution_payload.hashTreeRoot(allocator),
            try hashListRoot(allocator, self.versioned_hashes),
            self.parent_beacon_block_root,
            try self.execution_requests.hashTreeRoot(allocator),
        };
        return ssz.containerRoot(allocator, &roots);
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
            // BPO placeholders have no local Revision mapping yet.
            .bpo1, .bpo2 => error.UnsupportedFork,
            else => error.UnsupportedFork,
        };
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
        const witness = try self.witness.encode(allocator);
        defer allocator.free(witness);
        const chain_config = try self.chain_config.encode(allocator);
        defer allocator.free(chain_config);
        if (self.public_keys.len > max_public_keys) return error.InvalidListLength;
        const public_keys = try ssz.encodeFixedList(allocator, public_key_bytes, self.public_keys);
        defer allocator.free(public_keys);
        return ssz.encodeContainer(allocator, 4, .{
            .{ .variable = request },
            .{ .variable = witness },
            .{ .variable = chain_config },
            .{ .variable = public_keys },
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
        const fields = try ssz.splitVariableFields(4, bytes);
        return decodeFields(allocator, fields[0], fields[1], fields[2], fields[3]);
    }

    fn decodeFields(
        allocator: std.mem.Allocator,
        request_bytes: []const u8,
        witness_bytes: []const u8,
        chain_config_bytes: []const u8,
        public_keys_bytes: []const u8,
    ) Error!StatelessInput {
        const chain_config = try ChainConfig.decode(chain_config_bytes);
        const new_payload_request = try NewPayloadRequest.decode(allocator, chain_config.active_fork.fork, request_bytes);
        const witness = try ExecutionWitness.decode(allocator, witness_bytes);
        const public_keys = try decodePublicKeys(allocator, public_keys_bytes);
        try validateChainConfig(chain_config, new_payload_request);
        return .{
            .new_payload_request = new_payload_request,
            .witness = witness,
            .chain_config = chain_config,
            .public_keys = public_keys,
        };
    }
};

pub const StatelessValidationResult = struct {
    new_payload_request_root: [32]u8,
    successful_validation: bool,
    chain_config: ChainConfig,

    pub fn encode(self: StatelessValidationResult, allocator: std.mem.Allocator) Error![]u8 {
        var success: [1]u8 = undefined;
        ssz.writeBool(&success, self.successful_validation);
        const chain_config = try self.chain_config.encode(allocator);
        defer allocator.free(chain_config);
        return ssz.encodeContainer(allocator, 3, .{
            .{ .fixed = &self.new_payload_request_root },
            .{ .fixed = &success },
            .{ .variable = chain_config },
        });
    }

    pub fn decode(allocator: std.mem.Allocator, bytes: []const u8) Error!StatelessValidationResult {
        _ = allocator;
        if (bytes.len < 37) return error.InvalidByteLength;
        const chain_config_offset = readOffset(bytes[33..37]);
        if (chain_config_offset != 37) return error.InvalidFirstOffset;
        if (chain_config_offset > bytes.len) return error.OffsetOutOfBounds;
        return .{
            .new_payload_request_root = bytes[0..32].*,
            .successful_validation = try ssz.readBool(bytes[32..33]),
            .chain_config = try ChainConfig.decode(bytes[chain_config_offset..]),
        };
    }
};

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
    return validateStatelessResultBytesWithTraceAndOptions(allocator, bytes, null, .{});
}

pub fn validateStatelessResultBytesWithOptions(allocator: std.mem.Allocator, bytes: []const u8, options: ValidationOptions) Error!block_stf.Result {
    return validateStatelessResultBytesWithTraceAndOptions(allocator, bytes, null, options);
}

pub fn validateStatelessResultBytesWithTrace(allocator: std.mem.Allocator, bytes: []const u8, trace_sink: ?*trace.Sink) Error!block_stf.Result {
    return validateStatelessResultBytesWithTraceAndOptions(allocator, bytes, trace_sink, .{});
}

pub fn validateStatelessResultBytesWithTraceAndOptions(allocator: std.mem.Allocator, bytes: []const u8, trace_sink: ?*trace.Sink, options: ValidationOptions) Error!block_stf.Result {
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
    return stateless_validate.validateWithTrace(scratch, normalized, trace_sink) catch |err| switch (err) {
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
    var out = EthTransaction.blobSchedule(revision) orelse return error.UnsupportedBlobScheduleOverride;
    out.target = schedule.target;
    out.max = schedule.max;
    out.base_fee_update_fraction = schedule.base_fee_update_fraction;
    return out;
}

fn normalizeWithdrawals(allocator: std.mem.Allocator, withdrawals: []const Withdrawal) Error![]const mpt.Withdrawal {
    if (withdrawals.len == 0) return &.{};
    const out = try allocator.alloc(mpt.Withdrawal, withdrawals.len);
    for (out, withdrawals) |*target, source| target.* = source.toMpt();
    return out;
}

fn byteListListRoot(allocator: std.mem.Allocator, items: []const []const u8) Error![32]u8 {
    const roots = try allocator.alloc([32]u8, items.len);
    defer allocator.free(roots);
    for (roots, items) |*root, item| {
        root.* = try ssz.bytesListRootLimit(allocator, item, max_bytes_per_transaction);
    }
    return ssz.listRootLimit(allocator, roots, max_transactions_per_payload);
}

fn payloadV1FieldRoots(allocator: std.mem.Allocator, payload: ExecutionPayloadV1) Error![14][32]u8 {
    var roots: [14][32]u8 = undefined;
    roots[0] = payload.parent_hash;
    roots[1] = ssz.fixedBytesRoot(&payload.fee_recipient);
    roots[2] = payload.state_root;
    roots[3] = payload.receipts_root;
    roots[4] = try ssz.bytesVectorRoot(allocator, &payload.logs_bloom);
    roots[5] = payload.prev_randao;
    roots[6] = ssz.uint64Root(payload.block_number);
    roots[7] = ssz.uint64Root(payload.gas_limit);
    roots[8] = ssz.uint64Root(payload.gas_used);
    roots[9] = ssz.uint64Root(payload.timestamp);
    roots[10] = try ssz.bytesListRootLimit(allocator, payload.extra_data, max_extra_data_bytes);
    roots[11] = payload.base_fee_per_gas;
    roots[12] = payload.block_hash;
    roots[13] = try byteListListRoot(allocator, payload.transactions);
    return roots;
}

fn encodePayloadContainer(
    allocator: std.mem.Allocator,
    payload: ExecutionPayloadV1,
    comptime field_count: usize,
    tail: [field_count - 10]ssz.Field,
) Error![]u8 {
    if (payload.extra_data.len > 32) return error.ExtraDataTooLong;
    var block_number: [8]u8 = undefined;
    var gas_limit: [8]u8 = undefined;
    var gas_used: [8]u8 = undefined;
    var timestamp: [8]u8 = undefined;
    std.mem.writeInt(u64, &block_number, payload.block_number, .little);
    std.mem.writeInt(u64, &gas_limit, payload.gas_limit, .little);
    std.mem.writeInt(u64, &gas_used, payload.gas_used, .little);
    std.mem.writeInt(u64, &timestamp, payload.timestamp, .little);

    var fields: [field_count]ssz.Field = undefined;
    fields[0] = .{ .fixed = &payload.parent_hash };
    fields[1] = .{ .fixed = &payload.fee_recipient };
    fields[2] = .{ .fixed = &payload.state_root };
    fields[3] = .{ .fixed = &payload.receipts_root };
    fields[4] = .{ .fixed = &payload.logs_bloom };
    fields[5] = .{ .fixed = &payload.prev_randao };
    fields[6] = .{ .fixed = &block_number };
    fields[7] = .{ .fixed = &gas_limit };
    fields[8] = .{ .fixed = &gas_used };
    fields[9] = .{ .fixed = &timestamp };
    inline for (tail, 0..) |field, i| fields[10 + i] = field;
    return ssz.encodeContainer(allocator, field_count, fields);
}

fn decodePayloadV1Fields(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    extra_data_offset: usize,
    transactions_offset: usize,
    transactions_end: usize,
) Error!ExecutionPayloadV1 {
    if (extra_data_offset > transactions_offset or transactions_offset > transactions_end or transactions_end > bytes.len) {
        return error.OffsetsAreNotMonotonic;
    }
    const extra_data = bytes[extra_data_offset..transactions_offset];
    if (extra_data.len > 32) return error.ExtraDataTooLong;
    return .{
        .parent_hash = bytes[0..32].*,
        .fee_recipient = bytes[32..52].*,
        .state_root = bytes[52..84].*,
        .receipts_root = bytes[84..116].*,
        .logs_bloom = bytes[116..372].*,
        .prev_randao = bytes[372..404].*,
        .block_number = try ssz.readU64(bytes[404..412]),
        .gas_limit = try ssz.readU64(bytes[412..420]),
        .gas_used = try ssz.readU64(bytes[420..428]),
        .timestamp = try ssz.readU64(bytes[428..436]),
        .extra_data = extra_data,
        .base_fee_per_gas = bytes[440..472].*,
        .block_hash = bytes[472..504].*,
        .transactions = try decodeBoundedByteListList(allocator, bytes[transactions_offset..transactions_end], max_transactions_per_payload, max_bytes_per_transaction),
    };
}

fn validatePayloadOffsets(bytes_len: usize, fixed_len: usize, offsets: []const usize) Error!void {
    var previous = fixed_len;
    for (offsets, 0..) |offset, index| {
        if (index == 0 and offset != fixed_len) return error.InvalidFirstOffset;
        if (offset < previous) return error.OffsetsAreNotMonotonic;
        if (offset > bytes_len) return error.OffsetOutOfBounds;
        previous = offset;
    }
}

fn encodeFixedStructList(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime item_len: usize,
    items: []const T,
) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, item_len * items.len);
    errdefer allocator.free(out);
    for (items, 0..) |item, i| item.encodeInto(out[i * item_len ..][0..item_len]);
    return out;
}

fn prefixedFixedStructListBytes(
    allocator: std.mem.Allocator,
    prefix: u8,
    comptime T: type,
    comptime item_len: usize,
    items: []const T,
) Error![]u8 {
    const out = try allocator.alloc(u8, 1 + item_len * items.len);
    errdefer allocator.free(out);
    out[0] = prefix;
    for (items, 0..) |item, i| item.encodeInto(out[1 + i * item_len ..][0..item_len]);
    return out;
}

fn decodeBoundedFixedStructList(
    allocator: std.mem.Allocator,
    comptime T: type,
    comptime item_len: usize,
    bytes: []const u8,
    max_items: usize,
) Error![]const T {
    try validateBoundedFixedStructList(item_len, bytes, max_items);
    const count = bytes.len / item_len;
    const out = try allocator.alloc(T, count);
    for (out, 0..) |*item, i| item.* = try T.decode(bytes[i * item_len ..][0..item_len]);
    return out;
}

fn validateBoundedFixedStructList(comptime item_len: usize, bytes: []const u8, max_items: usize) Error!void {
    if (bytes.len % item_len != 0) return error.InvalidListLength;
    if (bytes.len / item_len > max_items) return error.InvalidListLength;
}

fn fixedStructListRoot(allocator: std.mem.Allocator, comptime T: type, items: []const T, max_items: usize) Error![32]u8 {
    if (items.len > max_items) return error.InvalidListLength;
    const roots = try allocator.alloc([32]u8, items.len);
    defer allocator.free(roots);
    for (roots, items) |*root, item| root.* = try item.hashTreeRoot(allocator);
    return ssz.listRootLimit(allocator, roots, max_items);
}

fn decodeHashList(allocator: std.mem.Allocator, bytes: []const u8) Error![]const [32]u8 {
    if (bytes.len % 32 != 0) return error.InvalidListLength;
    const out = try allocator.alloc([32]u8, bytes.len / 32);
    for (out, 0..) |*item, i| item.* = bytes[i * 32 ..][0..32].*;
    return out;
}

fn decodePublicKeys(allocator: std.mem.Allocator, bytes: []const u8) Error![]const [public_key_bytes]u8 {
    try ssz.validateFixedList(bytes, public_key_bytes);
    const count = bytes.len / public_key_bytes;
    if (count > max_public_keys) return error.InvalidListLength;
    const out = try allocator.alloc([public_key_bytes]u8, count);
    for (out, 0..) |*item, index| {
        item.* = bytes[index * public_key_bytes ..][0..public_key_bytes].*;
    }
    return out;
}

fn encodeBoundedByteListList(
    allocator: std.mem.Allocator,
    items: []const []const u8,
    max_items: usize,
    max_item_bytes: usize,
) Error![]u8 {
    if (items.len > max_items) return error.InvalidListLength;
    for (items) |item| {
        if (item.len > max_item_bytes) return error.InvalidListLength;
    }
    return ssz.encodeByteListList(allocator, items);
}

fn decodeBoundedByteListList(
    allocator: std.mem.Allocator,
    bytes: []const u8,
    max_items: usize,
    max_item_bytes: usize,
) Error![]const []const u8 {
    if (bytes.len == 0) return allocator.alloc([]const u8, 0);
    if (bytes.len < ssz.bytes_per_length_offset) return error.InvalidByteLength;
    const first_offset = readOffset(bytes[0..ssz.bytes_per_length_offset]);
    if (first_offset == 0 or first_offset % ssz.bytes_per_length_offset != 0) return error.InvalidFirstOffset;
    const count = first_offset / ssz.bytes_per_length_offset;
    if (count > max_items) return error.InvalidListLength;

    const items = try ssz.decodeByteListList(allocator, bytes);
    for (items) |item| {
        if (item.len > max_item_bytes) return error.InvalidListLength;
    }
    return items;
}

fn hashListRoot(allocator: std.mem.Allocator, hashes: []const [32]u8) Error![32]u8 {
    return ssz.listRootLimit(allocator, hashes, max_blob_commitments_per_block);
}

fn encodeOptionalU64List(allocator: std.mem.Allocator, value: ?u64) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, if (value == null) 0 else 8);
    if (value) |actual| std.mem.writeInt(u64, out[0..8], actual, .little);
    return out;
}

fn decodeOptionalU64List(bytes: []const u8) Error!?u64 {
    return switch (bytes.len) {
        0 => null,
        8 => try ssz.readU64(bytes),
        else => error.InvalidListLength,
    };
}

fn encodeBlobScheduleList(allocator: std.mem.Allocator, value: ?BlobSchedule) std.mem.Allocator.Error![]u8 {
    const out = try allocator.alloc(u8, if (value == null) 0 else 24);
    if (value) |actual| actual.encodeInto(out[0..24]);
    return out;
}

fn decodeBlobScheduleList(bytes: []const u8) Error!?BlobSchedule {
    return switch (bytes.len) {
        0 => null,
        24 => try BlobSchedule.decode(bytes),
        else => error.InvalidListLength,
    };
}

fn readOffset(bytes: []const u8) usize {
    return std.mem.readInt(u32, bytes[0..4], .little);
}

fn sszUint256FromBytes(bytes: [32]u8) u256 {
    return std.mem.readInt(u256, &bytes, .little);
}

fn evmWordFromBytes32(bytes: [32]u8) u256 {
    return uint256.fromBytes32(&bytes);
}
