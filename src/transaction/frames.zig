//! EIP-8141 frame transactions (type 0x06): frame and signature shapes, the
//! canonical signature hash, static validity, the gas and fee plan, protocol
//! signature validation, and settlement.
//!
//! Everything here is pure. It reads the transaction, the including block's
//! fees, and the spec's `Params`, never state. Running frames belongs to the
//! Ethereum transition (`transition.zig`); approval context, frame receipts,
//! and state-gas ownership belong to the executor's frame journal
//! (`executor/frame_journal.zig`).

const std = @import("std");
const rlp = @import("rlp");

const Address = @import("../address.zig").Address;
const crypto = @import("../crypto.zig");
const LogBuffer = @import("../state/LogBuffer.zig");
const precompile_backend = @import("../precompile/backend.zig");
const uint256 = @import("../uint256.zig");
const blob = @import("blob.zig");
const tx = @import("types.zig");
const type_id = @import("type_id.zig");
const validation = @import("validation.zig");

const ValidationError = validation.ValidationError;

/// Frame-transaction parameters an exact spec supplies.
pub const Params = struct {
    /// FRAME_TX_INTRINSIC_COST.
    intrinsic_gas: u64,
    /// FRAME_TX_PER_FRAME_COST.
    per_frame_gas: u64,
    /// TX_VALUE_COST, charged per frame carrying value to another account.
    value_transfer_gas: u64,
    /// Verification cost per signature scheme.
    arbitrary_signature_gas: u64,
    secp256k1_signature_gas: u64,
    p256_signature_gas: u64,
    /// STANDARD_TOKEN_COST for frame data and signature bytes.
    standard_token_gas: u64,
    /// TOTAL_COST_FLOOR_PER_TOKEN of the calldata floor (EIP-7976).
    floor_token_gas: u64,
    /// MAX_FRAMES.
    max_frames: u8,
    /// TX_MAX_GAS_LIMIT bounding intrinsic plus frame execution gas, and the
    /// calldata floor (EIP-7825).
    max_execution_gas: u64,
    /// State gas APPROVE charges when it creates the sender account.
    sender_account_state_gas: u64,
    /// ENTRY_POINT, the caller of DEFAULT and VERIFY frames.
    entry_point: Address,
    /// EXPIRY_VERIFIER, whose VERIFY frames are constrained statically.
    expiry_verifier: Address,
    /// EXPIRY_DATA_LENGTH.
    expiry_data_len: usize,
};

pub const Mode = enum(u8) {
    /// Execute as ENTRY_POINT.
    default = 0,
    /// Validate the transaction; runs static and may APPROVE.
    verify = 1,
    /// Execute as the sender, after execution approval.
    sender = 2,
    // Later EIPs extend the set (EIP-7906 ASSERT); unknown modes are invalid.
    _,

    pub fn known(self: Mode) bool {
        return switch (self) {
            .default, .verify, .sender => true,
            _ => false,
        };
    }
};

/// APPROVE scope bits, also the low two bits of `Flags`.
pub const scope = struct {
    pub const payment: u2 = 0x1;
    pub const execution: u2 = 0x2;
};

pub const Flags = packed struct(u8) {
    approve_payment: bool = false,
    approve_execution: bool = false,
    /// ATOMIC_BATCH_FLAG: batched with the following frame.
    atomic_batch: bool = false,
    reserved: u5 = 0,

    /// The approval scope the frame allows (`flags & APPROVE_SCOPE_MASK`).
    pub fn allowedScope(self: Flags) u2 {
        return @truncate(@as(u8, @bitCast(self)));
    }
};

pub const Limits = struct {
    execution: u64 = 0,
    state: u64 = 0,
};

pub const Frame = struct {
    mode: Mode = .default,
    flags: Flags = .{},
    target: ?Address = null,
    limits: Limits = .{},
    value: u256 = 0,
    data: []const u8 = &.{},

    pub fn resolvedTarget(self: Frame, sender: Address) Address {
        return self.target orelse sender;
    }
};

