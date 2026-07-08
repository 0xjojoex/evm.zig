const std = @import("std");
const definition_support = @import("../protocol/support.zig");
const Transaction = @import("./types.zig");

pub const AccessListCounts = Transaction.AccessListCounts;
pub const AccessListEntry = Transaction.AccessListEntry;

pub const IntrinsicGasOptions = struct {
    authorization_count: usize = 0,
    access_list_counts: AccessListCounts = .{},
    is_create: bool = false,
    value: u256 = 0,
    is_self_transfer: bool = false,
    creates_account: bool = false,
};

/// Gas charged in the two Amsterdam dimensions.
///
/// Regular gas is the classic EVM resource bounded by the transaction cap.
/// State gas is the EIP-8037 state-growth resource; it can be paid from the
/// transaction reservoir before spilling into regular gas.
pub const GasCharge = struct {
    regular: u64 = 0,
    state: u64 = 0,

    pub fn total(self: GasCharge) ?u64 {
        return std.math.add(u64, self.regular, self.state) catch return null;
    }
};

/// Transaction-level intrinsic and calldata-floor costs.
///
/// `regular` and `state` are charged before execution. `floor` is not charged
/// upfront; it is applied at settlement after refunds.
pub const InitialGas = struct {
    regular: u64,
    state: u64 = 0,
    state_refund: u64 = 0,
    floor: u64 = 0,

    pub fn stateFinal(self: InitialGas) u64 {
        return self.state -| self.state_refund;
    }

    pub fn total(self: InitialGas) ?u64 {
        return std.math.add(u64, self.regular, self.stateFinal()) catch return null;
    }

    pub fn minimum(self: InitialGas) ?u64 {
        return @max(self.total() orelse return null, self.floor);
    }
};

/// Initial execution gas state for the interpreter.
///
/// `regular_left` is the value visible to the `GAS` opcode. `reservoir` is the
/// extra transaction gas reserved for Amsterdam state-gas charges.
pub const ExecutionGas = struct {
    regular_left: u64,
    reservoir: u64 = 0,

    pub fn legacy(regular_left: u64) ExecutionGas {
        return .{ .regular_left = regular_left };
    }
};

