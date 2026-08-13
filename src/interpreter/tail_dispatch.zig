const std = @import("std");

const evmz = @import("../evm.zig");
const Spec = @import("../spec.zig").Spec;
const Interpreter = @import("../Interpreter.zig");
const Opcode = @import("../opcode.zig").Opcode;
const Stack = @import("../Stack.zig");
const uint256 = @import("../uint256.zig");
const instruction = @import("../instruction.zig");
const environment = @import("../instruction/environment.zig");
const immediate = @import("../instruction/immediate.zig");
const storage = @import("../instruction/storage.zig");
const system = @import("../instruction/system.zig");
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
pub fn Dispatch(comptime spec: Spec, comptime cfg: struct {
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
        const Environment = environment.Handlers(spec);
        const Storage = storage.Handlers(spec);
        const System = system.Handlers(spec);
        // ip rides in a register across tail calls; it always points at the NEXT
        // byte to decode (one past the handler's own opcode byte).
        const Handler = fn ([*]const u8, [*]u256, i64, *Context) TailStatus;

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

            /// Frame-backed/custom handlers may synchronously re-enter the host
            /// and grow the packed arena. Refresh activation-local pointers before
            /// the tail loop resumes.
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

        // Resolve every byte directly to its exact invalid, custom, or builtin
        // target. Builtins use the source byte's finalized admission metadata.
        const table: [256]*const Handler = blk: {
            @setEvalBranchQuota(20_000);
            var handlers: [256]*const Handler = undefined;
            for (0..handlers.len) |opcode_index| {
                const opcode_byte: u8 = @intCast(opcode_index);
                handlers[opcode_index] = switch (Instructions.entry(opcode_byte).dispatchTarget()) {
                    .invalid => &tailInvalid,
                    .custom => |Custom| &CustomHandler(opcode_byte, Custom).run,
                    .builtin => &BuiltinHandler(opcode_byte).run,
                };
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
                            builtinMemoryWritePlan(opcode_byte, ctx.stackSlice(sp))
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

        fn BuiltinHandler(comptime opcode_byte: u8) type {
            const opcode: Opcode = @enumFromInt(opcode_byte);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const info = spec.instruction.entry(opcode_byte).info;
                    const next_gas = chargeGas(ip, sp, gas, ctx, info.static_gas) orelse return .out_of_gas;
                    if (comptime writeProtectedBuiltin(opcode)) {
                        if (ctx.frame.msg.is_static) return halt(ctx, ip, sp, next_gas, .write_protection);
                    }
                    if (!ctx.hasStack(sp, info.stack_in)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    return @call(.always_tail, builtinBehaviorHandler(opcode), .{ ip, sp, next_gas, ctx });
                }
            };
        }

        inline fn writeProtectedBuiltin(comptime target: Opcode) bool {
            return switch (target) {
                .SSTORE,
                .TSTORE,
                .LOG0,
                .LOG1,
                .LOG2,
                .LOG3,
                .LOG4,
                .CREATE,
                .CREATE2,
                .SELFDESTRUCT,
                => true,
                else => false,
            };
        }

        inline fn builtinBehaviorHandler(comptime opcode: Opcode) *const Handler {
            return switch (opcode) {
                .STOP => &tailStop,
                .ADD => &BinaryHandler(.add).run,
                .MUL => &BinaryHandler(.mul).run,
                .SUB => &BinaryHandler(.sub).run,
                .DIV => &BinaryHandler(.div).run,
                .SDIV => &BinaryHandler(.sdiv).run,
                .MOD => &BinaryHandler(.mod).run,
                .SMOD => &BinaryHandler(.smod).run,
                .ADDMOD => &TernaryHandler(.add_mod).run,
                .MULMOD => &TernaryHandler(.mul_mod).run,
                .EXP => &tailExp,
                .SIGNEXTEND => &BinaryHandler(.sign_extend).run,
                .LT => &BinaryHandler(.lt).run,
                .GT => &BinaryHandler(.gt).run,
                .SLT => &BinaryHandler(.slt).run,
                .SGT => &BinaryHandler(.sgt).run,
                .EQ => &BinaryHandler(.eq).run,
                .ISZERO => &UnaryHandler(.iszero).run,
                .AND => &BinaryHandler(.bit_and).run,
                .OR => &BinaryHandler(.bit_or).run,
                .XOR => &BinaryHandler(.bit_xor).run,
                .NOT => &UnaryHandler(.bit_not).run,
                .BYTE => &BinaryHandler(.byte).run,
                .SHL => &ShiftHandler(.left).run,
                .SHR => &ShiftHandler(.right).run,
                .SAR => &ShiftHandler(.arithmetic).run,
                .CLZ => &UnaryHandler(.count_leading_zeros).run,
                .KECCAK256 => &tailKeccak256,
                .ADDRESS => &FrameValueHandler(.address).run,
                .BALANCE => &HostValueHandler(.balance).run,
                .ORIGIN => &ContextValueHandler(.origin).run,
                .CALLER => &FrameValueHandler(.caller).run,
                .CALLVALUE => &FrameValueHandler(.call_value).run,
                .CALLDATALOAD => &tailCalldataLoad,
                .CALLDATASIZE => &FrameValueHandler(.calldata_size).run,
                .CALLDATACOPY => &CopyHandler(.calldata).run,
                .CODESIZE => &FrameValueHandler(.code_size).run,
                .CODECOPY => &CopyHandler(.code).run,
                .GASPRICE => &ContextValueHandler(.gas_price).run,
                .EXTCODESIZE => &HostValueHandler(.code_size).run,
                .EXTCODECOPY => &tailExtcodecopy,
                .RETURNDATASIZE => &FrameValueHandler(.return_data_size).run,
                .RETURNDATACOPY => &CopyHandler(.return_data).run,
                .EXTCODEHASH => &HostValueHandler(.code_hash).run,
                .BLOCKHASH => &tailBlockhash,
                .COINBASE => &ContextValueHandler(.coinbase).run,
                .TIMESTAMP => &ContextValueHandler(.timestamp).run,
                .NUMBER => &ContextValueHandler(.number).run,
                .PREVRANDAO => &ContextValueHandler(.prev_randao).run,
                .GASLIMIT => &ContextValueHandler(.gas_limit).run,
                .CHAINID => &ContextValueHandler(.chain_id).run,
                .SELFBALANCE => &HostValueHandler(.self_balance).run,
                .BASEFEE => &ContextValueHandler(.base_fee).run,
                .BLOBHASH => &tailBlobhash,
                .BLOBBASEFEE => &ContextValueHandler(.blob_base_fee).run,
                .SLOTNUM => &ContextValueHandler(.slot_number).run,
                .POP => &tailPop,
                .MLOAD => &tailMload,
                .MSTORE => &tailMstore,
                .MSTORE8 => &tailMstore8,
                .SLOAD => &tailSload,
                .SSTORE => &tailSstore,
                .JUMP => &tailJump,
                .JUMPI => &tailJumpi,
                .PC => &tailPc,
                .MSIZE => &tailMsize,
                .GAS => &tailGas,
                .JUMPDEST => &tailJumpdest,
                .TLOAD => &tailTload,
                .TSTORE => &tailTstore,
                .MCOPY => &tailMcopy,
                .PUSH0 => &tailPush0,
                .PUSH1, .PUSH2, .PUSH3, .PUSH4, .PUSH5, .PUSH6, .PUSH7, .PUSH8, .PUSH9, .PUSH10, .PUSH11, .PUSH12, .PUSH13, .PUSH14, .PUSH15, .PUSH16, .PUSH17, .PUSH18, .PUSH19, .PUSH20, .PUSH21, .PUSH22, .PUSH23, .PUSH24, .PUSH25, .PUSH26, .PUSH27, .PUSH28, .PUSH29, .PUSH30, .PUSH31, .PUSH32 => &PushHandler(opcode).run,
                .DUP1, .DUP2, .DUP3, .DUP4, .DUP5, .DUP6, .DUP7, .DUP8, .DUP9, .DUP10, .DUP11, .DUP12, .DUP13, .DUP14, .DUP15, .DUP16 => &DupHandler(opcode).run,
                .SWAP1, .SWAP2, .SWAP3, .SWAP4, .SWAP5, .SWAP6, .SWAP7, .SWAP8, .SWAP9, .SWAP10, .SWAP11, .SWAP12, .SWAP13, .SWAP14, .SWAP15, .SWAP16 => &SwapHandler(opcode).run,
                .LOG0 => &LogHandler(0).run,
                .LOG1 => &LogHandler(1).run,
                .LOG2 => &LogHandler(2).run,
                .LOG3 => &LogHandler(3).run,
                .LOG4 => &LogHandler(4).run,
                .DUPN, .SWAPN, .EXCHANGE => &ExtendedStackHandler(opcode).run,
                .CREATE, .CALL, .CALLCODE, .DELEGATECALL, .CREATE2, .STATICCALL, .SELFDESTRUCT => &SystemHandler(opcode).run,
                .RETURN => &TerminalHandler(.success).run,
                .REVERT => &TerminalHandler(.revert).run,
                .INVALID => &tailInvalid,
                else => @compileError("missing tail handler for builtin " ++ @tagName(opcode)),
            };
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

        inline fn chargeGas(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context, cost: i64) ?i64 {
            if (cost > gas) {
                @branchHint(.unlikely);
                _ = ctx.finish(ip, sp, gas, .out_of_gas);
                return null;
            }
            return gas - cost;
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

        fn CustomHandler(comptime opcode_byte: u8, comptime Custom: type) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const info = spec.instruction.entry(opcode_byte).info;
                    const next_gas = chargeGas(ip, sp, gas, ctx, info.static_gas) orelse return .out_of_gas;
                    if (!ctx.hasStack(sp, info.stack_in)) return halt(ctx, ip, sp, next_gas, .stack_underflow);
                    ctx.spill(ip, sp, next_gas);
                    Custom.execute(spec, ctx.frame) catch |err| {
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
            const key_slot = sp - 1;
            ctx.frame.gas_left = gas;
            const value = Storage.sloadAfterPop(ctx.frame, key_slot[0]) catch |err| {
                recordError(ctx, ip, key_slot, ctx.frame.gas_left, err);
                return .thrown;
            };
            const loaded = value orelse return ctx.finish(ip, key_slot, ctx.frame.gas_left, .done);
            key_slot[0] = loaded;
            return tailNext(ip, sp, ctx.frame.gas_left, ctx);
        }

        fn tailSstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const next_sp = sp - 2;
            const key = (sp - 1)[0];
            const value = next_sp[0];
            ctx.frame.gas_left = gas;
            Storage.sstoreAfterPop(ctx.frame, key, value) catch |err| {
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
            const slot = sp - 1;
            const recipient: evmz.AddressWord = .fromAddress(ctx.frame.msg.recipient);
            const value = ctx.frame.host.getTransientStorage(recipient, slot[0]) catch |err| {
                recordError(ctx, ip, slot, gas, err);
                return .thrown;
            };
            slot[0] = value;
            return tailNext(ip, sp, gas, ctx);
        }

        fn tailTstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const nsp = sp - 2;
            const key = (sp - 1)[0];
            const recipient: evmz.AddressWord = .fromAddress(ctx.frame.msg.recipient);
            ctx.frame.host.setTransientStorage(recipient, key, nsp[0]) catch |err| {
                recordError(ctx, ip, nsp, gas, err);
                return .thrown;
            };
            return tailNext(ip, nsp, gas, ctx);
        }

        fn tailMcopy(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const nsp = sp - 3;
            const dest_word = (sp - 1)[0];
            const source_word = (sp - 2)[0];
            const size_word = nsp[0];
            if (size_word == 0) return tailNext(ip, nsp, gas, ctx);

            const dest = wordToUsizeOrOog(dest_word, ip, nsp, gas, ctx) orelse return .done;
            const source = wordToUsizeOrOog(source_word, ip, nsp, gas, ctx) orelse return .done;
            const size = wordToUsizeOrOog(size_word, ip, nsp, gas, ctx) orelse return .done;

            // Canonical MCOPY expands the source range before the destination.
            const source_gas = expandMemory(source, size, ip, nsp, gas, ctx) orelse return memoryFailureStatus(ctx);
            const dest_gas = expandMemory(dest, size, ip, nsp, source_gas, ctx) orelse return memoryFailureStatus(ctx);
            const copy_gas = copyWordGas(size, ip, nsp, dest_gas, ctx) orelse return .done;
            const final_gas = chargeGas(ip, nsp, dest_gas, ctx, copy_gas) orelse return .out_of_gas;

            ctx.frame.memory.copy(dest, source, size);
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn tailExp(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const base = (sp - 1)[0];
            const exponent = (sp - 2)[0];
            const nsp = sp - 1;
            const byte_gas = spec.instruction.exp_byte_gas;
            const dynamic_gas = byte_gas * uint256.countSignificantBytesSize(exponent);
            const final_gas = chargeGas(ip, nsp - 1, gas, ctx, dynamic_gas) orelse return .out_of_gas;
            (nsp - 1)[0] = @call(.always_inline, uint256.wrapExp, .{ base, exponent });
            return tailNext(ip, nsp, final_gas, ctx);
        }

        fn BinaryHandler(comptime op: BinaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const a = (sp - 1)[0];
                    const b = (sp - 2)[0];
                    const nsp = sp - 1;
                    (nsp - 1)[0] = switch (op) {
                        .add => a +% b,
                        .mul => a *% b,
                        .sub => a -% b,
                        .lt => @intFromBool(a < b),
                        .gt => @intFromBool(a > b),
                        .slt => @intFromBool(@as(i256, @bitCast(a)) < @as(i256, @bitCast(b))),
                        .sgt => @intFromBool(@as(i256, @bitCast(a)) > @as(i256, @bitCast(b))),
                        .eq => @intFromBool(a == b),
                        .byte => if (a >= 32) 0 else (b >> ((31 - @as(u8, @intCast(a))) * 8)) & 0xff,
                        .bit_and => a & b,
                        .bit_or => a | b,
                        .bit_xor => a ^ b,
                        .div => @call(.always_inline, uint256.div, .{ a, b }),
                        .sdiv => @call(.always_inline, uint256.sdiv, .{ a, b }),
                        .mod => @call(.always_inline, uint256.mod, .{ a, b }),
                        .smod => @call(.always_inline, uint256.smod, .{ a, b }),
                        .sign_extend => blk: {
                            if (a >= 32) break :blk b;
                            const sign_bit: u8 = @as(u8, @intCast(a)) * 8 + 7;
                            const mask = std.math.shl(u256, 1, sign_bit) - 1;
                            break :blk if (((b >> sign_bit) & 1) != 0) b | ~mask else b & mask;
                        },
                    };
                    return tailNext(ip, nsp, gas, ctx);
                }
            };
        }

        fn TernaryHandler(comptime op: TernaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const a = (sp - 1)[0];
                    const b = (sp - 2)[0];
                    const result_slot = sp - 3;
                    result_slot[0] = switch (op) {
                        .add_mod => uint256.addMod(a, b, result_slot[0]),
                        .mul_mod => uint256.mulMod(a, b, result_slot[0]),
                    };
                    return tailNext(ip, sp - 2, gas, ctx);
                }
            };
        }

        fn FrameValueHandler(comptime value: FrameValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                    sp[0] = switch (value) {
                        .address => ctx.frame.msg.recipient.toU256(),
                        .caller => ctx.frame.msg.sender.toU256(),
                        .call_value => ctx.frame.msg.value,
                        .calldata_size => @intCast(ctx.frame.msg.input_data.len),
                        .code_size => @intCast(ctx.frame.code.len),
                        .return_data_size => @intCast(ctx.frame.return_data.len),
                    };
                    return tailNext(ip, sp + 1, gas, ctx);
                }
            };
        }

        fn ContextValueHandler(comptime value: ContextValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                    const execution_context = ctx.frame.host.executionContext() catch |err| {
                        recordError(ctx, ip, sp, gas, err);
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
                    return tailNext(ip, sp + 1, gas, ctx);
                }
            };
        }

        fn HostValueHandler(comptime value: HostValue) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (comptime value == .self_balance) {
                        if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                        const result = ctx.frame.host.getBalance(.fromAddress(ctx.frame.msg.recipient)) catch |err| {
                            recordError(ctx, ip, sp, gas, err);
                            return .thrown;
                        };
                        sp[0] = result;
                        return tailNext(ip, sp + 1, gas, ctx);
                    }

                    const slot = sp - 1;
                    const target_address: evmz.AddressWord = .fromU256(slot[0]);
                    ctx.frame.gas_left = gas;
                    const result = Environment.readAccountValue(ctx.frame, target_address, switch (value) {
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
            const nsp = sp - 4;
            const target_address: evmz.AddressWord = .fromU256((sp - 1)[0]);
            const dest_offset_word = (sp - 2)[0];
            const source_offset_word = (sp - 3)[0];
            const size = wordToUsizeOrOog(nsp[0], ip, nsp, gas, ctx) orelse return .done;
            const dest_offset = memoryOffsetToUsizeOrOog(dest_offset_word, size, ip, nsp, gas, ctx) orelse return .done;

            ctx.frame.gas_left = gas;
            const access_ok = Environment.trackCodeAccountAccessGas(ctx.frame, target_address) catch |err| {
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
            const slot = sp - 1;
            const execution_context = ctx.frame.host.executionContext() catch |err| {
                recordError(ctx, ip, sp, gas, err);
                return .thrown;
            };
            const current_number: u256 = execution_context.block.number;
            const oldest_hashable = if (current_number > 256) current_number - 256 else 0;
            slot[0] = if (slot[0] < current_number and slot[0] >= oldest_hashable)
                ctx.frame.host.getBlockHash(slot[0]) catch |err| {
                    recordError(ctx, ip, sp, gas, err);
                    return .thrown;
                }
            else
                0;
            return tailNext(ip, sp, gas, ctx);
        }

        fn tailBlobhash(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const slot = sp - 1;
            const execution_context = ctx.frame.host.executionContext() catch |err| {
                recordError(ctx, ip, sp, gas, err);
                return .thrown;
            };
            const index = std.math.cast(usize, slot[0]);
            slot[0] = if (index) |i|
                if (i < execution_context.transaction.blob_hashes.len) execution_context.transaction.blob_hashes[i] else 0
            else
                0;
            return tailNext(ip, sp, gas, ctx);
        }

        fn ExtendedStackHandler(comptime opcode: Opcode) type {
            comptime std.debug.assert(opcode == .DUPN or opcode == .SWAPN or opcode == .EXCHANGE);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (comptime opcode == .EXCHANGE) {
                        const n, const m = immediate.decodeExchangeImmediate(ip[0]) orelse
                            return halt(ctx, ip, sp, gas, .invalid_opcode);
                        if (!ctx.hasStack(sp, @max(n, m) + 1)) return halt(ctx, ip, sp, gas, .stack_underflow);
                        const top = sp - 1;
                        std.mem.swap(u256, &((top - n)[0]), &((top - m)[0]));
                        return tailNext(ip + 1, sp, gas, ctx);
                    }

                    const depth = immediate.decodeDepthImmediate(ip[0]) orelse
                        return halt(ctx, ip, sp, gas, .invalid_opcode);
                    if (comptime opcode == .DUPN) {
                        if (!ctx.hasStack(sp, depth)) return halt(ctx, ip, sp, gas, .stack_underflow);
                        if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                        sp[0] = (sp - depth)[0];
                        return tailNext(ip + 1, sp + 1, gas, ctx);
                    }

                    if (!ctx.hasStack(sp, depth + 1)) return halt(ctx, ip, sp, gas, .stack_underflow);
                    const top = sp - 1;
                    std.mem.swap(u256, &top[0], &((top - depth)[0]));
                    return tailNext(ip + 1, sp, gas, ctx);
                }
            };
        }

        fn SystemHandler(comptime opcode: Opcode) type {
            comptime std.debug.assert(opcode == .CREATE or opcode == .CALL or opcode == .CALLCODE or
                opcode == .DELEGATECALL or opcode == .CREATE2 or opcode == .STATICCALL or
                opcode == .SELFDESTRUCT);
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    ctx.spill(ip, sp, gas);
                    (switch (opcode) {
                        .CREATE => System.create(ctx.frame),
                        .CALL, .CALLCODE, .DELEGATECALL, .STATICCALL => System.callByOp(ctx.frame, opcode),
                        .CREATE2 => System.create2(ctx.frame),
                        .SELFDESTRUCT => System.selfdestruct(ctx.frame),
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

        fn CopyHandler(comptime source_kind: CopySource) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const nsp = sp - 3;
                    const dest_offset_word = (sp - 1)[0];
                    const source_offset_word = (sp - 2)[0];
                    const size_word = nsp[0];
                    const size = wordToUsizeOrOog(size_word, ip, nsp, gas, ctx) orelse return .done;
                    const dest_offset = memoryOffsetToUsizeOrOog(dest_offset_word, size, ip, nsp, gas, ctx) orelse return .done;
                    const memory_gas = expandMemory(dest_offset, size, ip, nsp, gas, ctx) orelse return memoryFailureStatus(ctx);
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

        fn TerminalHandler(comptime terminal_status: TerminalStatus) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
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

        fn LogHandler(comptime topic_count: usize) type {
            if (topic_count > 4) @compileError("LOG supports at most four topics");
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    // Canonical logging pops offset/size before dynamic gas, then
                    // topics only after memory and data gas have succeeded.
                    const args_sp = sp - 2;
                    const offset_word = (sp - 1)[0];
                    const size_word = args_sp[0];
                    const size = wordToUsizeOrOog(size_word, ip, args_sp, gas, ctx) orelse return .done;
                    const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, args_sp, gas, ctx) orelse return .done;
                    const memory_gas = expandMemory(offset, size, ip, args_sp, gas, ctx) orelse return memoryFailureStatus(ctx);
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

        fn UnaryHandler(comptime op: UnaryOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const slot = sp - 1;
                    slot[0] = switch (op) {
                        .iszero => @intFromBool(slot[0] == 0),
                        .bit_not => ~slot[0],
                        .count_leading_zeros => @clz(slot[0]),
                    };
                    return tailNext(ip, sp, gas, ctx);
                }
            };
        }

        fn tailPop(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            return tailNext(ip, sp - 1, gas, ctx);
        }

        fn tailPush0(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
            sp[0] = 0;
            return tailNext(ip, sp + 1, gas, ctx);
        }

        fn PushHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                    const immediate_len: usize = @intFromEnum(opcode) - @intFromEnum(Opcode.PUSH0);
                    // `code_base` carries Bytecode.zero_padding_len (33) trailing zero
                    // bytes, so a full-width big-endian load is always in bounds and
                    // preserves truncated-push zero-fill semantics.
                    const Int = std.meta.Int(.unsigned, immediate_len * 8);
                    const immediate_bytes: *const [immediate_len]u8 = @ptrCast(ip);
                    sp[0] = std.mem.readInt(Int, immediate_bytes, .big);
                    return tailNext(ip + immediate_len, sp + 1, gas, ctx);
                }
            };
        }

        fn DupHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const depth = @intFromEnum(opcode) - @intFromEnum(Opcode.DUP1) + 1;
                    if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
                    sp[0] = (sp - depth)[0];
                    return tailNext(ip, sp + 1, gas, ctx);
                }
            };
        }

        fn SwapHandler(comptime opcode: Opcode) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const depth = @intFromEnum(opcode) - @intFromEnum(Opcode.SWAP1) + 1;
                    const top = sp - 1;
                    const target = top - depth;
                    const tmp = target[0];
                    target[0] = top[0];
                    top[0] = tmp;
                    return tailNext(ip, sp, gas, ctx);
                }
            };
        }

        fn ShiftHandler(comptime op: ShiftOp) type {
            return struct {
                fn run(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
                    const shift = (sp - 1)[0];
                    const value = (sp - 2)[0];
                    const nsp = sp - 1;
                    (nsp - 1)[0] = switch (op) {
                        .left => if (shift > std.math.maxInt(u8)) 0 else uint256.shl(value, @as(u8, @intCast(shift))),
                        .right => if (shift > std.math.maxInt(u8)) 0 else value >> @as(u8, @intCast(shift)),
                        .arithmetic => arithmeticShiftRight(value, shift),
                    };
                    return tailNext(ip, nsp, gas, ctx);
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
            const nsp = sp - 1;
            const target = std.math.cast(usize, nsp[0]) orelse return halt(ctx, ip, nsp, gas, .invalid_jump);
            if (!ctx.isValidJumpTarget(target)) return halt(ctx, ip, nsp, gas, .invalid_jump);
            return tailNext(ctx.code_base + target, nsp, gas, ctx);
        }

        fn tailJumpi(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const nsp = sp - 2;
            if (nsp[0] == 0) return tailNext(ip, nsp, gas, ctx);
            const target = std.math.cast(usize, (nsp + 1)[0]) orelse return halt(ctx, ip, nsp, gas, .invalid_jump);
            if (!ctx.isValidJumpTarget(target)) return halt(ctx, ip, nsp, gas, .invalid_jump);
            return tailNext(ctx.code_base + target, nsp, gas, ctx);
        }

        fn tailPc(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
            sp[0] = ctx.pcOf(ip) - 1;
            return tailNext(ip, sp + 1, gas, ctx);
        }

        fn tailMsize(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
            sp[0] = ctx.frame.memory.len();
            return tailNext(ip, sp + 1, gas, ctx);
        }

        fn tailGas(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            if (sp == ctx.stack_limit) return halt(ctx, ip, sp, gas, .stack_overflow);
            sp[0] = @intCast(gas);
            return tailNext(ip, sp + 1, gas, ctx);
        }

        fn tailJumpdest(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            return tailNext(ip, sp, gas, ctx);
        }

        fn tailCalldataLoad(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
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
            return tailNext(ip, sp, gas, ctx);
        }

        fn tailMload(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 32, ip, sp, gas, ctx) orelse return memoryFailureStatus(ctx);
            ctx.frame.memory.readInto(offset, &(sp - 1)[0]);
            return tailNext(ip, sp, mem_gas, ctx);
        }

        fn tailMstore(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 32, ip, sp, gas, ctx) orelse return memoryFailureStatus(ctx);
            const nsp = sp - 2;
            ctx.frame.memory.writeFrom(offset, &nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailMstore8(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const offset = wordToUsizeOrOog((sp - 1)[0], ip, sp, gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, 1, ip, sp, gas, ctx) orelse return memoryFailureStatus(ctx);
            const nsp = sp - 2;
            ctx.frame.memory.write8(offset, nsp[0]);
            return tailNext(ip, nsp, mem_gas, ctx);
        }

        fn tailKeccak256(ip: [*]const u8, sp: [*]u256, gas: i64, ctx: *Context) TailStatus {
            const offset_word = (sp - 1)[0];
            const size_word = (sp - 2)[0];
            const size = wordToUsizeOrOog(size_word, ip, sp, gas, ctx) orelse return .done;
            const offset = memoryOffsetToUsizeOrOog(offset_word, size, ip, sp, gas, ctx) orelse return .done;
            const mem_gas = expandMemory(offset, size, ip, sp, gas, ctx) orelse return memoryFailureStatus(ctx);
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
    };
}

fn tapeStepOutcome(state: *const Interpreter.FrameState) trace.TraceStepOutcome {
    return switch (state.*) {
        .running, .suspended => .success,
        .halted => |reason| switch (reason) {
            .success => .success,
            .revert => .revert,
            .out_of_gas => .out_of_gas,
            .invalid_opcode,
            .stack_underflow,
            .stack_overflow,
            .invalid_jump,
            .write_protection,
            .return_data_out_of_bounds,
            => .invalid,
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
