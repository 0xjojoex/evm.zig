//! OP rollup fee model: the L1 data-availability fee and the Isthmus
//! operator fee, priced from the L1Block predeploy and paid to protocol
//! vaults.
//!
//! Ports op-revm `l1block.rs` + `constants.rs` (verified against the
//! ethereum-optimism/optimism `rust/op-revm` source and its mainnet test
//! vectors). Pre-Regolith quirks (the 68-byte signature allowance) are out
//! of scope: the example family is Regolith-and-later.

const std = @import("std");

const evmz = @import("evmz");
const fast_lz = @import("fast_lz.zig");

const Address = evmz.Address;

/// The L1Block predeploy every OP block's attributes deposit rewrites.
pub const l1_block_predeploy: Address = .addr(0x4200000000000000000000000000000000000015);
/// Vault credited with each transaction's L1 DA fee.
pub const l1_fee_recipient: Address = .addr(0x420000000000000000000000000000000000001A);
/// Vault credited with the base fee: OP redirects EIP-1559's burn.
pub const base_fee_recipient: Address = .addr(0x4200000000000000000000000000000000000019);
/// Vault credited with the Isthmus operator fee.
pub const operator_fee_recipient: Address = .addr(0x420000000000000000000000000000000000001B);

pub const l1_base_fee_slot: u256 = 1;
pub const ecotone_l1_fee_scalars_slot: u256 = 3;
pub const l1_overhead_slot: u256 = 5;
pub const l1_scalar_slot: u256 = 6;
pub const ecotone_l1_blob_base_fee_slot: u256 = 7;
pub const operator_fee_scalars_slot: u256 = 8;

/// Which L1 cost function a revision uses. Fee-model revisions move
/// independently of the engine's Ethereum base fork.
pub const CostFork = enum { bedrock, ecotone, fjord };

const deposit_type_id: u8 = 0x7e;

