const std = @import("std");
const evmz = @import("../evm.zig");
const executor_module = @import("../executor.zig");

const Address = evmz.Address;
const Bytecode = evmz.Bytecode;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const Journal = @import("../state/Journal.zig");
const Opcode = evmz.Opcode;
const eip7702 = @import("./eip7702.zig");
const FrameIo = @import("../frame_io.zig");
const FrameStore = @import("./frame_store.zig");
const runtime_frames = @import("./runtime_frames.zig");
const transaction = @import("../transaction.zig");
const call_scratch_storage = @import("./call_scratch.zig");

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
            code_address: Address,
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

            fn init(executor: *Executor) CallRuntime {
                return .{
                    .executor = executor,
                    .host_iface = executor.host(),
                    .frames = &executor.runtime_frames,
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

            fn pushRootCall(self: *CallRuntime, msg: Host.Message, bytecode: *Bytecode) !void {
                var frame = try acquireRawFrame(
                    self.executor,
                    self.executor.allocator,
                    &self.host_iface,
                    &msg,
                    bytecode.bytes,
                    bytecode,
                );
                errdefer frame.deinit();
                try self.appendFrame(.{
                    .kind = .root_call,
                    .frame = frame,
                    .needs_action_loop = codeNeedsActionLoop(bytecode.bytes),
                });
            }

            fn pushChildCall(self: *CallRuntime, msg: Host.Message, checkpoint_state: Journal.Checkpoint, code_address: Address) !void {
                var scratch = try callScratch(self.executor, msg.depth);
                errdefer scratch.deinit();

                const code = try dupeCodeAlloc(self.executor, scratch.allocator, code_address);
                var frame = try acquireRawFrame(
                    self.executor,
                    scratch.allocator,
                    &self.host_iface,
                    &msg,
                    code,
                    null,
                );
                errdefer frame.deinit();

                try self.appendFrame(.{
                    .kind = .{ .call = checkpoint_state },
                    .frame = frame,
                    .scratch_depth = scratch.depth,
                    .needs_action_loop = codeNeedsActionLoop(code),
                });
            }

            fn pushChildCreate(self: *CallRuntime, child: ChildCreate) !void {
                var scratch = try callScratch(self.executor, child.msg.depth);
                errdefer scratch.deinit();

                var frame = try acquireRawFrame(
                    self.executor,
                    scratch.allocator,
                    &self.host_iface,
                    &child.msg,
                    child.init_code,
                    null,
                );
                errdefer frame.deinit();

                try self.appendFrame(.{
                    .kind = .{ .create = child },
                    .frame = frame,
                    .scratch_depth = scratch.depth,
                    .needs_action_loop = codeNeedsActionLoop(child.init_code),
                });
            }

            fn appendFrame(self: *CallRuntime, frame: RuntimeFrame) !void {
                if (self.executor.runtime_resources.maxLiveFrames()) |max_live_frames| {
                    if (self.frames.items.len >= max_live_frames) return error.FrameCapacityExceeded;
                    if (self.frames.items.len >= self.frames.capacity) return error.FrameCapacityExceeded;
                    self.frames.appendAssumeCapacity(frame);
                    return;
                }
                try self.frames.append(self.executor.allocator, frame);
            }

            fn popFrame(self: *CallRuntime) void {
                const index = self.frames.items.len - 1;
                deinitRuntimeFrame(&self.frames.items[index], self.executor);
                self.frames.items.len = index;
            }

            fn run(self: *CallRuntime) !Host.Result {
                while (self.frames.items.len > 0) {
                    const index = self.frames.items.len - 1;
                    const runtime_frame = &self.frames.items[index];
                    var interpreter = runtime_frame.frame.interpreter(Protocol);
                    const depth = runtime_frame.frame.callFrame().msg.depth;
                    const run_result: Interpreter.RunResult = if (runtime_frame.needs_action_loop)
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
                            try self.frames.items[frame_index].frame.callFrame().resumeCallResult(
                                call_action.continuation,
                                host_result.expectCall(),
                            );
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
                        } else {
                            self.frames.items[frame_index].pending_action = action;
                        }
                    },
                }
            }

            fn resumeParentAction(self: *CallRuntime, frame_index: usize, action: Interpreter.Action, result: Host.Result) !void {
                switch (action) {
                    .call => |call_action| try self.frames.items[frame_index].frame.callFrame().resumeCallResult(
                        call_action.continuation,
                        result.expectCall(),
                    ),
                    .create => |create_action| try self.frames.items[frame_index].frame.callFrame().resumeCreateResult(
                        create_action.continuation,
                        result.expectCreate(),
                    ),
                }
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

                        try self.pushChildCall(msg, child.checkpoint_state, child.code_address);
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
                var stable_result = result;
                stable_result.output_data = try self.frames.items[frame_index].frame.callFrame().stabilizeOutputData();

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

        fn deinitRuntimeFrame(frame: *RuntimeFrame, executor: *Executor) void {
            frame.frame.deinit();
            if (frame.scratch_depth) |depth| {
                endCallScratch(executor, depth);
            }
            frame.* = undefined;
        }

        pub fn executeCall(self: *Executor, options: executor_module.Call) !executor_module.EvmResult {
            const result = try executeCallTransaction(
                self,
                options.sender,
                options.recipient,
                options.input,
                .{
                    .regular_left = options.gas,
                    .reservoir = options.gas_reservoir,
                },
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
            gas: transaction.ExecutionGas,
            value: u256,
        ) !Interpreter.Result {
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

            const resolved = try resolvedCodeAddress(self, recipient);
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

            var scratch = try callScratch(self, 0);
            defer scratch.deinit();
            const code = try dupeCodeAlloc(self, scratch.allocator, resolved.address);
            var bytecode = try prepareBytecodeAlloc(self, scratch.allocator, code);

            var result = try executePreparedCallTransaction(self, .{
                .bytecode = &bytecode,
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

        fn topLevelDelegatedAccountAccess(self: *Executor, target: Address) !?evmz.protocol.interface.DelegatedAccountAccess {
            const already_warm = self.state.warm_accounts.contains(target);
            const access = Protocol.Call.topLevelDelegatedAccountAccess(
                self.revision(),
                Protocol.Precompile.active(self.revision(), target),
                already_warm,
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
            gas: *transaction.ExecutionGas,
        ) !TopFrameStateGasCharge {
            const same_address = std.mem.eql(u8, &sender, &recipient);
            const account_exists = if (value == 0 or same_address)
                true
            else
                try self.state.accountExists(recipient);
            const charge_i64 = Protocol.Call.topFrameValueTransferStateGas(self.revision(), value, same_address, account_exists);
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
            gas: transaction.ExecutionGas,
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

            const host_result = (try runPrecompileCall(
                self,
                0,
                recipient,
                input,
                std.math.cast(i64, gas.regular_left) orelse std.math.maxInt(i64),
                std.math.cast(i64, gas.reservoir) orelse std.math.maxInt(i64),
            )) orelse unreachable;
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
            gas: transaction.ExecutionGas,
            value: u256,
        ) !Host.Result {
            return executeCreate(self, .{
                .sender = sender,
                .init_code = init_code,
                .gas = gas.regular_left,
                .gas_reservoir = gas.reservoir,
                .value = value,
            });
        }

        pub fn executeCreate(self: *Executor, options: executor_module.Create) !executor_module.EvmResult {
            self.clearLastOutput();
            _ = try currentTxContext(self);
            return executeCreateMessage(self, .{
                .depth = 0,
                .kind = if (options.salt == null) .create else .create2,
                .gas = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
                .gas_reservoir = std.math.cast(i64, options.gas_reservoir) orelse std.math.maxInt(i64),
                .sender = options.sender,
                .input_data = options.init_code,
                .value = options.value,
                .create2_salt = options.salt orelse 0,
            });
        }

        pub fn prepareBytecodeAlloc(self: *const Executor, allocator: std.mem.Allocator, code: []const u8) !Bytecode {
            _ = self;
            return Bytecode.init(allocator, code);
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
            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = depth;
            defer self.state.trace_depth = previous_depth;
            return interpreter.execute();
        }

        pub fn executeInterpreterUntilAction(self: *Executor, interpreter: *BoundInterpreter, depth: u16) !Interpreter.RunResult {
            const previous_depth = self.state.trace_depth;
            self.state.trace_depth = depth;
            defer self.state.trace_depth = previous_depth;
            return interpreter.executeUntilAction();
        }

        pub fn currentTxContext(self: *const Executor) !Host.TxContext {
            return self.tx_context orelse error.MissingTxContext;
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
            bytecode: *Bytecode,
        ) !FrameLease {
            return acquireRawFrame(self, frame_allocator, host_iface, msg, bytecode.bytes, bytecode);
        }

        pub fn acquireRawFrame(
            self: *Executor,
            frame_allocator: std.mem.Allocator,
            host_iface: *Host,
            msg: *const Host.Message,
            code: []const u8,
            bytecode: ?*Bytecode,
        ) !FrameLease {
            return try self.frame_store.acquire(Protocol, self.allocator, frame_allocator, .{
                .host = host_iface,
                .msg = msg,
                .code = code,
                .bytecode = bytecode,
                .revision = self.revision(),
                .trace_sink = self.trace_sink,
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

        fn codeNeedsActionLoop(code: []const u8) bool {
            var pc: usize = 0;
            while (pc < code.len) {
                const opcode_byte = code[pc];
                pc += 1;
                if (isActionBoundaryOpcode(opcode_byte)) return true;
                pc += @min(pushDataLen(opcode_byte), code.len - pc);
            }
            return false;
        }

        inline fn isActionBoundaryOpcode(opcode_byte: u8) bool {
            const system_offset = opcode_byte -% @intFromEnum(Opcode.CREATE);
            return (system_offset <= @intFromEnum(Opcode.CREATE2) - @intFromEnum(Opcode.CREATE) and opcode_byte != @intFromEnum(Opcode.RETURN)) or
                opcode_byte == @intFromEnum(Opcode.STATICCALL);
        }

        inline fn pushDataLen(opcode_byte: u8) usize {
            if (opcode_byte < @intFromEnum(Opcode.PUSH1) or opcode_byte > @intFromEnum(Opcode.PUSH32)) return 0;
            return @as(usize, opcode_byte - @intFromEnum(Opcode.PUSH1)) + 1;
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

            const checkpoint_state = self.state.checkpoint();
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

            const resolved = try resolvedCodeAddress(self, msg.code_address);
            if (!resolved.delegated and Protocol.Precompile.active(self.revision(), msg.code_address)) {
                if (try runPrecompileCall(self, msg.depth, msg.code_address, msg.input_data, msg.gas, msg.gas_reservoir)) |result| {
                    if (result.status() == .success) {
                        try touchEmptyCallRecipient(self, msg);
                    }
                    try finishCallCheckpoint(self, checkpoint_state, result.status());
                    checkpoint_open = false;
                    return .{ .immediate = result };
                }
            }

            if ((try self.getCode(resolved.address)).len == 0) {
                try touchEmptyCallRecipient(self, msg);
                self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                return .{ .immediate = Host.Result.fromCall(.{
                    .status = .success,
                    .output_data = &.{},
                    .gas_left = msg.gas,
                    .gas_refund = 0,
                    .gas_reservoir = msg.gas_reservoir,
                }) };
            }

            checkpoint_open = false;
            return .{ .child = .{
                .checkpoint_state = checkpoint_state,
                .code_address = resolved.address,
            } };
        }

        fn runPrecompileCall(
            self: *Executor,
            depth: u16,
            recipient: Address,
            input: []const u8,
            gas: i64,
            gas_reservoir: i64,
        ) !?Host.Result {
            self.clearLastOutput();
            var scratch = try callScratch(self, depth);
            defer scratch.deinit();

            const output_buffer = if (self.last_call_output.bounded) self.last_call_output.buf else null;
            const precompile_result = Protocol.Precompile.executeWithOutputBuffer(
                scratch.allocator,
                self.revision(),
                recipient,
                input,
                gas,
                output_buffer,
            ) catch |err| switch (err) {
                error.NotImplemented => return Host.Result.fromCall(.{
                    .status = .invalid,
                    .output_data = &.{},
                    .gas_left = 0,
                    .gas_refund = 0,
                    .gas_reservoir = gas_reservoir,
                }),
                error.OutputBufferTooSmall => return error.ResultOutputCapacityExceeded,
                else => return err,
            };
            const result = precompile_result orelse return null;

            defer if (result.output_owned and result.output_data.len != 0) scratch.allocator.free(result.output_data);
            const output = if (result.output_owned)
                try self.setLastOutput(result.output_data)
            else
                try self.assumeLastOutputWritten(result.output_data.len);
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
                .gas_reservoir = gas_reservoir,
            });
        }

        fn finishCallCheckpoint(self: *Executor, checkpoint_state: Journal.Checkpoint, status: Interpreter.Status) !void {
            if (status != .success) {
                try self.state.revertToCheckpoint(checkpoint_state);
            } else {
                self.state.commitCheckpoint(checkpoint_state);
            }
        }

        fn touchEmptyCallRecipient(self: *Executor, msg: Host.Message) !void {
            if (msg.kind != .call or !Protocol.Call.touchesEmptyCallRecipient(self.revision())) return;
            _ = try self.getOrCreateAccount(msg.recipient);
        }

        fn resolvedCodeAddress(self: *Executor, address: Address) !struct { address: Address, delegated: bool } {
            const code = try self.getCode(address);
            if (eip7702.delegationTarget(code)) |target| {
                return .{ .address = target, .delegated = true };
            }
            return .{ .address = address, .delegated = false };
        }

        fn hasBalance(self: *Executor, address: Address, value: u256) !bool {
            const account = try self.state.getAccountOrLoad(address) orelse return value == 0;
            return account.balance >= value;
        }

        /// Host.call resolver for direct `Interpreter.execute()` users. Top-level call
        /// and create transactions enter `CallRuntime` through their executor entrypoints.
        pub fn resolveHostCall(self: *Executor, msg: Host.Message) !Host.Result {
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
                    var scratch = try callScratch(self, msg.depth);
                    defer scratch.deinit();
                    const code = try dupeCodeAlloc(self, scratch.allocator, child.code_address);
                    var frame = try acquireRawFrame(self, scratch.allocator, &host_iface, &msg, code, null);
                    defer frame.deinit();
                    var interpreter = frame.interpreter(Protocol);
                    const result = try executeInterpreter(self, &interpreter, msg.depth);

                    const output = try self.setLastOutput(result.output_data);
                    try finishCallCheckpoint(self, child.checkpoint_state, result.status);
                    checkpoint_open = false;
                    break :blk Host.Result.fromCall(.{
                        .status = result.status,
                        .output_data = output,
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
            if (Protocol.Create.createWarmsCreatedAddress(self.revision())) {
                try self.warmAccessListAddress(create_address);
            }
            const account_pre_existing = try self.state.accountExists(create_address);

            try self.state.setNonce(msg.sender, next_nonce);
            const checkpoint_state = self.state.checkpoint();
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
            }

            if (try createCollision(self, create_address)) {
                self.state.commitCheckpoint(checkpoint_state);
                checkpoint_open = false;
                return .{ .immediate = createFailure(self, create_address, 0, msg.gas_reservoir, .invalid) };
            }

            _ = try self.state.subtractBalance(msg.sender, msg.value);
            try self.state.addBalance(create_address, msg.value);
            try executor_module.transfer_logs.emit(self, msg.sender, create_address, msg.value);
            try self.state.setNonce(create_address, Protocol.Create.createInitialNonce(self.revision()));
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
            const account_state_gas_refund = Protocol.Create.createAccountStateGasRefund(self.revision(), child.account_pre_existing);
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

            if (Protocol.Create.createCodeSizeLimit(self.revision())) |limit| {
                if (output.len > limit) {
                    try self.state.revertToCheckpoint(child.checkpoint_state);
                    checkpoint_open = false;
                    return createFailureFromResult(self, child.address, result, .out_of_gas);
                }
            }
            if (Protocol.Create.rejectsCreateCode(self.revision(), output)) {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .invalid);
            }

            const runtime_size = std.math.cast(i64, output.len) orelse {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .out_of_gas);
            };
            const deposit_regular_cost = Protocol.Create.createDepositRegularGas(self.revision(), runtime_size) orelse {
                try self.state.revertToCheckpoint(child.checkpoint_state);
                checkpoint_open = false;
                return createFailureFromResult(self, child.address, result, .out_of_gas);
            };
            if (result.gas_left < deposit_regular_cost) {
                if (Protocol.Create.createDepositRegularGasOogCommits(self.revision())) {
                    self.state.commitCheckpoint(child.checkpoint_state);
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
            const deposit_state_gas = Protocol.Create.createDepositStateGas(self.revision(), runtime_size) orelse {
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
            self.state.commitCheckpoint(child.checkpoint_state);
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
            return account.nonce != 0 or account.code.len != 0 or try self.state.accountHasStorage(address);
        }
    };
}

test "CREATE final stabilization reuses already-stable output" {
    const Executor = executor_module.Executor(evmz.EthProtocol);
    const runtime = For(Executor);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{ .fail_index = 0 });
    var executor = Executor.init(failing_allocator.allocator(), .{
        .revision = .berlin,
    });
    defer executor.deinit();

    executor.last_call_output.deinit();
    executor.last_call_output = FrameIo.ByteSlot.initGrowable(std.testing.allocator);
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
