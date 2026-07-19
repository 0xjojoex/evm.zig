const Interpreter = @import("../Interpreter.zig");
const std = @import("std");
const evmz = @import("../evm.zig");
const uint256 = @import("../uint256.zig");

const CallFrame = Interpreter.CallFrame;

pub fn add(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result = a +% b;

    frame.stack.pushUnchecked(result);
}

pub fn mul(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result = a *% b;

    frame.stack.pushUnchecked(result);
}

pub fn sub(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    const result = a -% b;

    frame.stack.pushUnchecked(result);
}

pub fn div(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(uint256.div(a, b));
}

pub fn sdiv(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);

    frame.stack.pushUnchecked(uint256.sdiv(a, b));
}

pub fn mod(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(uint256.mod(a, b));
}

pub fn smod(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);
    frame.stack.pushUnchecked(uint256.smod(a, b));
}

pub fn addmod(frame: *CallFrame) !void {
    const a, const b, const c = try frame.stack.popN(3);
    frame.stack.pushUnchecked(uint256.addMod(a, b, c));
}

pub fn mulmod(frame: *CallFrame) !void {
    const a, const b, const c = try frame.stack.popN(3);
    frame.stack.pushUnchecked(uint256.mulMod(a, b, c));
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        inline fn frameRevision(frame: *const CallFrame) Protocol.Revision {
            return Interpreter.For(Protocol).revision(frame);
        }

        pub fn exp(frame: *CallFrame) !void {
            const a, const exponent = try frame.stack.popN(2);

            const exponent_byte_size = countSignificantBytesSize(exponent);
            frame.trackGas(Protocol.Instruction.expByteGas(Self.frameRevision(frame)) * exponent_byte_size);

            const result = wrapExp(a, exponent);
            frame.stack.pushUnchecked(result);
        }
    };
}

pub fn signextend(frame: *CallFrame) !void {
    const a, const b = try frame.stack.popN(2);

    var val = b;
    if (a < 32) {
        const sign_bit: u8 = @as(u8, @intCast(a)) * 8 + 7;
        const mask = std.math.shl(u256, 1, sign_bit) - 1;
        if (((b >> sign_bit) & 1) != 0) {
            val = b | ~mask;
        } else {
            val = b & mask;
        }
    }

    frame.stack.pushUnchecked(val);
}

pub fn keccak256(frame: *CallFrame) !void {
    const offset_word, const size_word = try frame.stack.popN(2);
    const size = frame.wordToUsizeOrOog(size_word) orelse return;
    const offset = frame.memoryOffsetToUsizeOrOog(offset_word, size) orelse return;

    if (!try frame.expandMemory(offset, size)) return;
    const min_word_size = (size + 31) / 32;
    const gas_for_word: i64 = @intCast(6 * min_word_size);
    frame.trackGas(gas_for_word);
    if (frame.status != .running) return;

    const value = frame.memory.readBytes(offset, size);

    const result = if (value.len == 0) evmz.crypto.keccak256_empty else evmz.crypto.keccak256(value);

    const final_result = evmz.uint256.fromBytes32(&result);
    frame.stack.pushUnchecked(final_result);
}

test "DIV and SDIV with one operand fail as invalid instructions" {
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x01, .DIV }, .invalid);
    try evmz.t.expectLatestForkBytecodeStatus(.{ .PUSH1, 0x01, .SDIV }, .invalid);
}

test "DIV and SDIV by zero push zero" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH1, 0x02, .DIV }, 0);
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH1, 0x02, .SDIV }, 0);
}

test "KECCAK256 of empty input returns the empty hash" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{ .PUSH0, .PUSH0, .KECCAK256 }, evmz.uint256.fromBytes32(&evmz.crypto.keccak256_empty));
}

pub inline fn wrapExp(a: u256, expo: u256) u256 {
    if (expo == 0) return 1;
    if (a == 0) return 0;
    if (a == 1) return 1;
    if (a == 2) {
        if (expo >= 256) return 0;
        return std.math.shl(u256, 1, @as(u16, @intCast(expo)));
    }

    const trailing_zero_bits: u16 = @intCast(@ctz(a));
    if (trailing_zero_bits != 0) {
        const zero_threshold = std.math.divCeil(u16, 256, trailing_zero_bits) catch unreachable;
        if (expo >= zero_threshold) return 0;
    }

    var value = a;
    var exponent = expo;
    var result: u256 = 1;
    while (exponent > 0) : (exponent >>= 1) {
        if ((exponent & 1) == 1) {
            result *%= value;
        }
        value *%= value;
    }

    return result;
}

test wrapExp {
    try std.testing.expectEqual(@as(u256, 1), wrapExp(0, 0));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(0, 3));
    try std.testing.expectEqual(@as(u256, 1), wrapExp(1, std.math.maxInt(u256)));
    try std.testing.expectEqual(wrapExp(2, 2), 4);
    try std.testing.expectEqual(@as(u256, 1) << 255, wrapExp(2, 255));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(2, 256));
    try std.testing.expectEqual(@as(u256, 0), wrapExp(4, 128));

    const a = 2;
    const exponent = 0xFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFFF;
    const result = wrapExp(a, exponent);
    try std.testing.expectEqual(@as(u256, 0), result);
}

test "EXP byte gas comes from comptime protocol" {
    const CheapExpProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const Instruction = struct {
            pub fn expByteGas(revision: evmz.eth.Revision) i64 {
                _ = revision;
                return 1;
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.EXP)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.ExecutionProtocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .spurious_dragon,
    });
    defer frame.deinit();

    try frame.frame.stack.push(0x0100);
    try frame.frame.stack.push(2);

    try For(CheapExpProtocol).exp(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_998), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

/// Returns how many bytes are needed to represent the significant part of a 256-bit integer.
pub inline fn countSignificantBytesSize(value: u256) i64 {
    return @divFloor(256 - @as(i64, @intCast(@clz(value))) + 7, 8);
}

test countSignificantBytesSize {
    try std.testing.expectEqual(countSignificantBytesSize(0), 0);
    try std.testing.expectEqual(countSignificantBytesSize(1), 1);
    try std.testing.expectEqual(countSignificantBytesSize(255), 1);
    try std.testing.expectEqual(countSignificantBytesSize(256), 2);
    try std.testing.expectEqual(countSignificantBytesSize(1000), 2);
    try std.testing.expectEqual(countSignificantBytesSize(std.math.maxInt(u256)), 32);
}
