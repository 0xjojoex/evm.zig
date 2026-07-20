const std = @import("std");

const evmz = @import("../evm.zig");
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Stack = @import("../Stack.zig");
const uint256 = @import("../uint256.zig");
const instruction = @import("../instruction.zig");
const arithmetic_instruction = @import("../instruction/arithmetic.zig");
const storage_instruction = @import("../instruction/storage.zig");
const trace = @import("../trace.zig");

const CallFrame = Interpreter.CallFrame;

const TailStatus = enum {
    done,
    invalid,
    out_of_gas,
    thrown,
};

const BinaryOp = enum {
    add,
    mul,
    sub,
    div,
    sdiv,
    mod,
    smod,
    lt,
    gt,
    slt,
    sgt,
    eq,
    byte,
    bit_and,
    bit_or,
    bit_xor,
};

const UnaryOp = enum {
    iszero,
    bit_not,
};

const ShiftOp = enum {
    left,
    right,
    arithmetic,
};

const FrameValue = enum {
    address,
    caller,
    call_value,
    calldata_size,
    code_size,
    return_data_size,
};

const CopySource = enum {
    calldata,
    code,
    return_data,
};

const TerminalStatus = enum {
    success,
    revert,
};

pub fn For(comptime ProtocolType: type) type {
    return DispatchFor(ProtocolType, false);
}

/// The one concrete replay-capture table for a protocol.
///
/// This type varies only with the protocol, never with the eventual trace
/// consumer. Captured spans are replayed after execution.
pub fn TraceFor(comptime ProtocolType: type) type {
    return DispatchFor(ProtocolType, true);
}

