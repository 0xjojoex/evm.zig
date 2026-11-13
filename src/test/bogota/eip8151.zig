//! EIP-8151 account-code-restricted ecRecover, pinned to Bogotá: the
//! restriction exists only there.

const std = @import("std");
const evmz = @import("../../evm.zig");
const support = @import("../vm_support.zig");

const Address = evmz.Address;
const addr = evmz.addr;

const sender = addr(0xaaaa);
const caller = addr(0xc0de);

/// hash, v = 28, r, s.
const signature_input = hex(
    "18c547e4f7b0f325ad1e56f57e26c745b09a3e503d86e00e5255ff7f715d3d1c" ++
        "000000000000000000000000000000000000000000000000000000000000001c" ++
        "73b1693892219d736caba55bdb67216e485557ea6b6af75f37096c9aa6a5a75f" ++
        "eeb940b1d03b21e36b0e47e79769f095fe2ab855bd91e3a38756b7d75a9c4549",
);

/// STATICCALL ecRecover with calldata[0..128] and the gas in calldata[128..160];
/// store the call's success in slot 0, RETURNDATASIZE in slot 1, and the
/// output word in slot 2.
const caller_code =
    // CALLDATACOPY(0, 0, 128)
    evmz.t.bytecode(.{ .PUSH1, 0x80, .PUSH0, .PUSH0, .CALLDATACOPY }) ++
    // STATICCALL(CALLDATALOAD(128), 0x01, 0, 128, 128, 32)
    evmz.t.bytecode(.{ .PUSH1, 0x20, .PUSH1, 0x80, .PUSH1, 0x80, .PUSH0, .PUSH1, 0x01 }) ++
    evmz.t.bytecode(.{ .PUSH1, 0x80, .CALLDATALOAD, .STATICCALL }) ++
    // SSTORE(0, success); SSTORE(1, RETURNDATASIZE); SSTORE(2, MLOAD(128))
    evmz.t.bytecode(.{ .PUSH0, .SSTORE, .RETURNDATASIZE, .PUSH1, 1, .SSTORE }) ++
    evmz.t.bytecode(.{ .PUSH1, 0x80, .MLOAD, .PUSH1, 2, .SSTORE, .STOP });

fn hex(comptime text: []const u8) [text.len / 2]u8 {
    var bytes: [text.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, text) catch unreachable;
    return bytes;
}

fn recoveredAddress() Address {
    const public_key = evmz.crypto.ecrecoverPublicKey(
        signature_input[0..32].*,
        signature_input[64..96].*,
        signature_input[96..128].*,
        1,
    ).?;
    return .fromPublicKey(public_key);
}

const Outcome = struct {
    success: bool,
    returned: ?Address,
};

/// Run one ecRecover call with `gas`, the recovered account holding `code`,
/// and that account warm when `warm`.
fn recover(comptime Bogota: type, code: []const u8, warm: bool, gas: i64) !Outcome {
    const recovered = recoveredAddress();
    var executor = Bogota.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000_000_000 });
    try evmz.t.seedExecutorAccount(&executor, caller, .{ .code = &caller_code });
    if (code.len != 0) try evmz.t.seedExecutorAccount(&executor, recovered, .{ .code = code });

    var input: [160]u8 = undefined;
    @memcpy(input[0..128], &signature_input);
    std.mem.writeInt(u256, input[128..160], @intCast(gas), .big);
    const access_list = [_]evmz.transaction.AccessListEntry{
        .{ .address = recovered, .storage_keys = &.{} },
    };
    const result = try support.expectExecuted(try support.transact(Bogota, &executor, .{
        .env = .{ .gas_limit = 10_000_000 },
        .tx = .{
            .sender = sender,
            .to = caller,
            .gas_limit = 1_000_000,
            .input = &input,
            .access_list = if (warm) &access_list else &.{},
        },
    }));
    try std.testing.expectEqual(support.TxStatus.success, result.status);

    const returned_size = try executor.getStorage(caller, 1);
    const word = try executor.getStorage(caller, 2);
    if (returned_size == 0) try std.testing.expectEqual(@as(u256, 0), word);
    return .{
        .success = try executor.getStorage(caller, 0) == 1,
        .returned = if (returned_size == 32) .fromBytes(word_bytes: {
            var bytes: [32]u8 = undefined;
            std.mem.writeInt(u256, &bytes, word, .big);
            break :word_bytes bytes[12..32].*;
        }) else null,
    };
}

test "Bogota ecRecover withholds a recovered account whose code is not a delegation" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    const recovered = recoveredAddress();
    var delegation: [evmz.eip7702.delegation_code_len]u8 = undefined;
    evmz.eip7702.writeDelegationCode(&delegation, addr(0xd00d));
    const plenty: i64 = 100_000;

    const empty = try recover(Bogota, &.{}, false, plenty);
    try std.testing.expect(empty.success);
    try std.testing.expectEqual(recovered, empty.returned.?);

    const delegated = try recover(Bogota, &delegation, false, plenty);
    try std.testing.expect(delegated.success);
    try std.testing.expectEqual(recovered, delegated.returned.?);

    // Withholding looks like a failed recovery: success with empty output.
    const contract = try recover(Bogota, &.{0x00}, false, plenty);
    try std.testing.expect(contract.success);
    try std.testing.expectEqual(@as(?Address, null), contract.returned);
}

test "Bogota ecRecover charges a warm or cold access and a code read for the recovered account" {
    const Bogota = evmz.t.Vm(.bogota) orelse return error.SkipZigTest;
    const recovered = recoveredAddress();
    const base = Bogota.spec.precompile.config.gas.get(.ecrecover);
    const check = Bogota.spec.precompile.ecrecover_account_check.?;
    for ([_]bool{ false, true }) |warm| {
        const access = if (warm) check.warm_access_gas else check.cold_access_gas;
        const exact = base + access + check.code_read_gas;
        const paid = try recover(Bogota, &.{}, warm, exact);
        try std.testing.expect(paid.success);
        try std.testing.expectEqual(recovered, paid.returned.?);
        const short = try recover(Bogota, &.{}, warm, exact - 1);
        try std.testing.expect(!short.success);
        try std.testing.expectEqual(@as(?Address, null), short.returned);
    }
}
