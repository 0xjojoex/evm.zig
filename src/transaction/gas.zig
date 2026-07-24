const std = @import("std");
const ExactSpec = @import("../spec.zig").Spec;
const ExecutionGas = @import("../execution/gas.zig").ExecutionGas;
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

/// Facts used to derive the transaction input-data floor.
///
/// Keeping this as one named value lets future transaction families add
/// floor-relevant facts without changing the exact-spec function signature.
pub const FloorGasInput = struct {
    input: []const u8,
    options: IntrinsicGasOptions = .{},
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
/// `regular` is charged before execution. `floor` is not charged upfront; it
/// is applied at settlement after refunds. State gas begins in the runtime
/// transaction program because its charge depends on reached account state.
pub const InitialGas = struct {
    regular: u64,
    floor: u64 = 0,

    pub fn minimum(self: InitialGas) u64 {
        return @max(self.regular, self.floor);
    }
};

/// Initial execution gas state for the interpreter.
///
/// `regular_left` is the value visible to the `GAS` opcode. `reservoir` is the
/// extra transaction gas reserved for Amsterdam state-gas charges.
pub const GasPlan = struct {
    intrinsic_gas: u64,
    floor_gas: u64,
    minimum_gas: u64,
    initial_gas: InitialGas,
    execution: ?ExecutionGas,
};

/// Stateless gas planner closed over one exact VM specification.
pub fn Runtime(comptime spec: ExactSpec) type {
    return struct {
        pub const specification = spec;
        const Self = @This();
        const transaction = spec.transaction;

        pub fn intrinsicGas(self: Self, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
            return self.intrinsicGasForTransaction(input, .{
                .authorization_count = authorization_count,
                .access_list_counts = access_list_counts,
            });
        }

        pub fn maxInitcodeSize(_: Self) usize {
            return transaction.max_initcode_size;
        }

        pub fn intrinsicGasForTransaction(_: Self, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            var gas: u64 = transaction.intrinsicBaseGas(options) orelse return null;
            if (options.is_create) {
                gas = std.math.add(u64, gas, transaction.create_intrinsic_gas) catch return null;
            }
            gas = std.math.add(u64, gas, transaction.calldataGas(input) orelse return null) catch return null;
            if (options.access_list_counts.addresses != 0) {
                const count = std.math.cast(u64, options.access_list_counts.addresses) orelse return null;
                const cost = std.math.mul(u64, count, transaction.access_list_address_gas) catch return null;
                gas = std.math.add(u64, gas, cost) catch return null;
            }
            if (options.access_list_counts.storage_keys != 0) {
                const count = std.math.cast(u64, options.access_list_counts.storage_keys) orelse return null;
                const cost = std.math.mul(u64, count, transaction.storage_key_gas) catch return null;
                gas = std.math.add(u64, gas, cost) catch return null;
            }
            gas = std.math.add(u64, gas, transaction.accessListDataGas(options.access_list_counts) orelse return null) catch return null;
            if (options.is_create) {
                const initcode_word_charge = transaction.initcode_word_gas;
                if (initcode_word_charge != 0) {
                    const words = std.math.cast(u64, wordCount(input.len)) orelse return null;
                    const initcode_cost = std.math.mul(u64, words, initcode_word_charge) catch return null;
                    gas = std.math.add(u64, gas, initcode_cost) catch return null;
                }
            }
            if (options.authorization_count != 0) {
                const count = std.math.cast(u64, options.authorization_count) orelse return null;
                const cost = std.math.mul(u64, count, transaction.authorization_intrinsic_gas) catch return null;
                gas = std.math.add(u64, gas, cost) catch return null;
            }
            return gas;
        }

        pub fn intrinsicBaseGas(_: Self, options: IntrinsicGasOptions) ?u64 {
            return transaction.intrinsicBaseGas(options);
        }

        pub fn gasPlan(self: Self, input: []const u8, gas_limit: u64, options: IntrinsicGasOptions) GasPlan {
            const intrinsic_gas = self.intrinsicGasForTransaction(input, options) orelse std.math.maxInt(u64);
            const floor_gas = self.floorGasForTransaction(input, options) orelse 0;
            const initial_gas = InitialGas{
                .regular = intrinsic_gas,
                .floor = floor_gas,
            };
            const minimum_gas = initial_gas.minimum();
            const regular_gas_limit = self.regularGasLimit(gas_limit);
            const execution = if (gas_limit >= minimum_gas and regular_gas_limit >= intrinsic_gas) blk: {
                const execution_total = gas_limit - intrinsic_gas;
                const regular_budget = regular_gas_limit - intrinsic_gas;
                const regular_left = @min(execution_total, regular_budget);
                break :blk ExecutionGas{
                    .regular_left = regular_left,
                    .reservoir = execution_total - regular_left,
                };
            } else null;
            return .{
                .intrinsic_gas = intrinsic_gas,
                .floor_gas = floor_gas,
                .minimum_gas = minimum_gas,
                .initial_gas = initial_gas,
                .execution = execution,
            };
        }

        pub fn regularGasLimit(_: Self, gas_limit: u64) u64 {
            const cap = transaction.regular_gas_cap orelse return gas_limit;
            return @min(gas_limit, cap);
        }

        pub fn minimumGas(self: Self, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
            return self.minimumGasForTransaction(input, .{
                .authorization_count = authorization_count,
                .access_list_counts = access_list_counts,
            });
        }

        pub fn minimumGasForTransaction(self: Self, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            const intrinsic = self.intrinsicGasForTransaction(input, options) orelse return null;
            const floor = self.floorGasForTransaction(input, options) orelse return intrinsic;
            return @max(intrinsic, floor);
        }

        pub fn floorGas(self: Self, input: []const u8) ?u64 {
            return self.floorGasForTransaction(input, .{});
        }

        pub fn floorGasForTransaction(_: Self, input: []const u8, options: IntrinsicGasOptions) ?u64 {
            return transaction.floorGas(.{
                .input = input,
                .options = options,
            });
        }
    };
}

fn runtime(comptime spec: ExactSpec) Runtime(spec) {
    return .{};
}

pub fn accessListCounts(access_list: []const AccessListEntry) AccessListCounts {
    var result = AccessListCounts{};
    result.addresses = access_list.len;
    for (access_list) |entry| {
        result.storage_keys += entry.storage_keys.len;
    }
    return result;
}

pub fn countZeroBytes(bytes: []const u8) u64 {
    var count: u64 = 0;
    for (bytes) |byte| count += @intFromBool(byte == 0);
    return count;
}

fn wordCount(len: usize) usize {
    return (len + 31) / 32;
}

test "transaction gas helpers" {
    const eth = @import("../eth.zig");
    const Frontier = runtime(eth.frontier);
    const Homestead = runtime(eth.homestead);
    const Byzantium = runtime(eth.byzantium);
    const Istanbul = runtime(eth.istanbul);
    const Berlin = runtime(eth.berlin);
    const London = runtime(eth.london);
    const Shanghai = runtime(eth.shanghai);
    const Prague = runtime(eth.prague);
    const Osaka = runtime(eth.osaka);
    const Amsterdam = runtime(eth.amsterdam);

    try std.testing.expectEqual(@as(u64, 21_072), Byzantium.intrinsicGas(&.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_020), Istanbul.intrinsicGas(&.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), Prague.intrinsicGas(&.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 29_120), Berlin.intrinsicGas(&.{ 0, 1 }, 0, .{
        .addresses = 1,
        .storage_keys = 3,
    }));
    try std.testing.expectEqual(@as(u64, 5), eth.transaction.calldataTokenCount(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 21_020), Istanbul.minimumGas(&.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_050), Prague.minimumGas(&.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 15_128), Amsterdam.minimumGas(&.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), Prague.minimumGas(&.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 21_008), Frontier.intrinsicGasForTransaction(&.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_008), Homestead.intrinsicGasForTransaction(&.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_010), Shanghai.intrinsicGasForTransaction(&.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 23_010), Amsterdam.intrinsicGasForTransaction(&.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 88_198), Amsterdam.intrinsicGasForTransaction(&([_]u8{1} ** 4059), .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 12_000), Amsterdam.intrinsicBaseGas(.{ .is_self_transfer = true }));
    try std.testing.expectEqual(@as(u64, 15_000), Amsterdam.intrinsicBaseGas(.{}));
    try std.testing.expectEqual(@as(u64, 21_000), Amsterdam.intrinsicBaseGas(.{ .value = 1 }));
    try std.testing.expectEqual(@as(u64, 21_000), Amsterdam.intrinsicGasForTransaction(&.{}, .{
        .value = 1,
        .creates_account = true,
    }));
    try std.testing.expectEqual(@as(u64, 23_000), Amsterdam.intrinsicBaseGas(.{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 24_756), Amsterdam.intrinsicBaseGas(.{ .is_create = true, .value = 1 }));
    try std.testing.expectEqual(@as(u64, 24_328), Amsterdam.intrinsicGasForTransaction(&.{}, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 1,
    } }));
    try std.testing.expectEqual(@as(u64, 22_816), Amsterdam.intrinsicGasForTransaction(&.{}, .{ .authorization_count = 1 }));
    try std.testing.expectEqual(@as(u64, 32_144), Amsterdam.intrinsicGasForTransaction(&.{}, .{
        .authorization_count = 1,
        .access_list_counts = .{
            .addresses = 1,
            .storage_keys = 1,
        },
    }));
    try std.testing.expectEqual(std.math.maxInt(usize), London.maxInitcodeSize());
    try std.testing.expectEqual(@as(usize, 49_152), Osaka.maxInitcodeSize());
    try std.testing.expectEqual(@as(usize, 131_072), Amsterdam.maxInitcodeSize());
    try std.testing.expectEqual(@as(u64, 7_424), eth.transaction.accessListDataCost(.{ .addresses = 1, .storage_keys = 3 }));
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
    const eth = @import("../eth.zig");
    const Istanbul = runtime(eth.istanbul);
    const Prague = runtime(eth.prague);
    const Amsterdam = runtime(eth.amsterdam);
    const istanbul = Istanbul.gasPlan(&.{ 0, 1 }, 100_000, .{});
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 0), istanbul.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.minimum_gas);
    try std.testing.expectEqual(@as(u64, 78_980), istanbul.execution.?.regular_left);

    const prague_floor = Prague.gasPlan(&.{ 1, 1, 1, 1 }, 21_100, .{});
    try std.testing.expectEqual(@as(u64, 21_064), prague_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.minimum_gas);
    try std.testing.expectEqual(null, prague_floor.execution);

    const amsterdam_floor = Amsterdam.gasPlan(&.{ 1, 1, 1, 1 }, 16_000, .{});
    try std.testing.expectEqual(@as(u64, 15_064), amsterdam_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 15_256), amsterdam_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 15_256), amsterdam_floor.minimum_gas);
    try std.testing.expectEqual(@as(u64, 936), amsterdam_floor.execution.?.regular_left);

    const amsterdam_access_list = Amsterdam.gasPlan(&.{ 0, 1 }, 100_000, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 3,
    } });
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 22_552), amsterdam_access_list.floor_gas);
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.minimum_gas);
    try std.testing.expectEqual(@as(u64, 65_556), amsterdam_access_list.execution.?.regular_left);

    const prague_authorization = Prague.gasPlan(&.{}, 100_000, .{ .authorization_count = 1 });
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_000), prague_authorization.floor_gas);
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.minimum_gas);
    try std.testing.expectEqual(@as(u64, 54_000), prague_authorization.execution.?.regular_left);
}