pub const Signature = struct {
    pub const Scheme = enum(u8) {
        arbitrary = 0,
        secp256k1 = 1,
        p256 = 2,
        _,
    };

    scheme: Scheme,
    signer: ?Address = null,
    /// Null signs the canonical signature hash; an explicit digest otherwise.
    msg: ?[32]u8 = null,
    signature: []const u8 = &.{},

    /// The protocol-resolved signer; ARBITRARY entries have none.
    pub fn resolvedSigner(self: Signature, sender: Address) ?Address {
        return switch (self.scheme) {
            .secp256k1, .p256 => self.signer orelse sender,
            else => null,
        };
    }
};

pub const Status = enum(u8) {
    failure = 0,
    success = 1,
    /// Not executed: an earlier frame of its atomic batch failed.
    skipped = 2,
};

pub const Receipt = struct {
    status: Status = .skipped,
    execution_gas_used: u64 = 0,
    /// Final attributed state gas; later frames' refills and rollbacks move it.
    state_gas_used: u64 = 0,
    /// The frame's logs in the transaction log buffer.
    log_range: LogBuffer.RowRange = .{},
};

/// Gas and fee plan resolved before any frame runs.
pub const Plan = struct {
    intrinsic_gas: u64,
    calldata_floor_gas: u64,
    /// Intrinsic gas plus every frame's execution and state limits.
    standard_gas_limit: u64,
    max_gas: u64,
    /// Worst-case block execution-dimension use.
    execution_reservation: u64,
    /// Worst-case block state-dimension use: the sum of frame state limits.
    state_reservation: u64,
    blob_gas: u64,
    base_fee: u256,
    blob_base_fee: u256,
    max_priority_fee_per_gas: u256,
    /// What APPROVE collects from the payer, after checking its balance. A
    /// rollup may widen it between `prepare` and `transactPrepared`; the payer
    /// gets back whatever settlement does not charge.
    max_cost: u256,
    /// GASPRICE in every frame: `base_fee + max_priority_fee // max_gas`.
    gas_price: u256,
};

/// A planned frame transaction awaiting `transactPrepared`.
pub const Prepared = struct {
    transaction: tx.Transaction,
    plan: Plan,
};

pub const PlanResult = union(enum) {
    rejected: ValidationError,
    planned: Plan,
};

/// Check every static constraint and price the transaction against the
/// including block. `progress` is the block's use before this transaction.
pub fn plan(
    comptime params: Params,
    comptime blob_schedule: ?blob.BlobSchedule,
    transaction: tx.Transaction,
    env: tx.Env,
    progress: tx.PreparationBlockProgress,
) PlanResult {
    return planChecked(params, blob_schedule, transaction, env, progress) catch |err| switch (err) {
        error.Overflow => .{ .rejected = .type_6_invalid_frame_format },
    };
}

fn planChecked(
    comptime params: Params,
    comptime blob_schedule: ?blob.BlobSchedule,
    transaction: tx.Transaction,
    env: tx.Env,
    progress: tx.PreparationBlockProgress,
) error{Overflow}!PlanResult {
    if (validation.classifyTransactionNonce(transaction.nonce) == .at_or_above_limit)
        return .{ .rejected = .nonce_is_max };
    if (transaction.frames.len == 0 or transaction.frames.len > params.max_frames)
        return .{ .rejected = .type_6_invalid_frame_format };

    var blob_gas: u64 = 0;
    if (transaction.blob_hashes.len != 0) {
        const schedule = blob_schedule orelse return .{ .rejected = .type_3_tx_blob_count_exceeded };
        if (transaction.blob_hashes.len > schedule.max_per_transaction)
            return .{ .rejected = .type_3_tx_blob_count_exceeded };
        for (transaction.blob_hashes) |hash| {
            if (blob.blobVersion(hash) != schedule.hash_version)
                return .{ .rejected = .type_3_tx_invalid_blob_versioned_hash };
        }
        blob_gas = try std.math.mul(u64, transaction.blob_hashes.len, schedule.gas_per_blob);
    }
    return planFrames(params, transaction, env, progress, blob_gas);
}

