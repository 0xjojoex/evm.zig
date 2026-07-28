//! Static execution artifacts for protocol-constant Ethereum system code.
//!
//! Lookup is keyed only by an authenticated account code hash. The state
//! reader validates ordinary code materialization; these built-in artifacts
//! can also execute directly from their authenticated hashes.

const std = @import("std");
const Bytecode = @import("../code/Bytecode.zig");
const static_bytecode = @import("../code/static.zig");
const Backend = @import("../prepared_code/Backend.zig");
const crypto = @import("../crypto.zig");

const history_storage_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe14604657602036036042575f35600143038111604257611fff81430311604257611fff9006545f5260205ff35b5f5ffd5b5f35611fff60014303065500");
pub const beacon_roots_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe14604d57602036146024575f5ffd5b5f35801560495762001fff810690815414603c575f5ffd5b62001fff01545f5260205ff35b5f5ffd5b62001fff42064281555f359062001fff015500");
const withdrawal_request_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe1460cb5760115f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146101f457600182026001905f5b5f82111560685781019083028483029004916001019190604d565b909390049250505036603814608857366101f457346101f4575f5260205ff35b34106101f457600154600101600155600354806003026004013381556001015f35815560010160203590553360601b5f5260385f601437604c5fa0600101600355005b6003546002548082038060101160df575060105b5f5b8181146101835782810160030260040181604c02815460601b8152601401816001015481526020019060020154807fffffffffffffffffffffffffffffffff00000000000000000000000000000000168252906010019060401c908160381c81600701538160301c81600601538160281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c81600101535360010160e1565b910180921461019557906002556101a0565b90505f6002555f6003555b5f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff14156101cd57505f5b6001546002828201116101e25750505f6101e8565b01600290035b5f555f600155604c025ff35b5f5ffd");
const consolidation_request_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe1460d35760115f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1461019a57600182026001905f5b5f82111560685781019083028483029004916001019190604d565b9093900492505050366060146088573661019a573461019a575f5260205ff35b341061019a57600154600101600155600354806004026004013381556001015f358155600101602035815560010160403590553360601b5f5260605f60143760745fa0600101600355005b6003546002548082038060021160e7575060025b5f5b8181146101295782810160040260040181607402815460601b815260140181600101548152602001816002015481526020019060030154905260010160e9565b910180921461013b5790600255610146565b90505f6002555f6003555b5f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff141561017357505f5b6001546001828201116101885750505f61018e565b01600190035b5f555f6001556074025ff35b5f5ffd");
const builder_deposit_request_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe1460e1575f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146101c65760015460028111605157506057565b60029003015b601190600182026001905f5b5f821115607e57810190830284830290049160010191906063565b909390049250505036603014609e57366101c657346101c6575f5260205ff35b34106101c657600154600101600155600354806003026004013381556001015f35815560010160203590553360601b5f5260305f60143760445fa0600101600355005b6003546002548082038060101160f5575060105b5f5b81811461012d5782810160030260040181604402815460601b8152601401816001015481526020019060020154905260010160f7565b910180921461013f579060025561014a565b90505f6002555f6003555b36610198575f54600154817fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146101865760028282011161018e575b50505f6101ba565b01600290036101ba565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff5b5f555f6001556044025ff35b5f5ffd");
const builder_exit_request_code = decodeHex("3373fffffffffffffffffffffffffffffffffffffffe1461011c575f54807fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff146102705760015460088111605257506058565b60089003015b601190600182026001905f5b5f821115607f57810190830284830290049160010191906064565b90939004925050503660b814609f57366102705734610270575f5260205ff35b8034106102705760383567ffffffffffffffff1680633b9aca001161027057633b9aca00029034031061027057600154600101600155600354806006026004015f358155600101602035815560010160403581556001016060358155600101608035815560010160a035905560b85f5f3760b85fa0600101600355005b60035460025480820380604011610131575060405b5f5b8181146101d7578281016006026004018160b8028154815260200181600101548152602001816002015480825260401c67ffffffffffffffff16816010018160381c81600701538160301c81600601538160281c81600501538160201c81600401538160181c81600301538160101c81600201538160081c816001015353602001816003015481526020018160040154815260200190600501549052600101610133565b91018092146101e957906002556101f4565b90505f6002555f6003555b36610242575f54600154817fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff1461023057600882820111610238575b50505f610264565b0160089003610264565b7fffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff5b5f555f60015560b8025ff35b5f5ffd");