/// The L1Block facts one transaction's rollup fees are priced from.
///
/// The scalars are u32/u64 in storage but held as `u256`
pub const L1BlockInfo = struct {
    l1_base_fee: u256 = 0,
    /// Pre-Ecotone cost inputs; also loaded for the first-Ecotone-block
    /// `empty_ecotone_scalars` fallback.
    l1_fee_overhead: u256 = 0,
    l1_base_fee_scalar: u256 = 0,
    l1_blob_base_fee: u256 = 0,
    l1_blob_base_fee_scalar: u256 = 0,
    operator_fee_scalar: u256 = 0,
    operator_fee_constant: u256 = 0,
    /// Ecotone activated but the attributes deposit has not set the new
    /// scalars yet: price with the Bedrock function.
    empty_ecotone_scalars: bool = false,

    /// Load the facts `cost_fork` needs through `state`, anything with
    /// `getStorage(Address, u256)`: a family `Context` reads the overlay so
    /// the same-block attributes deposit is visible.
    ///
    /// Packed slots, as big-endian byte offsets into the 32-byte word
    /// (op-revm `constants.rs`, *not* Solidity's low-end offsets)
    /// `shift = (32 - offset - width) * 8`:
    pub fn fetch(state: anytype, comptime cost_fork: CostFork, comptime operator_fee: bool) !L1BlockInfo {
        var info: L1BlockInfo = .{
            .l1_base_fee = try state.getStorage(l1_block_predeploy, l1_base_fee_slot),
        };
        if (cost_fork == .bedrock) {
            comptime std.debug.assert(!operator_fee);
            info.l1_base_fee_scalar = try state.getStorage(l1_block_predeploy, l1_scalar_slot);
            info.l1_fee_overhead = try state.getStorage(l1_block_predeploy, l1_overhead_slot);
            return info;
        }

        info.l1_blob_base_fee = try state.getStorage(l1_block_predeploy, ecotone_l1_blob_base_fee_slot);
        // slot3
        // uint64 sequenceNumber
        // uint32 blobBaseFeeScalar
        // uint32 baseFeeScalar
        const scalars: u256 = try state.getStorage(l1_block_predeploy, ecotone_l1_fee_scalars_slot);
        info.l1_base_fee_scalar = @as(u32, @truncate(scalars >> 96));
        info.l1_blob_base_fee_scalar = @as(u32, @truncate(scalars >> 64));
        // The first-block fallback keys on the packed scalar slot alone; the
        // slot-7 blob base fee does not participate. (op-revm's condition
        // reads a local named `l1_blob_base_fee` that is actually the blob
        // fee *scalar* sliced from slot 3.)
        info.empty_ecotone_scalars =
            info.l1_base_fee_scalar == 0 and info.l1_blob_base_fee_scalar == 0;
        if (info.empty_ecotone_scalars) {
            info.l1_fee_overhead = try state.getStorage(l1_block_predeploy, l1_overhead_slot);
        }

        if (operator_fee) {
            const operator: u256 = try state.getStorage(l1_block_predeploy, operator_fee_scalars_slot);
            info.operator_fee_scalar = @as(u32, @truncate(operator >> 64));
            info.operator_fee_constant = @as(u64, @truncate(operator));
        }
        return info;
    }

    /// L1 DA cost of one signed envelope. Deposits and empty envelopes cost
    /// zero; the family validates upstream that an Ethereum variant never
    /// reaches this with either (the zero-cost path is an explicit variant).
    pub fn txL1Cost(self: *const L1BlockInfo, enveloped: []const u8, comptime cost_fork: CostFork) u256 {
        if (enveloped.len == 0 or enveloped[0] == deposit_type_id) return 0;
        return switch (cost_fork) {
            .bedrock => self.bedrockCost(enveloped),
            .ecotone => if (self.empty_ecotone_scalars)
                self.bedrockCost(enveloped)
            else
                self.ecotoneCost(enveloped),
            .fjord => self.fjordCost(enveloped),
        };
    }

    /// `(dataGas + overhead) * l1BaseFee * scalar / 1e6`. Saturating, as
    /// op-revm computes it — the spec defines the result as an unbounded
    /// computation truncated to uint256, never a trap.
    fn bedrockCost(self: *const L1BlockInfo, enveloped: []const u8) u256 {
        return (istanbulDataGas(enveloped) +| self.l1_fee_overhead) *|
            self.l1_base_fee *| self.l1_base_fee_scalar / 1_000_000;
    }

    /// `dataGas * (l1BaseFee*16*baseFeeScalar + blobBaseFee*blobScalar) / 16e6`
    /// — the spec's `(dataGas/16) * scaled / 1e6` computed in the wider
    /// denominator for precision, as op-revm does.
    fn ecotoneCost(self: *const L1BlockInfo, enveloped: []const u8) u256 {
        return istanbulDataGas(enveloped) *| self.ecotoneFeeScaled() / (16 * 1_000_000);
    }

    /// `estimatedSizeScaled * (baseFeeScalar*l1BaseFee*16 + blobScalar*blobBaseFee) / 1e12`.
    fn fjordCost(self: *const L1BlockInfo, enveloped: []const u8) u256 {
        const scaled = self.ecotoneFeeScaled();
        if (scaled == 0) return 0;
        return @as(u256, fjordEstimatedSizeScaled(enveloped)) *| scaled / 1_000_000_000_000;
    }

    fn ecotoneFeeScaled(self: *const L1BlockInfo) u256 {
        return self.l1_base_fee *| 16 *| self.l1_base_fee_scalar +|
            self.l1_blob_base_fee *| self.l1_blob_base_fee_scalar;
    }

    /// DA gas of one envelope, as block explorers report it.
    pub fn dataGas(self: *const L1BlockInfo, enveloped: []const u8, comptime cost_fork: CostFork) u256 {
        _ = self;
        return switch (cost_fork) {
            .bedrock, .ecotone => istanbulDataGas(enveloped),
            .fjord => @as(u256, fjordEstimatedSizeScaled(enveloped)) * 16 / 1_000_000,
        };
    }

    /// Isthmus operator fee charged upfront on the full gas limit:
    /// `gasLimit * scalar / 1e6 + constant`. Deposits and empty envelopes
    /// are exempt.
    pub fn operatorFeeCharge(self: *const L1BlockInfo, enveloped: []const u8, gas: u64) u256 {
        if (enveloped.len == 0 or enveloped[0] == deposit_type_id) return 0;
        return self.operatorFee(gas);
    }

    /// Operator fee for an exact gas amount — the settlement-time recharge
    /// on gas actually used; the upfront-minus-used difference refunds.
    pub fn operatorFee(self: *const L1BlockInfo, gas: u64) u256 {
        return @as(u256, gas) *| self.operator_fee_scalar / 1_000_000 +| self.operator_fee_constant;
    }
};