fn planFrames(
    comptime params: Params,
    transaction: tx.Transaction,
    env: tx.Env,
    progress: tx.PreparationBlockProgress,
    blob_gas: u64,
) error{Overflow}!PlanResult {
    const add = std.math.add;
    const mul = std.math.mul;
    const sender = transaction.sender;
    const frames = transaction.frames;

    var total_execution: u64 = 0;
    var total_state: u64 = 0;
    var data_cost: u64 = 0;
    var floor_tokens: u64 = 0;
    var value_cost: u64 = 0;
    var expiry_frames: usize = 0;
    for (frames, 0..) |frame, index| {
        if (!frame.mode.known() or frame.flags.reserved != 0)
            return .{ .rejected = .type_6_invalid_frame_format };
        if (frame.mode != .sender and frame.value != 0)
            return .{ .rejected = .type_6_invalid_frame_format };
        if (frame.flags.approve_execution and !frame.resolvedTarget(sender).eql(sender))
            return .{ .rejected = .type_6_invalid_frame_format };
        if (frame.flags.atomic_batch and (frame.mode == .verify or index + 1 == frames.len or
            frames[index + 1].mode == .verify))
            return .{ .rejected = .type_6_invalid_frame_format };
        const in_batch = frame.flags.atomic_batch or (index > 0 and frames[index - 1].flags.atomic_batch);
        if (in_batch and frame.flags.allowedScope() != 0)
            return .{ .rejected = .type_6_invalid_frame_format };
        if (frame.mode == .verify and frame.target != null and
            frame.target.?.eql(params.expiry_verifier))
        {
            expiry_frames += 1;
            if (@as(u8, @bitCast(frame.flags)) != 0 or frame.limits.state != 0 or
                frame.data.len != params.expiry_data_len)
                return .{ .rejected = .type_6_invalid_frame_format };
        }

        total_execution = try add(u64, total_execution, frame.limits.execution);
        total_state = try add(u64, total_state, frame.limits.state);
        // total_frame_gas < 2**64
        _ = try add(u64, total_execution, total_state);
        data_cost = try add(u64, data_cost, try standardCost(params, frame.data));
        floor_tokens = try add(u64, floor_tokens, try floorTokens(frame.data.len));
        if (frame.value != 0 and frame.target != null and !frame.target.?.eql(sender))
            value_cost = try add(u64, value_cost, params.value_transfer_gas);
    }
    if (expiry_frames > 1) return .{ .rejected = .type_6_invalid_frame_format };

    var signature_gas: u64 = 0;
    for (transaction.signatures) |signature| {
        switch (signature.scheme) {
            .arbitrary => if (signature.signer != null) return .{ .rejected = .type_6_invalid_signature },
            .secp256k1, .p256 => {},
            _ => return .{ .rejected = .type_6_invalid_signature },
        }
        if (signature.msg) |digest| {
            if (std.mem.allEqual(u8, &digest, 0)) return .{ .rejected = .type_6_invalid_signature };
        }
        signature_gas = try add(u64, signature_gas, switch (signature.scheme) {
            .arbitrary => params.arbitrary_signature_gas,
            .secp256k1 => params.secp256k1_signature_gas,
            .p256 => params.p256_signature_gas,
            _ => unreachable,
        });
        const signer_len: usize = if (signature.signer != null) Address.len else 0;
        const msg_len: usize = if (signature.msg != null) 32 else 0;
        // Raw bytes elided from the signature hash are priced as if all
        // non-zero, so intrinsic gas follows from the hash's committed length.
        const signature_bytes_cost = if (signature.msg == null)
            try mul(u64, try floorTokens(signature.signature.len), params.standard_token_gas)
        else
            try standardCost(params, signature.signature);
        if (signature.signer) |signer| data_cost = try add(u64, data_cost, try standardCost(params, &signer.bytes));
        if (signature.msg) |digest| data_cost = try add(u64, data_cost, try standardCost(params, &digest));
        data_cost = try add(u64, data_cost, signature_bytes_cost);
        floor_tokens = try add(u64, floor_tokens, try floorTokens(signer_len));
        floor_tokens = try add(u64, floor_tokens, try floorTokens(msg_len));
        floor_tokens = try add(u64, floor_tokens, try floorTokens(signature.signature.len));
    }

    const base = try add(u64, params.intrinsic_gas, try mul(u64, frames.len, params.per_frame_gas));
    const fixed = try add(u64, try add(u64, base, signature_gas), value_cost);
    const intrinsic_gas = try add(u64, fixed, data_cost);
    const calldata_floor_gas = try add(u64, fixed, try mul(u64, floor_tokens, params.floor_token_gas));
    const execution_reservation = @max(try add(u64, intrinsic_gas, total_execution), calldata_floor_gas);
    if (execution_reservation > params.max_execution_gas)
        return .{ .rejected = .gas_limit_exceeds_maximum };
    const standard_gas_limit = try add(u64, try add(u64, intrinsic_gas, total_execution), total_state);
    const max_gas = @max(standard_gas_limit, try add(u64, calldata_floor_gas, total_state));

    if (env.gas_limit != 0) {
        const used = progress.block_gas;
        if (used.regular > env.gas_limit or execution_reservation > env.gas_limit - used.regular or
            used.state > env.gas_limit or total_state > env.gas_limit - used.state)
            return .{ .rejected = .gas_allowance_exceeded };
    }

    const required_max_fee = std.math.add(
        u256,
        uint256.checkedMul(max_gas, env.base_fee) orelse return .{ .rejected = .insufficient_max_fee_per_gas },
        uint256.checkedMul(blob_gas, env.blob_base_fee) orelse return .{ .rejected = .insufficient_max_fee_per_gas },
    ) catch return .{ .rejected = .insufficient_max_fee_per_gas };
    if (transaction.max_fee < required_max_fee) return .{ .rejected = .insufficient_max_fee_per_gas };
    const max_priority_fee_per_gas = transaction.max_priority_fee_per_gas orelse 0;
    const max_priority_fee = @min(
        uint256.checkedMul(max_priority_fee_per_gas, max_gas) orelse std.math.maxInt(u256),
        transaction.max_fee - required_max_fee,
    );
    return .{ .planned = .{
        .intrinsic_gas = intrinsic_gas,
        .calldata_floor_gas = calldata_floor_gas,
        .standard_gas_limit = standard_gas_limit,
        .max_gas = max_gas,
        .execution_reservation = execution_reservation,
        .state_reservation = total_state,
        .blob_gas = blob_gas,
        .base_fee = env.base_fee,
        .blob_base_fee = env.blob_base_fee,
        .max_priority_fee_per_gas = max_priority_fee_per_gas,
        .max_cost = required_max_fee + max_priority_fee,
        .gas_price = env.base_fee + max_priority_fee / max_gas,
    } };
}

