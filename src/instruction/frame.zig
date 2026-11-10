//! EIP-8141 frame opcodes: APPROVE and the frame-transaction introspection
//! opcodes. They read the running frame transaction through
//! `TransactionEnvironment.frame_transaction`; in any other transaction each
//! one halts exceptionally.

const std = @import("std");

const Interpreter = @import("../Interpreter.zig");
const frames = @import("../transaction/frames.zig");
const type_id = @import("../transaction/type_id.zig");
const uint256 = @import("../uint256.zig");
const instruction_table = @import("table.zig");

const CallFrame = Interpreter.CallFrame;

/// Install the frame opcodes on `instruction`, the exact spec of a fork that
/// activates frame transactions.
pub fn install(instruction: *instruction_table.Spec) void {
    @setEvalBranchQuota(100_000);
    instruction.install(.APPROVE, 0xaa, .{ .stack_in = 3 }, .{ .custom = Approve });
    instruction.install(.TXPARAM, 0xb0, .{ .static_gas = 2, .stack_in = 1 }, .{ .custom = TxParam });
    instruction.install(.FRAMEDATALOAD, 0xb1, .{ .static_gas = 3, .stack_in = 2 }, .{ .custom = FrameDataLoad });
    instruction.install(.FRAMEDATACOPY, 0xb2, .{ .static_gas = 3, .stack_in = 4 }, .{ .custom = FrameDataCopy });
    instruction.install(.FRAMEPARAM, 0xb3, .{ .static_gas = 2, .stack_in = 2 }, .{ .custom = FrameParam });
    instruction.install(.SIGPARAM, 0xb4, .{ .static_gas = 2, .stack_in = 2 }, .{ .custom = SigParam });
    instruction.install(.SIGDATACOPY, 0xb5, .{ .static_gas = 3, .stack_in = 4 }, .{ .custom = SigDataCopy });
}

/// The running frame transaction, or null after halting the frame outside one.
inline fn frameTransaction(call_frame: *CallFrame) ?*const frames.Context {
    return call_frame.execution_context.transaction.frame_transaction orelse {
        call_frame.halt(.invalid_opcode);
        return null;
    };
}

/// The index operand as an in-bounds index into `len` entries, or null after
/// halting the frame.
inline fn index(call_frame: *CallFrame, word: u256, len: usize) ?usize {
    if (word >= len) {
        call_frame.halt(.invalid_opcode);
        return null;
    }
    return @intCast(word);
}

/// Exit with the memory range as output and apply the approval, or revert
/// when it is refused. Charges only memory expansion; its writes bypass the
/// VERIFY frame's static restriction.
const Approve = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const offset_word = call_frame.pop() orelse return;
        const length_word = call_frame.pop() orelse return;
        const approval = call_frame.pop() orelse return;
        const length = call_frame.wordToUsizeOrOog(length_word) orelse return;
        const offset = call_frame.memoryOffsetToUsizeOrOog(offset_word, length) orelse return;
        if (!try call_frame.expandMemory(offset, length)) return;
        const context = frameTransaction(call_frame) orelse return;
        const frame_index = call_frame.execution_context.transaction.frame_index.?;
        const target = context.transaction.frames[frame_index].resolvedTarget(context.transaction.sender);
        if (!call_frame.msg.recipient.eql(target)) return call_frame.halt(.revert);
        const state_gas_left: u64 = @intCast(@max(call_frame.gas_reservoir, 0));
        switch (try call_frame.host.frameApprove(approval, state_gas_left)) {
            .reverted => call_frame.halt(.revert),
            .out_of_gas => call_frame.halt(.out_of_gas),
            .approved => |state_gas| {
                // Within the pool, which never spills, so the charge succeeds.
                const charged = call_frame.trackStateGas(@intCast(state_gas));
                std.debug.assert(charged);
                call_frame.setOutputRange(offset, length);
                call_frame.halt(.success);
            },
        }
    }
};

const TxParam = struct {
    pub inline fn execute(comptime spec: anytype, call_frame: *CallFrame) anyerror!void {
        const keyed_nonces = spec.transaction.frame.?.keyed_nonces;
        const param = call_frame.pop() orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const transaction = context.transaction;
        const keys = transaction.nonce_keys orelse &.{};
        const value: u256 = switch (param) {
            0x00 => type_id.frame,
            0x01 => transaction.nonce orelse 0,
            0x02 => transaction.sender.toU256(),
            0x03 => transaction.max_priority_fee_per_gas orelse 0,
            0x04 => transaction.max_fee,
            0x07 => transaction.blob_hashes.len,
            0x08 => uint256.fromBytes32(&context.signature_hash),
            0x09 => transaction.frames.len,
            0x0a => call_frame.execution_context.transaction.frame_index.?,
            0x0b => transaction.signatures.len,
            0x0c => @intCast(@max(call_frame.gas_reservoir, 0)),
            0x0d...0x10 => if (comptime keyed_nonces) |keyed| switch (param) {
                // EIP-8250.
                0x0d => context.legacy_nonce,
                0x0e => keys.len,
                0x0f => uint256.fromBytes32(&frames.nonceKeysHash(keyed.max_keys, keys)),
                else => if (keys.len == 0) 0 else keys[0],
            } else return call_frame.halt(.invalid_opcode),
            else => return call_frame.halt(.invalid_opcode),
        };
        _ = call_frame.push(value);
    }
};

