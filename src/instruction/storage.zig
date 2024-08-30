const std = @import("std");
const evmz = @import("../evm.zig");
const interpreter = @import("../interpreter.zig");
const instruction = evmz.instruction;
const Host = evmz.Host;

const CallFrame = interpreter.CallFrame;

/// https://evmc.ethereum.org/storagestatus.html
///
fn StorageCost(comptime spec: evmz.Spec) type {
    const StorageSpec = struct {
        warm_access: i16,
        set: i16,
        reset: i16,
        clear: i16,
    };

    const s = blk: {
        var storageSpec = StorageSpec{
            .warm_access = 200,
            .set = 20000,
            .reset = 5000,
            .clear = 15000,
        };

        if (spec.isImpl(.istanbul)) {
            storageSpec.warm_access = 800;
        }

        if (spec.isImpl(.berlin)) {
            storageSpec.warm_access = instruction.warm_storage_read_cost;
            storageSpec.reset = 5000 - instruction.cold_sload_cost;
        }

        if (spec.isImpl(.london)) {
            storageSpec.clear = 4800;
        }

        break :blk storageSpec;
    };

    return struct {
        cost: i16,
        refund: i16,

        fn getCost(status: Host.StorageStatus) @This() {
            const net_gas = spec.isImpl(.constantinople);
            if (!net_gas) {
                return switch (status) {
                    .added, .deleted_added, .deleted_restored => .{ .cost = s.set, .refund = 0 },
                    .deleted, .modified_deleted, .added_deleted => .{ .cost = s.reset, .refund = s.clear },
                    .modified, .assigned, .modified_restored => .{ .cost = s.reset, .refund = 0 },
                };
            }

            return switch (status) {
                .assigned => .{ .cost = s.warm_access, .refund = 0 },
                .added => .{ .cost = s.set, .refund = 0 },
                .deleted => .{ .cost = s.reset, .refund = s.clear },
                .modified => .{ .cost = s.reset, .refund = 0 },
                .deleted_added => .{ .cost = s.warm_access, .refund = s.clear },
                .modified_deleted => .{ .cost = s.warm_access, .refund = s.clear },
                .deleted_restored => .{ .cost = s.warm_access, .refund = s.reset - s.warm_access - s.clear },
                .added_deleted => .{ .cost = s.warm_access, .refund = s.set - s.warm_access },
                .modified_restored => .{ .cost = s.warm_access, .refund = s.reset - s.warm_access },
            };
        }
    };
}

pub fn Storage(comptime spec: evmz.Spec) type {
    return struct {
        const storageCost = StorageCost(spec);

        pub fn sstore(frame: *CallFrame) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }
            const key = try frame.stack.pop();
            const value = try frame.stack.pop();

            if (spec.isImpl(.istanbul) and frame.gas_left <= 2300) {
                frame.status = .out_of_gas;
                return;
            }

            if (spec.isImpl(.berlin) and try frame.host.accessStorage(frame.msg.recipient, key) == .cold) {
                frame.track_gas(instruction.cold_sload_gas);
                if (frame.gas_left < 0) {
                    return;
                }
            }

            const status = try frame.host.setStorage(frame.msg.recipient, key, value);

            const cost = storageCost.getCost(status);

            frame.gas_left -= cost.cost;
            frame.gas_refund += cost.refund;
        }

        pub fn sload(frame: *CallFrame) !void {
            const key = try frame.stack.pop();

            if (spec.isImpl(.berlin) and try frame.host.accessStorage(frame.msg.recipient, key) == .cold) {
                frame.track_gas(instruction.cold_sload_gas);
                if (frame.gas_left < 0) {
                    return;
                }
            }

            const value = frame.host.getStorage(frame.msg.recipient, key);
            try frame.stack.push(value orelse 0);
        }

        pub fn tload(frame: *CallFrame) !void {
            if (spec.isImpl(.cancun)) {
                return error.UnsupportedInstruction;
            }

            const key = try frame.stack.pop();
            const value = frame.host.getTransientStorage(frame.msg.recipient, key);
            try frame.stack.push(value orelse 0);
        }

        pub fn tstore(frame: *CallFrame) !void {
            if (spec.isImpl(.cancun)) {
                return error.UnsupportedInstruction;
            }

            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }

            const key = try frame.stack.pop();
            const value = try frame.stack.pop();

            try frame.host.setTransientStorage(frame.msg.recipient, key, value);
        }
    };
}
