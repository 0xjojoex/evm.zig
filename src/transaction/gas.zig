const std = @import("std");
const Transaction = @import("./Transaction.zig");
const Spec = @import("../spec.zig").Spec;

pub const authorization_intrinsic_gas: u64 = 25_000;
pub const authorization_existing_account_refund_gas: u64 = 12_500;
pub const amsterdam_cost_per_state_byte: u64 = 1_530;
pub const amsterdam_state_bytes_per_new_account: u64 = 120;
pub const amsterdam_state_bytes_per_auth_base: u64 = 23;
pub const amsterdam_state_bytes_per_storage_set: u64 = 64;
pub const amsterdam_account_write_cost: u64 = 8_000;
pub const amsterdam_storage_write_cost: u64 = 10_000;
pub const amsterdam_storage_clear_refund: u64 = 12_480;
pub const amsterdam_cold_storage_access_cost: u64 = 3_000;
pub const call_stipend: u64 = 2_300;
pub const amsterdam_call_value_cost: u64 = amsterdam_account_write_cost + call_stipend;
pub const amsterdam_code_deposit_word_cost: u64 = 6;
pub const amsterdam_regular_per_auth_base_cost: u64 = 7_816;
pub const amsterdam_auth_base_state_gas: u64 = amsterdam_state_bytes_per_auth_base * amsterdam_cost_per_state_byte;
pub const amsterdam_authorization_state_gas: u64 = amsterdam_new_account_state_gas + amsterdam_auth_base_state_gas;
pub const amsterdam_authorization_intrinsic_gas: u64 =
    amsterdam_account_write_cost +
    amsterdam_regular_per_auth_base_cost +
    amsterdam_authorization_state_gas;
pub const access_list_address_gas: u64 = 2_400;
pub const access_list_storage_key_gas: u64 = 1_900;
pub const amsterdam_access_list_address_gas: u64 = 3_000;
pub const amsterdam_access_list_storage_key_gas: u64 = 3_000;
pub const access_list_address_data_gas: u64 = 1_280;
pub const access_list_storage_key_data_gas: u64 = 2_048;
pub const create_transaction_gas: u64 = 32_000;
pub const amsterdam_tx_base_cost: u64 = 12_000;
pub const amsterdam_cold_account_access_cost: u64 = 3_000;
pub const amsterdam_create_access_cost: u64 = 11_000;
pub const amsterdam_tx_value_cost: u64 = 4_244;
pub const amsterdam_transfer_log_cost: u64 = 1_756;
pub const amsterdam_new_account_state_gas: u64 = 183_600;
pub const amsterdam_storage_set_state_gas: u64 = amsterdam_state_bytes_per_storage_set * amsterdam_cost_per_state_byte;
pub const initcode_word_gas: u64 = 2;
pub const max_initcode_size: usize = 49_152;
pub const amsterdam_max_initcode_size: usize = 131_072;
pub const max_transaction_gas_limit: u64 = 16_777_216;

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
    /// TODO(amsterdam): remove after call sites migrate to `execution`.
    /// Compatibility view for older call sites. New code should use `execution`.
    execution_gas: ?u64,
};

pub fn intrinsicGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return intrinsicGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn maxInitcodeSize(spec: Spec) usize {
    return if (spec.isImpl(.amsterdam)) amsterdam_max_initcode_size else max_initcode_size;
}

pub fn intrinsicGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    const regular_gas = intrinsicRegularGasForTransaction(spec, input, options) orelse return null;
    const state_gas = intrinsicStateGasForTransaction(spec, options) orelse return null;
    return std.math.add(u64, regular_gas, state_gas) catch return null;
}

