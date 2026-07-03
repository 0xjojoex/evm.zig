const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Host = @import("../Host.zig");
const evmz = @import("../evm.zig");
const std = @import("std");
const tx_gas = @import("../transaction/gas.zig");

const addr = evmz.addr;

const CallFrame = Interpreter.CallFrame;
const call_static_gas_floor = 40;

fn wordToGas(word: u256) i64 {
    return std.math.cast(i64, word) orelse std.math.maxInt(i64);
}

fn callBaseGas(spec: evmz.Spec) i64 {
    if (spec.isImpl(.berlin)) return 100;
    if (spec.isImpl(.tangerine_whistle)) return 700;
    return call_static_gas_floor;
}

fn nextDepth(depth: u16) u16 {
    return if (depth == std.math.maxInt(u16)) depth else depth + 1;
}

pub fn stop(frame: *CallFrame) !void {
    frame.status = .success;
}

pub fn invalid(frame: *CallFrame) !void {
    frame.failWithStatus(.invalid);
}

/// `RETURN` Halt the execution returning the output data
pub fn ret(frame: *CallFrame) !void {
    const offset, const size = try frame.stack.popN(2);

    const size_usize = frame.wordToUsizeOrOog(size) orelse return;
    const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, size_usize) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    const data = frame.memory.readBytes(offset_usize, size_usize);

    try frame.replaceOutputData(data);
    frame.status = .success;
}

/// `REVERT` Halt the execution reverting state changes but returning data and remaining gas
pub fn revert(frame: *CallFrame) !void {
    const offset, const size = try frame.stack.popN(2);

    const size_usize = frame.wordToUsizeOrOog(size) orelse return;
    const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, size_usize) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    const data = frame.memory.readBytes(offset_usize, size_usize);

    try frame.replaceOutputData(data);
    frame.status = .revert;
}