test "transaction gas plan uses an extended exact spec" {
    const custom = struct {
        fn intrinsicBaseGas(_: IntrinsicGasOptions) ?u64 {
            return 5;
        }

        fn calldataGas(input: []const u8) ?u64 {
            var result: u64 = 0;
            for (input) |byte| {
                result = std.math.add(u64, result, if (byte == 0) 2 else 3) catch return null;
            }
            return result;
        }

        fn accessListDataGas(counts: AccessListCounts) ?u64 {
            return @as(u64, @intCast(counts.addresses + counts.storage_keys));
        }

        fn floorGas(_: FloorGasInput) ?u64 {
            return 31;
        }
    };
    const custom_spec = @import("../eth/spec.zig").frontier.extend(.{ .transaction = .{
        .max_initcode_size = std.math.maxInt(usize),
        .create_intrinsic_gas = 7,
        .access_list_address_gas = 11,
        .storage_key_gas = 13,
        .initcode_word_gas = 17,
        .authorization_intrinsic_gas = 19,
        .intrinsicBaseGas = custom.intrinsicBaseGas,
        .calldataGas = custom.calldataGas,
        .accessListDataGas = custom.accessListDataGas,
        .floorGas = custom.floorGas,
        .regular_gas_cap = .{ .replace = 50 },
    } });
    const CustomGas = runtime(custom_spec);
    const plan = CustomGas.gasPlan(&.{ 0, 1 }, 100, .{
        .authorization_count = 2,
        .access_list_counts = .{ .addresses = 1, .storage_keys = 2 },
        .is_create = true,
    });

    try std.testing.expectEqual(@as(u64, 112), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 31), plan.floor_gas);
    try std.testing.expectEqual(null, plan.execution);
}

