//! Maps host messages, frames, and results onto trace capture records.
//!
//! None of this reaches Executor state. Callers pass the borrowed capture
//! context explicitly, and SELFDESTRUCT passes the executing frame depth,
//! because the `Host` vtable does not carry one.

const std = @import("std");

const evmz = @import("../evm.zig");
const FrameStore = @import("./FrameStore.zig");

const Address = evmz.Address;
const Context = @import("./capture_context.zig").Context;
const ExecutionGas = evmz.execution.ExecutionGas;
const ExecutionResult = evmz.execution.ExecutionResult;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const trace = evmz.trace;

pub inline fn beginCall(context: ?*Context, msg: *const Host.Message) !?trace.CallToken {
    const capture_value = context orelse return null;
    if (!capture_value.capturesCalls()) return null;

    const Endpoints = struct { from: Address, to: Address };
    const endpoints: Endpoints = switch (msg.kind) {
        .call, .staticcall => .{ .from = msg.sender, .to = msg.recipient },
        .delegatecall, .callcode => .{ .from = msg.recipient, .to = msg.code_address },
        .create, .create2 => .{ .from = msg.sender, .to = msg.recipient },
    };
    return capture_value.beginCall(.{
        .depth = msg.depth,
        .kind = callKind(msg.kind),
        .from = endpoints.from,
        .to = endpoints.to,
        .code_address = msg.code_address,
        .value = msg.value,
        .gas = msg.gas,
        .input = msg.input_data,
    });
}

pub fn finishCall(context: ?*Context, token: trace.CallToken, result: Host.Result) !void {
    try context.?.finishCall(token, callFinish(result));
}

pub fn finishCallReserved(context: *Context, token: trace.CallToken, result: Host.Result) void {
    context.finishCallReserved(token, callFinish(result));
}

pub fn beginRoot(context: ?*Context, message: evmz.Message, gas: ExecutionGas) !?trace.CallToken {
    const capture_value = context orelse return null;
    if (!capture_value.capturesCalls()) return null;

    return capture_value.beginCall(switch (message) {
        .call => |call| .{
            .depth = 0,
            .kind = .call,
            .from = call.sender,
            .to = call.recipient,
            .code_address = call.recipient,
            .value = call.value,
            .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
            .input = call.input,
        },
        .create => |create| .{
            .depth = 0,
            .kind = if (create.salt == null) .create else .create2,
            .from = create.sender,
            .to = create.recipient,
            .code_address = create.recipient,
            .value = create.value,
            .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
            .input = create.init_code,
        },
    });
}

pub fn finishRoot(context: *Context, token: trace.CallToken, result: ExecutionResult) !void {
    try context.finishCall(token, .{
        .status = callStatus(result.outcome.status, result.outcome.cause),
        .gas_left = result.gas_left,
        .output = result.output_data,
        // Root execution has no frame-local checkpoint in CallRuntime.
        .checkpoint_reverted = false,
    });
}

pub fn beginSelfDestruct(
    context: ?*Context,
    frame_depth: u16,
    address: Address,
    beneficiary: Address,
    balance: u256,
) !?trace.CallToken {
    const capture_value = context orelse return null;
    if (!capture_value.capturesCalls()) return null;
    const depth = std.math.add(u16, frame_depth, 1) catch std.math.maxInt(u16);
    return capture_value.beginCall(.{
        .depth = depth,
        .kind = .selfdestruct,
        .from = address,
        .to = beneficiary,
        .code_address = address,
        .value = balance,
    });
}

pub fn finishSelfDestruct(context: *Context, token: trace.CallToken) !void {
    try context.finishCall(token, .{
        .status = .success,
        .gas_left = 0,
    });
}

pub fn frameKind(frames: *FrameStore, index: usize) trace.TraceFrameKind {
    return switch (frames.control(index).kind) {
        .root_call => .root,
        .call => switch (frames.frame(index).msg.kind) {
            .call => .call,
            .staticcall => .staticcall,
            .callcode => .callcode,
            .delegatecall => .delegatecall,
            .create => .create,
            .create2 => .create2,
        },
        .create => |child| switch (child.kind) {
            .create => .create,
            .create2 => .create2,
            else => unreachable,
        },
    };
}

fn callKind(kind: Host.CallKind) trace.CallKind {
    return switch (kind) {
        .call => .call,
        .staticcall => .staticcall,
        .delegatecall => .delegatecall,
        .callcode => .callcode,
        .create => .create,
        .create2 => .create2,
    };
}

fn callStatus(status: Interpreter.Status, cause: evmz.execution.TerminalCause) trace.CallStatus {
    return switch (cause) {
        .call_depth_exceeded => .call_depth_exceeded,
        .insufficient_balance => .insufficient_balance,
        .nonce_overflow => .nonce_overflow,
        .invalid_opcode => .invalid_opcode,
        .stack_underflow => .stack_underflow,
        .stack_overflow => .stack_overflow,
        .invalid_jump => .invalid_jump,
        .write_protection => .write_protection,
        .return_data_out_of_bounds => .return_data_out_of_bounds,
        .contract_address_collision => .contract_address_collision,
        .max_code_size_exceeded => .max_code_size_exceeded,
        .invalid_code => .invalid_code,
        .code_store_out_of_gas => if (status == .success)
            .code_store_out_of_gas_committed
        else
            .code_store_out_of_gas,
        .none => .success,
        .revert => .revert,
        .out_of_gas => .out_of_gas,
        .invalid => switch (status) {
            .success => .success,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
            .invalid => .invalid,
        },
    };
}

fn callFinish(result: Host.Result) trace.CallFinish {
    return .{
        .status = callStatus(result.status(), result.terminalCause()),
        .gas_left = result.gas_left,
        .output = result.output_data,
        .checkpoint_reverted = result.checkpoint_reverted,
    };
}