pub fn callByOp(frame: *CallFrame, comptime op: Opcode) !void {
    if (op != Opcode.CALL and op != Opcode.STATICCALL and op != Opcode.DELEGATECALL and op != Opcode.CALLCODE) {
        @compileError("Invalid opcode for " ++ @tagName(op));
    }

    const gas, const address_word, const value, const in_offset, const in_size, const out_offset, const out_size = if (op == Opcode.CALL or op == Opcode.CALLCODE) try frame.stack.popN(7) else blk: {
        const gas, const address_word, const in_offset, const in_size, const out_offset, const out_size = try frame.stack.popN(6);
        break :blk .{ gas, address_word, 0, in_offset, in_size, out_offset, out_size };
    };
    const address = evmz.address.fromWord(address_word);

    const in_size_usize = frame.wordToUsizeOrOog(in_size) orelse return;
    const out_size_usize = frame.wordToUsizeOrOog(out_size) orelse return;
    const in_offset_usize = if (in_size_usize == 0) 0 else frame.wordToUsizeOrOog(in_offset) orelse return;
    const out_offset_usize = if (out_size_usize == 0) 0 else frame.wordToUsizeOrOog(out_offset) orelse return;

    if (frame.msg.is_static and op == Opcode.CALL and value > 0) {
        return error.StaticCallViolation;
    }

    frame.trackGas(callBaseGas(frame.spec) - call_static_gas_floor);
    if (frame.status != .running) return;

    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
        const cold_account_access_gas = if (frame.spec.isImpl(.amsterdam))
            tx_gas.amsterdam_cold_account_access_cost - evmz.instruction.warm_storage_read_cost
        else
            evmz.instruction.cold_account_access_gas;
        frame.trackGas(std.math.cast(i64, cold_account_access_gas) orelse std.math.maxInt(i64));
        if (frame.status != .running) return;
    }

    if (!try frame.expandMemory(in_offset_usize, in_size_usize)) return;
    if (!try frame.expandMemory(out_offset_usize, out_size_usize)) return;

    const data = frame.memory.readBytes(in_offset_usize, in_size_usize);

    var msg = Host.Message{
        .depth = nextDepth(frame.msg.depth),
        .kind = Host.CallKind.fromOpcode(op),
        .recipient = if (op == Opcode.CALL or op == Opcode.STATICCALL) address else frame.msg.recipient,
        .is_static = frame.msg.is_static or op == Opcode.STATICCALL,
        .code_address = address,
        .sender = if (op == Opcode.DELEGATECALL) frame.msg.sender else frame.msg.recipient,
        .value = if (op == Opcode.DELEGATECALL) frame.msg.value else value,
        .input_data = data,
        .gas = wordToGas(gas),
        .gas_reservoir = frame.gas_reservoir,
    };

    var cost: i64 = if (value > 0)
        std.math.cast(i64, if (frame.spec.isImpl(.amsterdam)) tx_gas.amsterdam_call_value_cost else evmz.instruction.call_value_cost) orelse std.math.maxInt(i64)
    else
        0;
    var account_state_gas: i64 = 0;

    if (op == Opcode.CALL) {
        const account_exists = try frame.host.accountExists(address);
        // EIP-161 narrows the new-account charge to value-bearing CALLs.
        const charges_new_account = if (frame.spec.isImpl(.spurious_dragon))
            value > 0 and !account_exists
        else
            !account_exists;
        if (charges_new_account) {
            if (frame.spec.isImpl(.amsterdam)) {
                account_state_gas = std.math.cast(i64, tx_gas.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64);
            } else {
                cost += evmz.instruction.account_creation_cost;
            }
        }
    }

    frame.trackGas(cost);
    if (frame.status != .running) return;
    frame.trackStateGas(account_state_gas);
    if (frame.status != .running) return;

    if (try frame.host.accessDelegatedAccount(address)) |delegated_access_status| {
        const delegated_access_cost: i64 = switch (delegated_access_status) {
            .cold => if (frame.spec.isImpl(.amsterdam))
                tx_gas.amsterdam_cold_account_access_cost
            else
                evmz.instruction.cold_account_access_cost,
            .warm => evmz.instruction.warm_storage_read_cost,
        };
        frame.trackGas(delegated_access_cost);
        if (frame.status != .running) return;
    }

    // EIP-150
    if (frame.spec.isImpl(.tangerine_whistle)) {
        msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
    } else if (msg.gas > frame.gas_left) {
        frame.failWithStatus(.out_of_gas);
        return;
    }

    if (value > 0) {
        msg.gas += evmz.instruction.call_stipend;
        frame.gas_left += evmz.instruction.call_stipend;
    }
    msg.gas_reservoir = frame.gas_reservoir;

    if (frame.msg.depth >= Host.max_call_depth) {
        frame.refillStateGas(account_state_gas);
        frame.stack.pushUnchecked(0);
        return;
    }

    const continuation = Interpreter.CallResume{
        .gas_limit = msg.gas,
        .out_offset = out_offset_usize,
        .out_size = out_size_usize,
        .state_gas_charged = account_state_gas,
    };
    frame.setPendingAction(.{ .call = .{
        .msg = msg,
        .continuation = continuation,
    } });
}

pub fn create(frame: *CallFrame) !void {
    return createImpl(frame, comptime false);
}

pub fn create2(frame: *CallFrame) !void {
    return createImpl(frame, comptime true);
}

