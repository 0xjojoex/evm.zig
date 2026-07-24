//! Instruction-table surgery: `spec.instruction.table` is a plain comptime
//! value with one entry per byte, so a fork can activate, retire, reprice,
//! or replace any of the 256 slots — including installing a brand-new
//! opcode with a custom handler on an unassigned byte.

const std = @import("std");
const evmz = @import("evmz");
const harness = @import("harness.zig");

/// An unassigned byte hosts the new opcode.
const square_byte: u8 = 0xb0;
const square_gas: i64 = 5;

comptime {
    std.debug.assert(!evmz.opcode.info(square_byte).defined);
}

/// SQUARE: pop x, push x*x (wrapping). `Instructions` is the compiled exact
/// table, so the handler charges its own spec-assigned static gas from it.
const Square = struct {
    pub inline fn execute(comptime Instructions: type, frame: *evmz.interpreter.CallFrame) anyerror!void {
        if (!frame.trackGas(comptime Instructions.table[square_byte].static_gas)) return;
        const x = try frame.stack.pop();
        try frame.stack.push(x *% x);
    }
};

// The mutation helpers are conveniences; `instruction.table` stays a plain
// value that can equally be indexed directly.
const custom_instruction = blk: {
    var instruction = evmz.eth.cancun.instruction;
    // New opcode on an unassigned byte.
    instruction.install(square_byte, square_gas, .{ .custom = Square });
    // Retire an opcode this fork does not want.
    instruction.deactivate(&.{.SELFDESTRUCT});
    // Reprice a builtin without touching its semantics.
    instruction.setStaticGas(&.{.BALANCE}, 1_000);
    break :blk instruction;
};

pub const square_cancun = evmz.eth.cancun.extend(.{ .instruction = custom_instruction });

const SquareVm = evmz.Vm(square_cancun);
const CancunVm = evmz.Vm(evmz.eth.cancun);

comptime {
    std.debug.assert(SquareVm.specification.instruction.entry(square_byte).active);
    std.debug.assert(!SquareVm.specification.instruction.entry(@intFromEnum(evmz.Opcode.SELFDESTRUCT)).active);
    std.debug.assert(SquareVm.specification.instruction.entry(@intFromEnum(evmz.Opcode.BALANCE)).static_gas == 1_000);
    std.debug.assert(CancunVm.specification.instruction.entry(@intFromEnum(evmz.Opcode.BALANCE)).static_gas == 100);
}

const sender = evmz.addr(0xaaaa);
const contract = evmz.addr(0xbbbb);

/// PUSH1 7; SQUARE; PUSH0; SSTORE; STOP — stores 49 at slot 0.
const square_code = [_]u8{ 0x60, 0x07, square_byte, 0x5f, 0x55, 0x00 };
/// PUSH2 0xcccc; SELFDESTRUCT — legal on stock Cancun, retired on the fork.
const selfdestruct_code = [_]u8{ 0x61, 0xcc, 0xcc, 0xff };

fn call(comptime VmType: type, allocator: std.mem.Allocator, code: []const u8) !harness.Result {
    return harness.transact(VmType, allocator, .{
        .accounts = &.{
            .{ .address = sender, .balance = 1_000_000 },
            .{ .address = contract, .code = code },
        },
        .sender = sender,
        .to = contract,
        .gas_limit = 100_000,
        .read_storage = .{ .address = contract, .key = 0 },
    });
}

pub fn run(allocator: std.mem.Allocator) !void {
    const squared = try call(SquareVm, allocator, &square_code);
    defer squared.deinit(allocator);
    const stock_square = try call(CancunVm, allocator, &square_code);
    defer stock_square.deinit(allocator);
    const retired = try call(SquareVm, allocator, &selfdestruct_code);
    defer retired.deinit(allocator);
    const stock_selfdestruct = try call(CancunVm, allocator, &selfdestruct_code);
    defer stock_selfdestruct.deinit(allocator);

    std.debug.print(
        "SQUARE (0x{x:0>2}) fork: {s}, storage[0] = {d}; stock cancun: {s}\n",
        .{ square_byte, @tagName(squared.status), squared.storage, @tagName(stock_square.status) },
    );
    std.debug.print(
        "retired SELFDESTRUCT: fork {s} vs stock {s}\n",
        .{ @tagName(retired.status), @tagName(stock_selfdestruct.status) },
    );

    if (squared.status != .success or squared.storage != 49) return error.ExampleSquareFailed;
    if (stock_square.status == .success) return error.ExampleStockAcceptedUnknownOpcode;
    if (retired.status == .success) return error.ExampleRetiredOpcodeStillActive;
    if (stock_selfdestruct.status != .success) return error.ExampleStockSelfDestructFailed;
}

test "custom opcode executes on the fork and stays invalid on stock Cancun" {
    const squared = try call(SquareVm, std.testing.allocator, &square_code);
    defer squared.deinit(std.testing.allocator);
    const stock = try call(CancunVm, std.testing.allocator, &square_code);
    defer stock.deinit(std.testing.allocator);

    try std.testing.expectEqual(evmz.TxStatus.success, squared.status);
    try std.testing.expectEqual(@as(u256, 49), squared.storage);
    try std.testing.expect(stock.status != .success);
}

test "retired opcode is invalid on the fork only" {
    const retired = try call(SquareVm, std.testing.allocator, &selfdestruct_code);
    defer retired.deinit(std.testing.allocator);
    const stock = try call(CancunVm, std.testing.allocator, &selfdestruct_code);
    defer stock.deinit(std.testing.allocator);

    try std.testing.expect(retired.status != .success);
    try std.testing.expectEqual(evmz.TxStatus.success, stock.status);
}
