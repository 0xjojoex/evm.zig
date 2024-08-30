const interpreter = @import("../interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Host = @import("../Host.zig");
const evmz = @import("../evm.zig");
const std = @import("std");

const addr = evmz.addr;

const CallFrame = interpreter.CallFrame;

pub fn System(comptime spec: evmz.Spec) type {
    return struct {
        pub fn stop(frame: *CallFrame) !void {
            frame.status = .success;
        }

        pub fn invalid(frame: *CallFrame) !void {
            // TODO: cosume all gas
            frame.status = .invalid;
        }

        /// `RETURN` Halt the execution returning the output data
        pub fn ret(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            const offset_usize: usize = @intCast(offset);
            const size_usize: usize = @intCast(size);

            const expand_cost = try frame.memory.expand(offset_usize, size_usize);
            frame.track_gas(expand_cost);
            const data = frame.memory.readBytes(offset_usize, size_usize);

            try frame.replaceReturnData(data);
            frame.status = .success;
        }

        /// `REVERT` Halt the execution reverting state changes but returning data and remaining gas
        pub fn revert(frame: *CallFrame) !void {
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();

            const offset_usize: usize = @intCast(offset);
            const size_usize: usize = @intCast(size);

            const expand_cost = try frame.memory.expand(offset_usize, size_usize);
            frame.track_gas(expand_cost);
            const data = frame.memory.readBytes(offset_usize, size_usize);

            try frame.replaceReturnData(data);
            frame.status = .revert;
        }

        pub fn callByOp(frame: *CallFrame, comptime op: Opcode) !void {
            if (op != Opcode.CALL and op != Opcode.STATICCALL and op != Opcode.DELEGATECALL and op != Opcode.CALLCODE) {
                @compileError("Invalid opcode for " ++ @tagName(op));
            }

            const gas = try frame.stack.pop();
            const address_word = try frame.stack.pop();
            const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));
            const value = if (op == Opcode.CALL or op == Opcode.CALLCODE) try frame.stack.pop() else 0;
            const in_offset = try frame.stack.pop();
            const in_size = try frame.stack.pop();
            const out_offset = try frame.stack.pop();
            const out_size = try frame.stack.pop();

            const in_offset_usize: usize = @intCast(in_offset);
            const in_size_usize: usize = @intCast(in_size);
            const out_offset_usize: usize = @intCast(out_offset);
            const out_size_usize: usize = @intCast(out_size);

            if (spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
                frame.track_gas(evmz.instruction.cold_sload_gas);
                if (frame.gas_left < 0) {
                    return;
                }
            }

            const expand_cost = try frame.memory.expand(in_offset_usize, in_size_usize);
            frame.track_gas(expand_cost);
            const expand_cost_out = try frame.memory.expand(out_offset_usize, out_size_usize);
            frame.track_gas(expand_cost_out);

            if (frame.gas_left < 0) {
                return;
            }

            const data = frame.memory.readBytes(in_offset_usize, in_size_usize);

            var msg = Host.Message{
                .depth = frame.msg.depth + 1,
                .kind = Host.CallKind.fromOpcode(op),
                .recipient = if (op == Opcode.CALL or op == Opcode.STATICCALL) address else frame.msg.recipient,
                .is_static = op == Opcode.STATICCALL,
                .code_address = address,
                .sender = if (op == Opcode.DELEGATECALL) frame.msg.sender else frame.msg.recipient,
                .value = if (op == Opcode.DELEGATECALL) frame.msg.value else value,
                .input_data = data,
                .gas = @bitCast(@as(u64, @truncate(gas))),
            };

            var cost: i64 = if (value > 0) evmz.instruction.call_value_cost else 0;

            if (op == Opcode.CALL and value > 0 and spec.isImpl(.spurious_dragon)) {
                if (try frame.host.accountExists(address)) {
                    cost += evmz.instruction.account_creation_cost;
                }
            }

            frame.track_gas(cost);
            if (frame.gas_left < 0) {
                return;
            }

            // EIP-150
            if (spec.isImpl(.tangerine_whistle)) {
                msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
            } else if (msg.gas > frame.gas_left) {
                // out of gas
                frame.status = .out_of_gas;
                return;
            }

            if (value > 0) {
                msg.gas += 2300;
                frame.gas_left += 2300;
            }

            const result = try frame.host.call(msg);

            frame.track_gas(msg.gas - result.gas_left);
            frame.gas_refund += result.gas_left;

            try frame.memory.writeBytes(out_offset_usize, result.output_data);

            try frame.replaceReturnData(result.output_data);

            if (result.status == .success) {
                try frame.stack.push(1);
            } else {
                try frame.stack.push(0);
            }
        }

        pub fn create(frame: *CallFrame) !void {
            return createImpl(frame, comptime false);
        }

        pub fn create2(frame: *CallFrame) !void {
            return createImpl(frame, comptime true);
        }

        pub inline fn createImpl(frame: *CallFrame, comptime is_create2: bool) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }

            const value = try frame.stack.pop();
            const offset = try frame.stack.pop();
            const size = try frame.stack.pop();
            const salt = if (is_create2) try frame.stack.pop() else 0;

            const offset_usize: usize = @intCast(offset);
            const size_usize: usize = @intCast(size);

            if (spec.isImpl(.shanghai) and size_usize > 0xC000) {
                frame.status = .out_of_gas;
                return;
            }

            const expend_cost = try frame.memory.expand(offset_usize, size_usize);
            frame.track_gas(expend_cost);

            const init_code_word_cost = blk: {
                var cost: i64 = 0;
                if (spec.isImpl(.shanghai)) {
                    cost = 2;
                }

                if (is_create2) {
                    cost += 6;
                }
                break :blk cost;
            };

            const init_code_cost = init_code_word_cost * evmz.calcWordSize(i64, @intCast(size_usize));
            frame.track_gas(init_code_cost);

            const init_code = frame.memory.readBytes(offset_usize, size_usize);

            var msg = Host.Message{
                .depth = frame.msg.depth + 1,
                .kind = if (is_create2) .create2 else .create,
                .input_data = init_code,
                .gas = frame.gas_left,
                .sender = frame.msg.recipient,
                .value = value,
                .create2_salt = salt,
            };

            if (spec.isImpl(.tangerine_whistle)) {
                msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
            }

            const result = try frame.host.call(msg);

            frame.track_gas(msg.gas - result.gas_left);
            frame.gas_refund += result.gas_left;

            if (result.status == .success) {
                try frame.replaceReturnData(result.output_data);
                try frame.stack.push(@byteSwap(@as(u160, @bitCast(result.create_address.?))));
            } else {
                try frame.stack.push(0);
            }
        }

        pub fn selfdestruct(frame: *CallFrame) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }

            const address_word = try frame.stack.pop();

            const address: [20]u8 = @bitCast(@byteSwap(@as(u160, @intCast(address_word))));

            if (spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
                frame.track_gas(evmz.instruction.cold_account_access_gas);

                if (frame.gas_left < 0) {
                    return;
                }
            }

            const should_refund = try frame.host.selfDestruct(frame.msg.recipient, address);

            if (should_refund and spec.isImpl(.london)) {
                frame.gas_refund += 24000;
            }

            frame.status = .success;
        }
    };
}