pub const GasPlan = struct {
    intrinsic_gas: u64,
    intrinsic_regular_gas: u64,
    intrinsic_state_gas: u64,
    floor_gas: u64,
    minimum_gas: u64,
    initial_gas: InitialGas,
    execution: ?ExecutionGas,
};

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        pub fn intrinsicGas(revision: Protocol.Revision, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Self.intrinsicGasForTransaction(revision, input, .{
                .authorization_count = authorization_count,
                .access_list_counts = access_list_counts,
            });
        }

        pub fn maxInitcodeSize(revision: Protocol.Revision) usize {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Protocol.Transaction.maxInitcodeSize(revision);
        }

        pub fn intrinsicGasForTransaction(revision: Protocol.Revision, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const regular_gas = Self.intrinsicRegularGasForTransaction(revision, input, options) orelse return null;
            const state_gas = Self.intrinsicStateGasForTransaction(revision, options) orelse return null;
            return std.math.add(u64, regular_gas, state_gas) catch return null;
        }

        pub fn intrinsicRegularGasForTransaction(revision: Protocol.Revision, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            var gas: u64 = Protocol.Transaction.intrinsicBaseGas(revision, options) orelse return null;
            if (options.is_create) {
                gas = std.math.add(u64, gas, Protocol.Transaction.createIntrinsicGas(revision) orelse return null) catch return null;
            }
            for (input) |byte| {
                gas = std.math.add(u64, gas, Protocol.Transaction.dataByteGas(revision, byte)) catch return null;
            }
            const access_list_address_count = std.math.cast(u64, options.access_list_counts.addresses) orelse return null;
            const access_list_storage_key_count = std.math.cast(u64, options.access_list_counts.storage_keys) orelse return null;
            const access_list_address_cost = std.math.mul(u64, access_list_address_count, Protocol.Transaction.accessListAddressGas(revision)) catch return null;
            const access_list_storage_key_cost = std.math.mul(u64, access_list_storage_key_count, Protocol.Transaction.storageKeyGas(revision)) catch return null;
            gas = std.math.add(u64, gas, access_list_address_cost) catch return null;
            gas = std.math.add(u64, gas, access_list_storage_key_cost) catch return null;
            gas = std.math.add(u64, gas, Protocol.Transaction.accessListDataGas(revision, options.access_list_counts) orelse return null) catch return null;
            if (options.is_create) {
                const initcode_word_charge = Protocol.Transaction.initCodeWordGas(revision);
                if (initcode_word_charge != 0) {
                    const words = std.math.cast(u64, wordCount(input.len)) orelse return null;
                    const initcode_cost = std.math.mul(u64, words, initcode_word_charge) catch return null;
                    gas = std.math.add(u64, gas, initcode_cost) catch return null;
                }
            }
            const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
            const auth_cost = std.math.mul(u64, auth_count, Protocol.Transaction.authorizationIntrinsicGas(revision)) catch return null;
            gas = std.math.add(u64, gas, auth_cost) catch return null;
            return gas;
        }

        pub fn intrinsicStateGasForTransaction(revision: Protocol.Revision, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Protocol.Transaction.intrinsicStateGas(revision, options);
        }

        pub fn intrinsicBaseGas(revision: Protocol.Revision, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Protocol.Transaction.intrinsicBaseGas(revision, options);
        }

        pub fn gasPlan(revision: Protocol.Revision, input: []const u8, gas_limit: u64, options: IntrinsicGasOptions) GasPlan {
            definition_support.assertRevisionSupported(Protocol, revision);
            const intrinsic_regular_gas = Self.intrinsicRegularGasForTransaction(revision, input, options) orelse std.math.maxInt(u64);
            const intrinsic_state_gas = Self.intrinsicStateGasForTransaction(revision, options) orelse std.math.maxInt(u64);
            const floor_gas = Self.floorGasForTransaction(revision, input, options) orelse 0;
            const initial_gas = InitialGas{
                .regular = intrinsic_regular_gas,
                .state = intrinsic_state_gas,
                .floor = floor_gas,
            };
            const intrinsic_gas = initial_gas.total() orelse std.math.maxInt(u64);
            const minimum_gas = initial_gas.minimum() orelse std.math.maxInt(u64);
            const regular_gas_limit = Self.regularGasLimit(revision, gas_limit);
            const execution = if (gas_limit >= minimum_gas and regular_gas_limit >= intrinsic_regular_gas) blk: {
                const execution_total = gas_limit - intrinsic_gas;
                const regular_budget = regular_gas_limit - intrinsic_regular_gas;
                const regular_left = @min(execution_total, regular_budget);
                break :blk ExecutionGas{
                    .regular_left = regular_left,
                    .reservoir = execution_total - regular_left,
                };
            } else null;
            return .{
                .intrinsic_gas = intrinsic_gas,
                .intrinsic_regular_gas = intrinsic_regular_gas,
                .intrinsic_state_gas = intrinsic_state_gas,
                .floor_gas = floor_gas,
                .minimum_gas = minimum_gas,
                .initial_gas = initial_gas,
                .execution = execution,
            };
        }

        pub fn regularGasLimit(revision: Protocol.Revision, gas_limit: u64) u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Protocol.Transaction.regularGasLimit(revision, gas_limit);
        }

        pub fn minimumGas(revision: Protocol.Revision, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Self.minimumGasForTransaction(revision, input, .{
                .authorization_count = authorization_count,
                .access_list_counts = access_list_counts,
            });
        }

        pub fn minimumGasForTransaction(revision: Protocol.Revision, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            const intrinsic = Self.intrinsicGasForTransaction(revision, input, options) orelse return null;
            const floor = Self.floorGasForTransaction(revision, input, options) orelse return intrinsic;
            return @max(intrinsic, floor);
        }

        pub fn floorGas(revision: Protocol.Revision, input: []const u8) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Self.floorGasForTransaction(revision, input, .{});
        }

        pub fn floorGasForTransaction(revision: Protocol.Revision, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            definition_support.assertRevisionSupported(Protocol, revision);
            return Protocol.Transaction.floorGas(revision, input, options);
        }
    };
}

pub fn accessListCounts(access_list: []const AccessListEntry) AccessListCounts {
    var result = AccessListCounts{};
    result.addresses = access_list.len;
    for (access_list) |entry| {
        result.storage_keys += entry.storage_keys.len;
    }
    return result;
}

fn wordCount(len: usize) usize {
    return (len + 31) / 32;
}

