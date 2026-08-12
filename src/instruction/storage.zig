const evmz = @import("../evm.zig");
const ExactSpec = @import("../spec.zig").Spec;
const Interpreter = @import("../Interpreter.zig");

const CallFrame = Interpreter.CallFrame;

pub fn Storage(comptime spec: ExactSpec) type {
    return struct {
        pub fn sstoreAfterPop(frame: *CallFrame, key: u256, value: u256) !void {
            const recipient: evmz.AddressWord = .fromAddress(frame.msg.recipient);
            const host = frame.host;
            if (spec.storage.sstore_minimum_gas) |minimum_gas| {
                if (frame.gas_left <= minimum_gas) {
                    @branchHint(.unlikely);
                    frame.halt(.out_of_gas);
                    return;
                }
            }

            const status = blk: {
                if (spec.storage.sstoreAccessGas(.warm)) |warm_access_gas| {
                    const cold_access_gas = spec.storage.sstoreAccessGas(.cold) orelse warm_access_gas;
                    if (frame.gas_left >= @max(warm_access_gas, cold_access_gas)) {
                        const result = try host.storeStorage(recipient, key, value);
                        const access_status = result.access_status;
                        if (!frame.trackGas(spec.storage.sstoreAccessGas(access_status) orelse 0)) return;
                        break :blk result.storage_status;
                    }

                    const access_status = try host.accessStorage(recipient, key);
                    const access_gas = spec.storage.sstoreAccessGas(access_status) orelse 0;
                    if (!frame.trackGas(access_gas)) return;
                }

                break :blk try host.setStorage(recipient, key, value);
            };

            const cost = spec.storage.sstoreGas(status);

            if (!frame.trackGas(cost.cost)) return;
            frame.gas_refund += cost.refund;

            const state_gas = spec.storage.sstoreStateGas(status);
            if (!frame.trackStateGas(state_gas.charge)) return;
            frame.refillStateGas(state_gas.refund);
        }

        pub fn sloadAfterPop(frame: *CallFrame, key: u256) !?u256 {
            const host = frame.host;
            const recipient: evmz.AddressWord = .fromAddress(frame.msg.recipient);
            if (spec.storage.sload_cold_access_gas) |cold_storage_access_gas| {
                if (frame.gas_left >= cold_storage_access_gas) {
                    const result = try host.loadStorage(recipient, key);
                    if (result.access_status == .cold) {
                        if (!frame.trackGas(cold_storage_access_gas)) return null;
                    }
                    return result.value;
                }

                if (try host.accessStorage(recipient, key) == .cold) {
                    if (!frame.trackGas(cold_storage_access_gas)) return null;
                }
            }

            return try host.getStorage(recipient, key);
        }
    };
}