pub inline fn createImpl(frame: *CallFrame, comptime is_create2: bool) !void {
    if (is_create2 and !frame.spec.isImpl(.constantinople)) {
        return error.UnsupportedInstruction;
    }
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const value, const offset, const size, const salt = if (is_create2) try frame.stack.popN(4) else blk: {
        const value, const offset, const size = try frame.stack.popN(3);
        break :blk .{ value, offset, size, 0 };
    };

    const size_usize = frame.wordToUsizeOrOog(size) orelse return;
    const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, size_usize) orelse return;

    if (frame.spec.isImpl(.shanghai) and size_usize > tx_gas.maxInitcodeSize(frame.spec)) {
        frame.failWithStatus(.out_of_gas);
        return;
    }

    if (!try frame.expandMemory(offset_usize, size_usize)) return;

    const init_code_word_cost = blk: {
        var cost: i64 = 0;
        if (frame.spec.isImpl(.shanghai)) {
            cost = 2;
        }

        if (is_create2) {
            cost += 6;
        }
        break :blk cost;
    };

    const size_i64 = frame.wordToIntOrStatus(i64, size, .out_of_gas) orelse return;
    const init_code_cost = std.math.mul(i64, init_code_word_cost, evmz.calcWordSize(i64, size_i64)) catch {
        frame.failWithStatus(.out_of_gas);
        return;
    };
    frame.trackGas(init_code_cost);
    if (frame.status != .running) return;

    const init_code = frame.memory.readBytes(offset_usize, size_usize);
    const account_state_gas = if (frame.spec.isImpl(.amsterdam))
        std.math.cast(i64, tx_gas.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64)
    else
        0;
    frame.trackStateGas(account_state_gas);
    if (frame.status != .running) return;

    var msg = Host.Message{
        .depth = nextDepth(frame.msg.depth),
        .kind = if (is_create2) .create2 else .create,
        .input_data = init_code,
        .gas = frame.gas_left,
        .gas_reservoir = frame.gas_reservoir,
        .sender = frame.msg.recipient,
        .value = value,
        .create2_salt = salt,
    };

    if (frame.spec.isImpl(.tangerine_whistle)) {
        msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
    }

    if (frame.msg.depth >= Host.max_call_depth) {
        frame.refillStateGas(account_state_gas);
        frame.stack.pushUnchecked(0);
        return;
    }

    const continuation = Interpreter.CreateResume{
        .gas_limit = msg.gas,
        .state_gas_charged = account_state_gas,
    };
    frame.setPendingAction(.{ .create = .{
        .msg = msg,
        .continuation = continuation,
    } });
}

pub fn selfdestruct(frame: *CallFrame) !void {
    if (frame.msg.is_static) {
        return error.StaticCallViolation;
    }

    const address_word = try frame.stack.pop();

    const address = evmz.address.fromWord(address_word);

    const balance = try frame.host.getBalance(frame.msg.recipient);
    const same_address = std.mem.eql(u8, &frame.msg.recipient, &address);
    const transfers_balance = balance > 0 and !same_address;
    const charges_new_account = if (!frame.spec.isImpl(.tangerine_whistle) or same_address)
        false
    else if (frame.spec.isImpl(.spurious_dragon))
        transfers_balance
    else
        true;
    const creates_account = charges_new_account and !try frame.host.accountExists(address);
    if (frame.spec.isImpl(.amsterdam)) {
        if (creates_account) {
            frame.trackGas(tx_gas.amsterdam_account_write_cost);
            if (frame.status != .running) return;
            frame.trackStateGas(std.math.cast(i64, tx_gas.amsterdam_new_account_state_gas) orelse std.math.maxInt(i64));
            if (frame.status != .running) return;
        }
    } else if (creates_account) {
        frame.trackGas(evmz.instruction.account_creation_cost);
        if (frame.status != .running) return;
    }

    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
        const cold_account_access_cost = if (frame.spec.isImpl(.amsterdam))
            tx_gas.amsterdam_cold_account_access_cost
        else
            evmz.instruction.cold_account_access_cost;
        frame.trackGas(std.math.cast(i64, cold_account_access_cost) orelse std.math.maxInt(i64));
        if (frame.status != .running) return;
    }

    const should_refund = try frame.host.selfDestruct(frame.msg.recipient, address);

    if (should_refund and !frame.spec.isImpl(.london)) {
        frame.gas_refund += 24000;
    }

    frame.status = .success;
}

test "RETURN zero length ignores oversized offset" {
    try evmz.t.expectLatestForkBytecodeStatus(.{
        .PUSH0,  .PUSH32,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        0xff,    0xff,
        .RETURN,
    }, .success);
}
