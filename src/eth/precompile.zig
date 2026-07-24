const std = @import("std");

const address = @import("../address.zig");
const precompile = @import("../precompile.zig");

pub const Entry = precompile.Contract;

/// Exact precompile values extend forward with the fork chain. Inactive
/// contracts may already have values here; `resolve` owns activation.
pub const frontier_config: precompile.Config = .{
    .active = active: {
        var result = [_]bool{false} ** precompile.contract_slots;
        for ([_]Entry{ .ecrecover, .sha256, .ripemd160, .identity }) |entry| {
            result[@intFromEnum(entry)] = true;
        }
        break :active result;
    },
    .gas = precompile.GasSchedule.init(.{
        .ecrecover = 3_000,
        .sha256_base = 60,
        .sha256_word = 12,
        .ripemd160_base = 600,
        .ripemd160_word = 120,
        .identity_base = 15,
        .identity_word = 3,
        .modexp_minimum = 0,
        .modexp_divisor = 20,
        .bn254_add = 500,
        .bn254_mul = 40_000,
        .bn254_pairing_base = 100_000,
        .bn254_pairing_pair = 80_000,
        .blake2f_round = 1,
        .kzg_point_evaluation = 50_000,
        .bls12_g1add = 375,
        .bls12_g1msm_multiplication = 12_000,
        .bls12_g2add = 600,
        .bls12_g2msm_multiplication = 22_500,
        .bls12_pairing_base = 37_700,
        .bls12_pairing_pair = 32_600,
        .bls12_map_fp_to_g1 = 5_500,
        .bls12_map_fp2_to_g2 = 23_800,
        .p256verify = 6_900,
    }),
    .modexp_pricing = .eip198,
    .modexp_max_input_len = null,
};

pub const byzantium_config: precompile.Config = config: {
    var result = frontier_config;
    activate(&result, &.{ .modexp, .bn254_add, .bn254_mul, .bn254_pairing });
    break :config result;
};

pub const istanbul_config: precompile.Config = config: {
    var result = byzantium_config;
    activate(&result, &.{.blake2f});
    result.gas.set(.bn254_add, 150);
    result.gas.set(.bn254_mul, 6_000);
    result.gas.set(.bn254_pairing_base, 45_000);
    result.gas.set(.bn254_pairing_pair, 34_000);
    break :config result;
};

pub const berlin_config: precompile.Config = config: {
    var result = istanbul_config;
    result.gas.set(.modexp_minimum, 200);
    result.gas.set(.modexp_divisor, 3);
    result.modexp_pricing = .eip2565;
    break :config result;
};

pub const cancun_config: precompile.Config = config: {
    var result = berlin_config;
    activate(&result, &.{.kzg_point_evaluation});
    break :config result;
};

pub const prague_config: precompile.Config = config: {
    var result = cancun_config;
    activate(&result, &.{
        .bls12_g1add,
        .bls12_g1msm,
        .bls12_g2add,
        .bls12_g2msm,
        .bls12_pairing_check,
        .bls12_map_fp_to_g1,
        .bls12_map_fp2_to_g2,
    });
    break :config result;
};

pub const osaka_config: precompile.Config = config: {
    var result = prague_config;
    activate(&result, &.{.p256verify});
    result.gas.set(.modexp_minimum, 500);
    result.modexp_pricing = .eip7883;
    result.modexp_max_input_len = 1_024;
    break :config result;
};

fn activate(config: *precompile.Config, comptime entries: []const Entry) void {
    inline for (entries) |entry| config.active[@intFromEnum(entry)] = true;
}

pub const Exact = precompile.Exact;
pub const executeWithConfig = precompile.executeWithConfig;

test "Ethereum exact precompile configs extend resolved values" {
    try std.testing.expectEqual(@as(i64, 3_000), frontier_config.gas.get(.ecrecover));
    try std.testing.expectEqual(@as(i64, 500), frontier_config.gas.get(.bn254_add));
    try std.testing.expectEqual(@as(i64, 150), istanbul_config.gas.get(.bn254_add));
    try std.testing.expectEqual(precompile.ModexpPricing.eip2565, berlin_config.modexp_pricing);
    try std.testing.expectEqual(@as(?u256, 1_024), osaka_config.modexp_max_input_len);
    try std.testing.expectEqual(@as(i64, 6_900), osaka_config.gas.get(.p256verify));
}

test "precompile activation extends exact configs" {
    const Frontier = Exact(frontier_config);
    const Byzantium = Exact(byzantium_config);
    const Istanbul = Exact(istanbul_config);
    const Berlin = Exact(berlin_config);
    const Cancun = Exact(cancun_config);
    const Prague = Exact(prague_config);
    const Osaka = Exact(osaka_config);

    try std.testing.expectEqual(Entry.ecrecover, Frontier.resolve(Entry.ecrecover.toAddress()).?);
    try std.testing.expect(Frontier.resolve(Entry.modexp.toAddress()) == null);
    try std.testing.expectEqual(Entry.modexp, Byzantium.resolve(Entry.modexp.toAddress()).?);
    try std.testing.expect(Byzantium.resolve(Entry.blake2f.toAddress()) == null);
    try std.testing.expectEqual(Entry.blake2f, Istanbul.resolve(Entry.blake2f.toAddress()).?);
    try std.testing.expect(Berlin.resolve(Entry.kzg_point_evaluation.toAddress()) == null);
    try std.testing.expectEqual(Entry.kzg_point_evaluation, Cancun.resolve(Entry.kzg_point_evaluation.toAddress()).?);
    try std.testing.expect(Cancun.resolve(Entry.bls12_g1add.toAddress()) == null);
    try std.testing.expectEqual(Entry.bls12_g1add, Prague.resolve(Entry.bls12_g1add.toAddress()).?);
    try std.testing.expect(Prague.resolve(address.addr(0x12)) == null);
    try std.testing.expect(Prague.resolve(Entry.p256verify.toAddress()) == null);
    try std.testing.expectEqual(Entry.p256verify, Osaka.resolve(Entry.p256verify.toAddress()).?);
}

test "precompile execution applies Ethereum activation before catalog execution" {
    const Frontier = Exact(frontier_config);
    const Byzantium = Exact(byzantium_config);
    try std.testing.expectEqual(null, Frontier.resolve(Entry.modexp.toAddress()));

    var mock_host = @import("../t.zig").MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const message: @import("../Host.zig").Message = .{
        .depth = 0,
        .kind = .call,
        .gas = 0,
        .sender = address.addr(0),
        .input_data = &.{},
        .value = 0,
    };
    const outcome = try Byzantium.execute(.modexp, .{
        .allocator = std.testing.allocator,
        .host = &host,
        .message = &message,
    });
    const result = outcome.result;
    try std.testing.expectEqual(precompile.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}
