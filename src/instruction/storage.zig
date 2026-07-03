const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const instruction = evmz.instruction;
const Host = evmz.Host;
const std = @import("std");
const tx_gas = @import("../transaction/gas.zig");

const CallFrame = Interpreter.CallFrame;

/// https://evmc.ethereum.org/storagestatus.html
///
const StorageCost = struct {
    cost: i16,
    refund: i16,

    const ActionCost = struct {
        warm_access: i16,
        set: i16,
        reset: i16,
        clear: i16,
    };

    fn getCost(spec: evmz.Spec, status: Host.StorageStatus) @This() {
        if (spec.isImpl(.amsterdam)) {
            const storage_write: i16 = @intCast(tx_gas.amsterdam_storage_write_cost);
            const clear_refund: i16 = @intCast(tx_gas.amsterdam_storage_clear_refund);
            return switch (status) {
                .assigned => .{ .cost = 0, .refund = 0 },
                .added, .modified => .{ .cost = storage_write, .refund = 0 },
                .deleted => .{ .cost = storage_write, .refund = clear_refund },
                .deleted_added => .{ .cost = 0, .refund = -clear_refund },
                .modified_deleted => .{ .cost = 0, .refund = clear_refund },
                .deleted_restored => .{ .cost = 0, .refund = storage_write - clear_refund },
                .added_deleted, .modified_restored => .{ .cost = 0, .refund = storage_write },
            };
        }

        const action = blk: {
            var actionCost = ActionCost{
                .warm_access = 200,
                .set = 20000,
                .reset = 5000,
                .clear = 15000,
            };

            if (spec.isImpl(.istanbul)) {
                actionCost.warm_access = 800;
            }

            if (spec.isImpl(.berlin)) {
                actionCost.warm_access = instruction.warm_storage_read_cost;
                actionCost.reset = 5000 - instruction.cold_sload_cost;
            }

            if (spec.isImpl(.london)) {
                actionCost.clear = 4800;
            }

            break :blk actionCost;
        };

        // Petersburg disabled EIP-1283; Istanbul reintroduced net metering via EIP-2200.
        const net_gas = spec == .constantinople or spec.isImpl(.istanbul);
        if (!net_gas) {
            return switch (status) {
                .added, .deleted_added, .deleted_restored => .{ .cost = action.set, .refund = 0 },
                .deleted, .modified_deleted, .added_deleted => .{ .cost = action.reset, .refund = action.clear },
                .modified, .assigned, .modified_restored => .{ .cost = action.reset, .refund = 0 },
            };
        }

        return switch (status) {
            .assigned => .{ .cost = action.warm_access, .refund = 0 },
            .added => .{ .cost = action.set, .refund = 0 },
            .deleted => .{ .cost = action.reset, .refund = action.clear },
            .modified => .{ .cost = action.reset, .refund = 0 },
            .deleted_added => .{ .cost = action.warm_access, .refund = -action.clear },
            .modified_deleted => .{ .cost = action.warm_access, .refund = action.clear },
            .deleted_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access - action.clear },
            .added_deleted => .{ .cost = action.warm_access, .refund = action.set - action.warm_access },
            .modified_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access },
        };
    }
};

test "Petersburg disables Constantinople net SSTORE metering until Istanbul" {
    try std.testing.expectEqual(StorageCost{ .cost = 200, .refund = 4800 }, StorageCost.getCost(.constantinople, .modified_restored));
    try std.testing.expectEqual(StorageCost{ .cost = 5000, .refund = 0 }, StorageCost.getCost(.petersburg, .modified_restored));
    try std.testing.expectEqual(StorageCost{ .cost = 800, .refund = 4200 }, StorageCost.getCost(.istanbul, .modified_restored));
}

test "Amsterdam SSTORE separates access and write gas from state gas" {
    try std.testing.expectEqual(StorageCost{ .cost = 10_000, .refund = 0 }, StorageCost.getCost(.amsterdam, .added));
    try std.testing.expectEqual(StorageCost{ .cost = 0, .refund = 10_000 }, StorageCost.getCost(.amsterdam, .added_deleted));
    try std.testing.expectEqual(StorageCost{ .cost = 0, .refund = -2_480 }, StorageCost.getCost(.amsterdam, .deleted_restored));
}

