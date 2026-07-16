const std = @import("std");
const Interpreter = @import("../Interpreter.zig");
const evmz = @import("../evm.zig");
const CallFrame = Interpreter.CallFrame;
const Host = evmz.Host;
const AccountAccessStatus = evmz.protocol.AccountAccessStatus;

fn trackCopyGas(frame: *CallFrame, size: usize) bool {
    const size_i64 = std.math.cast(i64, size) orelse {
        frame.failWithStatus(.out_of_gas);
        return false;
    };
    frame.trackGas(evmz.calcWordSize(i64, size_i64) * 3);
    return frame.status == .running;
}

fn sourceFromOffset(source: []const u8, offset_word: u256) []const u8 {
    const offset = std.math.cast(usize, offset_word) orelse return &.{};
    if (offset >= source.len) return &.{};
    return source[offset..];
}

fn accountAccessStatus(status: Host.AccessStatus) AccountAccessStatus {
    return switch (status) {
        .cold => .cold,
        .warm => .warm,
    };
}

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        inline fn frameRevision(frame: *const CallFrame) Protocol.Revision {
            return Interpreter.For(Protocol).revision(frame);
        }

        fn trackCodeAccountAccessGas(frame: *CallFrame, target_address: evmz.Address) !bool {
            if (Protocol.Instruction.codeAccountAccessGas(Self.frameRevision(frame), .warm) == null) return true;
            const access_status = accountAccessStatus(try frame.host.accessAccount(target_address));
            const access_gas = Protocol.Instruction.codeAccountAccessGas(Self.frameRevision(frame), access_status) orelse 0;
            frame.trackGas(access_gas);
            return frame.status == .running;
        }

        pub fn balance(frame: *CallFrame) !void {
            const target_address_word = try frame.stack.pop();
            const target_address = evmz.address.fromWord(target_address_word);
            if (Protocol.Instruction.accountReadColdAccessGas(Self.frameRevision(frame))) |cold_access_gas| {
                if (try frame.host.accessAccount(target_address) == .cold) {
                    frame.trackGas(cold_access_gas);
                    if (frame.status != .running) return;
                }
            }
            try frame.traceAccountAccess(target_address);
            const address_balance = try frame.host.getBalance(target_address);
            frame.stack.pushUnchecked(address_balance);
        }

        pub fn extcodesize(frame: *CallFrame) !void {
            const target_address_word = try frame.stack.pop();
            const target_address = evmz.address.fromWord(target_address_word);
            if (!try Self.trackCodeAccountAccessGas(frame, target_address)) return;
            try frame.traceAccountAccess(target_address);
            const size = try frame.host.getCodeSize(target_address);
            frame.stack.pushUnchecked(size);
        }

        pub fn extcodecopy(frame: *CallFrame) !void {
            const address_word, const dest_offset_word, const offset_word, const size_word = try frame.stack.popN(4);
            const target_address = evmz.address.fromWord(address_word);
            const size = frame.wordToUsizeOrOog(size_word) orelse return;
            const dest_offset = frame.memoryOffsetToUsizeOrOog(dest_offset_word, size) orelse return;

            if (!try Self.trackCodeAccountAccessGas(frame, target_address)) return;

            if (!try frame.expandMemory(dest_offset, size)) return;
            if (!trackCopyGas(frame, size)) return;
            try frame.traceAccountAccess(target_address);

            const dest = frame.memory.writeSlice(dest_offset, size);
            var copied: usize = 0;
            if (std.math.cast(usize, offset_word)) |offset| {
                copied = @min(try frame.host.copyCode(target_address, offset, dest), dest.len);
            }
            if (copied < dest.len) {
                @memset(dest[copied..], 0);
            }
        }

        pub fn extcodehash(frame: *CallFrame) !void {
            const address_word = try frame.stack.pop();
            const target_address = evmz.address.fromWord(address_word);
            if (Protocol.Instruction.accountReadColdAccessGas(Self.frameRevision(frame))) |cold_access_gas| {
                if (try frame.host.accessAccount(target_address) == .cold) {
                    frame.trackGas(cold_access_gas);
                    if (frame.status != .running) return;
                }
            }
            try frame.traceAccountAccess(target_address);
            const code_hash = try frame.host.getCodeHash(target_address);
            frame.stack.pushUnchecked(code_hash);
        }
    };
}

