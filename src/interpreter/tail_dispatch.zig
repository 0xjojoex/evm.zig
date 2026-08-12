const std = @import("std");

const evmz = @import("../evm.zig");
const ExactSpec = @import("../spec.zig").Spec;
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Stack = @import("../Stack.zig");
const uint256 = @import("../uint256.zig");
const instruction = @import("../instruction.zig");
const arithmetic_instruction = @import("../instruction/arithmetic.zig");
const environment_instruction = @import("../instruction/environment.zig");
const stack_instruction = @import("../instruction/stack.zig");
const storage_instruction = @import("../instruction/storage.zig");
const system_instruction = @import("../instruction/system.zig");
const trace = @import("../trace.zig");

const CallFrame = Interpreter.CallFrame;

const TailStatus = enum {
    done,
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
    sign_extend,
};

const UnaryOp = enum {
    iszero,
    bit_not,
    count_leading_zeros,
};

const TernaryOp = enum {
    add_mod,
    mul_mod,
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

const ContextValue = enum {
    origin,
    gas_price,
    base_fee,
    coinbase,
    timestamp,
    number,
    slot_number,
    prev_randao,
    gas_limit,
    chain_id,
    blob_base_fee,
};

const HostValue = enum {
    balance,
    code_size,
    code_hash,
    self_balance,
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

pub const Continuation = enum {
    chain,
    step,
};

/// Tail dispatch for an exact specification.
///
/// traced: whether the dispatch table should include traced handlers.
/// continuation: whether a successful opcode dispatches its successor or
/// returns after spilling the next instruction state.
pub fn Dispatch(comptime spec: ExactSpec, comptime cfg: struct {
    traced: bool,
    continuation: Continuation = .chain,
}) type {
    const traced = cfg.traced;
    const continuation = cfg.continuation;
    if (traced and continuation != .chain) {
        @compileError("traced tail dispatch requires chained continuation");
    }

    return struct {
        const Self = @This();
        const Instructions = instruction.Instruction(spec);
        const EnvironmentInstructions = environment_instruction.Enviroment(spec);
        const StorageInstructions = storage_instruction.Storage(spec);
        const SystemInstructions = system_instruction.System(spec);
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
            // Jumpdest state copied from the prepared view so JUMP/JUMPI avoid
            // an extra pointer chase per jump.
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
                const stack_len = self.stackLen(sp);
                std.debug.assert(stack_len <= Stack.capacity);
                self.frame.stack.len = @intCast(stack_len);
            }

            inline fn reloadSp(self: *Context) [*]u256 {
                return self.stack_base + self.frame.stack.len;
            }

            /// Fallback/custom handlers may synchronously re-enter the host and grow
            /// the packed arena. Refresh activation-local pointers before the
            /// tail loop resumes.
            inline fn refreshStackBase(self: *Context) void {
                self.stack_base = self.frame.stack.base;
                self.stack_limit = self.stack_base + Stack.capacity;
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

        const stable_tail_entries = [_]Entry{
            // LLVM currently emits these table-referenced handlers in reverse
            // declaration order. Keep this accepted block stable; later
            // selective additions grow through prepended_tail_entries below.
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
        const prepended_tail_entries = [_]Entry{
            .{ .opcode = .SELFDESTRUCT, .handler = &SystemHandler(.SELFDESTRUCT).run },
            .{ .opcode = .STATICCALL, .handler = &SystemHandler(.STATICCALL).run },
            .{ .opcode = .CREATE2, .handler = &SystemHandler(.CREATE2).run },
            .{ .opcode = .DELEGATECALL, .handler = &SystemHandler(.DELEGATECALL).run },
            .{ .opcode = .CALLCODE, .handler = &SystemHandler(.CALLCODE).run },
            .{ .opcode = .CALL, .handler = &SystemHandler(.CALL).run },
            .{ .opcode = .CREATE, .handler = &SystemHandler(.CREATE).run },
            .{ .opcode = .EXCHANGE, .handler = &ExtendedStackHandler(.EXCHANGE).run },
            .{ .opcode = .SWAPN, .handler = &ExtendedStackHandler(.SWAPN).run },
            .{ .opcode = .DUPN, .handler = &ExtendedStackHandler(.DUPN).run },
            .{ .opcode = .BLOBHASH, .handler = &tailBlobhash },
            .{ .opcode = .BLOCKHASH, .handler = &tailBlockhash },
            .{ .opcode = .EXTCODECOPY, .handler = &tailExtcodecopy },
            .{ .opcode = .SELFBALANCE, .handler = &HostValueHandler(.SELFBALANCE, .self_balance).run },
            .{ .opcode = .EXTCODEHASH, .handler = &HostValueHandler(.EXTCODEHASH, .code_hash).run },
            .{ .opcode = .EXTCODESIZE, .handler = &HostValueHandler(.EXTCODESIZE, .code_size).run },
            .{ .opcode = .BALANCE, .handler = &HostValueHandler(.BALANCE, .balance).run },
            .{ .opcode = .CLZ, .handler = &UnaryHandler(.CLZ, .count_leading_zeros).run },
            .{ .opcode = .SIGNEXTEND, .handler = &BinaryHandler(.SIGNEXTEND, .sign_extend).run },
            .{ .opcode = .MULMOD, .handler = &TernaryHandler(.MULMOD, .mul_mod).run },
            .{ .opcode = .ADDMOD, .handler = &TernaryHandler(.ADDMOD, .add_mod).run },
            .{ .opcode = .BLOBBASEFEE, .handler = &ContextValueHandler(.BLOBBASEFEE, .blob_base_fee).run },
            .{ .opcode = .SLOTNUM, .handler = &ContextValueHandler(.SLOTNUM, .slot_number).run },
            .{ .opcode = .CHAINID, .handler = &ContextValueHandler(.CHAINID, .chain_id).run },
            .{ .opcode = .GASLIMIT, .handler = &ContextValueHandler(.GASLIMIT, .gas_limit).run },
            .{ .opcode = .PREVRANDAO, .handler = &ContextValueHandler(.PREVRANDAO, .prev_randao).run },
            .{ .opcode = .NUMBER, .handler = &ContextValueHandler(.NUMBER, .number).run },
            .{ .opcode = .TIMESTAMP, .handler = &ContextValueHandler(.TIMESTAMP, .timestamp).run },
            .{ .opcode = .COINBASE, .handler = &ContextValueHandler(.COINBASE, .coinbase).run },
            .{ .opcode = .BASEFEE, .handler = &ContextValueHandler(.BASEFEE, .base_fee).run },
            .{ .opcode = .GASPRICE, .handler = &ContextValueHandler(.GASPRICE, .gas_price).run },
            .{ .opcode = .ORIGIN, .handler = &ContextValueHandler(.ORIGIN, .origin).run },
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

        const trailing_tail_entries = [_]Entry{
            .{ .opcode = .PUSH0, .handler = &tailPush0 },
            .{ .opcode = .SHL, .handler = &ShiftHandler(.SHL, .left).run },
            .{ .opcode = .SHR, .handler = &ShiftHandler(.SHR, .right).run },
        };

        // Direct handlers are installed when the exact dispatch table resolves
        // the byte to the same builtin. Invalid targets fail immediately;
        // custom and repointed targets are patched in after the canonical set.
        const table: [256]*const Handler = blk: {
            @setEvalBranchQuota(20_000);
            var handlers: [256]*const Handler = @splat(&tailInvalid);
            for (prepended_tail_entries) |entry| {
                if (tailFastPath(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (stable_tail_entries) |entry| {
                if (tailFastPath(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (trailing_tail_entries) |entry| {
                if (tailFastPath(entry.opcode)) {
                    handlers[@intFromEnum(entry.opcode)] = entry.handler;
                }
            }
            for (@intFromEnum(Opcode.PUSH1)..@intFromEnum(Opcode.PUSH32) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPath(opcode)) {
                    handlers[opcode_byte] = &PushHandler(opcode).run;
                }
            }
            for (@intFromEnum(Opcode.DUP1)..@intFromEnum(Opcode.DUP16) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPath(opcode)) {
                    handlers[opcode_byte] = &DupHandler(opcode).run;
                }
            }
            for (@intFromEnum(Opcode.SWAP1)..@intFromEnum(Opcode.SWAP16) + 1) |opcode_byte| {
                const opcode: Opcode = @enumFromInt(opcode_byte);
                if (tailFastPath(opcode)) {
                    handlers[opcode_byte] = &SwapHandler(opcode).run;
                }
            }
            for (0..handlers.len) |opcode_index| {
                const opcode_byte: u8 = @intCast(opcode_index);
                switch (Instructions.entry(opcode_byte).dispatchTarget()) {
                    .invalid => {},
                    .custom => |Custom| handlers[opcode_index] = &CustomHandler(Custom).run,
                    .builtin => |opcode| if (!tailFastPath(@enumFromInt(opcode_byte))) {
                        handlers[opcode_index] = builtinTailHandler(opcode);
                    },
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
                        ctx.frame.halt(.success);
                        ctx.capture.finishStep(.{
                            .pc_next = pc,
                            .gas_after = gas,
                            .outcome = tapeStepOutcome(&ctx.frame.state),
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
                        .outcome = tapeStepOutcome(&ctx.frame.state),
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

        inline fn tailFastPath(comptime opcode: Opcode) bool {
            return Instructions.tailFastPathBuiltin(opcode);
        }

        inline fn builtinTailHandler(comptime opcode: Opcode) *const Handler {
            inline for (prepended_tail_entries ++ stable_tail_entries ++ trailing_tail_entries) |entry| {
                if (opcode == entry.opcode) return entry.handler;
            }
            const opcode_byte = @intFromEnum(opcode);
            if (opcode_byte >= @intFromEnum(Opcode.PUSH1) and opcode_byte <= @intFromEnum(Opcode.PUSH32))
                return &PushHandler(opcode).run;
            if (opcode_byte >= @intFromEnum(Opcode.DUP1) and opcode_byte <= @intFromEnum(Opcode.DUP16))
                return &DupHandler(opcode).run;
            if (opcode_byte >= @intFromEnum(Opcode.SWAP1) and opcode_byte <= @intFromEnum(Opcode.SWAP16))
                return &SwapHandler(opcode).run;
            if (opcode == .INVALID) return &tailInvalid;
            @compileError("missing tail handler for builtin " ++ @tagName(opcode));
        }

        pub fn execute(frame: *CallFrame) anyerror!void {
            comptime {
                std.debug.assert(!traced);
                std.debug.assert(continuation == .chain);
            }
            return executeAt(frame, frame.code.ptr);
        }

        pub fn executeInstruction(frame: *CallFrame) anyerror!void {
            comptime {
                std.debug.assert(!traced);
                std.debug.assert(continuation == .step);
            }
            return executeAt(frame, frame.code.ptr);
        }

        fn executeAt(frame: *CallFrame, code_base: [*]const u8) anyerror!void {
            const stack_base = frame.stack.base;
            var ctx = Context{
                .frame = frame,
                .code_base = code_base,
                .code_len = frame.code.len,
                .jumpdest_masks = frame.jumpdest_masks,
                .stack_base = stack_base,
                .stack_limit = stack_base + Stack.capacity,
            };

            const ip = code_base + frame.pc;
            const status = dispatchFirst(ip, stack_base + frame.stack.len, frame.gas_left, &ctx);
            switch (status) {
                .done => ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas),
                .out_of_gas => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.halt(.out_of_gas);
                },
                .thrown => return ctx.err.?,
            }
        }

        inline fn dispatchFirst(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (comptime continuation == .step) {
                @setEvalBranchQuota(30_000);
                return switch (ip[0]) {
                    inline 0...255 => |opcode_byte| table[opcode_byte](ip + 1, sp, gas, ctx),
                };
            }
            return table[ip[0]](ip + 1, sp, gas, ctx);
        }

        pub fn executeTraced(capture: *trace.TraceCapture, frame: *CallFrame) anyerror!void {
            if (comptime !traced) @compileError("executeTraced requires tail_dispatch.bindTrace");

            // A resumed CALL/CREATE completes its parent step before its next
            // opcode begins. Suspended frames retain the pending step until the
            // runtime applies the child result.
            if (!frame.isSuspended()) {
                try capture.finishStep(.{
                    .pc_next = frame.pc,
                    .gas_after = frame.gas_left,
                    .outcome = tapeStepOutcome(&frame.state),
                    .stack = frame.stack.asSlice(),
                    .memory = frame.memory.readBytes(0, frame.memory.len()),
                });
            }
            if (!frame.isRunning()) return;
            if (frame.pc >= frame.code.len) {
                frame.halt(.success);
                return;
            }

            const code_base = frame.code.ptr;
            const stack_base = frame.stack.base;
            var ctx = Context{
                .frame = frame,
                .code_base = code_base,
                .code_len = frame.code.len,
                .jumpdest_masks = frame.jumpdest_masks,
                .stack_base = stack_base,
                .stack_limit = stack_base + Stack.capacity,
                .capture = capture,
            };

            const ip = code_base + frame.pc;
            const status = traced_table[ip[0]](ip + 1, stack_base + frame.stack.len, frame.gas_left, &ctx);
            switch (status) {
                .done => ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas),
                .out_of_gas => {
                    ctx.spill(ctx.final_ip, ctx.final_sp, ctx.final_gas);
                    frame.halt(.out_of_gas);
                },
                .thrown => return ctx.err.?,
            }

            if (!frame.isSuspended()) {
                try capture.finishStep(.{
                    .pc_next = frame.pc,
                    .gas_after = frame.gas_left,
                    .outcome = tapeStepOutcome(&frame.state),
                    .stack = frame.stack.asSlice(),
                    .memory = frame.memory.readBytes(0, frame.memory.len()),
                });
            }
        }

        // Zig requires .always_tail caller/callee signatures to match, so call this
        // only from opcode handlers with the Handler signature. `ip` must point at
        // the opcode byte to execute next.
        inline fn tailNext(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (comptime continuation == .step) return ctx.finish(ip, sp, gas, .done);
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
            if (comptime Instructions.tailFastPathBuiltin(opcode)) return null;
            return halt(ctx, ip, sp, gas, .invalid_opcode);
        }

        inline fn halt(ctx: *Context, ip: [*]const u8, sp: [*]u256, gas: i64, reason: Interpreter.FrameHalt) TailStatus {
            _ = gas;
            ctx.frame.halt(reason);
            return ctx.finish(ip, sp, 0, .done);
        }

        noinline fn recordError(ctx: *Context, ip: [*]const u8, sp: [*]u256, gas: i64, err: anyerror) void {
            @branchHint(.cold);
            ctx.spill(ip, sp, gas);
            ctx.err = err;
        }

        fn tailStop(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            ctx.frame.halt(.success);
            return ctx.finish(ip, sp, gas, .done);
        }

        fn tailInvalid(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            return halt(ctx, ip, sp, gas, .invalid_opcode);
        }

        fn CustomHandler(comptime Custom: type) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    ctx.spill(ip, sp, gas);
                    Custom.execute(Instructions, ctx.frame) catch |err| {
                        ctx.err = err;
                        return .thrown;
                    };
                    ctx.refreshStackBase();
                    if (!ctx.frame.isRunning()) {
                        return ctx.finish(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, .done);
                    }
                    return tailNext(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, ctx);
                }
            };
        }

        fn tailSload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.SLOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const key_slot = sp - 1;
            ctx.frame.gas_left = next_gas;
            const value = StorageInstructions.sloadAfterPop(ctx.frame, key_slot[0]) catch |err| {
                recordError(ctx, ip, key_slot, ctx.frame.gas_left, err);
                return .thrown;
            };
            const loaded = value orelse return ctx.finish(ip, key_slot, ctx.frame.gas_left, .done);
            key_slot[0] = loaded;
            return tailNext(ip, sp, ctx.frame.gas_left, ctx);
        }

        fn tailSstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            // Canonical SSTORE has no static-gas charge; all accounting is
            // performed by sstoreAfterPop after the static/stack checks.
            if (ctx.frame.msg.is_static) return halt(ctx, ip, sp, gas, .write_protection);
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, gas, .stack_underflow);

            const next_sp = sp - 2;
            const key = (sp - 1)[0];
            const value = next_sp[0];
            ctx.frame.gas_left = gas;
            StorageInstructions.sstoreAfterPop(ctx.frame, key, value) catch |err| {
                ctx.spill(ip, next_sp, ctx.frame.gas_left);
                ctx.err = err;
                return .thrown;
            };
            if (!ctx.frame.isRunning()) {
                return ctx.finish(ip, next_sp, ctx.frame.gas_left, .done);
            }
            return tailNext(ip, next_sp, ctx.frame.gas_left, ctx);
        }

        fn tailTload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.TLOAD, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.TLOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const slot = sp - 1;
            const recipient: evmz.AddressWord = .fromAddress(ctx.frame.msg.recipient);
            const value = ctx.frame.host.getTransientStorage(recipient, slot[0]) catch |err| {
                recordError(ctx, ip, slot, next_gas, err);
                return .thrown;
            };
            slot[0] = value;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailTstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.TSTORE, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.TSTORE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (ctx.frame.msg.is_static) return halt(ctx, ip, sp, next_gas, .write_protection);
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const nsp = sp - 2;
            const key = (sp - 1)[0];
            const recipient: evmz.AddressWord = .fromAddress(ctx.frame.msg.recipient);
            ctx.frame.host.setTransientStorage(recipient, key, nsp[0]) catch |err| {
                recordError(ctx, ip, nsp, next_gas, err);
                return .thrown;
            };
            return tailNext(ip, nsp, next_gas, ctx);
        }

        fn tailMcopy(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.MCOPY, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.MCOPY, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 3)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const nsp = sp - 3;
            const dest_word = (sp - 1)[0];
            const source_word = (sp - 2)[0];
            const size_word = nsp[0];
            if (size_word == 0) return tailNext(ip, nsp, next_gas, ctx);

            const dest = wordToUsizeOrOog(dest_word, ip, nsp, next_gas, ctx) orelse return .done;
            const source = wordToUsizeOrOog(source_word, ip, nsp, next_gas, ctx) orelse return .done;
            const size = wordToUsizeOrOog(size_word, ip, nsp, next_gas, ctx) orelse return .done;

            // Canonical MCOPY expands the source range before the destination.
            const source_gas = expandMemory(source, size, ip, nsp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
            const dest_gas = expandMemory(dest, size, ip, nsp, source_gas, ctx) orelse return memoryFailureStatus(ctx);
            const copy_gas = copyWordGas(size, ip, nsp, dest_gas, ctx) orelse return .done;
            const final_gas = chargeGas(ip, nsp, dest_gas, ctx, copy_gas) orelse return .out_of_gas;

            ctx.frame.memory.copy(dest, source, size);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn tailExp(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.EXP, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.EXP, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const base = (sp - 1)[0];
            const exponent = (sp - 2)[0];
            const nsp = sp - 1;
            const byte_gas = spec.instruction.exp_byte_gas;
            const dynamic_gas = byte_gas * arithmetic_instruction.countSignificantBytesSize(exponent);
            const final_gas = chargeGas(ip, nsp - 1, next_gas, ctx, dynamic_gas) orelse return .out_of_gas;
            (nsp - 1)[0] = expOutlined(base, exponent);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn BinaryHandler(comptime opcode: Opcode, comptime op: BinaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
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
                        .sign_extend => blk: {
                            if (a >= 32) break :blk b;
                            const sign_bit: u8 = @as(u8, @intCast(a)) * 8 + 7;
                            const mask = std.math.shl(u256, 1, sign_bit) - 1;
                            break :blk if (((b >> sign_bit) & 1) != 0) b | ~mask else b & mask;
                        },
                    };
                    return tailNext(ip, nsp, next_gas, ctx);
                }
            };
        }

        fn TernaryHandler(comptime opcode: Opcode, comptime op: TernaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 3)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    const a = (sp - 1)[0];
                    const b = (sp - 2)[0];
                    const result_slot = sp - 3;
                    result_slot[0] = switch (op) {
                        .add_mod => uint256.addMod(a, b, result_slot[0]),
                        .mul_mod => uint256.mulMod(a, b, result_slot[0]),
                    };
                    return tailNext(ip, sp - 2, next_gas, ctx);
                }
            };
        }

        fn FrameValueHandler(comptime opcode: Opcode, comptime value: FrameValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
                    sp[0] = switch (value) {
                        .address => ctx.frame.msg.recipient.toU256(),
                        .caller => ctx.frame.msg.sender.toU256(),
                        .call_value => ctx.frame.msg.value,
                        .calldata_size => @intCast(ctx.frame.msg.input_data.len),
                        .code_size => @intCast(ctx.frame.code.len),
                        .return_data_size => @intCast(ctx.frame.return_data.len),
                    };
                    return tailNext(ip, sp + 1, next_gas, ctx);
                }
            };
        }

        fn ContextValueHandler(comptime opcode: Opcode, comptime value: ContextValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
                    const execution_context = ctx.frame.host.executionContext() catch |err| {
                        recordError(ctx, ip, sp, next_gas, err);
                        return .thrown;
                    };
                    sp[0] = switch (value) {
                        .origin => execution_context.transaction.origin.toU256(),
                        .gas_price => execution_context.transaction.gas_price,
                        .base_fee => execution_context.block.base_fee,
                        .coinbase => execution_context.block.coinbase.toU256(),
                        .timestamp => execution_context.block.timestamp,
                        .number => execution_context.block.number,
                        .slot_number => execution_context.block.slot_number,
                        .prev_randao => execution_context.block.difficulty_or_prev_randao,
                        .gas_limit => execution_context.block.gas_limit,
                        .chain_id => execution_context.chain.chain_id,
                        .blob_base_fee => execution_context.block.blob_base_fee,
                    };
                    return tailNext(ip, sp + 1, next_gas, ctx);
                }
            };
        }

        fn HostValueHandler(comptime opcode: Opcode, comptime value: HostValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;

                    if (comptime value == .self_balance) {
                        if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
                        const result = ctx.frame.host.getBalance(.fromAddress(ctx.frame.msg.recipient)) catch |err| {
                            recordError(ctx, ip, sp, next_gas, err);
                            return .thrown;
                        };
                        sp[0] = result;
                        return tailNext(ip, sp + 1, next_gas, ctx);
                    }

                    if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    const slot = sp - 1;
                    const target_address: evmz.AddressWord = .fromU256(slot[0]);
                    ctx.frame.gas_left = next_gas;
                    const result = EnvironmentInstructions.readAccountValue(ctx.frame, target_address, switch (value) {
                        .balance => .balance,
                        .code_size => .code_size,
                        .code_hash => .code_hash,
                        .self_balance => unreachable,
                    }) catch |err| {
                        recordError(ctx, ip, slot, ctx.frame.gas_left, err);
                        return .thrown;
                    };
                    slot[0] = result orelse return ctx.finish(ip, slot, ctx.frame.gas_left, .done);
                    return tailNext(ip, sp, ctx.frame.gas_left, ctx);
                }
            };
        }

        fn tailExtcodecopy(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.EXTCODECOPY, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 4)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

            const nsp = sp - 4;
            const target_address: evmz.AddressWord = .fromU256((sp - 1)[0]);
            const dest_offset_word = (sp - 2)[0];
            const source_offset_word = (sp - 3)[0];
            const size = wordToUsizeOrOog(nsp[0], ip, nsp, next_gas, ctx) orelse return .done;
            const dest_offset = memoryOffsetToUsizeOrOog(dest_offset_word, size, ip, nsp, next_gas, ctx) orelse return .done;

            ctx.frame.gas_left = next_gas;
            const access_ok = EnvironmentInstructions.trackCodeAccountAccessGas(ctx.frame, target_address) catch |err| {
                recordError(ctx, ip, nsp, ctx.frame.gas_left, err);
                return .thrown;
            };
            if (!access_ok) return ctx.finish(ip, nsp, ctx.frame.gas_left, .done);

            const memory_gas = expandMemory(dest_offset, size, ip, nsp, ctx.frame.gas_left, ctx) orelse return memoryFailureStatus(ctx);
            const copy_gas = copyWordGas(size, ip, nsp, memory_gas, ctx) orelse return .done;
            const final_gas = chargeGas(ip, nsp, memory_gas, ctx, copy_gas) orelse return .out_of_gas;
            ctx.frame.traceAccountAccess(target_address) catch |err| {
                recordError(ctx, ip, nsp, final_gas, err);
                return .thrown;
            };

            const dest = ctx.frame.memory.writeSlice(dest_offset, size);
            var copied: usize = 0;
            if (std.math.cast(usize, source_offset_word)) |source_offset| {
                copied = @min(ctx.frame.host.copyCode(target_address, source_offset, dest) catch |err| {
                    recordError(ctx, ip, nsp, final_gas, err);
                    return .thrown;
                }, dest.len);
            }
            if (copied < dest.len) @memset(dest[copied..], 0);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn tailBlockhash(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.BLOCKHASH, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const slot = sp - 1;
            const execution_context = ctx.frame.host.executionContext() catch |err| {
                recordError(ctx, ip, sp, next_gas, err);
                return .thrown;
            };
            const current_number: u256 = execution_context.block.number;
            const oldest_hashable = if (current_number > 256) current_number - 256 else 0;
            slot[0] = if (slot[0] < current_number and slot[0] >= oldest_hashable)
                ctx.frame.host.getBlockHash(slot[0]) catch |err| {
                    recordError(ctx, ip, sp, next_gas, err);
                    return .thrown;
                }
            else
                0;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailBlobhash(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.BLOBHASH, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.BLOBHASH, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const slot = sp - 1;
            const execution_context = ctx.frame.host.executionContext() catch |err| {
                recordError(ctx, ip, sp, next_gas, err);
                return .thrown;
            };
            const index = std.math.cast(usize, slot[0]);
            slot[0] = if (index) |i|
                if (i < execution_context.transaction.blob_hashes.len) execution_context.transaction.blob_hashes[i] else 0
            else
                0;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn ExtendedStackHandler(comptime opcode: Opcode) type {
            comptime std.debug.assert(opcode == .DUPN or opcode == .SWAPN or opcode == .EXCHANGE);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;

                    if (comptime opcode == .EXCHANGE) {
                        const n, const m = stack_instruction.decodeExchangeImmediate(ip[0]) orelse
                            return halt(ctx, ip, sp, next_gas, .invalid_opcode);
                        if (!ctx.hasStack(sp, @max(n, m) + 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                        const top = sp - 1;
                        std.mem.swap(u256, &((top - n)[0]), &((top - m)[0]));
                        return tailNext(ip + 1, sp, next_gas, ctx);
                    }

                    const depth = stack_instruction.decodeDepthImmediate(ip[0]) orelse
                        return halt(ctx, ip, sp, next_gas, .invalid_opcode);
                    if (comptime opcode == .DUPN) {
                        if (!ctx.hasStack(sp, depth)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                        if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
                        sp[0] = (sp - depth)[0];
                        return tailNext(ip + 1, sp + 1, next_gas, ctx);
                    }

                    if (!ctx.hasStack(sp, depth + 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    const top = sp - 1;
                    std.mem.swap(u256, &top[0], &((top - depth)[0]));
                    return tailNext(ip + 1, sp, next_gas, ctx);
                }
            };
        }

        fn SystemHandler(comptime opcode: Opcode) type {
            comptime std.debug.assert(opcode == .CREATE or opcode == .CALL or opcode == .CALLCODE or
                opcode == .DELEGATECALL or opcode == .CREATE2 or opcode == .STATICCALL or
                opcode == .SELFDESTRUCT);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    ctx.spill(ip, sp, next_gas);
                    (switch (opcode) {
                        .CREATE => SystemInstructions.create(ctx.frame),
                        .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => SystemInstructions.callByOp(ctx.frame, opcode),
                        .CREATE2 => SystemInstructions.create2(ctx.frame),
                        .SELFDESTRUCT => SystemInstructions.selfdestruct(ctx.frame),
                        else => unreachable,
                    }) catch |err| {
                        ctx.err = err;
                        return .thrown;
                    };
                    ctx.refreshStackBase();
                    if (!ctx.frame.isRunning()) {
                        return ctx.finish(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, .done);
                    }
                    return tailNext(ctx.code_base + ctx.frame.pc, ctx.reloadSp(), ctx.frame.gas_left, ctx);
                }
            };
        }

        fn CopyHandler(comptime opcode: Opcode, comptime source_kind: CopySource) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (requireOpcode(opcode, ip, sp, gas, ctx)) |status| return status;
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, 3)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

                    const nsp = sp - 3;
                    const dest_offset_word = (sp - 1)[0];
                    const source_offset_word = (sp - 2)[0];
                    const size_word = nsp[0];
                    const size = wordToUsizeOrOog(size_word, ip, nsp, next_gas, ctx) orelse return .done;
                    const dest_offset = memoryOffsetToUsizeOrOog(dest_offset_word, size, ip, nsp, next_gas, ctx) orelse return .done;
                    const memory_gas = expandMemory(dest_offset, size, ip, nsp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
                    const copy_gas = copyWordGas(size, ip, nsp, memory_gas, ctx) orelse return .done;
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
                                return halt(ctx, ip, nsp, final_gas, .return_data_out_of_bounds);
                            if (source_offset > ctx.frame.return_data.len or size > ctx.frame.return_data.len - source_offset) {
                                return halt(ctx, ip, nsp, final_gas, .return_data_out_of_bounds);
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
                    if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, gas, .stack_underflow);

                    const nsp = sp - 2;
                    const offset_word = (sp - 1)[0];
                    const size_word = nsp[0];
                    const size = wordToUsizeOrOog(size_word, ip, nsp, gas, ctx) orelse return .done;
                    const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, nsp, gas, ctx) orelse return .done;
                    const final_gas = expandMemory(offset, size, ip, nsp, gas, ctx) orelse return memoryFailureStatus(ctx);
                    ctx.frame.setOutputRange(offset, size);
                    ctx.frame.halt(switch (terminal_status) {
                        .success => .success,
                        .revert => .revert,
                    });
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
                    if (ctx.frame.msg.is_static) return halt(ctx, ip, sp, next_gas, .write_protection);
                    if (!ctx.hasStack(sp, 2 + topic_count)) return halt(ctx, ip, sp, next_gas, .stack_underflow);

                    // Canonical logging pops offset/size before dynamic gas, then
                    // topics only after memory and data gas have succeeded.
                    const args_sp = sp - 2;
                    const offset_word = (sp - 1)[0];
                    const size_word = args_sp[0];
                    const size = wordToUsizeOrOog(size_word, ip, args_sp, next_gas, ctx) orelse return .done;
                    const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, args_sp, next_gas, ctx) orelse return .done;
                    const memory_gas = expandMemory(offset, size, ip, args_sp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
                    const data_gas = logDataGas(size, ip, args_sp, memory_gas, ctx) orelse return .done;
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
                    if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    const slot = sp - 1;
                    slot[0] = switch (op) {
                        .iszero => @intFromBool(slot[0] == 0),
                        .bit_not => ~slot[0],
                        .count_leading_zeros => @clz(slot[0]),
                    };
                    return tailNext(ip, sp, next_gas, ctx);
                }
            };
        }

        fn tailPop(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.POP, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            return tailNext(ip, sp - 1, next_gas, ctx);
        }

        fn tailPush0(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (requireOpcode(.PUSH0, ip, sp, gas, ctx)) |status| return status;
            const next_gas = charge(.PUSH0, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
            sp[0] = 0;
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn PushHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const next_gas = charge(opcode, ip, sp, gas, ctx) orelse return .out_of_gas;
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
                    const immediate_len: usize = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH0);
                    // `code_base` carries Bytecode.zero_padding_len (33) trailing zero
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
                    if (!ctx.hasStack(sp, depth)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
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
                    if (!ctx.hasStack(sp, depth + 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
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
                    if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
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
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const nsp = sp - 1;
            const target = std.math.cast(usize, nsp[0]) orelse return halt(ctx, ip, nsp, next_gas, .invalid_jump);
            if (!ctx.isValidJumpTarget(target)) return halt(ctx, ip, nsp, next_gas, .invalid_jump);
            return tailNext(ctx.code_base + target, nsp, next_gas, ctx);
        }

        fn tailJumpi(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.JUMPI, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const nsp = sp - 2;
            if (nsp[0] == 0) return tailNext(ip, nsp, next_gas, ctx);
            const target = std.math.cast(usize, (nsp + 1)[0]) orelse return halt(ctx, ip, nsp, next_gas, .invalid_jump);
            if (!ctx.isValidJumpTarget(target)) return halt(ctx, ip, nsp, next_gas, .invalid_jump);
            return tailNext(ctx.code_base + target, nsp, next_gas, ctx);
        }

        fn tailPc(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.PC, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
            sp[0] = ctx.pcOf(ip) - 1;
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailMsize(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSIZE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
            sp[0] = ctx.frame.memory.len();
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailGas(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.GAS, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, next_gas, .stack_overflow);
            sp[0] = @intCast(next_gas);
            return tailNext(ip, sp + 1, next_gas, ctx);
        }

        fn tailJumpdest(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.JUMPDEST, ip, sp, gas, ctx) orelse return .out_of_gas;
            return tailNext(ip, sp, next_gas, ctx);
        }

        fn tailCalldataLoad(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.CALLDATALOAD, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
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
            if (!ctx.hasStack(sp, 1)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 32, ip, sp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
            ctx.frame.memory.readInto(offset, &(sp - 1)[0]);
            return tailNext(ip, sp, mem_gas, ctx);
        }

        fn tailMstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSTORE, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 32, ip, sp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
            const nsp = sp - 2;
            ctx.frame.memory.writeFrom(offset, &nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailMstore8(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.MSTORE8, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, next_gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 1, ip, sp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
            const nsp = sp - 2;
            ctx.frame.memory.write8(offset, nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailKeccak256(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_gas = charge(.KECCAK256, ip, sp, gas, ctx) orelse return .out_of_gas;
            if (!ctx.hasStack(sp, 2)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
            const offset_word = (sp - 1)[0];
            const size_word = (sp - 2)[0];
            const size = wordToUsizeOrOog(size_word, ip, sp, next_gas, ctx) orelse return .done;
            const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, sp, next_gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, size, ip, sp, next_gas, ctx) orelse return memoryFailureStatus(ctx);
            const word_gas = keccakWordGas(size, ip, sp, mem_gas, ctx) orelse return .done;
            const final_gas = chargeGas(ip, sp, mem_gas, ctx, word_gas) orelse return .out_of_gas;
            const input = ctx.frame.memory.readBytes(offset, size);
            const result = if (input.len == 0) evmz.crypto.keccak256_empty else evmz.crypto.keccak256(input);
            const nsp = sp - 1;
            (nsp - 1)[0] = evmz.uint256.fromBytes32(&result);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        inline fn wordToUsizeOrOog(value: u256, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?usize {
            return std.math.cast(usize, value) orelse {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn memoryOffsetToUsizeOrOog(offset: u256, byte_size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?usize {
            if (byte_size == 0) return 0;
            return wordToUsizeOrOog(offset, ip, sp, gas, ctx);
        }

        inline fn memoryFailureStatus(ctx: *const Context) TailStatus {
            if (ctx.err != null) return .thrown;
            return if (ctx.frame.isRunning()) .out_of_gas else .done;
        }

        inline fn expandMemory(offset: usize, byte_size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            if (byte_size == 0) return gas;
            const end = std.math.add(usize, offset, byte_size) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            if (end <= ctx.frame.memory.len()) return gas;
            const expansion = ctx.frame.memory.planExpansion(offset, byte_size) orelse {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            const next_gas = chargeGas(ip, sp, gas, ctx, expansion.cost) orelse return null;
            ctx.frame.memory.applyExpansion(expansion) catch |err| switch (err) {
                error.OutOfMemory => {
                    recordError(ctx, ip, sp, next_gas, err);
                    return null;
                },
            };
            return next_gas;
        }

        inline fn keccakWordGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const padded = std.math.add(usize, size, 31) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            const words = padded / 32;
            const gas_usize = std.math.mul(usize, 6, words) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn copyWordGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const padded = std.math.add(usize, size, 31) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            const words = padded / 32;
            const gas_usize = std.math.mul(usize, 3, words) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn logDataGas(size: usize, ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) ?i64 {
            const gas_usize = std.math.mul(usize, 8, size) catch {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
            return std.math.cast(i64, gas_usize) orelse {
                _ = halt(ctx, ip, sp, gas, .out_of_gas);
                return null;
            };
        }

        inline fn sourceFromOffset(source: []const u8, offset_word: u256) []const u8 {
            const offset = std.math.cast(usize, offset_word) orelse return &.{};
            if (offset >= source.len) return &.{};
            return source[offset..];
        }

        fn stackPrefixLen(comptime opcode_byte: u8, before_len: usize) usize {
            const entry = comptime spec.instruction.entry(opcode_byte);
            if (!entry.defined() or before_len < entry.info.stack_in) return 0;

            if (opcode_byte >= @intFromEnum(Opcode.DUP1) and
                opcode_byte <= @intFromEnum(Opcode.DUP16))
            {
                return before_len;
            }

            // These instructions encode their affected suffix in an
            // immediate byte. Fall back to a full post-stack until
            // prepared-code metadata exposes that depth.
            if (opcode_byte == @intFromEnum(Opcode.DUPN) or
                opcode_byte == @intFromEnum(Opcode.SWAPN) or
                opcode_byte == @intFromEnum(Opcode.EXCHANGE))
            {
                return 0;
            }
            return before_len - entry.info.stack_in;
        }

        fn memoryWritePlan(comptime opcode_byte: u8, stack: []const u256) ?trace.tape.MemoryWritePlan {
            return builtinMemoryWritePlan(opcode_byte, stack);
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

fn tapeStepOutcome(state: *const Interpreter.FrameState) trace.TraceStepOutcome {
    return switch (state.*) {
        .running, .suspended => .success,
        .halted => |reason| switch (reason) {
            .success => .success,
            .invalid_opcode,
            .stack_underflow,
            .stack_overflow,
            .invalid_jump,
            .write_protection,
            .return_data_out_of_bounds,
            => .invalid,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
        },
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

test {
    _ = @import("./tail_dispatch_test.zig");
}