/// STANDARD_TOKEN_COST per token, with a zero byte one token and any other
/// byte four.
fn standardCost(comptime params: Params, bytes: []const u8) error{Overflow}!u64 {
    var tokens: u64 = bytes.len;
    for (bytes) |byte| {
        if (byte != 0) tokens += 3;
    }
    return std.math.mul(u64, tokens, params.standard_token_gas);
}

/// `floor_tokens_in`: every byte counts four tokens.
fn floorTokens(len: usize) error{Overflow}!u64 {
    return std.math.mul(u64, len, 4);
}

/// Amounts a completed frame transaction settles.
pub const Settlement = struct {
    gas_used_before_refund: u64,
    applied_refund: u64,
    /// Net state gas: the sum of frame receipts' final state gas.
    state_gas: u64,
    /// Charged execution gas, after the refund and the calldata floor.
    execution_gas: u64,
    /// Receipt and payer gas: `execution_gas + state_gas`.
    gas_used: u64,
    /// Block execution-dimension gas: before the refund (EIP-7778).
    block_execution_gas: u64,
    /// Burned.
    base_fee_paid: u256,
    /// Credited to the fee recipient.
    priority_fee_paid: u256,
    /// Returned to the payer out of `Plan.max_cost`.
    payer_refund: u256,
};

