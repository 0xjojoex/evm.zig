const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Host = @import("../Host.zig");
const evmz = @import("../evm.zig");
const std = @import("std");

const addr = evmz.addr;

const CallFrame = Interpreter.CallFrame;
const max_call_depth = 1024;
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
    // TODO: cosume all gas
    frame.status = .invalid;
}

/// `RETURN` Halt the execution returning the output data
pub fn ret(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const size_usize = frame.wordToUsizeOrOog(size) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
    const data = frame.memory.readBytes(offset_usize, size_usize);

    try frame.replaceReturnData(data);
    frame.status = .success;
}

/// `REVERT` Halt the execution reverting state changes but returning data and remaining gas
pub fn revert(frame: *CallFrame) !void {
    const offset = try frame.stack.pop();
    const size = try frame.stack.pop();

    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const size_usize = frame.wordToUsizeOrOog(size) orelse return;

    if (!try frame.expandMemory(offset_usize, size_usize)) return;
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
    const address = evmz.address.fromWord(address_word);
    const value = if (op == Opcode.CALL or op == Opcode.CALLCODE) try frame.stack.pop() else 0;
    const in_offset = try frame.stack.pop();
    const in_size = try frame.stack.pop();
    const out_offset = try frame.stack.pop();
    const out_size = try frame.stack.pop();

    const in_size_usize = frame.wordToUsizeOrOog(in_size) orelse return;
    const out_size_usize = frame.wordToUsizeOrOog(out_size) orelse return;
    const in_offset_usize = if (in_size_usize == 0) 0 else frame.wordToUsizeOrOog(in_offset) orelse return;
    const out_offset_usize = if (out_size_usize == 0) 0 else frame.wordToUsizeOrOog(out_offset) orelse return;

    frame.trackGas(callBaseGas(frame.spec) - call_static_gas_floor);
    if (frame.status != .running) return;

    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
        frame.trackGas(evmz.instruction.cold_account_access_gas);
        if (frame.status != .running) return;
    }

    if (!try frame.expandMemory(in_offset_usize, in_size_usize)) return;
    if (!try frame.expandMemory(out_offset_usize, out_size_usize)) return;

    const data = frame.memory.readBytes(in_offset_usize, in_size_usize);

    var msg = Host.Message{
        .depth = nextDepth(frame.msg.depth),
        .kind = Host.CallKind.fromOpcode(op),
        .recipient = if (op == Opcode.CALL or op == Opcode.STATICCALL) address else frame.msg.recipient,
        .is_static = op == Opcode.STATICCALL,
        .code_address = address,
        .sender = if (op == Opcode.DELEGATECALL) frame.msg.sender else frame.msg.recipient,
        .value = if (op == Opcode.DELEGATECALL) frame.msg.value else value,
        .input_data = data,
        .gas = wordToGas(gas),
    };

    var cost: i64 = if (value > 0) evmz.instruction.call_value_cost else 0;

    if (op == Opcode.CALL and value > 0 and frame.spec.isImpl(.spurious_dragon)) {
        if (!try frame.host.accountExists(address)) {
            cost += evmz.instruction.account_creation_cost;
        }
    }

    frame.trackGas(cost);
    if (frame.status != .running) return;

    // EIP-150
    if (frame.spec.isImpl(.tangerine_whistle)) {
        msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
    } else if (msg.gas > frame.gas_left) {
        // out of gas
        frame.status = .out_of_gas;
        return;
    }

    if (frame.msg.depth >= max_call_depth) {
        try frame.stack.push(0);
        return;
    }

    if (value > 0) {
        msg.gas += 2300;
        frame.gas_left += 2300;
    }

    const result = try frame.host.call(msg);

    const child_gas_left = @max(result.gas_left, 0);
    frame.trackGas(msg.gas - child_gas_left);
    frame.gas_refund += child_gas_left;
    if (frame.status != .running) return;

    const output_size = @min(out_size_usize, result.output_data.len);
    try frame.memory.writeBytes(out_offset_usize, result.output_data[0..output_size]);

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

    const offset_usize = frame.wordToUsizeOrOog(offset) orelse return;
    const size_usize = frame.wordToUsizeOrOog(size) orelse return;

    if (frame.spec.isImpl(.shanghai) and size_usize > 0xC000) {
        frame.status = .out_of_gas;
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
        frame.status = .out_of_gas;
        return;
    };
    frame.trackGas(init_code_cost);
    if (frame.status != .running) return;

    const init_code = frame.memory.readBytes(offset_usize, size_usize);

    var msg = Host.Message{
        .depth = nextDepth(frame.msg.depth),
        .kind = if (is_create2) .create2 else .create,
        .input_data = init_code,
        .gas = frame.gas_left,
        .sender = frame.msg.recipient,
        .value = value,
        .create2_salt = salt,
    };

    if (frame.spec.isImpl(.tangerine_whistle)) {
        msg.gas = @min(msg.gas, frame.gas_left - @divFloor(frame.gas_left, 64));
    }

    if (frame.msg.depth >= max_call_depth) {
        try frame.stack.push(0);
        return;
    }

    const result = try frame.host.call(msg);

    const child_gas_left = @max(result.gas_left, 0);
    frame.trackGas(msg.gas - child_gas_left);
    frame.gas_refund += child_gas_left;
    if (frame.status != .running) return;

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

    const address = evmz.address.fromWord(address_word);

    if (frame.spec.isImpl(.berlin) and try frame.host.accessAccount(address) == .cold) {
        frame.trackGas(evmz.instruction.cold_account_access_cost);

        if (frame.gas_left < 0) {
            return;
        }
    }

    const should_refund = try frame.host.selfDestruct(frame.msg.recipient, address);

    if (should_refund and frame.spec.isImpl(.london)) {
        frame.gas_refund += 24000;
    }

    frame.status = .success;
}