/// CALLDATALOAD of a frame's data.
const FrameDataLoad = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const offset_word = call_frame.pop() orelse return;
        const frame_word = call_frame.pop() orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const frame_index = index(call_frame, frame_word, context.transaction.frames.len) orelse return;
        const data = context.transaction.frames[frame_index].data;
        var buffer: [32]u8 = @splat(0);
        const source = sourceFromOffset(data, offset_word);
        const available = @min(buffer.len, source.len);
        @memcpy(buffer[0..available], source[0..available]);
        _ = call_frame.push(uint256.fromBytes32(&buffer));
    }
};

/// CALLDATACOPY of a frame's data.
const FrameDataCopy = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const operands = try copyOperands(call_frame) orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const frame_index = index(call_frame, operands.index, context.transaction.frames.len) orelse return;
        operands.copy(call_frame, context.transaction.frames[frame_index].data);
    }
};

const FrameParam = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const frame_word = call_frame.pop() orelse return;
        const param = call_frame.pop() orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const transaction = context.transaction;
        const frame_index = index(call_frame, frame_word, transaction.frames.len) orelse return;
        const frame = transaction.frames[frame_index];
        // Status and gas used exist only for completed frames.
        const completed = frame_index < call_frame.execution_context.transaction.frame_index.?;
        const receipt = context.receipts[frame_index];
        const value: u256 = switch (param) {
            0x00 => frame.resolvedTarget(transaction.sender).toU256(),
            0x01 => frame.limits.execution,
            0x02 => @backingInt(frame.mode),
            0x03 => @as(u8, @bitCast(frame.flags)),
            0x04 => frame.data.len,
            0x05 => if (completed) @backingInt(receipt.status) else return call_frame.halt(.invalid_opcode),
            0x06 => frame.flags.allowedScope(),
            0x07 => @intFromBool(frame.flags.atomic_batch),
            0x08 => frame.value,
            0x09 => frame.limits.state,
            0x0a => if (completed) receipt.execution_gas_used else return call_frame.halt(.invalid_opcode),
            0x0b => if (completed) receipt.state_gas_used else return call_frame.halt(.invalid_opcode),
            else => return call_frame.halt(.invalid_opcode),
        };
        _ = call_frame.push(value);
    }
};

/// Signature metadata; each scheme family withholds what the protocol does
/// not define for it.
const SigParam = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const signature_word = call_frame.pop() orelse return;
        const param = call_frame.pop() orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const transaction = context.transaction;
        const signature_index = index(call_frame, signature_word, transaction.signatures.len) orelse return;
        const signature = transaction.signatures[signature_index];
        const value: u256 = switch (param) {
            0x00 => (signature.resolvedSigner(transaction.sender) orelse
                return call_frame.halt(.invalid_opcode)).toU256(),
            0x01 => @backingInt(signature.scheme),
            0x02 => if (signature.msg) |msg| uint256.fromBytes32(&msg) else 0,
            0x03 => if (signature.scheme == .arbitrary)
                signature.signature.len
            else
                return call_frame.halt(.invalid_opcode),
            else => return call_frame.halt(.invalid_opcode),
        };
        _ = call_frame.push(value);
    }
};

/// CALLDATACOPY of an ARBITRARY signature's raw bytes.
const SigDataCopy = struct {
    pub inline fn execute(comptime _: anytype, call_frame: *CallFrame) anyerror!void {
        const operands = try copyOperands(call_frame) orelse return;
        const context = frameTransaction(call_frame) orelse return;
        const signatures = context.transaction.signatures;
        const signature_index = index(call_frame, operands.index, signatures.len) orelse return;
        const signature = signatures[signature_index];
        if (signature.scheme != .arbitrary) return call_frame.halt(.invalid_opcode);
        operands.copy(call_frame, signature.signature);
    }
};

/// A data copy whose gas — copy words and memory expansion — is already
/// charged, as CALLDATACOPY charges it before reading its source.
const CopyOperands = struct {
    memory_offset: usize,
    data_offset: u256,
    length: usize,
    index: u256,

    fn copy(self: CopyOperands, call_frame: *CallFrame, data: []const u8) void {
        call_frame.memory.writePaddedBytes(self.memory_offset, self.length, sourceFromOffset(data, self.data_offset));
    }
};

fn copyOperands(call_frame: *CallFrame) !?CopyOperands {
    const memory_offset_word = call_frame.pop() orelse return null;
    const data_offset = call_frame.pop() orelse return null;
    const length_word = call_frame.pop() orelse return null;
    const index_word = call_frame.pop() orelse return null;
    const length = call_frame.wordToUsizeOrOog(length_word) orelse return null;
    const memory_offset = call_frame.memoryOffsetToUsizeOrOog(memory_offset_word, length) orelse return null;
    const words = std.math.divCeil(usize, length, 32) catch unreachable;
    const copy_gas = std.math.cast(i64, words * 3) orelse {
        call_frame.halt(.out_of_gas);
        return null;
    };
    if (!call_frame.trackGas(copy_gas)) return null;
    if (!try call_frame.expandMemory(memory_offset, length)) return null;
    return .{ .memory_offset = memory_offset, .data_offset = data_offset, .length = length, .index = index_word };
}

fn sourceFromOffset(data: []const u8, offset_word: u256) []const u8 {
    const offset = std.math.cast(usize, offset_word) orelse return &.{};
    return if (offset < data.len) data[offset..] else &.{};
}
