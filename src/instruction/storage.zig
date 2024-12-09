const std = @import("std");
const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const instruction = evmz.instruction;
const Host = evmz.Host;

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

        const net_gas = spec.isImpl(.constantinople);
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
            .deleted_added => .{ .cost = action.warm_access, .refund = action.clear },
            .modified_deleted => .{ .cost = action.warm_access, .refund = action.clear },
            .deleted_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access - action.clear },
            .added_deleted => .{ .cost = action.warm_access, .refund = action.set - action.warm_access },
            .modified_restored => .{ .cost = action.warm_access, .refund = action.reset - action.warm_access },
        };
    }
};

pub fn sstore(frame: *CallFrame) !void {
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }
    const key = try frame.stack.pop();
    const value = try frame.stack.pop();

    if (frame.spec.isImpl(.istanbul) and frame.gas_left <= 2300) {
        frame.status = .out_of_gas;
        return;
    }

    if (frame.spec.isImpl(.berlin) and try frame.host.accessStorage(frame.msg.recipient, key) == .cold) {
        frame.trackGas(instruction.cold_sload_gas);
        if (frame.gas_left < 0) {
            return;
        }
    }

    const status = try frame.host.setStorage(frame.msg.recipient, key, value);

    const cost = StorageCost.getCost(frame.spec, status);

    frame.gas_left -= cost.cost;
    frame.gas_refund += cost.refund;
}

pub fn sload(frame: *CallFrame) !void {
    const key = try frame.stack.pop();

    if (frame.spec.isImpl(.berlin) and try frame.host.accessStorage(frame.msg.recipient, key) == .cold) {
        frame.trackGas(instruction.cold_sload_gas);
        if (frame.gas_left < 0) {
            return;
        }
    }

    const value = frame.host.getStorage(frame.msg.recipient, key);
    try frame.stack.push(value orelse 0);
}

pub fn tload(frame: *CallFrame) !void {
    if (frame.spec.isImpl(.cancun)) {
        return error.UnsupportedInstruction;
    }

    const key = try frame.stack.pop();
    const value = frame.host.getTransientStorage(frame.msg.recipient, key);
    try frame.stack.push(value orelse 0);
}

pub fn tstore(frame: *CallFrame) !void {
    if (frame.spec.isImpl(.cancun)) {
        return error.UnsupportedInstruction;
    }

    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const key = try frame.stack.pop();
    const value = try frame.stack.pop();

    try frame.host.setTransientStorage(frame.msg.recipient, key, value);
}