fn DispatchFor(comptime ProtocolType: type, comptime traced: bool) type {
    return struct {
        const Self = @This();
        const Protocol = ProtocolType;
        const Instructions = instruction.For(Protocol);
        const StorageInstructions = storage_instruction.For(Protocol);
        // ip rides in a register across tail calls; it always points at the NEXT
        // byte to decode (one past the handler's own opcode byte).
        const Handler = fn ([*]const u8, [*]u256, i64, *Context) TailStatus;

        const Entry = struct {
            opcode: Opcode,
            handler: *const Handler,
        };

        const JumpDestMaskInt = std.DynamicBitSetUnmanaged.MaskInt;

        const Context = struct {
            frame: *CallFrame,
            code_base: [*]const u8,
            // Jumpdest state flattened from frame.bytecode so JUMP/JUMPI avoid
            // the ctx -> frame -> bytecode -> bits pointer chase per jump.
            code_len: usize,
            jumpdest_masks: [*]const JumpDestMaskInt,
            stack_base: [*]u256,
            stack_limit: [*]u256,
            final_ip: [*]const u8 = undefined,
            final_sp: [*]u256 = undefined,
            final_gas: i64 = 0,
            err: ?anyerror = null,
            capture: if (traced) *trace.TraceCapture else void = if (traced) undefined else {},

            inline fn pcOf(self: *const Context, ip: [*]const u8) usize {
                return @intFromPtr(ip) - @intFromPtr(self.code_base);
            }

            inline fn isValidJumpTarget(self: *const Context, target: usize) bool {
                if (target >= self.code_len) return false;
                if (self.code_base[target] != @intFromEnum(Opcode.JUMPDEST)) return false;
                const shift: std.math.Log2Int(JumpDestMaskInt) = @truncate(target);
                return (self.jumpdest_masks[target / @bitSizeOf(JumpDestMaskInt)] & (@as(JumpDestMaskInt, 1) << shift)) != 0;
            }

            inline fn finish(self: *Context, ip: [*]const u8, sp: [*]u256, gas: i64, status: TailStatus) TailStatus {
                self.final_ip = ip;
                self.final_sp = sp;
                self.final_gas = gas;
                return status;
            }

            inline fn spill(self: *Context, ip: [*]const u8, sp: [*]u256, gas: i64) void {
                self.frame.pc = self.pcOf(ip);
                self.frame.gas_left = gas;
                self.frame.stack.len = self.stackLen(sp);
            }

            inline fn reloadSp(self: *Context) [*]u256 {
                return self.stack_base + self.frame.stack.len;
            }

            inline fn stackLen(self: *const Context, sp: [*]u256) usize {
                return (@intFromPtr(sp) - @intFromPtr(self.stack_base)) / @sizeOf(u256);
            }

            inline fn hasStack(self: *const Context, sp: [*]u256, needed: usize) bool {
                return (@intFromPtr(sp) - @intFromPtr(self.stack_base)) >= needed * @sizeOf(u256);
            }

            inline fn stackSlice(self: *const Context, sp: [*]u256) []const u256 {
                return self.stack_base[0..self.stackLen(sp)];
            }
        };

        const direct_entries = [_]Entry{
            // LLVM currently emits these table-referenced handlers in reverse
            // declaration order. Keep this accepted block stable; later
            // selective additions grow through promoted_entries below.
            .{ .opcode = .SMOD, .handler = &BinaryHandler(.SMOD, .smod).run },
            .{ .opcode = .BYTE, .handler = &BinaryHandler(.BYTE, .byte).run },
            .{ .opcode = .SDIV, .handler = &BinaryHandler(.SDIV, .sdiv).run },
            .{ .opcode = .SLT, .handler = &BinaryHandler(.SLT, .slt).run },
            .{ .opcode = .SGT, .handler = &BinaryHandler(.SGT, .sgt).run },
            .{ .opcode = .STOP, .handler = &tailStop },
            .{ .opcode = .ADD, .handler = &BinaryHandler(.ADD, .add).run },
            .{ .opcode = .MUL, .handler = &BinaryHandler(.MUL, .mul).run },
            .{ .opcode = .SUB, .handler = &BinaryHandler(.SUB, .sub).run },
            .{ .opcode = .DIV, .handler = &BinaryHandler(.DIV, .div).run },
            .{ .opcode = .MOD, .handler = &BinaryHandler(.MOD, .mod).run },
            .{ .opcode = .LT, .handler = &BinaryHandler(.LT, .lt).run },
            .{ .opcode = .GT, .handler = &BinaryHandler(.GT, .gt).run },
            .{ .opcode = .EQ, .handler = &BinaryHandler(.EQ, .eq).run },
            .{ .opcode = .ISZERO, .handler = &UnaryHandler(.ISZERO, .iszero).run },
            .{ .opcode = .AND, .handler = &BinaryHandler(.AND, .bit_and).run },
            .{ .opcode = .OR, .handler = &BinaryHandler(.OR, .bit_or).run },
            .{ .opcode = .XOR, .handler = &BinaryHandler(.XOR, .bit_xor).run },
            .{ .opcode = .NOT, .handler = &UnaryHandler(.NOT, .bit_not).run },
            .{ .opcode = .KECCAK256, .handler = &tailKeccak256 },
            .{ .opcode = .CALLDATALOAD, .handler = &tailCalldataLoad },
            .{ .opcode = .POP, .handler = &tailPop },
            .{ .opcode = .MLOAD, .handler = &tailMload },
            .{ .opcode = .MSTORE, .handler = &tailMstore },
            .{ .opcode = .MSTORE8, .handler = &tailMstore8 },
            .{ .opcode = .SLOAD, .handler = &tailSload },
            .{ .opcode = .SSTORE, .handler = &tailSstore },
            .{ .opcode = .JUMP, .handler = &tailJump },
            .{ .opcode = .JUMPI, .handler = &tailJumpi },
            .{ .opcode = .PC, .handler = &tailPc },
            .{ .opcode = .MSIZE, .handler = &tailMsize },
            .{ .opcode = .GAS, .handler = &tailGas },
            .{ .opcode = .JUMPDEST, .handler = &tailJumpdest },
        };

        // Reverse emission makes the final entry the stable edge nearest the
        // accepted direct block. Prepend later promotions to preserve addresses.
        const promoted_entries = [_]Entry{
            .{ .opcode = .EXP, .handler = &tailExp },
            .{ .opcode = .MCOPY, .handler = &tailMcopy },
            .{ .opcode = .TSTORE, .handler = &tailTstore },
            .{ .opcode = .TLOAD, .handler = &tailTload },
            .{ .opcode = .LOG4, .handler = &LogHandler(.LOG4, 4).run },
            .{ .opcode = .LOG3, .handler = &LogHandler(.LOG3, 3).run },
            .{ .opcode = .LOG2, .handler = &LogHandler(.LOG2, 2).run },
            .{ .opcode = .LOG1, .handler = &LogHandler(.LOG1, 1).run },
            .{ .opcode = .LOG0, .handler = &LogHandler(.LOG0, 0).run },
            .{ .opcode = .REVERT, .handler = &TerminalHandler(.REVERT, .revert).run },
            .{ .opcode = .RETURN, .handler = &TerminalHandler(.RETURN, .success).run },
            .{ .opcode = .RETURNDATACOPY, .handler = &CopyHandler(.RETURNDATACOPY, .return_data).run },
            .{ .opcode = .CODECOPY, .handler = &CopyHandler(.CODECOPY, .code).run },
            .{ .opcode = .CALLDATACOPY, .handler = &CopyHandler(.CALLDATACOPY, .calldata).run },
            .{ .opcode = .RETURNDATASIZE, .handler = &FrameValueHandler(.RETURNDATASIZE, .return_data_size).run },
            .{ .opcode = .ADDRESS, .handler = &FrameValueHandler(.ADDRESS, .address).run },
            .{ .opcode = .CALLER, .handler = &FrameValueHandler(.CALLER, .caller).run },
            .{ .opcode = .CALLVALUE, .handler = &FrameValueHandler(.CALLVALUE, .call_value).run },
            .{ .opcode = .CALLDATASIZE, .handler = &FrameValueHandler(.CALLDATASIZE, .calldata_size).run },
            .{ .opcode = .CODESIZE, .handler = &FrameValueHandler(.CODESIZE, .code_size).run },
            .{ .opcode = .SAR, .handler = &ShiftHandler(.SAR, .arithmetic).run },
        };

        const runtime_entries = [_]Entry{
            .{ .opcode = .PUSH0, .handler = &tailPush0 },
            .{ .opcode = .SHL, .handler = &ShiftHandler(.SHL, .left).run },
            .{ .opcode = .SHR, .handler = &ShiftHandler(.SHR, .right).run },
        };

        // Direct handlers are installed only when the protocol dispatch table resolves
        // the opcode to the same builtin. Most entries stay always-only; the small
        // runtime set performs its own revision check before charging gas.
        const table: [256]*const Handler = blk: {
            @setEvalBranchQuota(20_000);
            var handlers: [256]*const Handler = @splat(&tailCold);
            for (promoted_entries) |entry| {
                if (tailFastPathSupported(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (direct_entries) |entry| {
                if (tailFastPathAlways(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (runtime_entries) |entry| {
                if (tailFastPathSupported(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (@intFromEnum(Opcode.PUSH1)..@intFromEnum(Opcode.PUSH32) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPathAlways(opcode)) {
                    handlers[opcode_byte] = &PushHandler(opcode).run;
                }
            }
            for (@intFromEnum(Opcode.DUP1)..@intFromEnum(Opcode.DUP16) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPathAlways(opcode)) {
                    handlers[opcode_byte] = &DupHandler(opcode).run;
                }
            }
            for (@intFromEnum(Opcode.SWAP1)..@intFromEnum(Opcode.SWAP16) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPathAlways(opcode)) {
                    handlers[opcode_byte] = &SwapHandler(opcode).run;
                }
            }
            break :blk handlers;
        };

        // Captured rows wrap the selected core handler, then the core handler's
        // tail edge returns to this table. There is no generic one-op loop.
        const traced_table: [256]*const Handler = if (traced) blk: {
            var handlers: [256]*const Handler = undefined;
            for (0..handlers.len) |opcode_byte| {
                handlers[opcode_byte] = &TracedHandler(@intCast(opcode_byte)).run;
            }
            break :blk handlers;
        } else undefined;

        fn TracedHandler(comptime opcode_byte: u8) type {
            comptime std.debug.assert(traced);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const opcode_ip = ip - 1;
                    const pc = ctx.pcOf(opcode_ip);

                    // Prepared bytecode has trailing zero padding. Complete the
                    // real final step at the logical boundary and never record
                    // the padded STOP.
                    if (pc >= ctx.frame.code.len) {
                        ctx.frame.status = .success;
                        ctx.capture.finishStep(.{
                            .pc_next = pc,
                            .gas_after = gas,
                            .outcome = tapeStepOutcome(ctx.frame.status),
                            .stack = ctx.stackSlice(sp),
                            .memory = ctx.frame.memory.readBytes(0, ctx.frame.memory.len()),
                        }) catch |err| {
                            ctx.spill(opcode_ip, sp, gas);
                            ctx.err = err;
                            return .thrown;
                        };
                        return ctx.finish(opcode_ip, sp, gas, .done);
                    }

                    ctx.capture.finishStep(.{
                        .pc_next = pc,
                        .gas_after = gas,
                        .outcome = tapeStepOutcome(ctx.frame.status),
                        .stack = ctx.stackSlice(sp),
                        .memory = ctx.frame.memory.readBytes(0, ctx.frame.memory.len()),
                    }) catch |err| {
                        ctx.spill(opcode_ip, sp, gas);
                        ctx.err = err;
                        return .thrown;
                    };
                    ctx.capture.beginStep(.{
                        .frame_id = undefined,
                        .pc = pc,
                        .opcode = opcode_byte,
                        .gas_before = gas,
                        .refund_before = ctx.frame.gas_refund,
                        .stack_len = ctx.stackLen(sp),
                        .stack_prefix_len = stackPrefixLen(opcode_byte, ctx.stackLen(sp)),
                        .memory_size = ctx.frame.memory.len(),
                        .memory_write = if (ctx.capture.capturesMemoryWrites())
                            memoryWritePlan(opcode_byte, ctx.stackSlice(sp))
                        else
                            null,
                    }) catch |err| {
                        ctx.spill(opcode_ip, sp, gas);
                        ctx.err = err;
                        return .thrown;
                    };
                    return @call(.always_tail, table[opcode_byte], .{ ip, sp, gas, ctx });
                }
            };
        }

        inline fn tailFastPathAlways(comptime opcode: Opcode) bool {
            const availability = comptime Instructions.tailFastPathBuiltin(opcode) orelse return false;
            return availability == .always;
        }

        inline fn tailFastPathSupported(comptime opcode: Opcode) bool {
            const availability = comptime Instructions.tailFastPathBuiltin(opcode) orelse return false;
            return availability != .never;
        }

        pub fn execute(frame: *CallFrame, read_bytes: []const u8) anyerror!void {
            comptime std.debug.assert(!traced);
            return executeAt(frame, read_bytes.ptr);
        }

        fn executeAt(frame: *CallFrame, code_base: [*]const u8) anyerror!void {
            std.debug.assert(frame.bytecode.jumpdests.analyzed);
            const stack_base: [*]u256 = frame.stack.slots;
            var ctx = Context{
                .frame = frame,
                .code_base = code_base,
                .code_len = frame.code.len,
                .jumpdest_masks = frame.bytecode.jumpdests.bits.masks,
                .stack_base = stack_base,
                .stack_limit = stack_base + Stack.capacity,
            };

            const ip = code_base + frame.pc;
            const status = table[ip[0]](ip + 1, stack_base + frame.stack.len, frame.gas_left, &ctx);
            switch (status) {
                .done => ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas),
                .invalid => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.failWithStatus(.invalid);
                },
                .out_of_gas => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.failWithStatus(.out_of_gas);
                },
                .thrown => return ctx.err.?,
            }
        }

        pub fn executeTraced(capture: *trace.TraceCapture, frame: *CallFrame, read_bytes: []const u8) anyerror!void {
            if (comptime !traced) @compileError("executeTraced requires tail_dispatch.TraceFor");

            // A resumed CALL/CREATE completes its parent step before its next
            // opcode begins. Suspended frames retain the pending step until the
            // runtime applies the child result.
            if (frame.status != .suspended) {
                try capture.finishStep(.{
                    .pc_next = frame.pc,
                    .gas_after = frame.gas_left,
                    .outcome = tapeStepOutcome(frame.status),
                    .stack = frame.stack.asSlice(),
                    .memory = frame.memory.readBytes(0, frame.memory.len()),
                });
            }
            if (frame.status != .running) return;
            if (frame.pc >= frame.code.len) {
                frame.status = .success;
                return;
            }

            const code_base = read_bytes.ptr;
            std.debug.assert(frame.bytecode.jumpdests.analyzed);
            const stack_base: [*]u256 = frame.stack.slots;
            var ctx = Context{
                .frame = frame,
                .code_base = code_base,
                .code_len = frame.code.len,
                .jumpdest_masks = frame.bytecode.jumpdests.bits.masks,
                .stack_base = stack_base,
                .stack_limit = stack_base + Stack.capacity,
                .capture = capture,
            };

            const ip = code_base + frame.pc;
            const status = traced_table[ip[0]](ip + 1, stack_base + frame.stack.len, frame.gas_left, &ctx);
            switch (status) {
                .done => ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas),
                .invalid => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.failWithStatus(.invalid);
                },
                .out_of_gas => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.failWithStatus(.out_of_gas);
                },
                .thrown => return ctx.err.?,
            }

            if (frame.status != .suspended) {
                try capture.finishStep(.{
                    .pc_next = frame.pc,
                    .gas_after = frame.gas_left,
                    .outcome = tapeStepOutcome(frame.status),
                    .stack = frame.stack.asSlice(),
                    .memory = frame.memory.readBytes(0, frame.memory.len()),
                });
            }
        }

        // Zig requires .always_tail caller/callee signatures to match, so call this
        // only from opcode handlers with the Handler signature. `ip` must point at
        // the opcode byte to execute next.
        inline fn tailNext(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_table = if (traced) traced_table else table;
            return @call(.always_tail, next_table[ip[0]], .{ ip + 1, sp, gas, ctx });
        }

        inline fn charge(comptime opcode: Opcode, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const cost = Instructions.staticGasForFrame(ctx.frame, opcode);
            if (cost > gas) {
                @branchHint(.unlikely);
                _ = ctx.finish(ip, sp, gas, .out_of_gas);
                return null;
            }
            return gas - cost;
        }

        inline fn chargeGas(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context, cost: i64) ?i64 {
            if (cost > gas) {
                @branchHint(.unlikely);
                _ = ctx.finish(ip, sp, gas, .out_of_gas);
                return null;
            }
            return gas - cost;
        }

        inline fn requireOpcode(comptime opcode: Opcode, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?TailStatus {
            const maybe_availability = comptime Instructions.tailFastPathBuiltin(opcode);
            const availability = maybe_availability orelse return fail(ctx, ip, sp, gas, .invalid);
            return switch (comptime availability) {
                .always => null,
                .never => fail(ctx, ip, sp, gas, .invalid),
                .runtime => switch (comptime Protocol.Instruction.rawAvailability(
                    Protocol.Instruction.fromByte(@intFromEnum(opcode)),
                )) {
                    .always => null,
                    .never => fail(ctx, ip, sp, gas, .invalid),
                    .since => |activation| if (Instructions.revisionIncludes(Instructions.frameRevision(ctx.frame), activation)) null else fail(ctx, ip, sp, gas, .invalid),
                    .gate => |active| if (active(Instructions.frameRevision(ctx.frame))) null else fail(ctx, ip, sp, gas, .invalid),
                },
            };
        }

        // All fail() exits are exceptional (invalid opcode/stack/static, OOG).
        // noinline + cold marks every call site unlikely, so LLVM sinks the
        // exit blocks below each handler's fall-through fast path; an inline
        // @branchHint does not propagate to the caller's branch.
        noinline fn fail(ctx: *Context, ip: [*]const u8, sp: [*]u256, gas: i64, status: TailStatus) TailStatus {
            @branchHint(.cold);
            return ctx.finish(ip, sp, gas, status);
        }

        fn tailStop(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            ctx.frame.status = .success;
            return ctx.finish(ip, sp, gas, .done);
        }

        fn tailCold(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            ctx.spill(ip, sp, gas);
            const opcode_byte = (ip - 1)[0];
            executeColdOpcode(opcode_byte, ctx.frame) catch |err| {
                if (invalidStatusError(err)) {
                    if (ctx.frame.status == .running) {
                        ctx.frame.failWithStatus(.invalid);
                    }
                    return ctx.finish(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, .done);
                }
                ctx.err = err;
                return .thrown;
            };
            if (ctx.frame.status != .running) {
                return ctx.finish(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, .done);
            }
            return tailNext(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, ctx);
        }

        noinline fn executeColdOpcode(opcode_byte: u8, frame: *CallFrame) anyerror!void {
            // Common host-bound opcodes already paid the tail spill. Resolve their
            // protocol entry directly instead of crossing the generic cold switch again.
            return switch (opcode_byte) {
                @intFromEnum(Opcode.LOG0) => executeResolvedCold(.LOG0, frame),
                @intFromEnum(Opcode.LOG1) => executeResolvedCold(.LOG1, frame),
                @intFromEnum(Opcode.LOG2) => executeResolvedCold(.LOG2, frame),
                @intFromEnum(Opcode.LOG3) => executeResolvedCold(.LOG3, frame),
                @intFromEnum(Opcode.LOG4) => executeResolvedCold(.LOG4, frame),
                else => Instructions.execute(opcode_byte, frame),
            };
        }

        inline fn executeResolvedCold(comptime opcode: Opcode, frame: *CallFrame) anyerror!void {
            return Instructions.executeDispatchEntryForByte(@intFromEnum(opcode), frame);
        }

        fn tailSload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.SLOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);

            const key_slot = sp - 1;
            ctx.frame.gas_left = next_gas;
            const value = StorageInstructions.sloadAfterPop(ctx.frame, key_slot[0]) catch |err| {
                ctx.spill(ip, key_slot, ctx.frame.gas_left);
                ctx.err = err;
                return .thrown;
            };
            const loaded = value orelse return ctx.finish(ip, key_slot, ctx.frame.gas_left, .done);
            key_slot[0] = loaded;
            return tailNext(ip, sp, ctx.frame.gas_left, ctx);
        }

        fn tailSstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            // Canonical SSTORE has no static-gas charge; all accounting is
            // performed by sstoreAfterPop after the static/stack checks.
            if (ctx.frame.msg.is_static) return fail(ctx, ip, sp, gas, .invalid);
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, gas, .invalid);

            const next_sp = sp - 2;
            const key = (sp - 1)[0];
            const value = next_sp[0];
            ctx.frame.gas_left = gas;
            StorageInstructions.sstoreAfterPop(ctx.frame, key, value) catch |err| {
                ctx.spill(ip, next_sp, ctx.frame.gas_left);
                ctx.err = err;
                return .thrown;
            };
            if (ctx.frame.status != .running) {
                return ctx.finish(ip, next_sp, ctx.frame.gas_left, .done);
            }
            return tailNext(ip, next_sp, ctx.frame.gas_left, ctx);
        }

        fn tailTload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.TLOAD, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.TLOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);

            const slot = sp - 1;
            const value = ctx.frame.host.getTransientStorage(ctx.frame.msg.recipient, slot[0]) catch |err| {
                ctx.spill(ip, slot, next_gas);
                ctx.err = err;
                return .thrown;
            };
            slot[0] = value;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailTstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.TSTORE, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.TSTORE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (ctx.frame.msg.is_static) return fail(ctx, ip, sp, next_gas, .invalid);
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);

            const nsp = sp - 2;
            const key = (sp - 1)[0];
            ctx.frame.host.setTransientStorage(ctx.frame.msg.recipient, key, nsp[0]) catch |err| {
                ctx.spill(ip, nsp, next_gas);
                ctx.err = err;
                return .thrown;
            };
            return tailNext(ip, nsp, next_gas, ctx);
        }

        fn tailMcopy(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.MCOPY, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.MCOPY, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 3)) return fail(ctx, ip, sp, next_gas, .invalid);

            const nsp = sp - 3;
            const dest_word = (sp - 1)[0];
            const source_word = (sp - 2)[0];
            const size_word = nsp[0];
            if (size_word == 0) return tailNext(ip, nsp, next_gas, ctx);

            const dest = wordToUsizeOrOog(dest_word, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
            const source = wordToUsizeOrOog(source_word, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
            const size = wordToUsizeOrOog(size_word, ip, nsp, next_gas, ctx) orelse return .out_of_gas;

            // Canonical MCOPY expands the source range before the destination.
            const source_gas = expandMemory(source, size, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
            const dest_gas = expandMemory(dest, size, ip, nsp, source_gas, ctx) orelse return .out_of_gas;
            const copy_gas = copyWordGas(size, ip, nsp, dest_gas, ctx) orelse return .out_of_gas;
            const final_gas = chargeGas(ip, nsp, dest_gas, ctx, copy_gas) orelse return .out_of_gas;

            ctx.frame.memory.copy(dest, source, size);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn tailExp(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.EXP, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.EXP, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);

            const base = (sp - 1)[0];
            const exponent = (sp - 2)[0];
            const nsp = sp - 1;
            const byte_gas = Protocol.Instruction.expByteGas(Instructions.frameRevision(ctx.frame));
            const dynamic_gas = byte_gas * arithmetic_instruction.countSignificantBytesSize(exponent);
            const final_gas = chargeGas(ip, nsp - 1, next_gas, ctx, dynamic_gas) orelse return .out_of_gas;
            (nsp - 1)[0] = expOutlined(base, exponent);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn BinaryHandler(comptime opcode: Opcode, comptime op: BinaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
                    const a = (sp - 1)[0];
                    const b = (sp - 2)[0];
                    const nsp = sp - 1;
                    (nsp - 1)[0] = switch (op) {
                        .add => a +% b,
                        .mul => a *% b,
                        .sub => a -% b,
                        .div => divOutlined(a, b),
                        .sdiv => sdivOutlined(a, b),
                        .mod => modOutlined(a, b),
                        .smod => smodOutlined(a, b),
                        .lt => @intFromBool(a < b),
                        .gt => @intFromBool(a > b),
                        .slt => @intFromBool(@as(i256, @bitCast(a)) < @as(i256, @bitCast(b))),
                        .sgt => @intFromBool(@as(i256, @bitCast(a)) > @as(i256, @bitCast(b))),
                        .eq => @intFromBool(a == b),
                        .byte => if (a >= 32) 0 else (b >> ((31 - @as(u8, @intCast(a))) * 8)) & 0xff,
                        .bit_and => a & b,
                        .bit_or => a | b,
                        .bit_xor => a ^ b,
                    };
                    return tailNext(ip, nsp, next_gas, ctx);
                }
            };
        }

        fn FrameValueHandler(comptime opcode: Opcode, comptime value: FrameValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
                    sp[0] = switch (value) {
                        .address => evmz.address.toU256(ctx.frame.msg.recipient),
                        .caller => evmz.address.toU256(ctx.frame.msg.sender),
                        .call_value => ctx.frame.msg.value,
                        .calldata_size => @intCast(ctx.frame.msg.input_data.len),
                        .code_size => @intCast(ctx.frame.code.len),
                        .return_data_size => @intCast(ctx.frame.return_data.len),
                    };
                    return tailNext(ip, sp + 1, next_gas, ctx);
                }
            };
        }

        fn CopyHandler(comptime opcode: Opcode, comptime source_kind: CopySource) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 3)) return fail(ctx, ip, sp, next_gas, .invalid);

                    const nsp = sp - 3;
                    const dest_offset_word = (sp - 1)[0];
                    const source_offset_word = (sp - 2)[0];
                    const size_word = nsp[0];
                    const size = wordToUsizeOrOog(size_word, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
                    const dest_offset = memoryOffsetToUsizeOrOog(dest_offset_word, size, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
                    const memory_gas = expandMemory(dest_offset, size, ip, nsp, next_gas, ctx) orelse return .out_of_gas;
                    const copy_gas = copyWordGas(size, ip, nsp, memory_gas, ctx) orelse return .out_of_gas;
                    const final_gas = chargeGas(ip, nsp, memory_gas, ctx, copy_gas) orelse return .out_of_gas;

                    switch (source_kind) {
                        .calldata => ctx.frame.memory.writePaddedBytes(
                            dest_offset,
                            size,
                            sourceFromOffset(ctx.frame.msg.input_data, source_offset_word),
                        ),
                        .code => ctx.frame.memory.writePaddedBytes(
                            dest_offset,
                            size,
                            sourceFromOffset(ctx.frame.code, source_offset_word),
                        ),
                        .return_data => {
                            const source_offset = std.math.cast(usize, source_offset_word) orelse
                                return fail(ctx, ip, nsp, final_gas, .invalid);
                            if (source_offset > ctx.frame.return_data.len or size > ctx.frame.return_data.len - source_offset) {
                                return fail(ctx, ip, nsp, final_gas, .invalid);
                            }
                            ctx.frame.memory.writeBytes(
                                dest_offset,
                                ctx.frame.return_data[source_offset .. source_offset + size],
                            );
                        },
                    }
                    return tailNext(ip, nsp, final_gas, ctx);
                }
            };
        }

        fn TerminalHandler(comptime opcode: Opcode, comptime terminal_status: TerminalStatus) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, gas, .invalid);

                    const nsp = sp - 2;
                    const offset_word = (sp - 1)[0];
                    const size_word = nsp[0];
                    const size = wordToUsizeOrOog(size_word, ip, nsp, gas, ctx) orelse return .out_of_gas;
                    const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, nsp, gas, ctx) orelse return .out_of_gas;
                    const final_gas = expandMemory(offset, size, ip, nsp, gas, ctx) orelse return .out_of_gas;
                    const output = ctx.frame.memory.readBytes(offset, size);
                    ctx.frame.replaceOutputData(output) catch |err| {
                        ctx.spill(ip, nsp, final_gas);
                        ctx.err = err;
                        return .thrown;
                    };
                    ctx.frame.status = switch (terminal_status) {
                        .success => .success,
                        .revert => .revert,
                    };
                    return ctx.finish(ip, nsp, final_gas, .done);
                }
            };
        }

        fn LogHandler(comptime opcode: Opcode, comptime topic_count: usize) type {
            if (topic_count > 4) @compileError("LOG supports at most four topics");
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (ctx.frame.msg.is_static) return fail(ctx, ip, sp, next_gas, .invalid);
                    if (!ctx.hasStack(sp, 2 + topic_count)) return fail(ctx, ip, sp, next_gas, .invalid);

                    // Canonical logging pops offset/size before dynamic gas, then
                    // topics only after memory and data gas have succeeded.
                    const args_sp = sp - 2;
                    const offset_word = (sp - 1)[0];
                    const size_word = args_sp[0];
                    const size = wordToUsizeOrOog(size_word, ip, args_sp, next_gas, ctx) orelse return .out_of_gas;
                    const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, args_sp, next_gas, ctx) orelse return .out_of_gas;
                    const memory_gas = expandMemory(offset, size, ip, args_sp, next_gas, ctx) orelse return .out_of_gas;
                    const data_gas = logDataGas(size, ip, args_sp, memory_gas, ctx) orelse return .out_of_gas;
                    const final_gas = chargeGas(ip, args_sp, memory_gas, ctx, data_gas) orelse return .out_of_gas;

                    var topics: [topic_count]u256 = undefined;
                    inline for (0..topic_count) |index| {
                        topics[index] = (args_sp - 1 - index)[0];
                    }
                    const nsp = args_sp - topic_count;
                    ctx.frame.gas_left = final_gas;
                    ctx.frame.host.emitLog(.{
                        .address = ctx.frame.msg.recipient,
                        .topics = topics[0..],
                        .data = ctx.frame.memory.readBytes(offset, size),
                    }) catch |err| {
                        ctx.spill(ip, nsp, ctx.frame.gas_left);
                        ctx.err = err;
                        return .thrown;
                    };
                    return tailNext(ip, nsp, ctx.frame.gas_left, ctx);
                }
            };
        }

        fn UnaryHandler(comptime opcode: Opcode, comptime op: UnaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);
                    const slot = sp - 1;
                    slot[0] = switch (op) {
                        .iszero => @intFromBool(slot[0] == 0),
                        .bit_not => ~slot[0],
                    };
                    return tailNext(ip, sp, next_gas, ctx);
                }
            };
        }

        fn tailPop(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.POP, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);
            return tailNext(ip, sp - 1, next_gas, ctx);
        }

        fn tailPush0(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.PUSH0, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.PUSH0, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
            sp[0] = 0;
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn PushHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
                    const immediate_len: usize = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH0);
                    // read_bytes carries Bytecode.zero_padding_len (33) trailing zero
                    // bytes, so a full-width big-endian load is always in bounds and
                    // preserves truncated-push zero-fill semantics.
                    const Int = std.meta.Int(.unsigned, immediate_len * 8);
                    const immediate: *const [immediate_len]u8 = @ptrCast(ip);
                    sp[0] = std.mem.readInt(Int, immediate, .big);
                    return tailNext(ip + immediate_len, sp + 1, next_gas, ctx);
                }
            };
        }

        fn DupHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    const depth = @intFromEnum(opcode) - @intFromEnum(Opcode.DUP1) + 1;
                    if (!ctx.hasStack(sp, depth) or sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
                    sp[0] = (sp - depth)[0];
                    return tailNext(ip, sp + 1, next_gas, ctx);
                }
            };
        }

        fn SwapHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    const depth = @intFromEnum(opcode) - @intFromEnum(Opcode.SWAP1) + 1;
                    if (!ctx.hasStack(sp, depth + 1)) return fail(ctx, ip, sp, next_gas, .invalid);
                    const top = sp - 1;
                    const target = top - depth;
                    const tmp = target[0];
                    target[0] = top[0];
                    top[0] = tmp;
                    return tailNext(ip, sp, next_gas, ctx);
                }
            };
        }

        fn ShiftHandler(comptime opcode: Opcode, comptime op: ShiftOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
                    const shift = (sp - 1)[0];
                    const value = (sp - 2)[0];
                    const nsp = sp - 1;
                    (nsp - 1)[0] = switch (op) {
                        .left => if (shift > std.math.maxInt(u8)) 0 else uint256.shl(value, @as(u8, @intCast(shift))),
                        .right => if (shift > std.math.maxInt(u8)) 0 else value >> @as(u8, @intCast(shift)),
                        .arithmetic => arithmeticShiftRight(value, shift),
                    };
                    return tailNext(ip, nsp, next_gas, ctx);
                }
            };
        }

        inline fn arithmeticShiftRight(value: u256, shift: u256) u256 {
            const signed: i256 = @bitCast(value);
            if (shift >= std.math.maxInt(u8)) {
                return if (signed < 0) std.math.maxInt(u256) else 0;
            }
            return @bitCast(signed >> @as(u8, @intCast(shift)));
        }

        fn tailJump(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.JUMP, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);
            const nsp = sp - 1;
            const target = std.math.cast(usize, nsp[0]) orelse return fail(ctx, ip, nsp, next_gas, .invalid);
            if (!ctx.isValidJumpTarget(target)) return fail(ctx, ip, nsp, next_gas, .invalid);
            return tailNext(ctx.code_base + target, nsp, next_gas, ctx);
        }

        fn tailJumpi(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.JUMPI, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
            const nsp = sp - 2;
            if (nsp[0] == 0) return tailNext(ip, nsp, next_gas, ctx);
            const target = std.math.cast(usize, (nsp + 1)[0]) orelse return fail(ctx, ip, nsp, next_gas, .invalid);
            if (!ctx.isValidJumpTarget(target)) return fail(ctx, ip, nsp, next_gas, .invalid);
            return tailNext(ctx.code_base + target, nsp, next_gas, ctx);
        }

        fn tailPc(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.PC, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
            sp[0] = ctx.pcOf(ip) - 1;
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailMsize(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSIZE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
            sp[0] = ctx.frame.memory.len();
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailGas(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.GAS, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return fail(ctx, ip, sp, next_gas, .invalid);
            sp[0] = @intCast(next_gas);
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailJumpdest(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.JUMPDEST, ip, sp, gas, ctx) orelse return .out_of_gas;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailCalldataLoad(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.CALLDATALOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);
            const offset_word = (sp - 1)[0];
            var buffer: [32]u8 = [_]u8{0} ** 32;
            if (std.math.cast(usize, offset_word)) |offset| {
                const input = ctx.frame.msg.input_data;
                if (offset < input.len) {
                    const source = input[offset..];
                    const available = @min(buffer.len, source.len);
                    @memcpy(buffer[0..available], source[0..available]);
                }
            }
            (sp - 1)[0] = evmz.uint256.fromBytes32(&buffer);
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailMload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MLOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return fail(ctx, ip, sp, next_gas, .invalid);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const mem_gas = expandMemory(offset, 32, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            (sp - 1)[0] = ctx.frame.memory.read(offset);
            return tailNext(ip, sp, mem_gas, ctx);
        }

        fn tailMstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSTORE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const mem_gas = expandMemory(offset, 32, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const nsp = sp - 2;
            ctx.frame.memory.write(offset, nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailMstore8(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSTORE8, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const mem_gas = expandMemory(offset, 1, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const nsp = sp - 2;
            ctx.frame.memory.write8(offset, nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailKeccak256(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.KECCAK256, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return fail(ctx, ip, sp, next_gas, .invalid);
            const offset_word = (sp - 1)[0];
            const size_word = (sp - 2)[0];
            const size = wordToUsizeOrOog(size_word, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const mem_gas = expandMemory(offset, size, ip, sp, next_gas, ctx) orelse return .out_of_gas;
            const word_gas = keccakWordGas(size, ip, sp, mem_gas, ctx) orelse return .out_of_gas;
            const final_gas = chargeGas(ip, sp, mem_gas, ctx, word_gas) orelse return .out_of_gas;
            const input = ctx.frame.memory.readBytes(offset, size);
            const result = if (input.len == 0) evmz.crypto.keccak256_empty else evmz.crypto.keccak256(input);
            const nsp = sp - 1;
            (nsp - 1)[0] = evmz.uint256.fromBytes32(&result);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        inline fn wordToUsizeOrOog(value: u256, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?usize {
            return std.math.cast(usize, value) orelse {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn memoryOffsetToUsizeOrOog(offset: u256, byte_size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?usize {
            if (byte_size == 0) return 0;
            return wordToUsizeOrOog(offset, ip, sp, gas, ctx);
        }

        inline fn expandMemory(offset: usize, byte_size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            if (byte_size == 0) return gas;
            const end = std.math.add(usize, offset, byte_size) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            if (end <= ctx.frame.memory.len()) return gas;
            const expansion = ctx.frame.memory.expansionFor(offset, byte_size) catch |err| switch (err) {
                error.OutOfMemory => {
                    _ = fail(ctx, ip, sp, gas, .out_of_gas);
                    return null;
                },
            };
            const next_gas = chargeGas(ip, sp, gas, ctx, expansion.cost) orelse return null;
            ctx.frame.memory.expandPrepared(expansion) catch |err| switch (err) {
                error.OutOfMemory => {
                    _ = fail(ctx, ip, sp, next_gas, .out_of_gas);
                    return null;
                },
            };
            return next_gas;
        }

        inline fn keccakWordGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const padded = std.math.add(usize, size, 31) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            const words = padded / 32;
            const gas_usize = std.math.mul(usize, 6, words) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn copyWordGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const padded = std.math.add(usize, size, 31) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            const words = padded / 32;
            const gas_usize = std.math.mul(usize, 3, words) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn logDataGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const gas_usize = std.math.mul(usize, 8, size) catch {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = fail(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn sourceFromOffset(source: []const u8, offset_word: u256) []const u8 {
            const offset = std.math.cast(usize, offset_word) orelse return &.{};
            if (offset >= source.len) return &.{};
            return source[offset..];
        }

        fn stackPrefixLen(comptime opcode_byte: u8, before_len: usize) usize {
            const value = comptime Protocol.Instruction.fromByte(opcode_byte);
            const info = comptime Protocol.Instruction.info(value);
            if (!info.defined or before_len < info.stack_in) return 0;

            switch (comptime Protocol.Instruction.context(value)) {
                .byte => |inherited_byte| {
                    if (inherited_byte >= @intFromEnum(Opcode.DUP1) and
                        inherited_byte <= @intFromEnum(Opcode.DUP16))
                    {
                        return before_len;
                    }

                    // These instructions encode their affected suffix in an
                    // immediate byte. Fall back to a full post-stack until
                    // prepared-code metadata exposes that depth.
                    if (inherited_byte == @intFromEnum(Opcode.DUPN) or
                        inherited_byte == @intFromEnum(Opcode.SWAPN) or
                        inherited_byte == @intFromEnum(Opcode.EXCHANGE))
                    {
                        return 0;
                    }
                },
                .custom => {},
            }
            return before_len - info.stack_in;
        }

        fn memoryWritePlan(comptime opcode_byte: u8, stack: []const u256) ?trace.tape.MemoryWritePlan {
            const value = comptime Protocol.Instruction.fromByte(opcode_byte);
            return switch (comptime Protocol.Instruction.context(value)) {
                .byte => |inherited_byte| builtinMemoryWritePlan(inherited_byte, stack),
                // New instructions require an explicit trace-effect contract;
                // their runtime support is intentionally deferred.
                .custom => null,
            };
        }
    };
}

// Division lowerings are 2KB+ of code each; outlined they keep the contiguous
// handler region small (icache) while the work itself dwarfs the call overhead.
noinline fn divOutlined(a: u256, b: u256) u256 {
    return uint256.div(a, b);
}

noinline fn sdivOutlined(a: u256, b: u256) u256 {
    return uint256.sdiv(a, b);
}

noinline fn modOutlined(a: u256, b: u256) u256 {
    return uint256.mod(a, b);
}

noinline fn smodOutlined(a: u256, b: u256) u256 {
    return uint256.smod(a, b);
}

noinline fn expOutlined(base: u256, exponent: u256) u256 {
    return arithmetic_instruction.wrapExp(base, exponent);
}

fn tapeStepOutcome(status: Interpreter.FrameStatus) trace.TraceStepOutcome {
    return switch (status) {
        .running, .suspended, .success => .success,
        .invalid => .invalid,
        .revert => .revert,
        .out_of_gas => .out_of_gas,
    };
}

fn builtinMemoryWritePlan(opcode_byte: u8, stack: []const u256) ?trace.tape.MemoryWritePlan {
    const op = std.enums.fromInt(Opcode, opcode_byte) orelse return null;
    return switch (op) {
        .MSTORE => memoryRangeFromStack(stack, 1, null, 32),
        .MSTORE8 => memoryRangeFromStack(stack, 1, null, 1),
        .CALLDATACOPY, .CODECOPY, .RETURNDATACOPY, .MCOPY => memoryRangeFromStack(stack, 1, 3, null),
        .EXTCODECOPY => memoryRangeFromStack(stack, 2, 4, null),
        .CALL, .CALLCODE => memoryRangeFromStack(stack, 6, 7, null),
        .DELEGATECALL, .STATICCALL => memoryRangeFromStack(stack, 5, 6, null),
        else => null,
    };
}

fn memoryRangeFromStack(
    stack: []const u256,
    offset_depth: usize,
    size_depth: ?usize,
    fixed_size: ?usize,
) ?trace.tape.MemoryWritePlan {
    const required = @max(offset_depth, size_depth orelse 0);
    if (required == 0 or stack.len < required) return null;
    const offset = std.math.cast(usize, stack[stack.len - offset_depth]) orelse return null;
    const size = fixed_size orelse std.math.cast(usize, stack[stack.len - size_depth.?]) orelse return null;
    if (size == 0) return null;
    _ = std.math.add(usize, offset, size) catch return null;
    return .{ .offset = offset, .size = size };
}

test "captured memory plans use each opcode's destination operands" {
    try std.testing.expectEqual(
        trace.tape.MemoryWritePlan{ .offset = 3, .size = 5 },
        builtinMemoryWritePlan(@intFromEnum(Opcode.CALLDATACOPY), &.{ 5, 11, 3 }).?,
    );
    try std.testing.expectEqual(
        trace.tape.MemoryWritePlan{ .offset = 7, .size = 9 },
        builtinMemoryWritePlan(@intFromEnum(Opcode.EXTCODECOPY), &.{ 9, 11, 7, 13 }).?,
    );
    try std.testing.expectEqual(
        trace.tape.MemoryWritePlan{ .offset = 17, .size = 19 },
        builtinMemoryWritePlan(@intFromEnum(Opcode.CALL), &.{ 19, 17, 0, 0, 0, 0x1234, 100_000 }).?,
    );
    try std.testing.expectEqual(
        trace.tape.MemoryWritePlan{ .offset = 23, .size = 29 },
        builtinMemoryWritePlan(@intFromEnum(Opcode.STATICCALL), &.{ 29, 23, 0, 0, 0x1234, 100_000 }).?,
    );
    try std.testing.expect(builtinMemoryWritePlan(@intFromEnum(Opcode.MLOAD), &.{0}) == null);
}

fn invalidStatusError(err: anyerror) bool {
    return switch (err) {
        error.StackOverflow,
        error.StackUnderflow,
        error.StaticCallViolation,
        error.UnknownOpcode,
        error.UnsupportedInstruction,
        => true,
        else => false,
    };
}

test {
    _ = @import("./tail_dispatch_test.zig");
}