pub fn intrinsicRegularGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    var gas: u64 = intrinsicBaseGas(spec, options) orelse return null;
    if (options.is_create and spec.isImpl(.homestead) and !spec.isImpl(.amsterdam)) {
        gas = std.math.add(u64, gas, create_transaction_gas) catch return null;
    }
    const non_zero_byte_cost: u64 = if (spec.isImpl(.istanbul)) 16 else 68;
    for (input) |byte| {
        const byte_cost: u64 = if (byte == 0) 4 else non_zero_byte_cost;
        gas = std.math.add(u64, gas, byte_cost) catch return null;
    }
    const access_list_address_count = std.math.cast(u64, options.access_list_counts.addresses) orelse return null;
    const access_list_storage_key_count = std.math.cast(u64, options.access_list_counts.storage_keys) orelse return null;
    const address_gas = if (spec.isImpl(.amsterdam)) amsterdam_access_list_address_gas else access_list_address_gas;
    const storage_key_gas = if (spec.isImpl(.amsterdam)) amsterdam_access_list_storage_key_gas else access_list_storage_key_gas;
    const access_list_address_cost = std.math.mul(u64, access_list_address_count, address_gas) catch return null;
    const access_list_storage_key_cost = std.math.mul(u64, access_list_storage_key_count, storage_key_gas) catch return null;
    gas = std.math.add(u64, gas, access_list_address_cost) catch return null;
    gas = std.math.add(u64, gas, access_list_storage_key_cost) catch return null;
    if (spec.isImpl(.amsterdam)) {
        gas = std.math.add(u64, gas, accessListDataCost(options.access_list_counts) orelse return null) catch return null;
    }
    if (options.is_create and spec.isImpl(.shanghai)) {
        const words = std.math.cast(u64, wordCount(input.len)) orelse return null;
        const initcode_cost = std.math.mul(u64, words, initcode_word_gas) catch return null;
        gas = std.math.add(u64, gas, initcode_cost) catch return null;
    }
    if (spec.isImpl(.prague)) {
        const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
        const auth_gas = if (spec.isImpl(.amsterdam))
            amsterdam_account_write_cost + amsterdam_regular_per_auth_base_cost
        else
            authorization_intrinsic_gas;
        const auth_cost = std.math.mul(u64, auth_count, auth_gas) catch return null;
        gas = std.math.add(u64, gas, auth_cost) catch return null;
    }
    return gas;
}

pub fn intrinsicStateGasForTransaction(spec: Spec, options: IntrinsicGasOptions) ?u64 {
    if (!spec.isImpl(.amsterdam)) return 0;

    var gas: u64 = 0;
    if (options.is_create) {
        gas = std.math.add(u64, gas, amsterdam_new_account_state_gas) catch return null;
    }
    const auth_count = std.math.cast(u64, options.authorization_count) orelse return null;
    gas = std.math.add(u64, gas, std.math.mul(u64, auth_count, amsterdam_authorization_state_gas) catch return null) catch return null;
    return gas;
}

pub fn intrinsicBaseGas(spec: Spec, options: IntrinsicGasOptions) ?u64 {
    if (!spec.isImpl(.amsterdam)) return 21_000;

    var gas: u64 = amsterdam_tx_base_cost;
    if (options.is_create) {
        gas = std.math.add(u64, gas, amsterdam_create_access_cost) catch return null;
    } else if (!options.is_self_transfer) {
        gas = std.math.add(u64, gas, amsterdam_cold_account_access_cost) catch return null;
    }

    if (options.value != 0 and !options.is_self_transfer) {
        gas = std.math.add(u64, gas, amsterdam_transfer_log_cost) catch return null;
        if (!options.is_create) {
            gas = std.math.add(u64, gas, amsterdam_tx_value_cost) catch return null;
        }
    }
    return gas;
}

pub fn accessListCounts(access_list: []const AccessListEntry) AccessListCounts {
    var result = AccessListCounts{};
    result.addresses = access_list.len;
    for (access_list) |entry| {
        result.storage_keys += entry.storage_keys.len;
    }
    return result;
}

pub fn gasPlan(spec: Spec, input: []const u8, gas_limit: u64, options: IntrinsicGasOptions) GasPlan {
    const intrinsic_regular_gas = intrinsicRegularGasForTransaction(spec, input, options) orelse std.math.maxInt(u64);
    const intrinsic_state_gas = intrinsicStateGasForTransaction(spec, options) orelse std.math.maxInt(u64);
    const floor_gas = if (spec.isImpl(.prague)) floorGasForTransaction(spec, input, options) orelse std.math.maxInt(u64) else 0;
    const initial_gas = InitialGas{
        .regular = intrinsic_regular_gas,
        .state = intrinsic_state_gas,
        .floor = floor_gas,
    };
    const intrinsic_gas = initial_gas.total() orelse std.math.maxInt(u64);
    const minimum_gas = initial_gas.minimum() orelse std.math.maxInt(u64);
    const regular_gas_limit = regularGasLimit(spec, gas_limit);
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
        .execution_gas = if (execution) |gas| gas.regular_left else null,
    };
}

