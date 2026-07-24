//! Scalar value patches: plain numbers and flags swapped on top of stock
//! Cancun via `extend`.
//!
//! Plain optional patch fields inherit the base value when left null.
//! `OptionalPatch` fields distinguish "inherit" from "replace", so an
//! optional limit can also be replaced with `null` — removed outright, as
//! the `unlimited` spec below shows.

const std = @import("std");
const evmz = @import("evmz");
const harness = @import("harness.zig");

/// Cancun with a doubled contract-size ceiling and looser initcode caps.
pub const custom_cancun = evmz.eth.cancun.extend(.{
    .transaction = .{
        .max_initcode_size = 0x10000,
        .warms_coinbase = true,
    },
    .settlement = .{
        .gas_refund_cap_divisor = 4,
    },
    .authorization = .{
        .warms_delegated_target = true,
    },
    .create = .{
        .code_size_limit = .{ .replace = 0x8000 },
        .initcode_size_limit = .{ .replace = 0x10000 },
    },
});

/// `.replace = null` removes the optional limit instead of inheriting it.
pub const unlimited_cancun = evmz.eth.cancun.extend(.{
    .create = .{ .code_size_limit = .{ .replace = null } },
});

const CustomVm = evmz.Vm(custom_cancun);
const CancunVm = evmz.Vm(evmz.eth.cancun);

comptime {
    // Every knob stays introspectable on the compiled VM.
    std.debug.assert(CustomVm.specification.create.code_size_limit == 0x8000);
    std.debug.assert(CustomVm.specification.create.initcode_size_limit == 0x10000);
    std.debug.assert(CustomVm.specification.transaction.max_initcode_size == 0x10000);
    std.debug.assert(CustomVm.specification.settlement.gas_refund_cap_divisor == 4);
    std.debug.assert(CustomVm.specification.authorization.warms_delegated_target);
    std.debug.assert(CustomVm.specification.transaction.warms_coinbase);
    std.debug.assert(evmz.Vm(unlimited_cancun).specification.create.code_size_limit == null);
    // Unpatched sections inherit the stock Cancun values.
    std.debug.assert(CustomVm.specification.call.base_gas == CancunVm.specification.call.base_gas);
}

/// PUSH2 0x7000; PUSH1 0x00; RETURN — deposits 0x7000 zero bytes as runtime
/// code. That is over stock Cancun's 0x6000 cap but under the custom 0x8000.
const initcode = [_]u8{ 0x61, 0x70, 0x00, 0x60, 0x00, 0xf3 };

const deployer = evmz.addr(0xaaaa);

/// Send the same create transaction through one exact VM and report what the
/// spec's code size limit did to it.
fn deploy(comptime VmType: type, allocator: std.mem.Allocator) !harness.Result {
    return harness.transact(VmType, allocator, .{
        .accounts = &.{.{ .address = deployer, .balance = 1_000_000 }},
        .sender = deployer,
        .to = null,
        .input = &initcode,
        .gas_limit = 8_000_000,
    });
}

pub fn run(allocator: std.mem.Allocator) !void {
    const custom = try deploy(CustomVm, allocator);
    defer custom.deinit(allocator);
    const stock = try deploy(CancunVm, allocator);
    defer stock.deinit(allocator);

    std.debug.print(
        "custom-cancun (code size limit {d}): {s}, gas {d}, deployed {d} bytes\n",
        .{
            CustomVm.specification.create.code_size_limit.?,
            @tagName(custom.status),
            custom.gas_used,
            custom.deployed_code_len,
        },
    );
    std.debug.print(
        "stock cancun (code size limit {d}): {s}, gas {d}, deployed {d} bytes\n",
        .{
            CancunVm.specification.create.code_size_limit.?,
            @tagName(stock.status),
            stock.gas_used,
            stock.deployed_code_len,
        },
    );

    if (custom.status != .success) return error.ExampleCustomDeployFailed;
    if (custom.deployed_code_len != 0x7000) return error.ExampleCustomCodeSizeMismatch;
    if (stock.status == .success) return error.ExampleStockDeployUnexpectedlySucceeded;
}

test "raised code size limit admits what stock Cancun rejects" {
    const custom = try deploy(CustomVm, std.testing.allocator);
    defer custom.deinit(std.testing.allocator);
    const stock = try deploy(CancunVm, std.testing.allocator);
    defer stock.deinit(std.testing.allocator);

    try std.testing.expectEqual(evmz.TxStatus.success, custom.status);
    try std.testing.expectEqual(@as(usize, 0x7000), custom.deployed_code_len);
    try std.testing.expect(stock.status != .success);
    try std.testing.expectEqual(@as(usize, 0), stock.deployed_code_len);
}