pub fn gas(frame: *CallFrame) !void {
    const g: u64 = @intCast(frame.gas_left);
    const gas_left = @as(u256, g);
    try frame.stack.push(gas_left);
}

pub fn address(frame: *CallFrame) !void {
    try frame.stack.push(evmz.address.toU256(frame.msg.recipient));
}

pub fn caller(frame: *CallFrame) !void {
    try frame.stack.push(evmz.address.toU256(frame.msg.sender));
}

pub fn origin(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(evmz.address.toU256(tx_context.origin));
}

pub fn gasprice(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.gas_price);
}

pub fn basefee(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.base_fee);
}

pub fn coinbase(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(evmz.address.toU256(tx_context.coinbase));
}

pub fn timestamp(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.timestamp);
}

pub fn number(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.number);
}

pub fn slotnum(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.slot_number);
}

pub fn prevrandao(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.prev_randao);
}

pub fn gaslimit(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.gas_limit);
}

pub fn chainid(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.chain_id);
}

pub fn blockhash(frame: *CallFrame) !void {
    const block_number: u256 = try frame.stack.pop();

    const tx_context = try frame.host.getTxContext();
    const current_number: u256 = tx_context.number;
    const oldest_hashable = if (current_number > 256) current_number - 256 else 0;

    if (block_number < current_number and block_number >= oldest_hashable) {
        const block_hash = try frame.host.getBlockHash(block_number);
        frame.stack.pushUnchecked(block_hash);
    } else {
        frame.stack.pushUnchecked(0);
    }
}

pub fn callvalue(frame: *CallFrame) !void {
    try frame.stack.push(frame.msg.value);
}

pub fn calldataload(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    var buffer: [32]u8 = [_]u8{0} ** 32;

    const source = sourceFromOffset(frame.msg.input_data, offset);
    const available = @min(buffer.len, source.len);
    @memcpy(buffer[0..available], source[0..available]);

    frame.stack.pushUnchecked(evmz.uint256.fromBytes32(&buffer));
}

pub fn calldatasize(frame: *CallFrame) !void {
    try frame.stack.push(frame.msg.input_data.len);
}

pub fn calldatacopy(frame: *CallFrame) !void {
    const dest_offset_word, const offset_word, const size_word = try frame.stack.popN(3);
    const size = frame.wordToUsizeOrOog(size_word) orelse return;
    const dest_offset = frame.memoryOffsetToUsizeOrOog(dest_offset_word, size) orelse return;

    if (!try frame.expandMemory(dest_offset, size)) return;
    if (!trackCopyGas(frame, size)) return;

    const source = sourceFromOffset(frame.msg.input_data, offset_word);
    frame.memory.writePaddedBytes(dest_offset, size, source);
}

pub fn codesize(frame: *CallFrame) !void {
    try frame.stack.push(frame.code.len);
}

pub fn codecopy(frame: *CallFrame) !void {
    const dest_offset_word, const offset_word, const size_word = try frame.stack.popN(3);
    const size = frame.wordToUsizeOrOog(size_word) orelse return;
    const dest_offset = frame.memoryOffsetToUsizeOrOog(dest_offset_word, size) orelse return;

    if (!try frame.expandMemory(dest_offset, size)) return;
    if (!trackCopyGas(frame, size)) return;

    const source = sourceFromOffset(frame.code, offset_word);
    frame.memory.writePaddedBytes(dest_offset, size, source);
}

pub fn selfbalance(frame: *CallFrame) !void {
    const address_balance = try frame.host.getBalance(frame.msg.recipient);
    try frame.stack.push(address_balance);
}

