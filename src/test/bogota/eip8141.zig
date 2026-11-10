//! EIP-8141 frame transactions through the Ethereum transition, pinned to
//! Bogotá: frames exist only there.

const std = @import("std");
const evmz = @import("../../evm.zig");
const support = @import("../vm_support.zig");

const Address = evmz.Address;
const MemoryStore = evmz.state.MemoryStore;
const addr = evmz.addr;
const eip8037 = evmz.eth.eip8037;
const eip8141 = evmz.eth.eip8141;
const frames = evmz.transaction.frames;

/// SSTORE(0, CALLDATALOAD(0)).
const store_calldata_code = evmz.t.bytecode(.{ .PUSH0, .CALLDATALOAD, .PUSH0, .SSTORE, .STOP });
const revert_code = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .REVERT });
const store_contract = addr(0xc0de);
const reverter = addr(0xdead);
const coinbase = addr(0xc01b);
const secret: [32]u8 = @splat(0x42);
const one_word: [32]u8 = word: {
    var word: [32]u8 = @splat(0);
    word[31] = 1;
    break :word word;
};

fn Harness(comptime Bogota: type) type {
    return struct {
        const Self = @This();

        memory: MemoryStore,
        executor: Bogota.Executor,
        secp: evmz.crypto.secp256k1.Context,
        sender: Address,

        fn init(self: *Self, sender_balance: ?u256) !void {
            const allocator = std.testing.allocator;
            self.memory = MemoryStore.init(allocator);
            self.secp = try .init(allocator, @splat(7));
            self.sender = Address.fromPublicKey(try self.secp.publicKey(secret));
            if (sender_balance) |balance|
                try evmz.t.seedStoreAccount(&self.memory, self.sender, .{ .balance = balance });
            try evmz.t.seedStoreAccount(&self.memory, store_contract, .{ .code = &store_calldata_code });
            try evmz.t.seedStoreAccount(&self.memory, reverter, .{ .code = &revert_code });
            self.executor = .init(allocator, .{ .state = .{ .reader = self.memory.reader() } });
        }

        fn deinit(self: *Self) void {
            self.executor.deinit();
            self.secp.deinit();
            self.memory.deinit();
        }

        /// Sign `transaction` with one SECP256K1 signature over its signature
        /// hash, so the default code's VERIFY frame approves the sender.
        fn transact(self: *Self, transaction: evmz.transaction.Transaction, block: evmz.Env) !Bogota.Outcome {
            var signed = transaction;
            const placeholder = [_]frames.Signature{.{ .scheme = .secp256k1, .signature = &@as([65]u8, @splat(0)) }};
            signed.signatures = &placeholder;
            const sig_hash = try frames.signatureHash(std.testing.allocator, signed);
            const signature = try self.secp.sign(sig_hash, secret);
            var bytes: [65]u8 = undefined;
            bytes[0] = signature.recovery_id;
            @memcpy(bytes[1..], &signature.rs);
            const signatures = [_]frames.Signature{.{ .scheme = .secp256k1, .signature = &bytes }};
            signed.signatures = &signatures;
            return support.transact(Bogota, &self.executor, .{ .env = block, .tx = signed });
        }
    };
}

fn frameTx(sender: Address, frame_list: []const frames.Frame) evmz.transaction.Transaction {
    return .{
        .kind = .frame,
        .sender = sender,
        .chain_id = 1,
        .nonce = 0,
        .nonce_keys = &.{},
        .gas_limit = 0,
        .frames = frame_list,
        .max_fee = 10_000_000_000,
        .max_priority_fee_per_gas = 2,
    };
}

const self_verify: frames.Frame = .{
    .mode = .verify,
    .flags = .{ .approve_payment = true, .approve_execution = true },
    .limits = .{ .execution = 50_000, .state = 0 },
};

