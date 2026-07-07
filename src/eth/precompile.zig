const std = @import("std");

const address = @import("../address.zig");
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
    allocator: std.mem.Allocator,
    revision: Revision,
    entry: Entry,
    input_data: []const u8,
    gas: i64,
) precompile.Error!precompile.Result {
    return precompile.executeContract(entry, .{
        .allocator = allocator,
        .revision = revision,
        .input_data = input_data,
        .gas = gas,
    });
}

pub fn executeWithOutputBuffer(
    allocator: std.mem.Allocator,
    revision: Revision,
    entry: Entry,
    input_data: []const u8,
    gas: i64,
    output_buffer: ?[]u8,
) precompile.Error!precompile.Result {
    return precompile.executeContract(entry, .{
        .allocator = allocator,
        .revision = revision,
        .input_data = input_data,
        .gas = gas,
        .output_buffer = output_buffer,
    });
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

    const result = try execute(std.testing.allocator, .byzantium, .modexp, &.{}, 0);
    try std.testing.expectEqual(precompile.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 0), result.gas_left);
    try std.testing.expectEqual(@as(usize, 0), result.output_data.len);
}
