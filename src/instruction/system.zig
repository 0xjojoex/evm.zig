const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Host = @import("../Host.zig");
const evmz = @import("../evm.zig");
const std = @import("std");

const addr = evmz.addr;

const CallFrame = Interpreter.CallFrame;

fn wordToGas(word: u256) i64 {
    return std.math.cast(i64, word) orelse std.math.maxInt(i64);
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

pub fn For(comptime ProtocolType: type) type {
    return struct {
        const Self = @This();

        pub const Protocol = ProtocolType;

        inline fn frameRevision(frame: *const CallFrame) Protocol.Revision {
            return Interpreter.For(Protocol).revision(frame);
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

            const revision = Self.frameRevision(frame);
            frame.trackGas(Protocol.call.callBaseGas(revision) - evmz.instruction.For(Protocol).staticGasForFrame(frame, op));
            if (frame.status != .running) return;

            if (Protocol.call.callColdAccountAccessGas(revision)) |cold_account_access_gas| {
                if (try frame.host.accessAccount(address) == .cold) {
                    frame.trackGas(cold_account_access_gas);
                    if (frame.status != .running) return;
                }
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

            const value_transfer_gas: i64 = if (value > 0) Protocol.call.callValueTransferGas(revision) else 0;
            frame.trackGas(value_transfer_gas);
            if (frame.status != .running) return;

            frame.traceAccountAccess(address);

            var account_state_gas: i64 = 0;

            if (op == Opcode.CALL) {
                const account_exists = try frame.host.accountExists(address);
                const new_account_gas = Protocol.call.callNewAccountGas(revision, .{
                    .value = value,
                    .account_exists = account_exists,
                });
                frame.trackGas(new_account_gas.regular);
                if (frame.status != .running) return;
                account_state_gas = new_account_gas.state;
            }

            frame.trackStateGas(account_state_gas);
            if (frame.status != .running) return;

            if (try frame.host.accessDelegatedAccount(address)) |delegated_access_status| {
                const delegated_access_cost = Protocol.call.delegatedAccountAccessGas(revision, delegated_access_status == .cold);
                frame.trackGas(delegated_access_cost);
                if (frame.status != .running) return;
            }

            const child_gas = Protocol.call.childGas(revision, .{
                .requested = msg.gas,
                .available = frame.gas_left,
            });
            if (child_gas.out_of_gas) {
                frame.failWithStatus(.out_of_gas);
                return;
            }
            msg.gas = child_gas.gas;

            if (value > 0) {
                const stipend = Protocol.call.callValueStipend(revision);
                msg.gas += stipend;
                frame.gas_left += stipend;
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

        fn createImpl(frame: *CallFrame, comptime is_create2: bool) !void {
            if (frame.msg.is_static) {
                return error.StaticCallViolation;
            }

            const value, const offset, const size, const salt = if (is_create2) try frame.stack.popN(4) else blk: {
                const value, const offset, const size = try frame.stack.popN(3);
                break :blk .{ value, offset, size, 0 };
            };

            const size_usize = frame.wordToUsizeOrOog(size) orelse return;
            const offset_usize = frame.memoryOffsetToUsizeOrOog(offset, size_usize) orelse return;

            const revision = Self.frameRevision(frame);
            if (Protocol.create.createInitCodeSizeLimit(revision)) |limit| {
                if (size_usize > limit) {
                    frame.failWithStatus(.out_of_gas);
                    return;
                }
            }

            if (!try frame.expandMemory(offset_usize, size_usize)) return;

            const size_i64 = frame.wordToIntOrStatus(i64, size, .out_of_gas) orelse return;
            const init_code_word_cost = Protocol.create.createInitCodeWordGas(revision, is_create2);
            const init_code_cost = std.math.mul(i64, init_code_word_cost, evmz.calcWordSize(i64, size_i64)) catch {
                frame.failWithStatus(.out_of_gas);
                return;
            };
            frame.trackGas(init_code_cost);
            if (frame.status != .running) return;

            const init_code = frame.memory.readBytes(offset_usize, size_usize);
            const account_state_gas = Protocol.create.createAccountStateGas(revision);
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

            const child_gas = Protocol.call.childGas(revision, .{
                .requested = msg.gas,
                .available = frame.gas_left,
            });
            if (child_gas.out_of_gas) {
                frame.failWithStatus(.out_of_gas);
                return;
            }
            msg.gas = child_gas.gas;

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
            const revision = Self.frameRevision(frame);

            if (Protocol.self_destruct.selfDestructColdAccountAccessGas(revision)) |cold_account_access_cost| {
                if (try frame.host.accessAccount(address) == .cold) {
                    frame.trackGas(cold_account_access_cost);
                    if (frame.status != .running) return;
                }
            }
            frame.traceAccountAccess(address);

            const new_account_gas = Protocol.self_destruct.selfDestructNewAccountGas(
                revision,
                .{
                    .same_address = same_address,
                    .transfers_balance = transfers_balance,
                    .account_exists = try frame.host.accountExists(address),
                },
            );
            frame.trackGas(new_account_gas.regular);
            if (frame.status != .running) return;
            frame.trackStateGas(new_account_gas.state);
            if (frame.status != .running) return;
            const should_refund = try frame.host.selfDestruct(frame.msg.recipient, address);

            if (should_refund) {
                frame.gas_refund += Protocol.self_destruct.selfDestructRefundGas(revision);
            }

            frame.status = .success;
        }
    };
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