test "BALANCE cold account access gas comes from comptime protocol" {
    const CustomProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const Instruction = struct {
            pub fn accountReadColdAccessGas(revision: evmz.eth.Revision) ?i64 {
                _ = revision;
                return 7;
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.BALANCE)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .frontier,
    });
    defer frame.deinit();

    try frame.frame.stack.push(evmz.address.toU256(evmz.addr(2)));
    try For(CustomProtocol).balance(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_993), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "EXTCODESIZE account access gas comes from comptime protocol" {
    const CustomProtocol = struct {
        pub const Revision = evmz.eth.Revision;

        pub const Instruction = struct {
            pub fn codeAccountAccessGas(revision: evmz.eth.Revision, status: AccountAccessStatus) ?i64 {
                _ = revision;
                return switch (status) {
                    .cold => 9,
                    .warm => 4,
                };
            }
        };
    };

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.EXTCODESIZE)};

    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = &code,
        .revision = .frontier,
    });
    defer frame.deinit();

    try frame.frame.stack.push(evmz.address.toU256(evmz.addr(2)));
    try For(CustomProtocol).extcodesize(frame.frame);

    try std.testing.expectEqual(Interpreter.FrameStatus.running, frame.frame.status);
    try std.testing.expectEqual(@as(i64, 99_991), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "EXTCODECOPY writes directly and zero pads missing code bytes" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var target_code = [_]u8{ 0xaa, 0xbb, 0xcc };
    try mock_host.code.put(evmz.addr(2), &target_code);
    var host = mock_host.host();
    const msg = evmz.Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 100_000,
        .kind = evmz.Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const bytecode = &.{
        0x60, 0x04, // size
        0x60, 0x01, // code offset
        0x60, 0x00, // memory offset
        0x60, 0x02, // address
        0x3c, // EXTCODECOPY
    };

    var frame = try evmz.interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = bytecode,
        .revision = .cancun,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &.{ 0xbb, 0xcc, 0x00, 0x00 }, interpreter.call_frame.memory.readBytes(0, 4));
}

pub fn returndatasize(frame: *CallFrame) !void {
    try frame.stack.push(frame.return_data.len);
}

pub fn returndatacopy(frame: *CallFrame) !void {
    const dest_offset_word, const offset_word, const size_word = try frame.stack.popN(3);
    const size = frame.wordToUsizeOrOog(size_word) orelse return;
    const dest_offset = frame.memoryOffsetToUsizeOrOog(dest_offset_word, size) orelse return;

    if (!try frame.expandMemory(dest_offset, size)) return;
    if (!trackCopyGas(frame, size)) return;

    const offset = std.math.cast(usize, offset_word) orelse {
        frame.failWithStatus(.invalid);
        return;
    };
    if (offset > frame.return_data.len or size > frame.return_data.len - offset) {
        frame.failWithStatus(.invalid);
        return;
    }
    frame.memory.writeBytes(dest_offset, frame.return_data[offset .. offset + size]);
}

pub fn blobhash(frame: *CallFrame) !void {
    const index_word = try frame.stack.pop();
    const tx_context = try frame.host.getTxContext();
    const index = std.math.cast(usize, index_word) orelse {
        frame.stack.pushUnchecked(0);
        return;
    };

    if (index >= tx_context.blob_hashes.len) {
        frame.stack.pushUnchecked(0);
        return;
    }
    frame.stack.pushUnchecked(tx_context.blob_hashes[index]);
}

pub fn blobbasefee(frame: *CallFrame) !void {
    const tx_context = try frame.host.getTxContext();
    try frame.stack.push(tx_context.blob_base_fee);
}

test "CALLDATALOAD with oversized source offset returns zero" {
    try evmz.t.expectLatestForkBytecodeStackTop(.{
        .PUSH32,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        0xff,
        .CALLDATALOAD,
    }, 0);
}