fn senderFrame(target: Address, data: []const u8, limits: frames.Limits, atomic: bool) frames.Frame {
    return .{
        .mode = .sender,
        .flags = .{ .atomic_batch = atomic },
        .target = target,
        .limits = limits,
        .data = data,
    };
}

const env: evmz.Env = .{ .gas_limit = 30_000_000, .base_fee = 7, .coinbase = coinbase };

test "self-relayed frame transaction approves, executes, and settles from the payer" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();

    const frame_list = [_]frames.Frame{
        self_verify,
        senderFrame(store_contract, &one_word, .{ .execution = 100_000, .state = 200_000 }, false),
    };
    const result = try support.expectExecuted(try h.transact(frameTx(h.sender, &frame_list), env));
    const frame = result.frame.?;
    try std.testing.expect(frame.payer.eql(h.sender));
    try std.testing.expectEqual(frames.Status.success, frame.receipts[0].status);
    try std.testing.expectEqual(frames.Status.success, frame.receipts[1].status);
    // Only the SSTORE that creates the slot draws state gas.
    try std.testing.expectEqual(@as(u64, 0), frame.receipts[0].state_gas_used);
    try std.testing.expectEqual(eip8037.storage_set_state_gas, frame.receipts[1].state_gas_used);

    // gas_used = max(intrinsic + execution, calldata floor) + state gas, with
    // the intrinsic and floor derived from the EIP's own terms.
    // The empty-msg signature's 65 bytes are priced as non-zero (4 tokens
    // each); the frame data has 31 zero bytes and one non-zero byte; and the
    // EIP-8250 nonce calldata, `rlp([]) || rlp(0)` = `c0 80`, two non-zero.
    const signature_tokens: u64 = 65 * 4;
    const data_tokens: u64 = 31 + 4 + 2 * 4;
    const data_floor_tokens: u64 = (32 + 2) * 4;
    const fixed = eip8141.intrinsic_cost + 2 * eip8141.per_frame_cost + eip8141.secp256k1_signature_cost;
    const intrinsic = fixed + (signature_tokens + data_tokens) * evmz.eth.eip7623.standard_token_cost;
    const floor = fixed + (signature_tokens + data_floor_tokens) * evmz.eth.eip7976.total_cost_floor_per_token;
    const execution = frame.receipts[0].execution_gas_used + frame.receipts[1].execution_gas_used;
    const expected_gas = @max(intrinsic + execution, floor) + eip8037.storage_set_state_gas;
    try std.testing.expectEqual(expected_gas, result.gas.used);
    try std.testing.expectEqual(expected_gas, frame.settlement.gas_used);

    // The payer paid exactly base fee plus capped tip; the tip reached the
    // coinbase, and the sender nonce advanced once.
    const paid = frame.settlement.base_fee_paid + frame.settlement.priority_fee_paid;
    try std.testing.expectEqual(@as(u256, expected_gas) * 7, frame.settlement.base_fee_paid);
    try std.testing.expectEqual(@as(u256, expected_gas) * 2, frame.settlement.priority_fee_paid);
    try std.testing.expectEqual(1_000_000_000 - paid, try h.executor.getBalance(h.sender));
    try std.testing.expectEqual(frame.settlement.priority_fee_paid, try h.executor.getBalance(coinbase));
    try std.testing.expectEqual(@as(u64, 1), (try h.executor.getAccount(h.sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 1), try h.executor.getStorage(store_contract, 0));
}

test "a state-gas charge beyond the frame pool is out of gas, not a spill" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();

    const limits: frames.Limits = .{ .execution = 100_000, .state = eip8037.storage_set_state_gas - 1 };
    const frame_list = [_]frames.Frame{ self_verify, senderFrame(store_contract, &one_word, limits, false) };
    const result = try support.expectExecuted(try h.transact(frameTx(h.sender, &frame_list), env));
    const receipt = result.frame.?.receipts[1];
    try std.testing.expectEqual(frames.Status.failure, receipt.status);
    // Ordinary out-of-gas: the frame's whole execution budget is consumed.
    try std.testing.expectEqual(limits.execution, receipt.execution_gas_used);
    try std.testing.expectEqual(@as(u64, 0), receipt.state_gas_used);
    try std.testing.expectEqual(@as(u256, 0), try h.executor.getStorage(store_contract, 0));
}

