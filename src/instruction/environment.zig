const Interpreter = @import("../Interpreter.zig");
const evmz = @import("../evm.zig");
const ExactSpec = @import("../spec.zig").Spec;
const CallFrame = Interpreter.CallFrame;

pub const AccountValue = enum {
    balance,
    code_size,
    code_hash,
};

pub fn Environment(comptime spec: ExactSpec) type {
    const exact_instructions = spec.instruction;
    return struct {
        pub fn trackCodeAccountAccessGas(frame: *CallFrame, target_address: evmz.AddressWord) !bool {
            if (exact_instructions.codeAccountAccessGas(.warm) == null) return true;
            const access_status = try frame.host.accessAccount(target_address);
            const access_gas = exact_instructions.codeAccountAccessGas(access_status) orelse 0;
            return frame.trackGas(access_gas);
        }

        pub fn readAccountValue(frame: *CallFrame, target_address: evmz.AddressWord, comptime value: AccountValue) !?u256 {
            const access_gas = switch (value) {
                .balance, .code_hash => blk: {
                    const cold_gas = exact_instructions.account_read_cold_access_gas orelse break :blk 0;
                    break :blk if (try frame.host.accessAccount(target_address) == .cold) cold_gas else 0;
                },
                .code_size => blk: {
                    if (exact_instructions.codeAccountAccessGas(.warm) == null) break :blk 0;
                    const status = try frame.host.accessAccount(target_address);
                    break :blk exact_instructions.codeAccountAccessGas(status) orelse 0;
                },
            };
            if (!frame.trackGas(access_gas)) return null;
            try frame.traceAccountAccess(target_address);
            return switch (value) {
                .balance => try frame.host.getBalance(target_address),
                .code_size => try frame.host.getCodeSize(target_address),
                .code_hash => try frame.host.getCodeHash(target_address),
            };
        }
    };
}