test "transaction gas helpers" {
    const Ethereum = @import("../eth.zig");
    const EthGas = For(Ethereum);

    try std.testing.expectEqual(@as(u64, 21_072), EthGas.intrinsicGas(.byzantium, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_020), EthGas.intrinsicGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), EthGas.intrinsicGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 29_120), EthGas.intrinsicGas(.berlin, &.{ 0, 1 }, 0, .{
        .addresses = 1,
        .storage_keys = 3,
    }));
    try std.testing.expectEqual(@as(u64, 5), Ethereum.transaction.calldataTokenCount(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 21_020), EthGas.minimumGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_050), EthGas.minimumGas(.prague, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 15_020), EthGas.minimumGas(.amsterdam, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), EthGas.minimumGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 21_008), EthGas.intrinsicGasForTransaction(.frontier, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_008), EthGas.intrinsicGasForTransaction(.homestead, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_010), EthGas.intrinsicGasForTransaction(.shanghai, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 206_610), EthGas.intrinsicGasForTransaction(.amsterdam, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 271_798), EthGas.intrinsicGasForTransaction(.amsterdam, &([_]u8{1} ** 4059), .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 88_198), EthGas.intrinsicRegularGasForTransaction(.amsterdam, &([_]u8{1} ** 4059), .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 183_600), EthGas.intrinsicStateGasForTransaction(.amsterdam, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 12_000), EthGas.intrinsicBaseGas(.amsterdam, .{ .is_self_transfer = true }));
    try std.testing.expectEqual(@as(u64, 15_000), EthGas.intrinsicBaseGas(.amsterdam, .{}));
    try std.testing.expectEqual(@as(u64, 21_000), EthGas.intrinsicBaseGas(.amsterdam, .{ .value = 1 }));
    try std.testing.expectEqual(@as(u64, 21_000), EthGas.intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .value = 1,
        .creates_account = true,
    }));
    try std.testing.expectEqual(@as(u64, 0), EthGas.intrinsicStateGasForTransaction(.amsterdam, .{
        .value = 1,
        .creates_account = true,
    }));
    try std.testing.expectEqual(@as(u64, 23_000), EthGas.intrinsicBaseGas(.amsterdam, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 24_756), EthGas.intrinsicBaseGas(.amsterdam, .{ .is_create = true, .value = 1 }));
    try std.testing.expectEqual(@as(u64, 24_328), EthGas.intrinsicGasForTransaction(.amsterdam, &.{}, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 1,
    } }));
    try std.testing.expectEqual(@as(u64, 249_606), EthGas.intrinsicGasForTransaction(.amsterdam, &.{}, .{ .authorization_count = 1 }));
    try std.testing.expectEqual(@as(u64, 258_934), EthGas.intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .authorization_count = 1,
        .access_list_counts = .{
            .addresses = 1,
            .storage_keys = 1,
        },
    }));
    try std.testing.expectEqual(std.math.maxInt(usize), EthGas.maxInitcodeSize(.london));
    try std.testing.expectEqual(@as(usize, 49_152), EthGas.maxInitcodeSize(.osaka));
    try std.testing.expectEqual(@as(usize, 131_072), EthGas.maxInitcodeSize(.amsterdam));
    try std.testing.expectEqual(@as(u64, 7_424), Ethereum.transaction.accessListDataCost(.{ .addresses = 1, .storage_keys = 3 }));
    const storage_keys = [_]u256{ 1, 2, 3 };
    try std.testing.expectEqual(AccessListCounts{
        .addresses = 2,
        .storage_keys = 3,
    }, accessListCounts(&.{
        .{ .address = @import("../address.zig").addr(0xaaaa), .storage_keys = storage_keys[0..2] },
        .{ .address = @import("../address.zig").addr(0xbbbb), .storage_keys = storage_keys[2..] },
    }));
}