test "a later frame's refill returns state gas to the frame that paid for the slot" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();

    const limits: frames.Limits = .{ .execution = 100_000, .state = 200_000 };
    const frame_list = [_]frames.Frame{
        self_verify,
        senderFrame(store_contract, &one_word, limits, false),
        // Empty calldata loads zero and clears the slot set by frame 1.
        senderFrame(store_contract, &.{}, limits, false),
    };
    const result = try support.expectExecuted(try h.transact(frameTx(h.sender, &frame_list), env));
    const receipts = result.frame.?.receipts;
    try std.testing.expectEqual(frames.Status.success, receipts[2].status);
    try std.testing.expectEqual(@as(u64, 0), receipts[1].state_gas_used);
    try std.testing.expectEqual(@as(u64, 0), receipts[2].state_gas_used);
    try std.testing.expectEqual(@as(u64, 0), result.frame.?.settlement.state_gas);
}

test "a failing frame unrolls its atomic batch and skips the rest of it" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();

    const limits: frames.Limits = .{ .execution = 100_000, .state = 200_000 };
    const frame_list = [_]frames.Frame{
        self_verify,
        senderFrame(store_contract, &one_word, limits, true),
        senderFrame(reverter, &.{}, limits, true),
        senderFrame(store_contract, &one_word, limits, false),
    };
    const result = try support.expectExecuted(try h.transact(frameTx(h.sender, &frame_list), env));
    const receipts = result.frame.?.receipts;
    try std.testing.expectEqual(frames.Status.success, receipts[1].status);
    try std.testing.expect(receipts[1].execution_gas_used > 0);
    try std.testing.expectEqual(@as(u64, 0), receipts[1].state_gas_used);
    try std.testing.expectEqual(frames.Status.failure, receipts[2].status);
    try std.testing.expectEqual(frames.Status.skipped, receipts[3].status);
    try std.testing.expectEqual(@as(u64, 0), receipts[3].execution_gas_used);
    try std.testing.expectEqual(@as(u256, 0), try h.executor.getStorage(store_contract, 0));
}

test "approval creates a missing sender only from the frame's state pool" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    const free: evmz.Env = .{ .gas_limit = 30_000_000, .coinbase = coinbase };
    var short = self_verify;
    short.limits.state = eip8037.new_account_state_gas - 1;
    var enough = self_verify;
    enough.limits.state = eip8037.new_account_state_gas;
    {
        var h: Harness(Bogota) = undefined;
        try h.init(null);
        defer h.deinit();
        var transaction = frameTx(h.sender, &.{short});
        transaction.max_fee = 0;
        try std.testing.expectEqual(
            evmz.transaction.validation.ValidationError.type_6_invalid_frame_execution,
            try support.expectRejected(try h.transact(transaction, free)),
        );
    }
    var h: Harness(Bogota) = undefined;
    try h.init(null);
    defer h.deinit();
    var transaction = frameTx(h.sender, &.{enough});
    transaction.max_fee = 0;
    const result = try support.expectExecuted(try h.transact(transaction, free));
    try std.testing.expectEqual(eip8037.new_account_state_gas, result.frame.?.receipts[0].state_gas_used);
    try std.testing.expectEqual(@as(u64, 1), (try h.executor.getAccount(h.sender)).?.nonce);
}