pub fn regularGasLimit(spec: Spec, gas_limit: u64) u64 {
    return if (spec.isImpl(.osaka)) @min(gas_limit, max_transaction_gas_limit) else gas_limit;
}

pub fn minimumGas(spec: Spec, input: []const u8, authorization_count: usize, access_list_counts: AccessListCounts) ?u64 {
    return minimumGasForTransaction(spec, input, .{
        .authorization_count = authorization_count,
        .access_list_counts = access_list_counts,
    });
}

pub fn minimumGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    const intrinsic = intrinsicGasForTransaction(spec, input, options) orelse return null;
    if (!spec.isImpl(.prague)) return intrinsic;

    const floor = floorGasForTransaction(spec, input, options) orelse return null;
    return @max(intrinsic, floor);
}

pub fn floorGas(spec: Spec, input: []const u8) ?u64 {
    return floorGasForTransaction(spec, input, .{});
}

pub fn floorGasForTransaction(spec: Spec, input: []const u8, options: IntrinsicGasOptions) ?u64 {
    if (!spec.isImpl(.prague)) return null;
    const floor_data_cost = if (spec.isImpl(.amsterdam)) blk: {
        const bytes = std.math.cast(u64, input.len) orelse return null;
        const floor_tokens = std.math.mul(u64, bytes, 4) catch return null;
        break :blk std.math.mul(u64, floor_tokens, 16) catch return null;
    } else blk: {
        const tokens = calldataTokenCount(input) orelse return null;
        break :blk std.math.mul(u64, tokens, 10) catch return null;
    };
    const floor_base_gas = if (spec.isImpl(.amsterdam)) amsterdam_tx_base_cost else 21_000;
    var gas = std.math.add(u64, floor_base_gas, floor_data_cost) catch return null;
    if (spec.isImpl(.amsterdam)) {
        gas = std.math.add(u64, gas, accessListDataCost(options.access_list_counts) orelse return null) catch return null;
    }
    return gas;
}

pub fn calldataTokenCount(input: []const u8) ?u64 {
    var tokens: u64 = 0;
    for (input) |byte| {
        const byte_tokens: u64 = if (byte == 0) 1 else 4;
        tokens = std.math.add(u64, tokens, byte_tokens) catch return null;
    }
    return tokens;
}

pub fn accessListDataCost(counts: AccessListCounts) ?u64 {
    const address_count = std.math.cast(u64, counts.addresses) orelse return null;
    const storage_key_count = std.math.cast(u64, counts.storage_keys) orelse return null;
    const address_cost = std.math.mul(u64, address_count, access_list_address_data_gas) catch return null;
    const storage_key_cost = std.math.mul(u64, storage_key_count, access_list_storage_key_data_gas) catch return null;
    return std.math.add(u64, address_cost, storage_key_cost) catch return null;
}

fn wordCount(len: usize) usize {
    return (len + 31) / 32;
}

