const std = @import("std");
const evmz = @import("../evm.zig");
const executor_module = @import("../executor.zig");

const Address = evmz.Address;
const Bytecode = evmz.Bytecode;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;
const Journal = @import("../state/Journal.zig");
const Overlay = @import("../state/Overlay.zig");
const eip7702 = @import("./eip7702.zig");
const frame_io = @import("../frame_io.zig");
const FrameStore = @import("./frame_store.zig");
const runtime_frames = @import("./runtime_frames.zig");
const ExecutionGas = @import("../execution.zig").ExecutionGas;
const call_scratch_storage = @import("./call_scratch.zig");
const context_adapter = @import("./context.zig");
const CaptureContext = executor_module.CaptureContext;

pub fn For(comptime Executor: type) type {
    return struct {
        const Protocol = Executor.Protocol;
        const BoundInterpreter = Interpreter.For(Protocol);

        pub const ScratchScope = struct {
            executor: *Executor,
            depth: u16,
            allocator: std.mem.Allocator,

            pub fn deinit(self: *ScratchScope) void {
                endCallScratch(self.executor, self.depth);
                self.* = undefined;
            }
        };

        pub const FrameLease = FrameStore.Lease;

        const StartedCall = union(enum) {
            immediate: Host.Result,
            child: ChildCall,
        };

        const ChildCall = struct {
            checkpoint_state: Journal.Checkpoint,
            bytecode: *const Bytecode,
        };

        const StartedCreate = union(enum) {
            immediate: Host.Result,
            child: ChildCreate,
        };

        const ChildCreate = runtime_frames.ChildCreate;
        const RuntimeFrame = runtime_frames.Frame;

        const CallRuntime = struct {
            executor: *Executor,
            host_iface: Host,
            frames: *std.ArrayList(RuntimeFrame),
            capture_context: ?*CaptureContext,

            fn init(executor: *Executor) CallRuntime {
                return .{
                    .executor = executor,
                    .host_iface = executor.host(),
                    .frames = &executor.runtime_frames,
                    .capture_context = executor.capture_context,
                };
            }

            fn deinit(self: *CallRuntime) void {
                while (self.frames.items.len > 0) {
                    self.popFrame();
                }
            }

            fn prepare(self: *CallRuntime) !void {
                if (self.frames.items.len != 0) return error.ActiveRuntimeFrames;
                if (self.executor.runtime_resources.maxLiveFrames()) |max_live_frames| {
                    if (self.frames.capacity < max_live_frames) return error.FrameCapacityExceeded;
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

            fn pushChildCall(self: *CallRuntime, msg: Host.Message, checkpoint_state: Journal.Checkpoint, bytecode: *const Bytecode) !void {
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
                });
            }

            fn pushChildCreate(self: *CallRuntime, child: ChildCreate) !void {
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
                });
            }

            fn appendFrame(self: *CallRuntime, frame: RuntimeFrame) !void {
                if (self.executor.runtime_resources.maxLiveFrames()) |max_live_frames| {
                    if (self.frames.items.len >= max_live_frames) return error.FrameCapacityExceeded;
                    if (self.frames.items.len >= self.frames.capacity) return error.FrameCapacityExceeded;
                    self.frames.appendAssumeCapacity(frame);
                } else {
                    try self.frames.append(self.executor.allocator, frame);
                }
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
                const index = self.frames.items.len - 1;
                if (self.stepCaptureContext()) |context| context.popFrame();
                deinitRuntimeFrame(&self.frames.items[index]);
                self.frames.items.len = index;
            }

            inline fn stepCaptureContext(self: *CallRuntime) ?*CaptureContext {
                const context = self.capture_context orelse return null;
                return if (context.capturesSteps()) context else null;
            }

            fn run(self: *CallRuntime) !Host.Result {
                while (self.frames.items.len > 0) {
                    const index = self.frames.items.len - 1;
                    const runtime_frame = &self.frames.items[index];
                    var interpreter = runtime_frame.frame.interpreter(Protocol);
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
                            if (self.frames.items.len == 1) {
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
                const previous_depth = self.executor.state.trace_depth;
                self.executor.state.trace_depth = msg.depth;
                defer self.executor.state.trace_depth = previous_depth;

                switch (try beginCall(self.executor, msg)) {
                    .immediate => |result| return result,
                    .child => |child| {
                        var checkpoint_open = true;
                        errdefer {
                            if (checkpoint_open) self.executor.state.revertToCheckpoint(child.checkpoint_state) catch {};
                        }

                        try self.pushChildCall(msg, child.checkpoint_state, child.bytecode);
                        checkpoint_open = false;
                        return null;
                    },
                }
            }

            fn startCreate(self: *CallRuntime, msg: Host.Message) !?Host.Result {
                const previous_depth = self.executor.state.trace_depth;
                self.executor.state.trace_depth = msg.depth;
                defer self.executor.state.trace_depth = previous_depth;

                if (msg.depth > Host.max_call_depth) return createFailure(self.executor, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid);

                switch (try beginCreate(self.executor, msg)) {
                    .immediate => |result| return result,
                    .child => |child| {
                        var checkpoint_open = true;
                        errdefer {
                            if (checkpoint_open) self.executor.state.revertToCheckpoint(child.checkpoint_state) catch {};
                        }

                        try self.pushChildCreate(child);
                        checkpoint_open = false;
                        return null;
                    },
                }
            }

            fn finishFrame(self: *CallRuntime, frame_index: usize, result: Interpreter.Result) !Host.Result {
                const call_frame = self.frames.items[frame_index].frame.callFrame();
                var stable_result = result;
                stable_result.output_data = try call_frame.stabilizeOutputData();
                if (self.stepCaptureContext()) |context| {
                    try context.finishCurrentFrame(.{
                        .outcome = Interpreter.traceFrameOutcome(stable_result.status),
                        .memory_size = call_frame.memory.len(),
                    });
                }

                return switch (self.frames.items[frame_index].kind) {
                    .root_call => Host.Result.fromCall(.{
                        .status = stable_result.status,
                        .output_data = stable_result.output_data,
                        .gas_left = stable_result.gas_left,
                        .gas_refund = stable_result.gas_refund,
                        .gas_reservoir = stable_result.gas_reservoir,
                        .state_gas_spent = stable_result.state_gas_spent,
                        .state_gas_from_gas_left = stable_result.state_gas_from_gas_left,
                    }),
                    .call => |checkpoint_state| blk: {
                        try finishCallCheckpoint(self.executor, checkpoint_state, stable_result.status);
                        break :blk Host.Result.fromCall(.{
                            .status = stable_result.status,
                            .output_data = stable_result.output_data,
                            .gas_left = stable_result.gas_left,
                            .gas_refund = stable_result.gas_refund,
                            .gas_reservoir = stable_result.gas_reservoir,
                            .state_gas_spent = stable_result.state_gas_spent,
                            .state_gas_from_gas_left = stable_result.state_gas_from_gas_left,
                        });
                    },
                    .create => |child| try finishCreate(self.executor, child, stable_result),
                };
            }
        };

        fn traceFrameKind(frame: *const RuntimeFrame) evmz.trace.TraceFrameKind {
            return switch (frame.kind) {
                .root_call => .root,
                .call => switch (frame.frame.callFrame().msg.kind) {
                    .call => if (frame.frame.callFrame().msg.is_static) .staticcall else .call,
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
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            _ = try currentTxContext(self);
            var execution_gas = gas;
            const top_frame_state_gas = try chargeTopFrameValueTransferStateGas(self, sender, recipient, value, &execution_gas);
            if (top_frame_state_gas.out_of_gas) {
                return .{
                    .status = .out_of_gas,
                    .gas_left = 0,
                    .gas_refund = 0,
                    .gas_reservoir = std.math.cast(i64, execution_gas.reservoir) orelse std.math.maxInt(i64),
                    .output_data = &.{},
                };
            }

            const resolved = try resolveCode(self, recipient);
            if (!resolved.delegated and Protocol.Precompile.active(self.revision(), recipient)) {
                var result = try runPrecompileCallTransaction(self, sender, recipient, input, execution_gas, value);
                finishTopFrameStateGas(&result, top_frame_state_gas);
                return result;
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
                    return result;
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
            return result;
        }

        fn topLevelDelegatedAccountAccess(self: *Executor, target: Address) !?evmz.protocol.DelegatedAccountAccess {
            const already_warm = self.state.warm_accounts.contains(target);
            const access = Protocol.call.topLevelDelegatedAccountAccess(
                self.revision(),
                .{
                    .target_is_precompile = Protocol.Precompile.active(self.revision(), target),
                    .already_warm = already_warm,
                },
            ) orelse return null;
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
            const charge_i64 = Protocol.call.topFrameValueTransferStateGas(self.revision(), .{
                .value = value,
                .same_address = same_address,
                .creates_account = creates_account,
            });
            if (charge_i64 == 0) return .{};

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
                    .gas_left = 0,
                    .gas_refund = 0,
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
                    .gas_left = 0,
                    .gas_refund = 0,
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

            var runtime = CallRuntime.init(self);
            defer runtime.deinit();
            try runtime.prepare();
            try runtime.pushRootCall(message, options.bytecode);
            const call_result = (try runtime.run()).expectCall();
            return .{
                .status = call_result.status,
                .gas_left = call_result.gas_left,
                .gas_refund = call_result.gas_refund,
                .gas_reservoir = call_result.gas_reservoir,
                .state_gas_spent = call_result.state_gas_spent,
                .state_gas_from_gas_left = call_result.state_gas_from_gas_left,
                .output_data = self.lastOutputData(),
            };
        }

        pub fn executeCreateTransaction(
            self: *Executor,
            sender: Address,
            init_code: []const u8,
            gas: ExecutionGas,
            value: u256,
        ) !Host.Result {
            return executeCreate(self, .{
                .sender = sender,
                .init_code = init_code,
                .value = value,
            }, gas);
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
            return executeCreateMessage(self, .{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
                .create2_salt = options.salt orelse 0,
            });
        }

        pub fn prepareBytecodeAlloc(self: *const Executor, allocator: std.mem.Allocator, code: []const u8) !Bytecode {
            return Bytecode.prepare(allocator, code, self.config);
        }

        pub const ResolvedCode = struct {
            address: Address,
            delegated: bool,
            original_view: Overlay.CodeView,
        };

        /// Resolve canonical code first, then consult the executor-owned derived
        /// cache. Address-based callers materialize through Overlay for witness
        /// validation and code-read tracing; CALL paths can reuse that traced view.
        pub fn resolveExecutionCode(self: *Executor, address: Address) !*const Bytecode {
            return resolveExecutionCodeView(self, try self.state.getCodeView(address));
        }

        pub fn resolveExecutionCodeView(self: *Executor, code: Overlay.CodeView) !*const Bytecode {
            const execution = if (self.prepared_code_execution) |*active|
                active
            else
                return error.MissingPreparedCodeExecution;
            return execution.resolve(code.code_hash, code.bytes, .{
                .admit = self.prepared_code_admission,
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

            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = depth;
            defer self.state.trace_depth = previous_depth;
            return interpreter.execute();
        }

        pub fn executeInterpreterUntilAction(self: *Executor, interpreter: *BoundInterpreter, depth: u16) !Interpreter.RunResult {
            self.beginPreparedCodeExecution();
            defer self.endPreparedCodeExecution();

            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = depth;
            defer self.state.trace_depth = previous_depth;
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

            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = depth;
            defer self.state.trace_depth = previous_depth;
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

        pub fn acquireBytecodeFrame(
            self: *Executor,
            frame_allocator: std.mem.Allocator,
            host_iface: *Host,
            msg: *const Host.Message,
            bytecode: *const Bytecode,
        ) !FrameLease {
            return try self.frame_store.acquire(Protocol, self.allocator, frame_allocator, .{
                .host = host_iface,
                .msg = msg,
                .bytecode = bytecode,
                .revision = self.revision(),
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
            if (self.runtime_resources.maxLiveFrames()) |max_live_frames| {
                if (index >= max_live_frames) return error.FrameCapacityExceeded;
                if (index >= self.call_scratch_slots.items.len) return error.FrameCapacityExceeded;
                self.call_scratch_slots.items[index].reset();
                return self.call_scratch_slots.items[index].allocator();
            }

            while (self.call_scratch_slots.items.len <= index) {
                const slot = try self.allocator.create(call_scratch_storage.Slot);
                errdefer self.allocator.destroy(slot);
                slot.* = call_scratch_storage.Slot.initGrowable(self.allocator);
                errdefer slot.deinit(self.allocator);
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
                    .output_data = try self.setLastOutput(call_result.output_data),
                    .gas_left = call_result.gas_left,
                    .gas_refund = call_result.gas_refund,
                    .gas_reservoir = call_result.gas_reservoir,
                    .state_gas_spent = call_result.state_gas_spent,
                    .state_gas_from_gas_left = call_result.state_gas_from_gas_left,
                }),
                .create => |create_result| Host.Result.fromCreate(create_result.address, .{
                    .status = create_result.status,
                    .output_data = if (aliasesLastOutput(self, create_result.output_data))
                        self.lastOutputData()
                    else
                        try self.setLastOutput(create_result.output_data),
                    .gas_left = create_result.gas_left,
                    .gas_refund = create_result.gas_refund,
                    .gas_reservoir = create_result.gas_reservoir,
                    .state_gas_spent = create_result.state_gas_spent,
                    .state_gas_from_gas_left = create_result.state_gas_from_gas_left,
                    .state_gas_refund = create_result.state_gas_refund,
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
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }) };
            }

            const checkpoint_state = try self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
            }

            if (msg.value > 0 and (msg.kind == .call or msg.kind == .callcode)) {
                const value_ok = if (msg.kind == .call)
                    try self.transferValue(msg.sender, msg.recipient, msg.value)
                else
                    try hasBalance(self, msg.recipient, msg.value);
                if (!value_ok) {
                    try self.state.revertToCheckpoint(checkpoint_state);
                    checkpoint_open = false;
                    return .{ .immediate = Host.Result.fromCall(.{
                        .status = .invalid,
                        .output_data = &.{},
                        .gas_left = msg.gas,
                        .gas_refund = 0,
                        .gas_reservoir = msg.gas_reservoir,
                    }) };
                }
            }

            const resolved = try resolveCode(self, msg.code_address);
            if (!resolved.delegated and Protocol.Precompile.active(self.revision(), msg.code_address)) {
                if (try runPrecompileCall(self, &msg)) |result| {
                    if (result.status() == .success) {
                        try touchEmptyCallRecipient(self, msg);
                    }
                    try finishCallCheckpoint(self, checkpoint_state, result.status());
                    checkpoint_open = false;
                    return .{ .immediate = result };
                }
            }

            const code = try resolvedCodeView(self, resolved);
            if (code.bytes.len == 0) {
                try touchEmptyCallRecipient(self, msg);
                try self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                return .{ .immediate = Host.Result.fromCall(.{
                    .status = .success,
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }) };
            }

            const bytecode = try resolveExecutionCodeView(self, code);
            checkpoint_open = false;
            return .{ .child = .{
                .checkpoint_state = checkpoint_state,
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

            const output_buffer = if (self.last_call_output.bounded) self.last_call_output.buf else null;
            var host_iface = self.host();
            const precompile_outcome = Protocol.Precompile.execute(
                self.revision(),
                msg.code_address,
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
                error.OutputBufferTooSmall => return error.ResultOutputCapacityExceeded,
                else => return err,
            };
            const outcome = precompile_outcome orelse return null;
            const result = switch (outcome) {
                .result => |result| result,
                .service_error => |err| return err,
            };

            defer if (result.output_owned and result.output_data.len != 0) scratch.allocator.free(result.output_data);
            const output = if (result.output_owned) output: {
                break :output try self.setLastOutput(result.output_data);
            } else if (result.output_data.len == 0) output: {
                break :output &.{};
            } else output: {
                const buffer = output_buffer orelse return error.InvalidPrecompileOutput;
                if (result.output_data.ptr != buffer.ptr or result.output_data.len > buffer.len) {
                    return error.InvalidPrecompileOutput;
                }
                break :output try self.assumeLastOutputWritten(result.output_data.len);
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

        fn finishCallCheckpoint(self: *Executor, checkpoint_state: Journal.Checkpoint, status: Interpreter.Status) !void {
            if (status != .success) {
                try self.state.revertToCheckpoint(checkpoint_state);
            } else {
                try self.state.commitCheckpoint(checkpoint_state);
            }
        }

        fn touchEmptyCallRecipient(self: *Executor, msg: Host.Message) !void {
            if (msg.kind != .call or !Protocol.call.touchesEmptyCallRecipient(self.revision())) return;
            _ = try self.getOrCreateAccount(msg.recipient);
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

        pub fn resolvedCodeView(self: *Executor, resolved: ResolvedCode) !Overlay.CodeView {
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

            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = msg.depth;
            defer self.state.trace_depth = previous_depth;

            if (msg.kind == .create or msg.kind == .create2) {
                // Opcode handlers check the caller frame depth before constructing the
                // child message. The executor receives that already-incremented child.
                if (msg.depth > Host.max_call_depth) return createFailure(self, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid);
                return executeCreateMessage(self, msg);
            }

            return switch (try beginCall(self, msg)) {
                .immediate => |result| result,
                .child => |child| blk: {
                    var checkpoint_open = true;
                    errdefer {
                        if (checkpoint_open) self.state.revertToCheckpoint(child.checkpoint_state) catch {};
                    }

                    var host_iface = self.host();
                    var frame = try acquireBytecodeFrame(self, self.allocator, &host_iface, &msg, child.bytecode);
                    defer frame.deinit();
                    var interpreter = frame.interpreter(Protocol);
                    var result = try executeInterpreter(self, &interpreter, msg.depth);
                    result.output_data = try self.setLastOutput(result.output_data);

                    try finishCallCheckpoint(self, child.checkpoint_state, result.status);
                    checkpoint_open = false;
                    break :blk Host.Result.fromCall(.{
                        .status = result.status,
                        .output_data = result.output_data,
                        .gas_left = result.gas_left,
                        .gas_refund = result.gas_refund,
                        .gas_reservoir = result.gas_reservoir,
                        .state_gas_spent = result.state_gas_spent,
                        .state_gas_from_gas_left = result.state_gas_from_gas_left,
                    });
                },
            };
        }

        fn executeCreateMessage(self: *Executor, msg: Host.Message) !Host.Result {
            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = msg.depth;
            defer self.state.trace_depth = previous_depth;

            if (msg.depth > Host.max_call_depth) return createFailure(self, evmz.addr(0), msg.gas, msg.gas_reservoir, .invalid);

            return switch (try beginCreate(self, msg)) {
                .immediate => |result| result,
                .child => |child| blk: {
                    var checkpoint_open = true;
                    errdefer {
                        if (checkpoint_open) self.state.revertToCheckpoint(child.checkpoint_state) catch {};
                    }

                    var runtime = CallRuntime.init(self);
                    defer runtime.deinit();
                    try runtime.pushChildCreate(child);
                    const result = try runtime.run();
                    checkpoint_open = false;
                    break :blk result;
                },
            };
        }

        fn beginCreate(self: *Executor, msg: Host.Message) !StartedCreate {
            const caller = try self.getOrCreateAccount(msg.sender);
            const create_address = switch (msg.kind) {
                .create => evmz.address.create(msg.sender, caller.nonce),
                .create2 => evmz.address.create2(msg.sender, msg.create2_salt, msg.input_data),
                else => unreachable,
            };
            if (caller.balance < msg.value) {
                return .{ .immediate = createFailure(self, create_address, msg.gas, msg.gas_reservoir, .invalid) };
            }

            const next_nonce = std.math.add(u64, caller.nonce, 1) catch return .{ .immediate = createFailure(self, create_address, msg.gas, msg.gas_reservoir, .invalid) };
            if (Protocol.create.createWarmsCreatedAddress(self.revision())) {
                try self.warmAccount(create_address);
            }
            try self.traceAccountAccess(create_address, msg.depth);
            const account_pre_existing = try self.state.accountExists(create_address);

            try self.state.setNonce(msg.sender, next_nonce);
            const checkpoint_state = try self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
            }

            if (try createCollision(self, create_address)) {
                try self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                return .{ .immediate = createFailure(self, create_address, 0, msg.gas_reservoir, .invalid) };
            }

            _ = try self.state.subtractBalance(msg.sender, msg.value);
            try self.state.addBalance(create_address, msg.value);
            try executor_module.transfer_logs.emit(self, .{
                .from = msg.sender,
                .to = create_address,
                .amount = msg.value,
            });
            try self.state.setNonce(create_address, Protocol.create.createInitialNonce(self.revision()));
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
            checkpoint_open = false;
            return .{ .child = .{
                .checkpoint_state = checkpoint_state,
                .address = create_address,
                .account_pre_existing = account_pre_existing,
                .kind = msg.kind,
                .msg = child_msg,
                .init_code = msg.input_data,
            } };
        }

        fn finishCreate(self: *Executor, child: ChildCreate, result: Interpreter.Result) !Host.Result {
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(child.checkpoint_state) catch {};
            }

            const output = try self.setLastOutput(result.output_data);
            const account_state_gas_refund = Protocol.create.createAccountStateGasRefund(self.revision(), child.account_pre_existing);
            if (result.status != .success) {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return Host.Result.fromCreate(child.address, .{
                    .status = result.status,
                    .output_data = output,
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                    .gas_reservoir = result.gas_reservoir,
                    .state_gas_spent = result.state_gas_spent,
                    .state_gas_from_gas_left = result.state_gas_from_gas_left,
                });
            }

            if (Protocol.create.createCodeSizeLimit(self.revision())) |limit| {
                if (output.len > limit) {
                    try self.state.revertToCheckpoint(child.checkpoint_state);
                    checkpoint_open = false;
                    return createFailureFromResult(self, child.address, result, .out_of_gas);
                }
            }
            if (Protocol.create.rejectsCreateCode(self.revision(), output)) {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .invalid);
            }

            const runtime_size = std.math.cast(i64, output.len) orelse {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .out_of_gas);
            };
            const deposit_regular_cost = Protocol.create.createDepositRegularGas(self.revision(), runtime_size) orelse {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .out_of_gas);
            };
            if (result.gas_left < deposit_regular_cost) {
                if (Protocol.create.createDepositRegularGasOogCommits(self.revision())) {
                    try self.state.commitCheckpoint(child.checkpoint_state);
                    checkpoint_open = false;
                    return Host.Result.fromCreate(child.address, .{
                        .status = .success,
                        .output_data = output,
                        .gas_left = result.gas_left,
                        .gas_refund = result.gas_refund,
                        .gas_reservoir = result.gas_reservoir,
                        .state_gas_spent = result.state_gas_spent,
                        .state_gas_from_gas_left = result.state_gas_from_gas_left,
                        .state_gas_refund = account_state_gas_refund,
                    });
                }
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .out_of_gas);
            }

            var deposit_result = result;
            deposit_result.gas_left -= deposit_regular_cost;
            const deposit_state_gas = Protocol.create.createDepositStateGas(self.revision(), runtime_size) orelse {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, deposit_result, .out_of_gas);
            };
            deposit_result.trackStateGas(deposit_state_gas);
            if (deposit_result.status != .success) {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, deposit_result, deposit_result.status);
            }

            try self.state.setCode(child.address, output);
            try self.state.commitCheckpoint(child.checkpoint_state);
            checkpoint_open = false;

            return Host.Result.fromCreate(child.address, .{
                .status = .success,
                .output_data = output,
                .gas_left = deposit_result.gas_left,
                .gas_refund = deposit_result.gas_refund,
                .gas_reservoir = deposit_result.gas_reservoir,
                .state_gas_spent = deposit_result.state_gas_spent,
                .state_gas_from_gas_left = deposit_result.state_gas_from_gas_left,
                .state_gas_refund = account_state_gas_refund,
            });
        }

        fn createFailure(self: *Executor, create_address: Address, gas_left: i64, gas_reservoir: i64, status: Interpreter.Status) Host.Result {
            self.clearLastOutput();
            return Host.Result.fromCreate(create_address, .{
                .status = status,
                .output_data = &.{},
                .gas_left = gas_left,
                .gas_refund = 0,
                .gas_reservoir = gas_reservoir,
            });
        }

        fn createFailureFromResult(self: *Executor, create_address: Address, result: Interpreter.Result, status: Interpreter.Status) Host.Result {
            var failed = result;
            failed.status = status;
            failed.gas_left = 0;
            failed.gas_refund = 0;
            failed.finalizeFrameStateGas();
            return createFailure(self, create_address, failed.gas_left, failed.gas_reservoir, status);
        }

        fn createCollision(self: *Executor, address: Address) !bool {
            if (Protocol.Precompile.active(self.revision(), address)) return true;
            const account = try self.state.getAccountOrLoad(address) orelse return false;
            return account.nonce != 0 or try self.state.accountHasCode(address) or try self.state.accountHasStorage(address);
        }
    };
}

test "CREATE final stabilization reuses already-stable output" {
    const Executor = executor_module.Executor(evmz.Evm.ExecutionProtocol);
    const runtime = For(Executor);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var executor = Executor.init(failing_allocator.allocator(), .{
        .revision = .berlin,
    });
    defer executor.deinit();

    executor.last_call_output.deinit();
    executor.last_call_output = frame_io.ByteSlot.initGrowable(std.testing.allocator);
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