test "frame transactions without approval are invalid" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();
    const ValidationError = evmz.transaction.validation.ValidationError;
    const limits: frames.Limits = .{ .execution = 100_000, .state = 0 };

    try std.testing.expectEqual(ValidationError.type_6_invalid_frame_execution, try support.expectRejected(
        try h.transact(frameTx(h.sender, &.{senderFrame(store_contract, &.{}, limits, false)}), env),
    ));
    const default_only = [_]frames.Frame{.{ .target = store_contract, .limits = limits }};
    try std.testing.expectEqual(ValidationError.type_6_invalid_frame_execution, try support.expectRejected(
        try h.transact(frameTx(h.sender, &default_only), env),
    ));
    try std.testing.expect(!h.executor.acceptedChanges().hasChanges());
}

/// `keccak256(left_pad_32(sender) || be32(key))`, the EIP-8250 slot formula.
fn keyedSlot(sender: Address, key: u256) u256 {
    var preimage: [64]u8 = @splat(0);
    @memcpy(preimage[12..32], &sender.bytes);
    std.mem.writeInt(u256, preimage[32..64], key, .big);
    return std.mem.readInt(u256, &evmz.crypto.keccak256(&preimage), .big);
}

test "keyed nonces advance their slots on approval and leave the account nonce" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    const ValidationError = evmz.transaction.validation.ValidationError;
    const eip8250 = evmz.eth.eip8250;
    var h: Harness(Bogota) = undefined;
    try h.init(1_000_000_000);
    defer h.deinit();

    var verify = self_verify;
    verify.limits.state = 2 * eip8250.keyed_nonce_first_use_state_gas;
    const keys = [_]u256{ 3, 1 << 200 };
    var transaction = frameTx(h.sender, &.{verify});
    transaction.nonce_keys = &keys;
    // A fresh key holds sequence 0.
    transaction.nonce = 0;
    const result = try support.expectExecuted(try h.transact(transaction, env));
    // Both slots were fresh, so approval charged two first uses to the frame.
    try std.testing.expectEqual(verify.limits.state, result.frame.?.receipts[0].state_gas_used);
    for (keys) |key|
        try std.testing.expectEqual(@as(u256, 1), try h.executor.getStorage(eip8250.nonce_manager, keyedSlot(h.sender, key)));
    try std.testing.expectEqual(@as(u64, 0), (try h.executor.getAccount(h.sender)).?.nonce);

    // Replaying the sequence is too low; an unsorted key set is malformed.
    try std.testing.expectEqual(ValidationError.nonce_too_low, try support.expectRejected(try h.transact(transaction, env)));
    const unsorted = [_]u256{ 1 << 200, 3 };
    transaction.nonce_keys = &unsorted;
    transaction.nonce = 1;
    try std.testing.expectEqual(ValidationError.type_6_invalid_frame_format, try support.expectRejected(try h.transact(transaction, env)));

    // A used key is no longer free for the single-use sequence; a fresh one
    // is exhausted by it, and only it pays first-use state gas.
    transaction.nonce = frames.max_nonce_seq;
    transaction.nonce_keys = keys[0..1];
    try std.testing.expectEqual(ValidationError.nonce_too_low, try support.expectRejected(try h.transact(transaction, env)));
    const fresh = [_]u256{7};
    transaction.nonce_keys = &fresh;
    const single = try support.expectExecuted(try h.transact(transaction, env));
    try std.testing.expectEqual(eip8250.keyed_nonce_first_use_state_gas, single.frame.?.receipts[0].state_gas_used);
    try std.testing.expectEqual(@as(u256, frames.max_nonce_seq), try h.executor.getStorage(eip8250.nonce_manager, keyedSlot(h.sender, 7)));
}

test "forks before Bogotá reject frame transactions" {
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var executor = Amsterdam.Executor.init(std.testing.allocator, .{ .state = .{ .reader = memory.reader() } });
    defer executor.deinit();
    try std.testing.expectEqual(
        evmz.transaction.validation.ValidationError.type_6_tx_pre_fork,
        try support.expectRejected(try support.transact(Amsterdam, &executor, .{
            .env = env,
            .tx = frameTx(addr(1), &.{self_verify}),
        })),
    );
}
