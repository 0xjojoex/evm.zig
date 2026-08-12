const std = @import("std");
const Interpreter = @import("../Interpreter.zig");
const evmz = @import("../evm.zig");
const ExactSpec = @import("../spec.zig").Spec;
const CallFrame = Interpreter.CallFrame;
const Host = evmz.Host;

pub const AccountValue = enum {
    balance,
    code_size,
    code_hash,
};

pub fn Enviroment(comptime spec: ExactSpec) type {
    const exact_instructions = spec.instruction;
    return struct {
        pub fn trackCodeAccountAccessGas(frame: *CallFrame, target_address: evmz.AddressWord) !bool {
            if (exact_instructions.codeAccountAccessGas(.warm) == null) return true;
            const access_status = try frame.host.accessAccount(target_address);
            const access_gas = exact_instructions.codeAccountAccessGas(access_status) orelse 0;
            return frame.trackGas(access_gas);
        }

        pub fn readAccountValue(frame: *CallFrame, target_address: evmz.AddressWord, comptime value: AccountValue) !?u256 {
            const access_gas = switch (value) {
                .balance, .code_hash => blk: {
                    const cold_gas = exact_instructions.account_read_cold_access_gas orelse break :blk 0;
                    break :blk if (try frame.host.accessAccount(target_address) == .cold) cold_gas else 0;
                },
                .code_size => blk: {
                    if (exact_instructions.codeAccountAccessGas(.warm) == null) break :blk 0;
                    const status = try frame.host.accessAccount(target_address);
                    break :blk exact_instructions.codeAccountAccessGas(status) orelse 0;
                },
            };
            if (!frame.trackGas(access_gas)) return null;
            try frame.traceAccountAccess(target_address);
            return switch (value) {
                .balance => try frame.host.getBalance(target_address),
                .code_size => try frame.host.getCodeSize(target_address),
                .code_hash => try frame.host.getCodeHash(target_address),
            };
        }
    };
}

test "BALANCE cold account access gas comes from the exact spec" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    const exact = comptime exact: {
        var result = evmz.eth.frontier.instruction;
        result.account_read_cold_access_gas = 7;
        break :exact result;
    };
    const spec = evmz.eth.frontier.extend(.{
        .instruction = exact,
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.BALANCE)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(evmz.addr(2).toU256());
    var intpr = frame.interpreter();
    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 99_973), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "EXTCODESIZE account access gas comes from the exact spec" {
    if (comptime !evmz.t.forkEnabled(.frontier)) return error.SkipZigTest;
    const exact = comptime exact: {
        var result = evmz.eth.frontier.instruction;
        result.code_account_cold_access_gas = 9;
        result.code_account_warm_access_gas = 4;
        break :exact result;
    };
    const spec = evmz.eth.frontier.extend(.{
        .instruction = exact,
    });

    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    var msg = evmz.t.defaultMessage();
    const code = [_]u8{@intFromEnum(evmz.Opcode.EXTCODESIZE)};

    var frame = try Interpreter.Interpreter(spec).OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = &code },
    });
    defer frame.deinit();

    frame.frame.stack.push(evmz.addr(2).toU256());
    var intpr = frame.interpreter();
    const result = try intpr.execute();

    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(i64, 99_971), frame.frame.gas_left);
    try std.testing.expectEqual(@as(u256, 0), frame.frame.stack.pop());
}

test "EXTCODECOPY writes directly and zero pads missing code bytes" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
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

    const Cancun = evmz.Vm(evmz.eth.cancun);
    var frame = try Cancun.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .source = .{ .code = bytecode },
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{ 0xbb, 0xcc, 0x00, 0x00 }, interpreter.call_frame.memory.readBytes(0, 4));
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