/// Calldata pricing of the enveloped bytes: 16 gas per nonzero byte, 4 per
/// zero byte (Istanbul rates, which OP froze for DA pricing).
fn istanbulDataGas(enveloped: []const u8) u256 {
    var gas: u64 = 0;
    for (enveloped) |byte| gas +|= if (byte == 0) 4 else 16;
    return gas;
}

/// Fjord estimated compressed size, scaled by 1e6:
/// `max(100e6, 836500*fastLzSize - 42585600)`.
fn fjordEstimatedSizeScaled(enveloped: []const u8) u64 {
    const linear = 836_500 * @as(u64, fast_lz.compressedLen(enveloped));
    return @max(100_000_000, linear -| 42_585_600);
}

/// Pack the Ecotone fee scalars the way the L1Block predeploy stores slot 3.
pub fn packEcotoneScalars(base_fee_scalar: u32, blob_base_fee_scalar: u32) u256 {
    return (@as(u256, base_fee_scalar) << 96) | (@as(u256, blob_base_fee_scalar) << 64);
}

/// Pack the Isthmus operator fee params the way slot 8 stores them.
pub fn packOperatorFeeScalars(scalar: u32, constant: u64) u256 {
    return (@as(u256, scalar) << 64) | constant;
}

const facade = [_]u8{ 0xfa, 0xca, 0xde };

test "bedrock cost matches the op-revm regolith vector" {
    const info = L1BlockInfo{
        .l1_base_fee = 1_000,
        .l1_fee_overhead = 1_000,
        .l1_base_fee_scalar = 1_000,
    };
    try std.testing.expectEqual(@as(u256, 1_048), info.txL1Cost(&facade, .bedrock));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{}, .bedrock));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{ 0x7e, 0xfa, 0xca, 0xde }, .bedrock));
}

test "ecotone cost matches the op-revm vectors and empty-scalar fallback" {
    var info = L1BlockInfo{
        .l1_base_fee = 1_000,
        .l1_base_fee_scalar = 1_000,
        .l1_blob_base_fee = 1_000,
        .l1_blob_base_fee_scalar = 1_000,
        .l1_fee_overhead = 1_000,
    };
    try std.testing.expectEqual(@as(u256, 51), info.txL1Cost(&facade, .ecotone));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{}, .ecotone));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{ 0x7e, 0xfa, 0xca, 0xde }, .ecotone));

    info.empty_ecotone_scalars = true;
    try std.testing.expectEqual(@as(u256, 1_048), info.txL1Cost(&facade, .ecotone));
}

test "fjord cost matches the op-revm vectors" {
    const info = L1BlockInfo{
        .l1_base_fee = 1_000,
        .l1_base_fee_scalar = 1_000,
        .l1_blob_base_fee = 1_000,
        .l1_blob_base_fee_scalar = 1_000,
    };
    // fastLzSize 4 clamps to the 100e6 minimum estimated size.
    try std.testing.expectEqual(@as(u256, 1_700), info.txL1Cost(&facade, .fjord));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{}, .fjord));
    try std.testing.expectEqual(@as(u256, 0), info.txL1Cost(&.{ 0x7e, 0xfa, 0xca, 0xde }, .fjord));
}