/// Settle against the frame receipts once every frame and atomic rollback has
/// finished. `refund_counter` is the transaction's EIP-3529 storage refund.
pub fn settle(
    gas_plan: Plan,
    frames: []const Frame,
    receipts: []const Receipt,
    refund_counter: u64,
    refund_quotient: u64,
) Settlement {
    std.debug.assert(frames.len == receipts.len);
    var unused: u64 = 0;
    var state_gas: u64 = 0;
    for (frames, receipts) |frame, receipt| {
        std.debug.assert(receipt.execution_gas_used <= frame.limits.execution);
        std.debug.assert(receipt.state_gas_used <= frame.limits.state);
        unused += frame.limits.execution - receipt.execution_gas_used;
        unused += frame.limits.state - receipt.state_gas_used;
        state_gas += receipt.state_gas_used;
    }
    const before_refund = gas_plan.standard_gas_limit - unused;
    const applied_refund = @min(refund_counter, before_refund / refund_quotient);
    const after_refund = before_refund - applied_refund;
    std.debug.assert(state_gas <= after_refund);
    const execution_gas = @max(after_refund - state_gas, gas_plan.calldata_floor_gas);
    const gas_used = execution_gas + state_gas;
    std.debug.assert(gas_used <= gas_plan.max_gas);
    const base_fee_paid = @as(u256, gas_used) * gas_plan.base_fee +
        @as(u256, gas_plan.blob_gas) * gas_plan.blob_base_fee;
    std.debug.assert(base_fee_paid <= gas_plan.max_cost);
    const priority_fee_paid = @min(
        uint256.checkedMul(gas_plan.max_priority_fee_per_gas, gas_used) orelse std.math.maxInt(u256),
        gas_plan.max_cost - base_fee_paid,
    );
    return .{
        .gas_used_before_refund = before_refund,
        .applied_refund = applied_refund,
        .state_gas = state_gas,
        .execution_gas = execution_gas,
        .gas_used = gas_used,
        .block_execution_gas = @max(before_refund - state_gas, gas_plan.calldata_floor_gas),
        .base_fee_paid = base_fee_paid,
        .priority_fee_paid = priority_fee_paid,
        .payer_refund = gas_plan.max_cost - base_fee_paid - priority_fee_paid,
    };
}

/// The default code's VERIFY rule: the signature the allowed scope selects
/// must be a SECP256K1 entry over the signature hash whose signer is the
/// frame's resolved target. Signatures were validated before any frame ran.
pub fn defaultCodeApproves(transaction: tx.Transaction, target: Address, allowed: u2) bool {
    if (allowed == 0) return false;
    const index: usize = if (allowed & scope.execution != 0) 0 else 1;
    if (index >= transaction.signatures.len) return false;
    const signature = transaction.signatures[index];
    return signature.scheme == .secp256k1 and signature.msg == null and
        signature.resolvedSigner(transaction.sender).?.eql(target);
}

/// Validate every protocol signature against `sig_hash`. ARBITRARY entries
/// are left to EVM code.
pub fn signaturesValid(transaction: tx.Transaction, sig_hash: [32]u8) bool {
    for (transaction.signatures) |signature| {
        const digest = signature.msg orelse sig_hash;
        const signer = signature.resolvedSigner(transaction.sender);
        const valid = switch (signature.scheme) {
            .arbitrary => true,
            .secp256k1 => secp256k1Valid(signature.signature, signer.?, digest),
            .p256 => p256Valid(signature.signature, signer.?, digest),
            _ => false,
        };
        if (!valid) return false;
    }
    return true;
}

const secp256k1_n: u256 = 0xfffffffffffffffffffffffffffffffebaaedce6af48a03bbfd25e8cd0364141;
const secp256r1_n: u256 = 0xffffffff00000000ffffffffffffffffbce6faada7179e84f3b9cac2fc632551;

fn secp256k1Valid(bytes: []const u8, signer: Address, digest: [32]u8) bool {
    if (bytes.len != 65) return false;
    const v = bytes[0];
    const r = bytes[1..33].*;
    const s = bytes[33..65].*;
    const r_value = std.mem.readInt(u256, &r, .big);
    const s_value = std.mem.readInt(u256, &s, .big);
    if (v > 1 or r_value == 0 or r_value >= secp256k1_n or s_value == 0 or s_value > secp256k1_n / 2)
        return false;
    const public_key = crypto.ecrecoverPublicKey(digest, r, s, v) orelse return false;
    return Address.fromPublicKey(public_key).eql(signer);
}

