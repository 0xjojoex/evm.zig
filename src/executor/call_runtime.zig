const std = @import("std");
const evmz = @import("../evm.zig");
const executor_module = @import("../executor.zig");

const Address = evmz.Address;
const Bytecode = evmz.Bytecode;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const eip7702 = @import("./eip7702.zig");
const frame_io = @import("../frame_io.zig");
const FrameStore = @import("./frame_store.zig");
const runtime_frames = @import("./runtime_frames.zig");
const ExecutionGas = @import("../execution.zig").ExecutionGas;
const call_scratch_storage = @import("./call_scratch.zig");
const context_adapter = @import("./context.zig");
const CaptureContext = executor_module.CaptureContext;

pub fn bind(comptime Executor: type) type {
    return struct {
        const State = Executor.State;
        const ScopeCheckpoint = Executor.ScopeCheckpoint;
        const spec = Executor.specification;
        const BoundInterpreter = Interpreter.Interpreter(spec);

        pub const ScratchScope = struct {
            executor: *Executor,
            depth: u16,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *ScratchScope) void {
                endCallScratch(self.executor, self.depth);
                self.* = undefined;
            }
        };

        const FrameLease = FrameStore.Lease;

        const StartedCall = union(enum) {
            immediate: Host.Result,
            child: ChildCall,
        };

        const ChildCall = struct {
            checkpoint_state: ScopeCheckpoint,
            bytecode: *const Bytecode,
        };

        const StartedCreate = union(enum) {
            immediate: Host.Result,
            child: ChildCreate,
        };

        const CreateCallerPreparation = union(enum) {
            rejected: Host.Result,
            nonce: u64,
        };

        const ChildCreate = runtime_frames.ChildCreate;
        const RuntimeFrame = runtime_frames.Frame;

        /// Owns one interior call/create checkpoint until it is resolved or
        /// transferred to a runtime frame. Any early error restores it.
        const CheckpointGuard = struct {
            state: *State,
            checkpoint_state: ScopeCheckpoint,
            open: bool = true,

            fn begin(state: *State) !CheckpointGuard {
                return .{
                    .state = state,
                    .checkpoint_state = state.checkpoint(),
                };
            }

            fn init(state: *State, checkpoint_state: ScopeCheckpoint) CheckpointGuard {
                return .{
                    .state = state,
                    .checkpoint_state = checkpoint_state,
                };
            }

            fn commit(self: *CheckpointGuard) !void {
                self.state.commitCheckpoint(self.checkpoint_state);
                self.open = false;
            }

            fn restore(self: *CheckpointGuard) !void {
                self.state.revertToCheckpoint(self.checkpoint_state);
                self.open = false;
            }

            fn finish(self: *CheckpointGuard, status: Interpreter.Status) !void {
                if (status == .success) {
                    try self.commit();
                } else {
                    try self.restore();
                }
            }

            fn disarm(self: *CheckpointGuard) void {
                std.debug.assert(self.open);
                self.open = false;
            }

            fn deinit(self: *CheckpointGuard) void {
                if (self.open) self.state.revertToCheckpoint(self.checkpoint_state);
                self.* = undefined;
            }
        };

        const CallRuntime = struct {
            executor: *Executor,
            host_iface: Host,
            frames: *std.ArrayList(RuntimeFrame),
            frame_base: usize,
            capture_context: ?*CaptureContext,

            fn init(executor: *Executor) CallRuntime {
                return .{
                    .executor = executor,
                    .host_iface = executor.host(),
                    .frames = &executor.runtime_frames,
                    .frame_base = executor.runtime_frames.items.len,
                    .capture_context = executor.currentCaptureContext(),
                };
            }

            fn deinit(self: *CallRuntime) void {
                while (self.frames.items.len > self.frame_base) {
                    self.popFrame();
                }
            }

            fn prepare(self: *CallRuntime) !void {
                // TODO: reivew
                if (self.frame_base != 0) return error.ActiveRuntimeFrames;
                try self.prepareNested();
            }

            fn prepareNested(self: *CallRuntime) !void {
                std.debug.assert(self.frames.items.len == self.frame_base);
                if (self.frame_base == 0) {
                    if (self.capture_context) |context| {
                        if (context.capturesSteps()) {
                            try context.reserveFrameCapacity(Executor.default_max_live_frames);
                        }
                    }
                }
            }

            fn pushRootCall(self: *CallRuntime, msg: Host.Message, bytecode: *const Bytecode) !void {
                var frame = try acquireBytecodeFrame(
                    self.executor,
                    self.executor.allocator,
                    &self.host_iface,
                    &msg,
                    bytecode,
                );
                errdefer frame.deinit();
                try self.appendFrame(.{
                    .kind = .root_call,
                    .frame = frame,
                });
            }

            fn pushChildCall(
                self: *CallRuntime,
                msg: Host.Message,
                checkpoint_state: ScopeCheckpoint,
                bytecode: *const Bytecode,
                call_capture: ?evmz.trace.CallToken,
            ) !void {
                var frame = try acquireBytecodeFrame(
                    self.executor,
                    self.executor.allocator,
                    &self.host_iface,
                    &msg,
                    bytecode,
                );
                errdefer frame.deinit();
                try self.appendFrame(.{
                    .kind = .{ .call = checkpoint_state },
                    .frame = frame,
                    .call_capture = call_capture,
                });
            }

            fn pushChildCreate(self: *CallRuntime, child: ChildCreate, call_capture: ?evmz.trace.CallToken) !void {
                const execution = if (self.executor.prepared_code_execution) |*active|
                    active
                else
                    return error.MissingPreparedCodeExecution;
                const bytecode = try execution.prepareTransient(child.init_code);
                var frame = try acquireBytecodeFrame(
                    self.executor,
                    self.executor.allocator,
                    &self.host_iface,
                    &child.msg,
                    bytecode,
                );
                errdefer frame.deinit();

                try self.appendFrame(.{
                    .kind = .{ .create = child },
                    .frame = frame,
                    .call_capture = call_capture,
                });
            }

            fn appendFrame(self: *CallRuntime, frame: RuntimeFrame) !void {
                try self.frames.append(self.executor.allocator, frame);
                errdefer self.frames.items.len -= 1;

                if (self.stepCaptureContext()) |context| {
                    const runtime_frame = &self.frames.items[self.frames.items.len - 1];
                    const parent_stack = if (self.frames.items.len > 1)
                        self.frames.items[self.frames.items.len - 2].frame.callFrame().stack.asSlice()
                    else
                        &.{};
                    const parent_memory_size = if (self.frames.items.len > 1)
                        self.frames.items[self.frames.items.len - 2].frame.callFrame().memory.len()
                    else
                        0;
                    try context.pushFrame(
                        runtime_frame.frame.callFrame().msg.depth,
                        traceFrameKind(runtime_frame),
                        runtime_frame.frame.callFrame().stack.asSlice(),
                        runtime_frame.frame.callFrame().memory.len(),
                        runtime_frame.frame.callFrame().return_data,
                        parent_stack,
                        parent_memory_size,
                    );
                }
            }

            fn popFrame(self: *CallRuntime) void {
                std.debug.assert(self.frames.items.len > self.frame_base);
                const index = self.frames.items.len - 1;
                if (self.stepCaptureContext()) |context| context.popFrame();
                deinitRuntimeFrame(&self.frames.items[index]);
                self.frames.items.len = index;
            }

            inline fn stepCaptureContext(self: *CallRuntime) ?*CaptureContext {
                const context = self.capture_context orelse return null;
                return if (context.capturesSteps()) context else null;
            }

            inline fn callCaptureContext(self: *CallRuntime) ?*CaptureContext {
                const context = self.capture_context orelse return null;
                return if (context.capturesCalls()) context else null;
            }

            fn run(self: *CallRuntime) !Host.Result {
                while (self.frames.items.len > self.frame_base) {
                    const index = self.frames.items.len - 1;
                    const runtime_frame = &self.frames.items[index];
                    var interpreter = runtime_frame.frame.interpreter(spec);
                    const depth = runtime_frame.frame.callFrame().msg.depth;
                    const run_result: Interpreter.RunResult = if (self.stepCaptureContext()) |context|
                        try executeCapturedInterpreterUntilAction(
                            self.executor,
                            &interpreter,
                            depth,
                            context.currentFrame(),
                        )
                    else if (runtime_frame.frame.callFrame().bytecode.needs_action_loop)
                        try executeInterpreterUntilAction(self.executor, &interpreter, depth)
                    else
                        .{ .finished = try executeInterpreter(self.executor, &interpreter, depth) };
                    switch (run_result) {
                        .action => |action| try self.handleAction(index, action),
                        .finished => |result| {
                            const host_result = try self.finishFrame(index, result);
                            if (self.frames.items.len == self.frame_base + 1) {
                                const stable = try stabilizeFinalResult(self.executor, host_result);
                                self.popFrame();
                                return stable;
                            }

                            const parent_index = self.frames.items.len - 2;
                            const parent_action = self.frames.items[parent_index].pending_action orelse unreachable;
                            try self.resumeParentAction(parent_index, parent_action, host_result);
                            self.frames.items[parent_index].pending_action = null;
                            self.popFrame();
                        },
                    }
                }
                unreachable;
            }

            fn handleAction(self: *CallRuntime, frame_index: usize, action: Interpreter.Action) !void {
                switch (action) {
                    .call => |call_action| {
                        if (try self.startCall(call_action.msg)) |host_result| {
                            const call_result = host_result.expectCall();
                            try self.frames.items[frame_index].frame.callFrame().resumeCallResult(
                                call_action.continuation,
                                call_result,
                            );
                            self.captureCallOutput(frame_index, call_action.continuation, call_result.output_data.len);
                            try self.captureReturnData(frame_index);
                        } else {
                            self.frames.items[frame_index].pending_action = action;
                        }
                    },
                    .create => |create_action| {
                        if (try self.startCreate(create_action.msg)) |host_result| {
                            try self.frames.items[frame_index].frame.callFrame().resumeCreateResult(
                                create_action.continuation,
                                host_result.expectCreate(),
                            );
                            try self.captureReturnData(frame_index);
                        } else {
                            self.frames.items[frame_index].pending_action = action;
                        }
                    },
                }
            }

            fn resumeParentAction(self: *CallRuntime, frame_index: usize, action: Interpreter.Action, result: Host.Result) !void {
                switch (action) {
                    .call => |call_action| {
                        const call_result = result.expectCall();
                        try self.frames.items[frame_index].frame.callFrame().resumeCallResult(
                            call_action.continuation,
                            call_result,
                        );
                        self.captureCallOutput(frame_index, call_action.continuation, call_result.output_data.len);
                    },
                    .create => |create_action| try self.frames.items[frame_index].frame.callFrame().resumeCreateResult(
                        create_action.continuation,
                        result.expectCreate(),
                    ),
                }
                try self.captureReturnData(frame_index);
            }

            fn captureReturnData(self: *CallRuntime, frame_index: usize) !void {
                const context = self.stepCaptureContext() orelse return;
                try context.replaceFrameReturnData(
                    frame_index,
                    self.frames.items[frame_index].frame.callFrame().return_data,
                );
            }

            fn captureCallOutput(
                self: *CallRuntime,
                frame_index: usize,
                continuation: Interpreter.CallResume,
                output_len: usize,
            ) void {
                const context = self.stepCaptureContext() orelse return;
                context.setFrameMemoryWrite(
                    frame_index,
                    continuation.out_offset,
                    @min(continuation.out_size, output_len),
                );
            }

            fn startCall(self: *CallRuntime, msg: Host.Message) !?Host.Result {
                const previous_depth = self.executor.trace_depth;
                self.executor.trace_depth = msg.depth;
                defer self.executor.trace_depth = previous_depth;

                const call_capture = try beginCallCapture(self.capture_context, msg);
                if (Host.precheckResult(msg)) |result| {
                    if (call_capture) |token| try finishCallCapture(self.capture_context, token, result);
                    return result;
                }
                switch (try beginCall(self.executor, msg)) {
                    .immediate => |result| {
                        if (call_capture) |token| try finishCallCapture(self.capture_context, token, result);
                        return result;
                    },
                    .child => |child| {
                        var checkpoint = CheckpointGuard.init(&self.executor.state, child.checkpoint_state);
                        defer checkpoint.deinit();

                        try self.pushChildCall(msg, child.checkpoint_state, child.bytecode, call_capture);
                        checkpoint.disarm();
                        return null;
                    },
                }
            }

            fn startCreate(self: *CallRuntime, msg: Host.Message) !?Host.Result {
                const previous_depth = self.executor.trace_depth;
                self.executor.trace_depth = msg.depth;
                defer self.executor.trace_depth = previous_depth;

                const call_capture = try beginCallCapture(self.capture_context, msg);
                if (Host.precheckResult(msg)) |result| {
                    if (call_capture) |token| try finishCallCapture(self.capture_context, token, result);
                    return result;
                }
                if (msg.depth > Host.max_call_depth) {
                    const result = createFailureWithCause(self.executor, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);
                    if (call_capture) |token| try finishCallCapture(self.capture_context, token, result);
                    return result;
                }

                switch (try beginCreate(self.executor, msg)) {
                    .immediate => |result| {
                        if (call_capture) |token| try finishCallCapture(self.capture_context, token, result);
                        return result;
                    },
                    .child => |child| {
                        var checkpoint = CheckpointGuard.init(&self.executor.state, child.checkpoint_state);
                        defer checkpoint.deinit();

                        try self.pushChildCreate(child, call_capture);
                        checkpoint.disarm();
                        return null;
                    },
                }
            }

            fn finishFrame(self: *CallRuntime, frame_index: usize, result: Interpreter.Result) !Host.Result {
                const frame_kind = self.frames.items[frame_index].kind;
                const call_capture = self.frames.items[frame_index].call_capture;
                var checkpoint: ?CheckpointGuard = switch (frame_kind) {
                    .root_call => null,
                    .call => |checkpoint_state| CheckpointGuard.init(&self.executor.state, checkpoint_state),
                    .create => |child| CheckpointGuard.init(&self.executor.state, child.checkpoint_state),
                };
                defer if (checkpoint) |*guard| guard.deinit();

                const call_frame = self.frames.items[frame_index].frame.callFrame();
                if (self.stepCaptureContext()) |context| {
                    try context.finishCurrentFrame(.{
                        .outcome = Interpreter.traceFrameOutcome(result.status),
                        .memory_size = call_frame.memory.len(),
                    });
                }

                if (call_capture != null) {
                    try self.callCaptureContext().?.reserveCallOutput(result.output_data.len);
                }

                const host_result = switch (frame_kind) {
                    .root_call => Host.Result.fromCall(.{
                        .status = result.status,
                        .cause = result.cause,
                        .output_data = result.output_data,
                        .gas_left = result.gas_left,
                        .gas_refund = result.gas_refund,
                        .gas_reservoir = result.gas_reservoir,
                        .state_gas_spent = result.state_gas_spent,
                        .state_gas_from_gas_left = result.state_gas_from_gas_left,
                    }),
                    .call => blk: {
                        if (checkpoint) |*guard| {
                            try guard.finish(result.status);
                        } else unreachable;
                        break :blk Host.Result.fromCall(.{
                            .status = result.status,
                            .cause = result.cause,
                            .checkpoint_reverted = result.status != .success,
                            .output_data = result.output_data,
                            .gas_left = result.gas_left,
                            .gas_refund = result.gas_refund,
                            .gas_reservoir = result.gas_reservoir,
                            .state_gas_spent = result.state_gas_spent,
                            .state_gas_from_gas_left = result.state_gas_from_gas_left,
                        });
                    },
                    .create => |child| blk: {
                        if (checkpoint) |*guard| {
                            break :blk try finishCreate(self.executor, child, result, guard);
                        }
                        unreachable;
                    },
                };
                if (call_capture) |token| {
                    finishCallCaptureReserved(self.callCaptureContext().?, token, host_result);
                }
                return host_result;
            }
        };

        inline fn beginCallCapture(
            context: ?*CaptureContext,
            msg: Host.Message,
        ) !?evmz.trace.CallToken {
            const capture = context orelse return null;
            if (!capture.capturesCalls()) return null;

            const Endpoints = struct { from: Address, to: Address };
            const endpoints: Endpoints = switch (msg.kind) {
                .call, .staticcall => .{ .from = msg.sender, .to = msg.recipient },
                .delegatecall, .callcode => .{ .from = msg.recipient, .to = msg.code_address },
                .create, .create2 => .{ .from = msg.sender, .to = msg.recipient },
            };
            return capture.beginCall(.{
                .depth = msg.depth,
                .kind = callCaptureKind(msg.kind),
                .from = endpoints.from,
                .to = endpoints.to,
                .code_address = msg.code_address,
                .value = msg.value,
                .gas = msg.gas,
                .input = msg.input_data,
            });
        }

        fn finishCallCapture(
            context: ?*CaptureContext,
            token: evmz.trace.CallToken,
            result: Host.Result,
        ) !void {
            try context.?.finishCall(token, callCaptureFinish(result));
        }

        fn finishCallCaptureReserved(
            context: *CaptureContext,
            token: evmz.trace.CallToken,
            result: Host.Result,
        ) void {
            context.finishCallReserved(token, callCaptureFinish(result));
        }

        fn callCaptureKind(kind: Host.CallKind) evmz.trace.CallKind {
            return switch (kind) {
                .call => .call,
                .staticcall => .staticcall,
                .delegatecall => .delegatecall,
                .callcode => .callcode,
                .create => .create,
                .create2 => .create2,
            };
        }

        fn callCaptureStatus(status: Interpreter.Status, cause: evmz.execution.TerminalCause) evmz.trace.CallStatus {
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

        fn callCaptureFinish(result: Host.Result) evmz.trace.CallFinish {
            return .{
                .status = callCaptureStatus(result.status(), result.terminalCause()),
                .gas_left = result.gasLeft(),
                .output = result.outputData(),
                .checkpoint_reverted = result.checkpointReverted(),
            };
        }

        pub fn beginRootCapture(
            self: *Executor,
            message: executor_module.Message,
            gas: ExecutionGas,
        ) !?evmz.trace.CallToken {
            const context = self.currentCaptureContext() orelse return null;
            if (!context.capturesCalls()) return null;

            return context.beginCall(switch (message) {
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

        pub fn finishRootCapture(
            self: *Executor,
            token: evmz.trace.CallToken,
            result: Interpreter.Result,
        ) !void {
            try self.currentCaptureContext().?.finishCall(token, .{
                .status = callCaptureStatus(result.status, result.terminalCause()),
                .gas_left = result.gas_left,
                .output = result.output_data,
                // Root execution has no frame-local checkpoint in CallRuntime.
                .checkpoint_reverted = false,
            });
        }

        pub fn finishRootHostCapture(
            self: *Executor,
            token: evmz.trace.CallToken,
            result: Host.Result,
        ) !void {
            try finishCallCapture(self.currentCaptureContext(), token, result);
        }

        pub fn beginSelfDestructCapture(
            self: *Executor,
            address: Address,
            beneficiary: Address,
            balance: u256,
        ) !?evmz.trace.CallToken {
            const context = self.currentCaptureContext() orelse return null;
            if (!context.capturesCalls()) return null;
            const depth = std.math.add(u16, self.trace_depth, 1) catch
                std.math.maxInt(u16);
            return context.beginCall(.{
                .depth = depth,
                .kind = .selfdestruct,
                .from = address,
                .to = beneficiary,
                .code_address = address,
                .value = balance,
            });
        }

        pub fn finishSelfDestructCapture(
            self: *Executor,
            token: evmz.trace.CallToken,
        ) !void {
            try self.currentCaptureContext().?.finishCall(token, .{
                .status = .success,
                .gas_left = 0,
            });
        }

        fn traceFrameKind(frame: *const RuntimeFrame) evmz.trace.TraceFrameKind {
            return switch (frame.kind) {
                .root_call => .root,
                .call => switch (frame.frame.callFrame().msg.kind) {
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

        fn deinitRuntimeFrame(frame: *RuntimeFrame) void {
            frame.frame.deinit();
            frame.* = undefined;
        }

        pub fn executeCall(
            self: *Executor,
            options: executor_module.Call,
            gas: ExecutionGas,
        ) !executor_module.EvmResult {
            const result = try executeCallTransaction(
                self,
                options.sender,
                options.recipient,
                options.input,
                gas,
                options.value,
            );
            return Host.Result.fromCall(.{
                .status = result.status,
                .cause = result.cause,
                .output_data = result.output_data,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
                .state_gas_from_gas_left = result.state_gas_from_gas_left,
            });
        }

        pub fn executeCallTransaction(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !Interpreter.Result {
            return (try executeCallTransactionPhased(
                self,
                sender,
                recipient,
                input,
                gas,
                value,
            )).result;
        }

        pub fn executeCallTransactionPhased(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !executor_module.TransactionExecutionOutcome {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            _ = try currentTxContext(self);
            var execution_gas = gas;
            const top_frame_state_gas = try chargeTopFrameValueTransferStateGas(self, sender, recipient, value, &execution_gas);
            if (top_frame_state_gas.out_of_gas) {
                return .{
                    .stage = .preparation,
                    .result = .{
                        .status = .out_of_gas,
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    },
                };
            }

            const resolved = try resolveCode(self, recipient);
            if (!resolved.delegated and spec.precompile.active(recipient)) {
                var result = try runPrecompileCallTransaction(self, sender, recipient, input, execution_gas, value);
                finishTopFrameStateGas(&result, top_frame_state_gas);
                return .{ .stage = .payload, .result = result };
            }
            if (resolved.delegated) {
                const access = try topLevelDelegatedAccountAccess(self, resolved.address);
                const access_cost = if (access) |entry|
                    std.math.cast(u64, entry.gas) orelse std.math.maxInt(u64)
                else
                    0;
                if (execution_gas.regular_left < access_cost) {
                    var result = Interpreter.Result{
                        .status = .out_of_gas,
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    };
                    finishTopFrameStateGas(&result, top_frame_state_gas);
                    return .{ .stage = .preparation, .result = result };
                }
                execution_gas.regular_left -= access_cost;
            }

            const bytecode = try resolveExecutionCodeView(self, try resolvedCodeView(self, resolved));
            var result = try executePreparedCallTransaction(self, .{
                .bytecode = bytecode,
                .sender = sender,
                .recipient = recipient,
                .input = input,
                .gas = execution_gas.regular_left,
                .gas_reservoir = execution_gas.reservoir,
                .value = value,
            });
            finishTopFrameStateGas(&result, top_frame_state_gas);
            return .{ .stage = .payload, .result = result };
        }

        fn topLevelDelegatedAccountAccess(self: *Executor, target: Address) !?evmz.execution.DelegatedAccountAccess {
            const already_warm = self.state.isAccountWarm(target);
            const access = spec.call.topLevelDelegatedAccountAccess(.{
                .target_is_precompile = spec.precompile.active(target),
                .already_warm = already_warm,
            }) orelse return null;
            if (access.status == .cold and !already_warm) {
                try self.state.warmAccount(target);
            }
            return access;
        }

        const TopFrameStateGasCharge = struct {
            spent: i64 = 0,
            from_regular: i64 = 0,
            out_of_gas: bool = false,
        };

        fn chargeTopFrameValueTransferStateGas(
            self: *Executor,
            sender: Address,
            recipient: Address,
            value: u256,
            gas: *ExecutionGas,
        ) !TopFrameStateGasCharge {
            const same_address = std.mem.eql(u8, &sender, &recipient);
            const creates_account = if (value == 0 or same_address)
                false
            else
                !try self.state.accountExists(recipient);
            const charge_i64 = spec.call.topFrameValueTransferStateGas(.{
                .value = value,
                .same_address = same_address,
                .creates_account = creates_account,
            });
            return chargeTopFrameStateGas(gas, charge_i64);
        }

        fn chargeTopFrameCreateStateGas(
            self: *Executor,
            options: executor_module.Create,
            gas: *ExecutionGas,
        ) !TopFrameStateGasCharge {
            // The integrated rule compares the pre-transaction account to the
            // empty account value. Storage does not make an account alive.
            const target_alive = if (try self.state.getAccountOrLoad(options.recipient)) |account|
                account.nonce != 0 or
                    account.balance != 0 or
                    !std.mem.eql(u8, &account.code_hash, &evmz.crypto.keccak256_empty)
            else
                false;

            return chargeTopFrameStateGas(
                gas,
                spec.create.accountStateGas(.{ .target_alive = target_alive }),
            );
        }

        fn chargeTopFrameStateGas(
            gas: *ExecutionGas,
            charge_i64: i64,
        ) TopFrameStateGasCharge {
            if (charge_i64 <= 0) return .{};

            const charge = std.math.cast(u64, charge_i64) orelse std.math.maxInt(u64);
            const from_reservoir = @min(gas.reservoir, charge);
            const from_regular = charge - from_reservoir;
            if (from_regular > gas.regular_left) return .{ .out_of_gas = true };

            gas.reservoir -= from_reservoir;
            gas.regular_left -= from_regular;
            return .{
                .spent = charge_i64,
                .from_regular = std.math.cast(i64, from_regular) orelse std.math.maxInt(i64),
            };
        }

        fn finishTopFrameStateGas(result: *Interpreter.Result, charge: TopFrameStateGasCharge) void {
            if (charge.spent == 0) return;
            const from_reservoir = std.math.sub(i64, charge.spent, charge.from_regular) catch 0;
            switch (result.status) {
                .success => {
                    result.state_gas_spent = std.math.add(i64, result.state_gas_spent, charge.spent) catch std.math.maxInt(i64);
                    result.state_gas_from_gas_left = std.math.add(i64, result.state_gas_from_gas_left, charge.from_regular) catch std.math.maxInt(i64);
                },
                .revert => {
                    result.gas_reservoir = std.math.add(i64, result.gas_reservoir, from_reservoir) catch std.math.maxInt(i64);
                    result.gas_left = std.math.add(i64, result.gas_left, charge.from_regular) catch std.math.maxInt(i64);
                },
                .invalid, .out_of_gas => {
                    result.gas_reservoir = std.math.add(i64, result.gas_reservoir, from_reservoir) catch std.math.maxInt(i64);
                },
            }
        }

        fn runPrecompileCallTransaction(
            self: *Executor,
            sender: Address,
            recipient: Address,
            input: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !Interpreter.Result {
            self.clearLastOutput();
            _ = try currentTxContext(self);
            if (!try self.transferValue(sender, recipient, value)) {
                return .{
                    .status = .invalid,
                    .cause = .insufficient_balance,
                    .gas_left = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                    .gas_refund = 0,
                    .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }

            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = recipient,
                .sender = sender,
                .input_data = input,
                .value = value,
                .code_address = recipient,
            };
            const host_result = (try runPrecompileCall(self, &message)) orelse unreachable;
            const result = host_result.expectCall();
            return .{
                .status = result.status,
                .cause = result.cause,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
                .gas_reservoir = result.gas_reservoir,
                .state_gas_spent = result.state_gas_spent,
                .state_gas_from_gas_left = result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };
        }

        pub fn executePreparedCallTransaction(
            self: *Executor,
            options: executor_module.PreparedCallTransaction,
        ) !Interpreter.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = try currentTxContext(self);
            if (!try self.transferValue(options.sender, options.recipient, options.value)) {
                return .{
                    .status = .invalid,
                    .cause = .insufficient_balance,
                    .gas_left = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
                    .gas_refund = 0,
                    .gas_reservoir = std.math.cast(i64, options.gas_reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }

            const message = Host.Message{
                .depth = 0,
                .kind = .call,
                .gas = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, options.gas_reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.input,
                .value = options.value,
                .code_address = options.recipient,
            };

            const host_result = try executePreparedCallMessage(self, message, options.bytecode);
            const call_result = host_result.expectCall();
            return .{
                .status = call_result.status,
                .cause = call_result.cause,
                .gas_left = call_result.gas_left,
                .gas_refund = call_result.gas_refund,
                .gas_reservoir = call_result.gas_reservoir,
                .state_gas_spent = call_result.state_gas_spent,
                .state_gas_from_gas_left = call_result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };
        }

        /// Execute one already-resolved root message through the index-based runtime.
        /// The caller owns transaction/checkpoint setup and prepared-code execution.
        pub fn executePreparedCallMessage(
            self: *Executor,
            message: Host.Message,
            bytecode: *const Bytecode,
        ) !Host.Result {
            var runtime = CallRuntime.init(self);
            defer runtime.deinit();
            try runtime.prepare();
            try runtime.pushRootCall(message, bytecode);
            return runtime.run();
        }

        pub fn executeCreateTransaction(
            self: *Executor,
            sender: Address,
            recipient: Address,
            init_code: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !Host.Result {
            return executeCreate(self, .{
                .sender = sender,
                .recipient = recipient,
                .init_code = init_code,
                .value = value,
            }, gas);
        }

        /// Execute a root transaction CREATE. Transaction lifecycle owns the
        /// sender nonce; only raw and nested CREATE increment their creator.
        pub fn executeCreateTransactionPhased(
            self: *Executor,
            options: executor_module.Create,
            gas: ExecutionGas,
        ) !executor_module.TransactionExecutionOutcome {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = try currentTxContext(self);
            var execution_gas = gas;
            const top_frame_state_gas = try chargeTopFrameCreateStateGas(self, options, &execution_gas);
            if (top_frame_state_gas.out_of_gas) {
                return .{
                    .stage = .preparation,
                    .result = .{
                        .status = .out_of_gas,
                        .gas_left = 0,
                        .gas_refund = 0,
                        .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                        .output_data = &.{},
                    },
                };
            }

            const host_result = try executeTransactionCreateMessage(self, .{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, execution_gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
            });
            const create_result = host_result.expectCreate();
            var result = Interpreter.Result{
                .status = create_result.status,
                .cause = create_result.cause,
                .gas_left = create_result.gas_left,
                .gas_refund = create_result.gas_refund,
                .gas_reservoir = create_result.gas_reservoir,
                .state_gas_spent = create_result.state_gas_spent,
                .state_gas_from_gas_left = create_result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };
            finishTopFrameStateGas(&result, top_frame_state_gas);
            return .{ .stage = .payload, .result = result };
        }

        pub fn executeCreate(
            self: *Executor,
            options: executor_module.Create,
            gas: ExecutionGas,
        ) !executor_module.EvmResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            self.clearLastOutput();
            _ = try currentTxContext(self);
            try self.traceAccountAccess(options.recipient);
            return executeCreateMessage(self, .{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .recipient = options.recipient,
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
            });
        }

        pub fn prepareBytecodeAlloc(self: *const Executor, allocator: std.mem.Allocator, code: []const u8) !Bytecode {
            return Bytecode.prepare(allocator, code, self.config);
        }

        pub const ResolvedCode = struct {
            address: Address,
            delegated: bool,
            original_view: State.CodeView,
        };

        /// Resolve canonical code first, then consult the executor-owned derived
        /// cache. Address-based callers materialize through tracked state for witness
        /// validation and code-read tracing; CALL paths can reuse that traced view.
        pub fn resolveExecutionCode(self: *Executor, address: Address) !*const Bytecode {
            return resolveExecutionCodeView(self, try self.state.getCodeView(address));
        }

        pub fn resolveExecutionCodeView(self: *Executor, code: State.CodeView) !*const Bytecode {
            const execution = if (self.prepared_code_execution) |*active|
                active
            else
                return error.MissingPreparedCodeExecution;
            return execution.resolve(code.code_hash, code.bytes, .{
                .admit = true,
            });
        }

        pub fn dupeExecutionCodeAlloc(self: *Executor, allocator: std.mem.Allocator, address: Address) ![]u8 {
            const code = try self.getCode(address);
            if (eip7702.delegationTarget(code)) |target| {
                return dupeCodeAlloc(self, allocator, target);
            }
            return allocator.dupe(u8, code);
        }

        fn dupeCodeAlloc(self: *Executor, allocator: std.mem.Allocator, address: Address) ![]u8 {
            return allocator.dupe(u8, try self.getCode(address));
        }

        pub fn executeInterpreter(self: *Executor, interpreter: *BoundInterpreter, depth: u16) !Interpreter.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.trace_depth;
            self.trace_depth = depth;
            defer self.trace_depth = previous_depth;
            return interpreter.execute();
        }

        pub fn executeInterpreterUntilAction(self: *Executor, interpreter: *BoundInterpreter, depth: u16) !Interpreter.RunResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.trace_depth;
            self.trace_depth = depth;
            defer self.trace_depth = previous_depth;
            return interpreter.executeUntilAction();
        }

        fn executeCapturedInterpreterUntilAction(
            self: *Executor,
            interpreter: *BoundInterpreter,
            depth: u16,
            capture: *evmz.trace.TraceCapture,
        ) !Interpreter.RunResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.trace_depth;
            self.trace_depth = depth;
            defer self.trace_depth = previous_depth;
            return interpreter.executeCapturedUntilAction(capture);
        }

        pub fn currentTxContext(self: *const Executor) !Host.TxContext {
            const context = self.execution_context orelse return error.MissingTxContext;
            return context_adapter.toHost(context);
        }

        pub fn getTxContext(ptr: *anyopaque) !Host.TxContext {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return currentTxContext(self);
        }

        fn acquireBytecodeFrame(
            self: *Executor,
            frame_allocator: std.mem.Allocator,
            host_iface: *Host,
            msg: *const Host.Message,
            bytecode: *const Bytecode,
        ) !FrameLease {
            return try self.frame_store.acquire(self.allocator, frame_allocator, .{
                .host = host_iface,
                .msg = msg,
                .bytecode = bytecode,
            });
        }

        pub fn callScratch(self: *Executor, depth: u16) !ScratchScope {
            return .{
                .executor = self,
                .depth = depth,
                .allocator = try beginCallScratch(self, depth),
            };
        }

        fn beginCallScratch(self: *Executor, depth: u16) !std.mem.Allocator {
            const index: usize = depth;
            while (self.call_scratch_slots.items.len <= index) {
                const slot = try self.allocator.create(call_scratch_storage.Slot);
                errdefer self.allocator.destroy(slot);
                slot.* = call_scratch_storage.Slot.init(self.allocator);
                errdefer slot.deinit();
                try self.call_scratch_slots.append(self.allocator, slot);
            }
            self.call_scratch_slots.items[index].reset();
            return self.call_scratch_slots.items[index].allocator();
        }

        fn endCallScratch(self: *Executor, depth: u16) void {
            const index: usize = depth;
            if (index < self.call_scratch_slots.items.len) {
                self.call_scratch_slots.items[index].reset();
            }
        }

        pub fn stabilizeFinalResult(self: *Executor, result: Host.Result) !Host.Result {
            return switch (result) {
                .call => |call_result| Host.Result.fromCall(.{
                    .status = call_result.status,
                    .cause = call_result.cause,
                    .output_data = try self.setLastOutput(call_result.output_data),
                    .gas_left = call_result.gas_left,
                    .gas_refund = call_result.gas_refund,
                    .gas_reservoir = call_result.gas_reservoir,
                    .state_gas_spent = call_result.state_gas_spent,
                    .state_gas_from_gas_left = call_result.state_gas_from_gas_left,
                    .checkpoint_reverted = call_result.checkpoint_reverted,
                }),
                .create => |create_result| Host.Result.fromCreate(create_result.address, .{
                    .status = create_result.status,
                    .cause = create_result.cause,
                    .output_data = if (aliasesLastOutput(self, create_result.output_data))
                        self.lastOutputData()
                    else
                        try self.setLastOutput(create_result.output_data),
                    .gas_left = create_result.gas_left,
                    .gas_refund = create_result.gas_refund,
                    .gas_reservoir = create_result.gas_reservoir,
                    .state_gas_spent = create_result.state_gas_spent,
                    .state_gas_from_gas_left = create_result.state_gas_from_gas_left,
                    .checkpoint_reverted = create_result.checkpoint_reverted,
                }),
            };
        }

        fn aliasesLastOutput(self: *const Executor, output_data: []const u8) bool {
            const last = self.last_call_output.slice();
            if (output_data.len != last.len) return false;
            if (output_data.len == 0) return true;
            return output_data.ptr == last.ptr;
        }

        fn beginCall(self: *Executor, msg: Host.Message) !StartedCall {
            if (msg.depth > Host.max_call_depth) {
                return .{ .immediate = Host.Result.fromCall(.{
                    .status = .invalid,
                    .cause = .call_depth_exceeded,
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }) };
            }

            var checkpoint = try CheckpointGuard.begin(&self.state);
            defer checkpoint.deinit();

            if (msg.value > 0 and (msg.kind == .call or msg.kind == .callcode)) {
                const value_ok = if (msg.kind == .call)
                    try self.transferValue(msg.sender, msg.recipient, msg.value)
                else
                    try hasBalance(self, msg.recipient, msg.value);
                if (!value_ok) {
                    try checkpoint.restore();
                    return .{ .immediate = Host.Result.fromCall(.{
                        .status = .invalid,
                        .cause = .insufficient_balance,
                        .output_data = &.{},
                        .gas_left = msg.gas,
                        .gas_refund = 0,
                        .gas_reservoir = msg.gas_reservoir,
                    }) };
                }
            }

            const resolved = try resolveCode(self, msg.code_address);
            if (!resolved.delegated and spec.precompile.active(msg.code_address)) {
                if (try runPrecompileCall(self, &msg)) |result| {
                    if (result.status() == .success) {
                        try touchEmptyCallRecipient(self, msg);
                    }
                    try checkpoint.finish(result.status());
                    return .{ .immediate = hostResultWithCheckpointReverted(
                        result,
                        result.status() != .success,
                    ) };
                }
            }

            const code = try resolvedCodeView(self, resolved);
            if (code.bytes.len == 0) {
                try touchEmptyCallRecipient(self, msg);
                try checkpoint.commit();
                return .{ .immediate = Host.Result.fromCall(.{
                    .status = .success,
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }) };
            }

            const bytecode = try resolveExecutionCodeView(self, code);
            checkpoint.disarm();
            return .{ .child = .{
                .checkpoint_state = checkpoint.checkpoint_state,
                .bytecode = bytecode,
            } };
        }

        fn runPrecompileCall(
            self: *Executor,
            msg: *const Host.Message,
        ) !?Host.Result {
            self.clearLastOutput();
            var scratch = try callScratch(self, msg.depth);
            defer scratch.deinit();

            const output_buffer = null;
            var host_iface = self.host();
            const precompile = spec.precompile.resolve(msg.code_address) orelse return null;
            const precompile_outcome = spec.precompile.execute(
                precompile,
                .{
                    .allocator = scratch.allocator,
                    .host = &host_iface,
                    .message = msg,
                    .output_buffer = output_buffer,
                    .runtime = self.precompile_runtime,
                },
            ) catch |err| switch (err) {
                error.NotImplemented => return Host.Result.fromCall(.{
                    .status = .invalid,
                    .output_data = &.{},
                    .gas_left = 0,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }),
                else => return err,
            };
            const result = switch (precompile_outcome) {
                .result => |result| result,
                .service_error => |err| return err,
            };

            defer if (result.output_owned and result.output_data.len != 0) scratch.allocator.free(result.output_data);
            const output = if (result.output_owned) output: {
                break :output try self.setLastOutput(result.output_data);
            } else if (result.output_data.len == 0) output: {
                break :output &.{};
            } else {
                return error.InvalidPrecompileOutput;
            };
            const status: Interpreter.Status = switch (result.status) {
                .success => .success,
                .failure => .invalid,
                .out_of_gas => .out_of_gas,
            };
            return Host.Result.fromCall(.{
                .status = status,
                .output_data = output,
                .gas_left = if (status == .success) result.gas_left else 0,
                .gas_refund = 0,
                .gas_reservoir = msg.gas_reservoir,
            });
        }

        fn touchEmptyCallRecipient(self: *Executor, msg: Host.Message) !void {
            if (msg.kind != .call or !spec.call.touches_empty_recipient) return;
            try self.state.touchAccount(msg.recipient);
        }

        pub fn resolveCode(self: *Executor, address: Address) !ResolvedCode {
            const original = try self.state.getCodeView(address);
            if (eip7702.delegationTarget(original.bytes)) |target| {
                return .{
                    .address = target,
                    .delegated = true,
                    .original_view = original,
                };
            }
            return .{
                .address = address,
                .delegated = false,
                .original_view = original,
            };
        }

        pub fn resolvedCodeView(self: *Executor, resolved: ResolvedCode) !State.CodeView {
            if (resolved.delegated) return self.state.getCodeView(resolved.address);
            return resolved.original_view;
        }

        fn hasBalance(self: *Executor, address: Address, value: u256) !bool {
            const account = try self.state.getAccountOrLoad(address) orelse return value == 0;
            return account.balance >= value;
        }

        /// Host.call resolver for direct `Interpreter.execute()` users. Top-level call
        /// and create transactions enter `CallRuntime` through their executor entrypoints.
        pub fn resolveHostCall(self: *Executor, msg: Host.Message) !Host.Result {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.trace_depth;
            self.trace_depth = msg.depth;
            defer self.trace_depth = previous_depth;

            const capture = self.currentCaptureContext();
            const call_capture = try beginCallCapture(capture, msg);
            const result = Host.precheckResult(msg) orelse if (msg.kind == .create or msg.kind == .create2) result: {
                // Direct Host callers may still submit an over-depth message.
                // Opcode-generated terminal attempts were resolved above.
                if (msg.depth > Host.max_call_depth) {
                    break :result createFailureWithCause(self, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);
                }
                break :result try executeCreateMessage(self, msg);
            } else switch (try beginCall(self, msg)) {
                .immediate => |immediate| immediate,
                .child => |child| blk: {
                    var checkpoint = CheckpointGuard.init(&self.state, child.checkpoint_state);
                    defer checkpoint.deinit();

                    var runtime = CallRuntime.init(self);
                    defer runtime.deinit();
                    try runtime.prepareNested();
                    try runtime.pushChildCall(msg, child.checkpoint_state, child.bytecode, null);
                    const result = try runtime.run();
                    checkpoint.disarm();
                    break :blk result;
                },
            };
            if (call_capture) |token| try finishCallCapture(capture, token, result);
            return result;
        }

        fn executeCreateMessage(self: *Executor, msg: Host.Message) !Host.Result {
            return executeCreateMessageWith(self, msg, beginCreate);
        }

        fn executeTransactionCreateMessage(self: *Executor, msg: Host.Message) !Host.Result {
            return executeCreateMessageWith(self, msg, beginTransactionCreate);
        }

        fn executeCreateMessageWith(
            self: *Executor,
            msg: Host.Message,
            comptime begin: anytype,
        ) !Host.Result {
            const previous_depth = self.trace_depth;
            self.trace_depth = msg.depth;
            defer self.trace_depth = previous_depth;

            if (msg.depth > Host.max_call_depth) return createFailureWithCause(self, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid, .call_depth_exceeded);

            return switch (try begin(self, msg)) {
                .immediate => |result| result,
                .child => |child| blk: {
                    var checkpoint = CheckpointGuard.init(&self.state, child.checkpoint_state);
                    defer checkpoint.deinit();

                    var runtime = CallRuntime.init(self);
                    defer runtime.deinit();
                    try runtime.prepareNested();
                    try runtime.pushChildCreate(child, null);
                    const result = try runtime.run();
                    checkpoint.disarm();
                    break :blk result;
                },
            };
        }

        fn beginCreate(self: *Executor, msg: Host.Message) !StartedCreate {
            const caller_nonce = switch (try prepareCreateCaller(self, msg)) {
                .rejected => |result| return .{ .immediate = result },
                .nonce => |nonce| nonce,
            };
            const next_nonce = std.math.add(u64, caller_nonce, 1) catch
                return .{ .immediate = createFailureWithCause(self, msg.recipient, msg.gas, msg.gas_reservoir, .invalid, .nonce_overflow) };
            try warmCreatedAddressIfNeeded(self, msg.recipient);
            try self.state.setNonce(msg.sender, next_nonce);
            return beginPreparedCreate(self, msg);
        }

        fn beginTransactionCreate(self: *Executor, msg: Host.Message) !StartedCreate {
            switch (try prepareCreateCaller(self, msg)) {
                .rejected => |result| return .{ .immediate = result },
                .nonce => {},
            }
            try warmCreatedAddressIfNeeded(self, msg.recipient);
            return beginPreparedCreate(self, msg);
        }

        fn prepareCreateCaller(self: *Executor, msg: Host.Message) !CreateCallerPreparation {
            const caller = try self.getAccountOrLoad(msg.sender) orelse evmz.state.Account{};
            const create_address = msg.recipient;
            if (caller.balance < msg.value) {
                return .{ .rejected = createFailureWithCause(self, create_address, msg.gas, msg.gas_reservoir, .invalid, .insufficient_balance) };
            }
            return .{ .nonce = caller.nonce };
        }

        fn warmCreatedAddressIfNeeded(self: *Executor, create_address: Address) !void {
            if (spec.create.warms_created_address) {
                try self.warmAccount(create_address);
            }
        }

        fn beginPreparedCreate(self: *Executor, msg: Host.Message) !StartedCreate {
            const create_address = msg.recipient;
            var checkpoint = try CheckpointGuard.begin(&self.state);
            defer checkpoint.deinit();

            if (try createCollision(self, create_address)) {
                try checkpoint.commit();
                return .{ .immediate = createFailureWithCause(
                    self,
                    create_address,
                    0,
                    msg.gas_reservoir,
                    .invalid,
                    .contract_address_collision,
                ) };
            }

            _ = try self.state.subtractBalance(msg.sender, msg.value);
            try self.state.addBalance(create_address, msg.value);
            try executor_module.transfer_logs.emit(self, .{
                .from = msg.sender,
                .to = create_address,
                .amount = msg.value,
            });
            try self.state.setNonce(create_address, spec.create.initial_nonce);
            try self.state.clearCode(create_address);
            try self.state.markCreatedContract(create_address);

            const child_msg = Host.Message{
                .depth = msg.depth,
                .kind = .call,
                .gas = msg.gas,
                .gas_reservoir = msg.gas_reservoir,
                .recipient = create_address,
                .sender = msg.sender,
                .input_data = &.{},
                .value = msg.value,
                .is_static = msg.is_static,
                .code_address = create_address,
            };
            checkpoint.disarm();
            return .{ .child = .{
                .checkpoint_state = checkpoint.checkpoint_state,
                .address = create_address,
                .kind = msg.kind,
                .msg = child_msg,
                .init_code = msg.input_data,
            } };
        }

        fn finishCreate(
            self: *Executor,
            child: ChildCreate,
            result: Interpreter.Result,
            checkpoint: *CheckpointGuard,
        ) !Host.Result {
            const output = result.output_data;
            if (result.status != .success) {
                try checkpoint.restore();
                return Host.Result.fromCreate(child.address, .{
                    .status = result.status,
                    .cause = result.cause,
                    .checkpoint_reverted = true,
                    .output_data = output,
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                    .gas_reservoir = result.gas_reservoir,
                    .state_gas_spent = result.state_gas_spent,
                    .state_gas_from_gas_left = result.state_gas_from_gas_left,
                });
            }

            if (spec.create.code_size_limit) |limit| {
                if (output.len > limit) {
                    try checkpoint.restore();
                    return createFailureFromResult(self, child.address, result, .out_of_gas, .max_code_size_exceeded);
                }
            }
            if (spec.create.rejectsCode(output)) {
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, result, .invalid, .invalid_code);
            }

            const runtime_size = std.math.cast(i64, output.len) orelse {
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, result, .out_of_gas, .code_store_out_of_gas);
            };
            const deposit_regular_cost = spec.create.depositRegularGas(runtime_size) orelse {
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, result, .out_of_gas, .code_store_out_of_gas);
            };
            if (result.gas_left < deposit_regular_cost) {
                if (spec.create.deposit_regular_gas_oog_commits) {
                    try checkpoint.commit();
                    return Host.Result.fromCreate(child.address, .{
                        .status = .success,
                        .cause = .code_store_out_of_gas,
                        .output_data = output,
                        .gas_left = result.gas_left,
                        .gas_refund = result.gas_refund,
                        .gas_reservoir = result.gas_reservoir,
                        .state_gas_spent = result.state_gas_spent,
                        .state_gas_from_gas_left = result.state_gas_from_gas_left,
                    });
                }
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, result, .out_of_gas, .code_store_out_of_gas);
            }

            var deposit_result = result;
            deposit_result.gas_left -= deposit_regular_cost;
            const deposit_state_gas = spec.create.depositStateGas(runtime_size) orelse {
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, deposit_result, .out_of_gas, .code_store_out_of_gas);
            };
            deposit_result.trackStateGas(deposit_state_gas);
            if (deposit_result.status != .success) {
                try checkpoint.restore();
                return createFailureFromResult(self, child.address, deposit_result, deposit_result.status, .code_store_out_of_gas);
            }

            try self.state.setCode(child.address, output);
            try checkpoint.commit();

            return Host.Result.fromCreate(child.address, .{
                .status = .success,
                .output_data = output,
                .gas_left = deposit_result.gas_left,
                .gas_refund = deposit_result.gas_refund,
                .gas_reservoir = deposit_result.gas_reservoir,
                .state_gas_spent = deposit_result.state_gas_spent,
                .state_gas_from_gas_left = deposit_result.state_gas_from_gas_left,
            });
        }

        fn createFailure(self: *Executor, create_address: Address, gas_left: i64, gas_reservoir: i64, status: Interpreter.Status) Host.Result {
            return createFailureWithCause(self, create_address, gas_left, gas_reservoir, status, null);
        }

        fn createFailureWithCause(
            self: *Executor,
            create_address: Address,
            gas_left: i64,
            gas_reservoir: i64,
            status: Interpreter.Status,
            cause: ?evmz.execution.TerminalCause,
        ) Host.Result {
            self.clearLastOutput();
            return Host.Result.fromCreate(create_address, .{
                .status = status,
                .cause = cause,
                .output_data = &.{},
                .gas_left = gas_left,
                .gas_refund = 0,
                .gas_reservoir = gas_reservoir,
            });
        }

        fn createFailureFromResult(
            self: *Executor,
            create_address: Address,
            result: Interpreter.Result,
            status: Interpreter.Status,
            cause: evmz.execution.TerminalCause,
        ) Host.Result {
            var failed = result;
            failed.status = status;
            failed.gas_left = 0;
            failed.gas_refund = 0;
            failed.finalizeFrameStateGas();
            const host_result = createFailureWithCause(
                self,
                create_address,
                failed.gas_left,
                failed.gas_reservoir,
                status,
                cause,
            );
            return hostResultWithCheckpointReverted(host_result, true);
        }

        fn hostResultWithCheckpointReverted(result: Host.Result, reverted: bool) Host.Result {
            return switch (result) {
                .call => |call_result| blk: {
                    var updated = call_result;
                    updated.checkpoint_reverted = reverted;
                    break :blk Host.Result.fromCall(updated);
                },
                .create => |create_result| blk: {
                    var updated = create_result;
                    updated.checkpoint_reverted = reverted;
                    break :blk .{ .create = updated };
                },
            };
        }

        fn createCollision(self: *Executor, address: Address) !bool {
            if (spec.precompile.active(address)) return true;
            const account = try self.state.getAccountOrLoad(address) orelse return false;
            // EIP-7610 clarifies this rule retroactively for every Ethereum
            // revision: storage-only destinations also collide.
            return account.nonce != 0 or
                try self.state.accountHasCode(address) or
                try self.state.accountHasStorage(address);
        }
    };
}

test "CREATE final stabilization reuses already-stable output" {
    const Berlin = evmz.Vm(evmz.eth.berlin);
    const Executor = Berlin.Executor;
    const runtime = bind(Executor);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var executor = Executor.init(failing_allocator.allocator(), .{});
    defer executor.deinit();

    executor.last_call_output.deinit();
    executor.last_call_output = frame_io.ByteSlot.init(std.testing.allocator);
    _ = try executor.setLastOutput(&.{0xaa});
    const result = (try runtime.stabilizeFinalResult(&executor, Host.Result.fromCreate(evmz.addr(0x1234), .{
        .status = .success,
        .output_data = executor.lastOutputData(),
        .gas_left = 7,
        .gas_refund = 0,
    }))).expectCreate();

    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
    try std.testing.expect(result.output_data.ptr == executor.lastOutputData().ptr);
}

test "EIP-7610 creation collision applies retroactively to every revision" {
    const target = evmz.addr(0x1234);

    inline for (std.enums.values(evmz.eth.Revision)) |revision| {
        try expectCreationCollision(revision, target);
    }
}

test "interior checkpoint guard restores unresolved state and preserves commits" {
    const Cancun = evmz.Vm(evmz.eth.cancun);
    const Executor = Cancun.Executor;
    const runtime = bind(Executor);
    const address = evmz.addr(0x1234);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    const attempt = executor.state.beginTransaction();
    executor.state.beginScope();
    defer {
        executor.state.closeScope();
        executor.state.seal(attempt);
        executor.state.discard(attempt);
    }

    {
        var checkpoint = try runtime.CheckpointGuard.begin(&executor.state);
        defer checkpoint.deinit();
        try executor.state.addBalance(address, 7);
    }
    try std.testing.expectEqual(@as(u256, 0), try executor.state.getBalance(address));

    {
        var checkpoint = try runtime.CheckpointGuard.begin(&executor.state);
        defer checkpoint.deinit();
        try executor.state.addBalance(address, 9);
        try checkpoint.commit();
    }
    try std.testing.expectEqual(@as(u256, 9), try executor.state.getBalance(address));
}

fn expectCreationCollision(comptime revision: evmz.eth.Revision, target: Address) !void {
    const Exact = evmz.Vm(evmz.eth.specAt(revision));
    const Runtime = bind(Exact.Executor);
    var executor = Exact.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var target_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try target_account.storage.put(1, 1);
    try executor.state.seedAccount(target, target_account);
    try std.testing.expect(try Runtime.createCollision(&executor, target));
}

test "nested call runtime owns its segment and keeps capture indices global" {
    const Exact = evmz.Vm(evmz.eth.cancun);
    const Executor = Exact.Executor;
    const runtime = bind(Executor);
    const child_address = evmz.addr(0x3333);

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&.{ 0x60, 0x07, 0x60, 0x00, 0x55, 0x00 });
    try executor.state.seedAccount(child_address, child_account);

    var tape = evmz.trace.TraceTape.initGrowable(std.testing.allocator);
    defer tape.deinit();
    var capture = CaptureContext.init(std.testing.allocator, .{ .tape = &tape });
    defer capture.deinit();
    try capture.begin();
    errdefer capture.abort() catch {};

    try executor.beginCapturedTransaction(.{
        .chain_id = 1,
        .gas_price = 0,
        .origin = evmz.addr(0x1111),
        .coinbase = evmz.addr(0),
        .number = 0,
        .timestamp = 0,
        .gas_limit = 100_000,
        .prev_randao = 0,
        .base_fee = 0,
        .blob_base_fee = 0,
        .blob_hashes = &.{},
    }, evmz.addr(0x1111), evmz.addr(0x2222), &capture);
    defer executor.closeTransaction();

    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();

    var bytecode = try executor.prepareBytecode(&.{0x00});
    defer bytecode.deinit(std.testing.allocator);
    const root_message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100,
        .recipient = evmz.addr(0x2222),
        .sender = evmz.addr(0x1111),
        .input_data = &.{},
        .value = 0,
        .code_address = evmz.addr(0x2222),
    };

    var outer = runtime.CallRuntime.init(&executor);
    try outer.prepare();
    try outer.pushRootCall(root_message, &bytecode);
    try std.testing.expectEqual(@as(usize, 1), executor.runtime_frames.items.len);

    var nested_probe = runtime.CallRuntime.init(&executor);
    try std.testing.expectEqual(@as(usize, 1), nested_probe.frame_base);
    try std.testing.expectError(error.ActiveRuntimeFrames, nested_probe.prepare());
    const child_result = (try runtime.resolveHostCall(&executor, .{
        .depth = 1,
        .kind = .call,
        .gas = 100_000,
        .recipient = child_address,
        .sender = root_message.recipient,
        .input_data = &.{},
        .value = 0,
        .code_address = child_address,
    })).expectCall();
    try std.testing.expectEqual(Interpreter.Status.success, child_result.status);
    try std.testing.expectEqual(@as(usize, 1), executor.runtime_frames.items.len);
    try std.testing.expectEqual(@as(usize, 1), capture.frame_captures.items.len);
    try std.testing.expectEqual(@as(u256, 7), try executor.state.getStorage(child_address, 0));

    const root_result = (try outer.run()).expectCall();
    try std.testing.expectEqual(Interpreter.Status.success, root_result.status);
    try std.testing.expectEqual(@as(usize, 0), executor.runtime_frames.items.len);

    const span = (try capture.finish()).?;
    defer tape.resolve(span) catch unreachable;
    try std.testing.expectEqual(@as(usize, 2), span.frames.len);
    try std.testing.expectEqual(evmz.trace.TraceFrameKind.root, span.frames[0].kind);
    try std.testing.expectEqual(@as(?u32, 0), span.frames[1].parent_frame_id);
    try std.testing.expectEqual(evmz.trace.TraceFrameKind.call, span.frames[1].kind);
}