const history_storage_code_hash = decodeHex("6e49e66782037c0555897870e29fa5e552daf4719552131a0abce779daec0a5d");
const beacon_roots_code_hash = decodeHex("f57acd40259872606d76197ef052f3d35588dadf919ee1f0e3cb9b62d3f4b02c");
const withdrawal_request_code_hash = decodeHex("0345a365d2f4c5975b9f1599abe0a2ee76b7a3a731bc68781bd04c84e4858f50");
const consolidation_request_code_hash = decodeHex("78c6cb5202685228bbcbfb992b1c4e116c7ec5ef11e25b8e92716cfc628ddd60");
const builder_deposit_request_code_hash = decodeHex("90a0b24eb190d6c50f00f6f751dc4c2778658abf3631aceb80586c43f8bd9f2f");
const builder_exit_request_code_hash = decodeHex("1dd29c1e0dbc3ab670d229dbd3438003ec9015c1df9058beeb64ff301b60b98d");

const HistoryStorage = static_bytecode.View(&history_storage_code);
const BeaconRoots = static_bytecode.View(&beacon_roots_code);
const WithdrawalRequest = static_bytecode.View(&withdrawal_request_code);
const ConsolidationRequest = static_bytecode.View(&consolidation_request_code);
const BuilderDepositRequest = static_bytecode.View(&builder_deposit_request_code);
const BuilderExitRequest = static_bytecode.View(&builder_exit_request_code);
const artifacts = [_]Artifact{
    .{ .hash = history_storage_code_hash, .view = HistoryStorage.view },
    .{ .hash = beacon_roots_code_hash, .view = BeaconRoots.view },
    .{ .hash = withdrawal_request_code_hash, .view = WithdrawalRequest.view },
    .{ .hash = consolidation_request_code_hash, .view = ConsolidationRequest.view },
    .{ .hash = builder_deposit_request_code_hash, .view = BuilderDepositRequest.view },
    .{ .hash = builder_exit_request_code_hash, .view = BuilderExitRequest.view },
};
var backend_context: u8 = 0;

const Artifact = struct {
    hash: [32]u8,
    view: Bytecode.View,
};

pub fn backend() Backend {
    return .{
        .ptr = &backend_context,
        .vtable = &backend_vtable,
    };
}

const backend_vtable = Backend.VTable{
    .beginExecution = beginExecution,
    .endExecution = endExecution,
    .lookup = lookup,
    .authenticated_lookup = true,
    .admit = admit,
};

fn beginExecution(ptr: *anyopaque) !void {
    _ = ptr;
}

fn endExecution(ptr: *anyopaque) void {
    _ = ptr;
}

fn lookup(ptr: *anyopaque, code_hash: [32]u8) !?Bytecode.View {
    _ = ptr;
    for (artifacts) |artifact| {
        if (std.mem.eql(u8, &code_hash, &artifact.hash)) return artifact.view;
    }
    return null;
}

fn admit(
    ptr: *anyopaque,
    code_hash: [32]u8,
    raw_code: []const u8,
) !?Bytecode.View {
    _ = ptr;
    _ = code_hash;
    _ = raw_code;
    return null;
}

test "protocol artifacts are selected by their authenticated hashes" {
    const codes = .{
        history_storage_code,
        beacon_roots_code,
        withdrawal_request_code,
        consolidation_request_code,
        builder_deposit_request_code,
        builder_exit_request_code,
    };
    inline for (codes, artifacts) |code, artifact| {
        try std.testing.expectEqualSlices(u8, &artifact.hash, &crypto.keccak256(&code));
        const prepared = (try backend().lookup(artifact.hash)).?;
        try std.testing.expectEqualSlices(u8, &code, prepared.bytes);
    }
    try std.testing.expectEqual(
        @as(?Bytecode.View, null),
        try backend().lookup([_]u8{0xff} ** 32),
    );
}

fn decodeHex(comptime hex: []const u8) [hex.len / 2]u8 {
    @setEvalBranchQuota(10_000);
    var bytes: [hex.len / 2]u8 = undefined;
    _ = std.fmt.hexToBytes(&bytes, hex) catch unreachable;
    return bytes;
}