fn p256Valid(bytes: []const u8, signer: Address, digest: [32]u8) bool {
    if (bytes.len != 128) return false;
    const r_value = std.mem.readInt(u256, bytes[0..32], .big);
    const s_value = std.mem.readInt(u256, bytes[32..64], .big);
    if (r_value == 0 or r_value >= secp256r1_n or s_value == 0 or s_value > secp256r1_n / 2)
        return false;
    const key_hash = crypto.keccak256(bytes[64..128]);
    if (!Address.fromBytes(key_hash[12..32].*).eql(signer)) return false;
    var input: [160]u8 = undefined;
    @memcpy(input[0..32], &digest);
    @memcpy(input[32..160], bytes);
    return precompile_backend.p256Verify(&input);
}

/// Canonical signature hash: the type-0x06 envelope with every empty-`msg`
/// signature's raw bytes replaced by their byte length.
pub fn signatureHash(allocator: std.mem.Allocator, transaction: tx.Transaction) ![32]u8 {
    const encoded = try encodeEnvelope(allocator, transaction, .signing);
    defer allocator.free(encoded);
    return crypto.keccak256(encoded);
}

/// The type-0x06 envelope bytes of `transaction`.
pub fn encode(allocator: std.mem.Allocator, transaction: tx.Transaction) ![]u8 {
    return encodeEnvelope(allocator, transaction, .full);
}

const Projection = enum { full, signing };

const Encoding = struct {
    transaction: *const tx.Transaction,
    projection: Projection,
};

fn encodeEnvelope(
    allocator: std.mem.Allocator,
    transaction: tx.Transaction,
    projection: Projection,
) ![]u8 {
    const value: Encoding = .{ .transaction = &transaction, .projection = projection };
    const payload_len = try rlp.encodedListLen(emitTransaction, value);
    const out = try allocator.alloc(u8, payload_len + 1);
    errdefer allocator.free(out);
    out[0] = type_id.frame;
    _ = try rlp.encodeList(emitTransaction, out[1..], value);
    return out;
}

fn emitTransaction(fields: anytype, value: Encoding) rlp.EncodeError!void {
    const transaction = value.transaction;
    try fields.encode(u256, transaction.chain_id orelse 0);
    try fields.encode(u256, transaction.nonce orelse 0);
    try fields.encode(Address, transaction.sender);
    try fields.list(emitFrames, value);
    try fields.list(emitSignatures, value);
    try fields.list(emitFees, value);
    try fields.list(emitBlobHashes, value);
}

fn emitFrames(fields: anytype, value: Encoding) rlp.EncodeError!void {
    for (value.transaction.frames) |frame| try fields.list(emitFrame, frame);
}

fn emitFrame(fields: anytype, frame: Frame) rlp.EncodeError!void {
    try fields.encode(u8, @backingInt(frame.mode));
    try fields.encode(u8, @bitCast(frame.flags));
    try fields.encode(?Address, frame.target);
    try fields.encode(Limits, frame.limits);
    try fields.encode(u256, frame.value);
    try fields.encode([]const u8, frame.data);
}

const SignatureEncoding = struct {
    signature: Signature,
    projection: Projection,
};

fn emitSignatures(fields: anytype, value: Encoding) rlp.EncodeError!void {
    for (value.transaction.signatures) |signature|
        try fields.list(emitSignature, SignatureEncoding{ .signature = signature, .projection = value.projection });
}

fn emitSignature(fields: anytype, value: SignatureEncoding) rlp.EncodeError!void {
    const signature = value.signature;
    try fields.encode(u8, @backingInt(signature.scheme));
    try fields.encode(?Address, signature.signer);
    try fields.encode(?[32]u8, signature.msg);
    if (value.projection == .signing and signature.msg == null)
        try fields.encode(u64, signature.signature.len)
    else
        try fields.encode([]const u8, signature.signature);
}

fn emitFees(fields: anytype, value: Encoding) rlp.EncodeError!void {
    try fields.encode(u256, value.transaction.max_fee);
    try fields.encode(u256, value.transaction.max_priority_fee_per_gas orelse 0);
}

fn emitBlobHashes(fields: anytype, value: Encoding) rlp.EncodeError!void {
    for (value.transaction.blob_hashes) |hash| try fields.encode([32]u8, uint256.toBytes32(hash));
}