test "Amsterdam gas plan executes only capped regular gas" {
    const eth = @import("../eth.zig");
    const Amsterdam = runtime(eth.amsterdam);
    const plan = Amsterdam.gasPlan(&.{}, 120_000_000, .{});
    try std.testing.expectEqual(@as(u64, 15_000), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, eth.transaction.max_transaction_gas_limit - 15_000), plan.execution.?.regular_left);
    try std.testing.expectEqual(@as(u64, 120_000_000 - eth.transaction.max_transaction_gas_limit), plan.execution.?.reservoir);
}

test "Amsterdam calldata floor includes only decomposed regular transaction primitives" {
    const Amsterdam = runtime(@import("../eth.zig").amsterdam);
    const input = [_]u8{1} ** 4059;
    const plan = Amsterdam.gasPlan(&input, 282_776, .{ .is_create = true });
    try std.testing.expectEqual(@as(u64, 88_198), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 282_776), plan.floor_gas);
    try std.testing.expectEqual(@as(u64, 194_578), plan.execution.?.regular_left);

    const value_and_authorization_floor = Amsterdam.floorGasForTransaction(&input, .{
        .value = 1,
        .authorization_count = 1,
    });
    try std.testing.expectEqual(@as(?u64, 280_776), value_and_authorization_floor);

    const self_transfer_floor = Amsterdam.floorGasForTransaction(&input, .{
        .value = 1,
        .is_self_transfer = true,
    });
    try std.testing.expectEqual(@as(?u64, 271_776), self_transfer_floor);

    const access_list_floor = Amsterdam.floorGasForTransaction(&input, .{
        .access_list_counts = .{ .addresses = 1, .storage_keys = 1 },
    });
    try std.testing.expectEqual(@as(?u64, 278_104), access_list_floor);
}