test "transaction gas plan computes executable gas after intrinsic and floor costs" {
    const EthGas = For(@import("../eth.zig"));
    const istanbul = EthGas.gasPlan(.istanbul, &.{ 0, 1 }, 100_000, .{});
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 0), istanbul.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.minimum_gas);
    try std.testing.expectEqual(@as(u64, 78_980), istanbul.execution.?.regular_left);

    const prague_floor = EthGas.gasPlan(.prague, &.{ 1, 1, 1, 1 }, 21_100, .{});
    try std.testing.expectEqual(@as(u64, 21_064), prague_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.minimum_gas);
    try std.testing.expectEqual(null, prague_floor.execution);

    const amsterdam_floor = EthGas.gasPlan(.amsterdam, &.{ 1, 1, 1, 1 }, 15_200, .{});
    try std.testing.expectEqual(@as(u64, 15_064), amsterdam_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 12_256), amsterdam_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 15_064), amsterdam_floor.minimum_gas);
    try std.testing.expectEqual(@as(u64, 136), amsterdam_floor.execution.?.regular_left);

    const amsterdam_access_list = EthGas.gasPlan(.amsterdam, &.{ 0, 1 }, 100_000, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 3,
    } });
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 19_552), amsterdam_access_list.floor_gas);
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.minimum_gas);
    try std.testing.expectEqual(@as(u64, 65_556), amsterdam_access_list.execution.?.regular_left);

    const prague_authorization = EthGas.gasPlan(.prague, &.{}, 100_000, .{ .authorization_count = 1 });
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_000), prague_authorization.floor_gas);
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.minimum_gas);
    try std.testing.expectEqual(@as(u64, 54_000), prague_authorization.execution.?.regular_left);
}

test "transaction gas plan uses comptime protocol" {
    const CustomRevision = enum { custom };
    const CustomProtocol = struct {
        pub const Revision = CustomRevision;

        pub const Transaction = struct {
            pub fn intrinsicBaseGas(revision: Revision, options: IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = options;
                return 5;
            }

            pub fn createIntrinsicGas(revision: Revision) ?u64 {
                _ = revision;
                return 7;
            }

            pub fn dataByteGas(revision: Revision, byte: u8) u64 {
                _ = revision;
                return if (byte == 0) 2 else 3;
            }

            pub fn accessListAddressGas(revision: Revision) u64 {
                _ = revision;
                return 11;
            }

            pub fn storageKeyGas(revision: Revision) u64 {
                _ = revision;
                return 13;
            }

            pub fn accessListDataGas(revision: Revision, counts: AccessListCounts) ?u64 {
                _ = revision;
                return @as(u64, @intCast(counts.addresses + counts.storage_keys));
            }

            pub fn initCodeWordGas(revision: Revision) u64 {
                _ = revision;
                return 17;
            }

            pub fn authorizationIntrinsicGas(revision: Revision) u64 {
                _ = revision;
                return 19;
            }

            pub fn intrinsicStateGas(revision: Revision, options: IntrinsicGasOptions) ?u64 {
                _ = revision;
                return @as(u64, @intCast(options.authorization_count)) + 23;
            }

            pub fn floorGas(revision: Revision, input: []const u8, options: IntrinsicGasOptions) ?u64 {
                _ = revision;
                _ = input;
                _ = options;
                return 31;
            }

            pub fn regularGasLimit(revision: Revision, gas_limit: u64) u64 {
                _ = revision;
                return @min(gas_limit, 50);
            }
        };
    };

    const CustomGas = For(CustomProtocol);
    const plan = CustomGas.gasPlan(.custom, &.{ 0, 1 }, 100, .{
        .authorization_count = 2,
        .access_list_counts = .{ .addresses = 1, .storage_keys = 2 },
        .is_create = true,
    });

    try std.testing.expectEqual(@as(u64, 137), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 112), plan.intrinsic_regular_gas);
    try std.testing.expectEqual(@as(u64, 25), plan.intrinsic_state_gas);
    try std.testing.expectEqual(@as(u64, 31), plan.floor_gas);
    try std.testing.expectEqual(null, plan.execution);
}

test "Amsterdam gas plan executes only capped regular gas" {
    const Ethereum = @import("../eth.zig");
    const plan = For(Ethereum).gasPlan(.amsterdam, &.{}, 120_000_000, .{});
    try std.testing.expectEqual(@as(u64, 15_000), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, Ethereum.transaction.max_transaction_gas_limit - 15_000), plan.execution.?.regular_left);
    try std.testing.expectEqual(@as(u64, 120_000_000 - Ethereum.transaction.max_transaction_gas_limit), plan.execution.?.reservoir);
}

test "Amsterdam create gas plan splits regular and state intrinsic gas" {
    const plan = For(@import("../eth.zig")).gasPlan(.amsterdam, &([_]u8{1} ** 4059), 271_798, .{ .is_create = true });
    try std.testing.expectEqual(@as(u64, 271_798), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 88_198), plan.intrinsic_regular_gas);
    try std.testing.expectEqual(@as(u64, 183_600), plan.intrinsic_state_gas);
    try std.testing.expectEqual(@as(u64, 0), plan.execution.?.regular_left);
}