pub fn sstore(frame: *CallFrame) !void {
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }
    const key, const value = try frame.stack.popN(2);

    const recipient = frame.msg.recipient;
    const host = frame.host;

    if (frame.spec.isImpl(.istanbul) and frame.gas_left <= instruction.call_stipend) {
        frame.failWithStatus(.out_of_gas);
        return;
    }

    const access_status = if (frame.spec.isImpl(.berlin)) try host.accessStorage(recipient, key) else .warm;

    if (frame.spec.isImpl(.amsterdam)) {
        const access_gas: u64 = switch (access_status) {
            .cold => tx_gas.amsterdam_cold_storage_access_cost,
            .warm => instruction.warm_storage_read_cost,
        };
        frame.trackGas(std.math.cast(i64, access_gas) orelse std.math.maxInt(i64));
        if (frame.status != .running) return;
    } else if (frame.spec.isImpl(.berlin) and access_status == .cold) {
        frame.trackGas(instruction.cold_sload_cost);
        if (frame.status != .running) return;
    }

    const status = try host.setStorage(recipient, key, value);

    const cost = StorageCost.getCost(frame.spec, status);

    frame.trackGas(cost.cost);
    if (frame.status != .running) return;
    frame.gas_refund += cost.refund;

    if (frame.spec.isImpl(.amsterdam)) {
        const state_gas = std.math.cast(i64, tx_gas.amsterdam_storage_set_state_gas) orelse std.math.maxInt(i64);
        switch (status) {
            .added => frame.trackStateGas(state_gas),
            .added_deleted => frame.refillStateGas(state_gas),
            else => {},
        }
    }
}

pub fn sload(frame: *CallFrame) !void {
    const key = try frame.stack.pop();
    const host = frame.host;
    const recipient = frame.msg.recipient;

    if (frame.spec.isImpl(.berlin) and try host.accessStorage(recipient, key) == .cold) {
        const cold_sload_gas = if (frame.spec.isImpl(.amsterdam))
            tx_gas.amsterdam_cold_storage_access_cost - instruction.warm_storage_read_cost
        else
            instruction.cold_sload_gas;
        frame.trackGas(std.math.cast(i64, cold_sload_gas) orelse std.math.maxInt(i64));
        if (frame.status != .running) return;
    }

    const value = try host.getStorage(recipient, key);
    frame.stack.pushUnchecked(value);
}

pub fn tload(frame: *CallFrame) !void {
    const key = try frame.stack.pop();
    const value = try frame.host.getTransientStorage(frame.msg.recipient, key);
    frame.stack.pushUnchecked(value);
}

pub fn tstore(frame: *CallFrame) !void {
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const key, const value = try frame.stack.popN(2);

    try frame.host.setTransientStorage(frame.msg.recipient, key, value);
}

test "transient storage opcodes are only enabled from Cancun" {
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH1, 0x00, .TLOAD }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStackTopBySpec(.{ .PUSH1, 0x00, .TLOAD }, .cancun, 1);

    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .shanghai, .invalid);
    try evmz.t.expectBytecodeStatusBySpec(.{ .PUSH1, 0x01, .PUSH1, 0x00, .TSTORE }, .cancun, .success);
}

test "cold SSTORE charges full cold SLOAD cost from Berlin" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 100_000,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const bytecode = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };

    var frame = try evmz.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = bytecode,
        .spec = .berlin,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 100_000 - 3 - 3 - instruction.cold_sload_cost - 20_000), result.gas_left);
}

test "Amsterdam cold new SSTORE charges state gas from reservoir" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 100_000,
        .gas_reservoir = @intCast(tx_gas.amsterdam_storage_set_state_gas),
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const bytecode = &.{ 0x60, 0x2a, 0x60, 0x00, 0x55 };

    var frame = try evmz.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = bytecode,
        .spec = .amsterdam,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(i64, 100_000 - 3 - 3 - 3_000 - 10_000), result.gas_left);
    try std.testing.expectEqual(@as(i64, 0), result.gas_reservoir);
    try std.testing.expectEqual(@as(i64, @intCast(tx_gas.amsterdam_storage_set_state_gas)), result.state_gas_spent);
    try std.testing.expectEqual(@as(i64, 0), result.state_gas_from_gas_left);
}

test "cold SLOAD out of gas stops before storage read" {
    var mock_host = evmz.t.MockHost.init(std.testing.allocator, null);
    defer mock_host.deinit();
    var host = mock_host.host();
    const msg = Host.Message{
        .depth = 0,
        .sender = evmz.addr(0),
        .gas = 3 + instruction.cold_sload_cost - 1,
        .kind = Host.CallKind.call,
        .recipient = evmz.addr(0),
        .value = 0,
        .input_data = &.{},
    };
    const bytecode = &.{ 0x60, 0x00, 0x54 };

    var frame = try evmz.Interpreter.OwnedCallFrame.init(std.testing.allocator, .{
        .host = &host,
        .msg = &msg,
        .code = bytecode,
        .spec = .berlin,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    try std.testing.expectEqual(evmz.Interpreter.Status.out_of_gas, result.status);
    try std.testing.expectEqual(@as(u64, 1), mock_host.access_storage_reads);
    try std.testing.expectEqual(@as(u64, 0), mock_host.storage_reads);
}
