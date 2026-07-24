//! Precompile customization, two ways:
//!
//! 1. Derive a new exact `precompile.Config` from the Ethereum catalog —
//!    activation flags and gas pricing are plain comptime values, so an
//!    L2-style fork can enable P256VERIFY early at its own price.
//! 2. Hand the spec a completely custom precompile type. The `precompile`
//!    field is any type with `Entry`/`resolve`/`active`/`execute`; this one
//!    owns one extra address and delegates the rest to the derived catalog.

const std = @import("std");
const evmz = @import("evmz");
const harness = @import("harness.zig");

const l2_precompile_config = blk: {
    var config = evmz.eth.precompile.cancun_config;
    // RIP-7212 P256VERIFY, active before Osaka and priced like an L2 would.
    config.active[@intFromEnum(evmz.eth.precompile.Entry.p256verify)] = true;
    config.gas.set(.p256verify, 3_450);
    break :blk config;
};
const StandardSet = evmz.eth.precompile.Exact(l2_precompile_config);

pub const reverse_address = evmz.addr(0x1234);
const reverse_gas: i64 = 100;

const CustomSet = struct {
    pub const Entry = union(enum) {
        standard: StandardSet.Entry,
        reverse,
    };

    pub fn resolve(target: evmz.Address) ?Entry {
        if (std.mem.eql(u8, &target, &reverse_address)) return .reverse;
        if (StandardSet.resolve(target)) |entry| return .{ .standard = entry };
        return null;
    }

    pub fn active(target: evmz.Address) bool {
        return resolve(target) != null;
    }

    pub fn execute(
        entry: Entry,
        call: evmz.execution.PrecompileCall,
    ) evmz.precompile.Error!evmz.execution.PrecompileOutcome {
        switch (entry) {
            .standard => |standard| return StandardSet.execute(standard, call),
            .reverse => {
                if (call.message.gas < reverse_gas) {
                    return .{ .result = .{
                        .status = .out_of_gas,
                        .output_data = &.{},
                        .gas_left = 0,
                        .output_owned = false,
                    } };
                }
                const output = try call.allocator.dupe(u8, call.message.input_data);
                std.mem.reverse(u8, output);
                return .{ .result = .{
                    .status = .success,
                    .output_data = output,
                    .gas_left = call.message.gas - reverse_gas,
                } };
            },
        }
    }
};

pub const precompile_cancun = evmz.eth.cancun.extend(.{ .precompile = CustomSet });

const CustomVm = evmz.Vm(precompile_cancun);
const CancunVm = evmz.Vm(evmz.eth.cancun);

const sender = evmz.addr(0xaaaa);

fn reverse(comptime VmType: type, allocator: std.mem.Allocator, input: []const u8) !harness.Result {
    return harness.transact(VmType, allocator, .{
        .accounts = &.{.{ .address = sender, .balance = 1_000_000 }},
        .sender = sender,
        .to = reverse_address,
        .input = input,
        .gas_limit = 100_000,
    });
}

pub fn run(allocator: std.mem.Allocator) !void {
    const p256 = evmz.precompile.Contract.p256verify.toAddress();
    const reversed = try reverse(CustomVm, allocator, "evmz");
    defer reversed.deinit(allocator);

    std.debug.print(
        "REVERSE precompile at 0x1234: {s} -> \"{s}\", gas {d}\n",
        .{ @tagName(reversed.status), reversed.output, reversed.gas_used },
    );
    std.debug.print(
        "P256VERIFY active: custom {}, stock cancun {}\n",
        .{ CustomVm.specification.precompile.active(p256), CancunVm.specification.precompile.active(p256) },
    );

    if (reversed.status != .success) return error.ExampleReverseFailed;
    if (!std.mem.eql(u8, reversed.output, "zmve")) return error.ExampleReverseMismatch;
}

test "custom precompile type serves its own address through the VM" {
    const reversed = try reverse(CustomVm, std.testing.allocator, "evmz");
    defer reversed.deinit(std.testing.allocator);

    try std.testing.expectEqual(evmz.TxStatus.success, reversed.status);
    try std.testing.expectEqualSlices(u8, "zmve", reversed.output);

    // On stock Cancun the same address is plain empty state: the call
    // succeeds as a no-op value transfer and returns nothing.
    const stock = try reverse(CancunVm, std.testing.allocator, "evmz");
    defer stock.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), stock.output.len);
}

test "derived config activates P256VERIFY ahead of the Ethereum catalog" {
    const p256 = evmz.precompile.Contract.p256verify.toAddress();
    try std.testing.expect(CustomVm.specification.precompile.active(p256));
    try std.testing.expect(!CancunVm.specification.precompile.active(p256));
    try std.testing.expect(evmz.Vm(evmz.eth.osaka).specification.precompile.active(p256));
}