test "transaction gas helpers" {
    try std.testing.expectEqual(@as(u64, 21_072), intrinsicGas(.byzantium, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_020), intrinsicGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), intrinsicGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 29_120), intrinsicGas(.berlin, &.{ 0, 1 }, 0, .{
        .addresses = 1,
        .storage_keys = 3,
    }));
    try std.testing.expectEqual(@as(u64, 5), calldataTokenCount(&.{ 0, 1 }));
    try std.testing.expectEqual(@as(u64, 21_020), minimumGas(.istanbul, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 21_050), minimumGas(.prague, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 15_020), minimumGas(.amsterdam, &.{ 0, 1 }, 0, .{}));
    try std.testing.expectEqual(@as(u64, 46_020), minimumGas(.prague, &.{ 0, 1 }, 1, .{}));
    try std.testing.expectEqual(@as(u64, 21_008), intrinsicGasForTransaction(.frontier, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_008), intrinsicGasForTransaction(.homestead, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 53_010), intrinsicGasForTransaction(.shanghai, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 206_610), intrinsicGasForTransaction(.amsterdam, &.{ 0, 0 }, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 271_798), intrinsicGasForTransaction(.amsterdam, &([_]u8{1} ** 4059), .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 88_198), intrinsicRegularGasForTransaction(.amsterdam, &([_]u8{1} ** 4059), .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 183_600), intrinsicStateGasForTransaction(.amsterdam, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 12_000), intrinsicBaseGas(.amsterdam, .{ .is_self_transfer = true }));
    try std.testing.expectEqual(@as(u64, 15_000), intrinsicBaseGas(.amsterdam, .{}));
    try std.testing.expectEqual(@as(u64, 21_000), intrinsicBaseGas(.amsterdam, .{ .value = 1 }));
    try std.testing.expectEqual(@as(u64, 21_000), intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .value = 1,
        .creates_account = true,
    }));
    try std.testing.expectEqual(@as(u64, 0), intrinsicStateGasForTransaction(.amsterdam, .{
        .value = 1,
        .creates_account = true,
    }));
    try std.testing.expectEqual(@as(u64, 23_000), intrinsicBaseGas(.amsterdam, .{ .is_create = true }));
    try std.testing.expectEqual(@as(u64, 24_756), intrinsicBaseGas(.amsterdam, .{ .is_create = true, .value = 1 }));
    try std.testing.expectEqual(@as(u64, 24_328), intrinsicGasForTransaction(.amsterdam, &.{}, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 1,
    } }));
    try std.testing.expectEqual(@as(u64, 249_606), intrinsicGasForTransaction(.amsterdam, &.{}, .{ .authorization_count = 1 }));
    try std.testing.expectEqual(@as(u64, 258_934), intrinsicGasForTransaction(.amsterdam, &.{}, .{
        .authorization_count = 1,
        .access_list_counts = .{
            .addresses = 1,
            .storage_keys = 1,
        },
    }));
    try std.testing.expectEqual(@as(usize, 49_152), maxInitcodeSize(.osaka));
    try std.testing.expectEqual(@as(usize, 131_072), maxInitcodeSize(.amsterdam));
    try std.testing.expectEqual(@as(u64, 7_424), accessListDataCost(.{ .addresses = 1, .storage_keys = 3 }));
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
    const istanbul = gasPlan(.istanbul, &.{ 0, 1 }, 100_000, .{});
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 0), istanbul.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_020), istanbul.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 78_980), istanbul.execution_gas);

    const prague_floor = gasPlan(.prague, &.{ 1, 1, 1, 1 }, 21_100, .{});
    try std.testing.expectEqual(@as(u64, 21_064), prague_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 21_160), prague_floor.minimum_gas);
    try std.testing.expectEqual(@as(?u64, null), prague_floor.execution_gas);

    const amsterdam_floor = gasPlan(.amsterdam, &.{ 1, 1, 1, 1 }, 15_200, .{});
    try std.testing.expectEqual(@as(u64, 15_064), amsterdam_floor.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 12_256), amsterdam_floor.floor_gas);
    try std.testing.expectEqual(@as(u64, 15_064), amsterdam_floor.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 136), amsterdam_floor.execution_gas);

    const amsterdam_access_list = gasPlan(.amsterdam, &.{ 0, 1 }, 100_000, .{ .access_list_counts = .{
        .addresses = 1,
        .storage_keys = 3,
    } });
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 19_552), amsterdam_access_list.floor_gas);
    try std.testing.expectEqual(@as(u64, 34_444), amsterdam_access_list.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 65_556), amsterdam_access_list.execution_gas);

    const prague_authorization = gasPlan(.prague, &.{}, 100_000, .{ .authorization_count = 1 });
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 21_000), prague_authorization.floor_gas);
    try std.testing.expectEqual(@as(u64, 46_000), prague_authorization.minimum_gas);
    try std.testing.expectEqual(@as(?u64, 54_000), prague_authorization.execution_gas);
}

test "Amsterdam gas plan executes only capped regular gas" {
    const plan = gasPlan(.amsterdam, &.{}, 120_000_000, .{});
    try std.testing.expectEqual(@as(u64, 15_000), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(?u64, max_transaction_gas_limit - 15_000), plan.execution_gas);
    try std.testing.expectEqual(@as(u64, 120_000_000 - max_transaction_gas_limit), plan.execution.?.reservoir);
}

test "Amsterdam create gas plan splits regular and state intrinsic gas" {
    const plan = gasPlan(.amsterdam, &([_]u8{1} ** 4059), 271_798, .{ .is_create = true });
    try std.testing.expectEqual(@as(u64, 271_798), plan.intrinsic_gas);
    try std.testing.expectEqual(@as(u64, 88_198), plan.intrinsic_regular_gas);
    try std.testing.expectEqual(@as(u64, 183_600), plan.intrinsic_state_gas);
    try std.testing.expectEqual(@as(?u64, 0), plan.execution_gas);
}