test "signature hash commits to elided signature lengths, not their bytes" {
    const allocator = std.testing.allocator;
    const digest: [32]u8 = @splat(1);
    var transaction: tx.Transaction = .{
        .kind = .frame,
        .sender = Address.fromBytes(@splat(0xaa)),
        .chain_id = 1,
        .nonce = 0,
        .gas_limit = 0,
        .frames = &.{.{ .limits = .{ .execution = 1 } }},
        .signatures = &.{
            .{ .scheme = .arbitrary, .signature = &.{ 1, 2, 3 } },
            .{ .scheme = .arbitrary, .msg = digest, .signature = &.{4} },
        },
    };
    const base = try signatureHash(allocator, transaction);

    // Same length, different elided bytes: same hash.
    transaction.signatures = &.{
        .{ .scheme = .arbitrary, .signature = &.{ 9, 9, 9 } },
        .{ .scheme = .arbitrary, .msg = digest, .signature = &.{4} },
    };
    try std.testing.expectEqual(base, try signatureHash(allocator, transaction));

    // A different elided length, or different bytes under an explicit msg,
    // change the hash.
    transaction.signatures = &.{
        .{ .scheme = .arbitrary, .signature = &.{ 9, 9 } },
        .{ .scheme = .arbitrary, .msg = digest, .signature = &.{4} },
    };
    try std.testing.expect(!std.mem.eql(u8, &base, &try signatureHash(allocator, transaction)));
    transaction.signatures = &.{
        .{ .scheme = .arbitrary, .signature = &.{ 1, 2, 3 } },
        .{ .scheme = .arbitrary, .msg = digest, .signature = &.{5} },
    };
    try std.testing.expect(!std.mem.eql(u8, &base, &try signatureHash(allocator, transaction)));
}

test "type-0x06 envelopes round-trip through the raw decoder" {
    const allocator = std.testing.allocator;
    const raw = @import("raw.zig");
    const sender = Address.fromBytes(@splat(0xaa));
    const frame_list = [_]Frame{
        .{ .mode = .verify, .flags = .{ .approve_payment = true, .approve_execution = true }, .limits = .{ .execution = 50_000 } },
        .{
            .mode = .sender,
            .flags = .{ .atomic_batch = true },
            .target = Address.fromBytes(@splat(0xbb)),
            .limits = .{ .execution = 30_000, .state = 1_000 },
            .value = 9,
            .data = &.{ 0xde, 0xad },
        },
        .{ .mode = .default, .target = Address.fromBytes(@splat(0xcc)), .limits = .{ .execution = 1 } },
    };
    const signatures = [_]Signature{
        .{ .scheme = .secp256k1, .signature = &@as([65]u8, @splat(1)) },
        .{ .scheme = .arbitrary, .msg = @splat(2), .signature = &.{ 3, 4 } },
    };
    const blob_hashes = [_]u256{(@as(u256, 1) << 248) | 7};
    const transaction: tx.Transaction = .{
        .kind = .frame,
        .sender = sender,
        .chain_id = 0x1234,
        .nonce = 7,
        .gas_limit = 0,
        .frames = &frame_list,
        .signatures = &signatures,
        .max_fee = 1_000_000,
        .max_priority_fee_per_gas = 2,
        .blob_hashes = &blob_hashes,
    };
    const encoded = try encode(allocator, transaction);
    defer allocator.free(encoded);
    var decoded = try raw.decodeRaw(allocator, encoded);
    defer decoded.deinit(allocator);

    const got = decoded.tx;
    try std.testing.expectEqual(tx.TxKind.frame, got.kind);
    try std.testing.expect(got.sender.eql(sender));
    try std.testing.expectEqual(transaction.chain_id, got.chain_id);
    try std.testing.expectEqual(transaction.nonce, got.nonce);
    try std.testing.expectEqual(transaction.max_fee, got.max_fee);
    try std.testing.expectEqual(transaction.max_priority_fee_per_gas, got.max_priority_fee_per_gas);
    try std.testing.expectEqualDeep(transaction.frames, got.frames);
    try std.testing.expectEqualDeep(transaction.signatures, got.signatures);
    try std.testing.expectEqualSlices(u256, &blob_hashes, got.blob_hashes);
    // Re-encoding the decoded value reproduces the envelope.
    const reencoded = try encode(allocator, got);
    defer allocator.free(reencoded);
    try std.testing.expectEqualSlices(u8, encoded, reencoded);
}
