const std = @import("std");

const address = @import("../address.zig");
const precompile_runtime = @import("../execution/precompile_runtime.zig");
const precompile = @import("../precompile.zig");
const Revision = @import("revision.zig").Revision;

const Address = address.Address;

pub const Entry = precompile.Contract;

pub fn resolve(revision: Revision, target: Address) ?Entry {
    const contract = precompile.contractFromAddress(target) orelse return null;
    if (!revision.isImpl(minimumRevision(contract))) return null;
    return contract;
}

pub fn active(revision: Revision, target: Address) bool {
    return resolve(revision, target) != null;
}

pub fn execute(
    revision: Revision,
    entry: Entry,
    call: precompile_runtime.PrecompileCall,
) precompile.Error!precompile_runtime.PrecompileOutcome {
    return .{ .result = try precompile.executeContract(entry, .{
        .allocator = call.allocator,
        .revision = revision,
        .input_data = call.message.input_data,
        .gas = call.message.gas,
        .output_buffer = call.output_buffer,
    }) };
}

fn minimumRevision(contract: Entry) Revision {
    return switch (contract) {
        .ecrecover,
        .sha256,
        .ripemd160,
        .identity,
        => .frontier,

        .modexp,
        .bn254_add,
        .bn254_mul,
        .bn254_pairing,
        => .byzantium,

        .blake2f => .istanbul,
        .kzg_point_evaluation => .cancun,

        .bls12_g1add,
        .bls12_g1msm,
        .bls12_g2add,
        .bls12_g2msm,
        .bls12_pairing_check,
        .bls12_map_fp_to_g1,
        .bls12_map_fp2_to_g2,
        => .prague,

        .p256verify => .osaka,
    };
}

test "precompile activation follows Ethereum revisions" {
    try std.testing.expectEqual(Entry.ecrecover, resolve(.frontier, Entry.ecrecover.toAddress()).?);
    try std.testing.expect(resolve(.frontier, Entry.modexp.toAddress()) == null);
    try std.testing.expectEqual(Entry.modexp, resolve(.byzantium, Entry.modexp.toAddress()).?);
    try std.testing.expect(resolve(.byzantium, Entry.blake2f.toAddress()) == null);
    try std.testing.expectEqual(Entry.blake2f, resolve(.istanbul, Entry.blake2f.toAddress()).?);
    try std.testing.expect(resolve(.shanghai, Entry.kzg_point_evaluation.toAddress()) == null);
    try std.testing.expectEqual(Entry.kzg_point_evaluation, resolve(.cancun, Entry.kzg_point_evaluation.toAddress()).?);
    try std.testing.expect(resolve(.cancun, Entry.bls12_g1add.toAddress()) == null);
    try std.testing.expectEqual(Entry.bls12_g1add, resolve(.prague, Entry.bls12_g1add.toAddress()).?);
    try std.testing.expect(resolve(.prague, address.addr(0x12)) == null);
    try std.testing.expect(resolve(.prague, Entry.p256verify.toAddress()) == null);
    try std.testing.expectEqual(Entry.p256verify, resolve(.osaka, Entry.p256verify.toAddress()).?);
}

test "precompile execution applies Ethereum activation before catalog execution" {
    try std.testing.expectEqual(null, resolve(.frontier, Entry.modexp.toAddress()));

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
    const outcome = try execute(.byzantium, .modexp, .{
        .allocator = std.testing.allocator,
        .host = &host,
        .message = &message,
    });
    const result = outcome.result;
    try std.testing.expectEqual(precompile.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}