test "ecotone cost reproduces OP mainnet block 118024092" {
    // <https://optimistic.etherscan.io/tx/0xa75ef696bf67439b4d5b61da85de9f3ceaa2e145abe982212101b244b63749c2>
    const info = L1BlockInfo{
        .l1_base_fee = 47_036_678_951,
        .l1_base_fee_scalar = 1_368,
        .l1_blob_base_fee = 57_422_457_042,
        .l1_blob_base_fee_scalar = 810_949,
    };
    const tx_hex =
        "02f8b30a832253fc8402d11f39842c8a46398301388094dc6ff44d5d932cbd77b52e5612ba0529dc6226f180b844a9059cbb000000000000000000000000d43e02db81f4d46cdf8521f623d21ea0ec7562a5000000000000000000000000000000000000000000000000" ++
        "8ac7230489e80000c001a02947e24750723b48f886931562c55d9e07f856d8e06468e719755e18bbc3a570a0784da9ce59fd7754ea5be6e17a86b348e441348cd48ace59d174772465eadbd1";
    var tx: [tx_hex.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tx, tx_hex);

    try std.testing.expectEqual(@as(u256, 2_456), info.dataGas(&tx, .ecotone));
    try std.testing.expectEqual(@as(u256, 7_306_020_222_001), info.txL1Cost(&tx, .ecotone));
}

test "fjord cost reproduces OP mainnet block 124665056" {
    // <https://optimistic.etherscan.io/tx/0x1059e8004daff32caa1f1b1ef97fe3a07a8cf40508f5b835b66d9420d87c4a4a>
    const info = L1BlockInfo{
        .l1_base_fee = 1_055_991_687,
        .l1_base_fee_scalar = 5_227,
        .l1_blob_base_fee = 1,
        .l1_blob_base_fee_scalar = 1_014_213,
    };
    const tx = @embedFile("fjord_vector_tx.hex");
    var decoded: [tx.len / 2]u8 = undefined;
    _ = try std.fmt.hexToBytes(&decoded, tx);

    try std.testing.expectEqual(@as(u256, 4_471), info.dataGas(&decoded, .fjord));
    try std.testing.expectEqual(@as(u256, 0x5bf1ab43d), info.txL1Cost(&decoded, .fjord));
}

test "empty-scalar detection keys on the packed slot, not the blob base fee" {
    const StorageMock = struct {
        pub fn getStorage(_: @This(), account: evmz.Address, key: u256) !u256 {
            std.debug.assert(account.eql(l1_block_predeploy));
            return switch (key) {
                l1_base_fee_slot => 1_000,
                // A nonzero slot-7 value must not defeat the first-block
                // fallback: only the packed scalar slot decides.
                ecotone_l1_blob_base_fee_slot => 999,
                ecotone_l1_fee_scalars_slot => 0,
                l1_overhead_slot => 1_000,
                else => 0,
            };
        }
    };
    const info = try L1BlockInfo.fetch(StorageMock{}, .ecotone, false);

    try std.testing.expect(info.empty_ecotone_scalars);
    try std.testing.expectEqual(@as(u256, 1_000), info.l1_fee_overhead);
}

test "operator fee formula and refund shape" {
    const info = L1BlockInfo{
        .operator_fee_scalar = 1_000,
        .operator_fee_constant = 10,
    };
    // gas * scalar / 1e6 + constant.
    try std.testing.expectEqual(@as(u256, 10_010), info.operatorFee(10_000_000));
    try std.testing.expectEqual(@as(u256, 10), info.operatorFee(0));
    // Deposits and system-call envelopes are exempt from the charge.
    try std.testing.expectEqual(@as(u256, 0), info.operatorFeeCharge(&.{}, 10_000_000));
    try std.testing.expectEqual(@as(u256, 0), info.operatorFeeCharge(&.{deposit_type_id}, 10_000_000));
    try std.testing.expectEqual(@as(u256, 10_010), info.operatorFeeCharge(&facade, 10_000_000));
}

test "slot packing round-trips through fetch's unpacking offsets" {
    const packed_fee = packEcotoneScalars(1_368, 810_949);
    try std.testing.expectEqual(@as(u32, 1_368), @as(u32, @truncate(packed_fee >> 96)));
    try std.testing.expectEqual(@as(u32, 810_949), @as(u32, @truncate(packed_fee >> 64)));

    const packed_operator = packOperatorFeeScalars(7, 1_000_000);
    try std.testing.expectEqual(@as(u32, 7), @as(u32, @truncate(packed_operator >> 64)));
    try std.testing.expectEqual(@as(u64, 1_000_000), @as(u64, @truncate(packed_operator)));
}
