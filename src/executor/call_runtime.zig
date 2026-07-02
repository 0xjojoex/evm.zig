const std = @import("std");
const evmz = @import("../evm.zig");
const Executor = @import("../executor.zig");

const Address = evmz.Address;
const Bytecode = evmz.Bytecode;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const Journal = @import("../state/Journal.zig");
const Opcode = evmz.Opcode;
const eip7702 = @import("./eip7702.zig");

pub const ScratchScope = struct {
    executor: *Executor,
    depth: u16,
    allocator: std.mem.Allocator,

    pub fn deinit(self: *ScratchScope) void {
        endCallScratch(self.executor, self.depth);
        self.* = undefined;
    }
};

pub const FrameLease = struct {
    executor: *Executor,
    frame: *Interpreter.CallFrame,

    pub fn deinit(self: *FrameLease) void {
        self.frame.deinit();
        self.executor.call_frame_pool.destroy(self.frame);
        self.* = undefined;
    }

    pub fn interpreter(self: *FrameLease) Interpreter {
        return Interpreter.init(self.frame);
    }
};

const RuntimeFrameKind = union(enum) {
    root_call,
    call: Journal.Checkpoint,
    create: ChildCreate,
};

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

const ChildCreate = struct {
    checkpoint_state: Journal.Checkpoint,
    address: Address,
    msg: Host.Message,
    init_code: []const u8,
};

const RuntimeFrame = struct {
    kind: RuntimeFrameKind,
    frame: FrameLease,
    scratch: ?ScratchScope = null,
    can_yield: bool,
    pending_action: ?Interpreter.Action = null,

    fn deinit(self: *RuntimeFrame) void {
        self.frame.deinit();
        if (self.scratch) |*scratch| {
            scratch.deinit();
        }
        self.* = undefined;
    }
};

const CallRuntime = struct {
    executor: *Executor,
    host_iface: Host,
    frames: std.ArrayList(RuntimeFrame) = .empty,

    fn init(executor: *Executor) CallRuntime {
        return .{
            .executor = executor,
            .host_iface = executor.host(),
        };
    }

    fn deinit(self: *CallRuntime) void {
        while (self.frames.items.len > 0) {
            self.popFrame();
        }
        self.frames.deinit(self.executor.allocator);
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
        try self.frames.append(self.executor.allocator, .{
            .kind = .root_call,
            .frame = frame,
            .can_yield = codeMayYield(bytecode.bytes),
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

        try self.frames.append(self.executor.allocator, .{
            .kind = .{ .call = checkpoint_state },
            .frame = frame,
            .scratch = scratch,
            .can_yield = codeMayYield(code),
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

        try self.frames.append(self.executor.allocator, .{
            .kind = .{ .create = child },
            .frame = frame,
            .scratch = scratch,
            .can_yield = codeMayYield(child.init_code),
        });
    }

    fn popFrame(self: *CallRuntime) void {
        const index = self.frames.items.len - 1;
        self.frames.items[index].deinit();
        self.frames.items.len = index;
    }

    fn run(self: *CallRuntime) !Host.Result {
        while (self.frames.items.len > 0) {
            const index = self.frames.items.len - 1;
            const runtime_frame = &self.frames.items[index];
            var interpreter = runtime_frame.frame.interpreter();
            const depth = runtime_frame.frame.frame.msg.depth;
            const run_result: Interpreter.RunResult = if (runtime_frame.can_yield)
                executeInterpreterUntilAction(self.executor, &interpreter, depth)
            else
                .{ .finished = executeInterpreter(self.executor, &interpreter, depth) };
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
                    try self.frames.items[frame_index].frame.frame.resumeCallResult(
                        call_action.continuation,
                        host_result.expectCall(),
                    );
                } else {
                    self.frames.items[frame_index].pending_action = action;
                }
            },
            .create => |create_action| {
                if (try self.startCreate(create_action.msg)) |host_result| {
                    try self.frames.items[frame_index].frame.frame.resumeCreateResult(
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
            .call => |call_action| try self.frames.items[frame_index].frame.frame.resumeCallResult(
                call_action.continuation,
                result.expectCall(),
            ),
            .create => |create_action| try self.frames.items[frame_index].frame.frame.resumeCreateResult(
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

        if (msg.depth > Host.max_call_depth) return createFailure(self.executor, evmz.addr(0), msg.gas, .invalid);

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
        return switch (self.frames.items[frame_index].kind) {
            .root_call => Host.Result.fromCall(.{
                .status = result.status,
                .output_data = result.output_data,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            }),
            .call => |checkpoint_state| blk: {
                try finishCallCheckpoint(self.executor, checkpoint_state, result.status);
                break :blk Host.Result.fromCall(.{
                    .status = result.status,
                    .output_data = result.output_data,
                    .gas_left = result.gas_left,
                    .gas_refund = result.gas_refund,
                });
            },
            .create => |child| try finishCreate(self.executor, child, result),
        };
    }
};

pub fn executeCall(self: *Executor, options: Executor.Call) !Executor.EvmResult {
    const result = try executeCallTransaction(
        self,
        options.sender,
        options.recipient,
        options.input,
        options.gas,
        options.value,
    );
    return Host.Result.fromCall(.{
        .status = result.status,
        .output_data = result.output_data,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
    });
}

pub fn executeCallTransaction(
    self: *Executor,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
    value: u256,
) !Interpreter.Result {
    const resolved = try resolvedCodeAddress(self, recipient);
    if (!resolved.delegated and evmz.precompile.activeAt(self.spec, recipient) != null) {
        return executePrecompileCallTransaction(self, sender, recipient, input, gas, value);
    }

    var scratch = try callScratch(self, 0);
    defer scratch.deinit();
    const code = try dupeCodeAlloc(self, scratch.allocator, resolved.address);
    var bytecode = try prepareBytecodeAlloc(self, scratch.allocator, code);

    return executePreparedCallTransaction(self, .{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = recipient,
        .input = input,
        .gas = gas,
        .value = value,
    });
}

fn executePrecompileCallTransaction(
    self: *Executor,
    sender: Address,
    recipient: Address,
    input: []const u8,
    gas: u64,
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

    const host_result = (try executePrecompileCall(
        self,
        recipient,
        input,
        std.math.cast(i64, gas) orelse std.math.maxInt(i64),
    )) orelse unreachable;
    const result = host_result.expectCall();
    return .{
        .status = result.status,
        .gas_left = result.gas_left,
        .gas_refund = result.gas_refund,
        .output_data = self.last_call_output,
    };
}

pub fn executePreparedCallTransaction(
    self: *Executor,
    options: Executor.PreparedCallTransaction,
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
        .recipient = options.recipient,
        .sender = options.sender,
        .input_data = options.input,
        .value = options.value,
        .code_address = options.recipient,
    };

    var runtime = CallRuntime.init(self);
    defer runtime.deinit();
    try runtime.pushRootCall(message, options.bytecode);
    const call_result = (try runtime.run()).expectCall();
    return .{
        .status = call_result.status,
        .gas_left = call_result.gas_left,
        .gas_refund = call_result.gas_refund,
        .output_data = self.last_call_output,
    };
}

pub fn executeCreateTransaction(
    self: *Executor,
    sender: Address,
    init_code: []const u8,
    gas: u64,
    value: u256,
) !Host.Result {
    return executeCreate(self, .{
        .sender = sender,
        .init_code = init_code,
        .gas = gas,
        .value = value,
    });
}

pub fn executeCreate(self: *Executor, options: Executor.Create) !Executor.EvmResult {
    self.clearLastOutput();
    _ = try currentTxContext(self);
    return createContract(self, .{
        .depth = 0,
        .kind = if (options.salt == null) .create else .create2,
        .gas = std.math.cast(i64, options.gas) orelse std.math.maxInt(i64),
        .sender = options.sender,
        .input_data = options.init_code,
        .value = options.value,
        .create2_salt = options.salt orelse 0,
    });
}

pub fn prepareBytecodeAlloc(self: *const Executor, allocator: std.mem.Allocator, code: []const u8) !Bytecode {
    return Bytecode.init(allocator, code, self.config.preprocessing);
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

pub fn executeInterpreter(self: *Executor, interpreter: *Interpreter, depth: u16) Interpreter.Result {
    const previous_depth = self.state.trace_depth;
    self.state.trace_depth = depth;
    defer self.state.trace_depth = previous_depth;
    return interpreter.execute();
}

pub fn executeInterpreterUntilAction(self: *Executor, interpreter: *Interpreter, depth: u16) Interpreter.RunResult {
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
    const call_frame = try self.call_frame_pool.create(self.allocator);
    errdefer self.call_frame_pool.destroy(call_frame);
    try call_frame.init(frame_allocator, .{
        .host = host_iface,
        .msg = msg,
        .code = code,
        .bytecode = bytecode,
        .spec = self.spec,
        .config = self.config,
        .trace_sink = self.trace_sink,
    });
    return .{
        .executor = self,
        .frame = call_frame,
    };
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
    while (self.call_scratch_arenas.items.len <= index) {
        const arena = try self.allocator.create(std.heap.ArenaAllocator);
        errdefer self.allocator.destroy(arena);
        arena.* = std.heap.ArenaAllocator.init(self.allocator);
        errdefer arena.deinit();
        try self.call_scratch_arenas.append(self.allocator, arena);
    }
    _ = self.call_scratch_arenas.items[index].reset(.retain_capacity);
    return self.call_scratch_arenas.items[index].allocator();
}

fn endCallScratch(self: *Executor, depth: u16) void {
    const index: usize = depth;
    if (index < self.call_scratch_arenas.items.len) {
        _ = self.call_scratch_arenas.items[index].reset(.retain_capacity);
    }
}

fn setLastOutput(self: *Executor, output_data: []const u8) ![]u8 {
    self.clearLastOutput();
    self.last_call_output = try self.allocator.dupe(u8, output_data);
    return self.last_call_output;
}

fn stabilizeFinalResult(self: *Executor, result: Host.Result) !Host.Result {
    const output = try setLastOutput(self, result.outputData());
    return Host.Result.fromCall(.{
        .status = result.status(),
        .output_data = output,
        .gas_left = result.gasLeft(),
        .gas_refund = result.gasRefund(),
    });
}

fn codeMayYield(code: []const u8) bool {
    var pc: usize = 0;
    while (pc < code.len) {
        const opcode_byte = code[pc];
        pc += 1;
        if (isYieldBoundaryOpcode(opcode_byte)) return true;
        pc += @min(pushDataLen(opcode_byte), code.len - pc);
    }
    return false;
}

inline fn isYieldBoundaryOpcode(opcode_byte: u8) bool {
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
            }) };
        }
    }

    const resolved = try resolvedCodeAddress(self, msg.code_address);
    if (!resolved.delegated and evmz.precompile.activeAt(self.spec, msg.code_address) != null) {
        if (try executePrecompileCall(self, msg.code_address, msg.input_data, msg.gas)) |result| {
            if (result.status() == .success) {
                try touchLegacyCallRecipient(self, msg);
            }
            try finishCallCheckpoint(self, checkpoint_state, result.status());
            checkpoint_open = false;
            return .{ .immediate = result };
        }
    }

    if ((try self.getCode(resolved.address)).len == 0) {
        try touchLegacyCallRecipient(self, msg);
        self.state.commitCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return .{ .immediate = Host.Result.fromCall(.{
            .status = .success,
            .output_data = &.{},
            .gas_left = msg.gas,
            .gas_refund = 0,
        }) };
    }

    checkpoint_open = false;
    return .{ .child = .{
        .checkpoint_state = checkpoint_state,
        .code_address = resolved.address,
    } };
}

fn executePrecompileCall(
    self: *Executor,
    recipient: Address,
    input: []const u8,
    gas: i64,
) !?Host.Result {
    const precompile_result = evmz.precompile.execute(
        self.allocator,
        self.spec,
        recipient,
        input,
        gas,
    ) catch |err| switch (err) {
        error.NotImplemented => return Host.Result.fromCall(.{
            .status = .invalid,
            .output_data = &.{},
            .gas_left = 0,
            .gas_refund = 0,
        }),
        else => return err,
    };
    const result = precompile_result orelse return null;

    self.clearLastOutput();
    self.last_call_output = result.output_data;
    const status: Interpreter.Status = switch (result.status) {
        .success => .success,
        .failure => .invalid,
        .out_of_gas => .out_of_gas,
    };
    return Host.Result.fromCall(.{
        .status = status,
        .output_data = self.last_call_output,
        .gas_left = if (status == .success) result.gas_left else 0,
        .gas_refund = 0,
    });
}

fn finishCallCheckpoint(self: *Executor, checkpoint_state: Journal.Checkpoint, status: Interpreter.Status) !void {
    if (status != .success) {
        try self.state.revertToCheckpoint(checkpoint_state);
    } else {
        self.state.commitCheckpoint(checkpoint_state);
    }
}

fn touchLegacyCallRecipient(self: *Executor, msg: Host.Message) !void {
    // EIP-161 stops zero-value CALLs from creating empty accounts.
    if (self.spec.isImpl(.spurious_dragon) or msg.kind != .call) return;
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

pub fn call(self: *Executor, msg: Host.Message) !Host.Result {
    const previous_depth = self.state.trace_depth;
    self.state.trace_depth = msg.depth;
    defer self.state.trace_depth = previous_depth;

    if (msg.kind == .create or msg.kind == .create2) {
        // Opcode handlers check the caller frame depth before constructing the
        // child message. The executor receives that already-incremented child.
        if (msg.depth > Host.max_call_depth) return createFailure(self, evmz.addr(0), msg.gas, .invalid);
        return createContract(self, msg);
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
            var interpreter = frame.interpreter();
            const result = executeInterpreter(self, &interpreter, msg.depth);

            self.clearLastOutput();
            self.last_call_output = try self.allocator.dupe(u8, result.output_data);
            try finishCallCheckpoint(self, child.checkpoint_state, result.status);
            checkpoint_open = false;
            break :blk Host.Result.fromCall(.{
                .status = result.status,
                .output_data = self.last_call_output,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        },
    };
}

fn createContract(self: *Executor, msg: Host.Message) !Host.Result {
    const previous_depth = self.state.trace_depth;
    self.state.trace_depth = msg.depth;
    defer self.state.trace_depth = previous_depth;

    if (msg.depth > Host.max_call_depth) return createFailure(self, evmz.addr(0), msg.gas, .invalid);

    return switch (try beginCreate(self, msg)) {
        .immediate => |result| result,
        .child => |child| blk: {
            var checkpoint_open = true;
            errdefer {
                if (checkpoint_open) self.state.revertToCheckpoint(child.checkpoint_state) catch {};
            }

            var host_iface = self.host();
            var scratch = try callScratch(self, child.msg.depth);
            defer scratch.deinit();
            var frame = try acquireRawFrame(self, scratch.allocator, &host_iface, &child.msg, child.init_code, null);
            defer frame.deinit();
            var interpreter = frame.interpreter();

            const result = executeInterpreter(self, &interpreter, child.msg.depth);
            checkpoint_open = false;
            break :blk try finishCreate(self, child, result);
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
        return .{ .immediate = createFailure(self, create_address, msg.gas, .invalid) };
    }

    if (self.spec.isImpl(.berlin)) {
        try self.warmAccessListAddress(create_address);
    }

    const next_nonce = std.math.add(u64, caller.nonce, 1) catch return .{ .immediate = createFailure(self, create_address, msg.gas, .invalid) };
    try self.state.setNonce(msg.sender, next_nonce);
    const checkpoint_state = self.state.checkpoint();
    var checkpoint_open = true;
    errdefer {
        if (checkpoint_open) self.state.revertToCheckpoint(checkpoint_state) catch {};
    }

    if (try createCollision(self, create_address)) {
        self.state.commitCheckpoint(checkpoint_state);
        checkpoint_open = false;
        return .{ .immediate = createFailure(self, create_address, 0, .invalid) };
    }

    _ = try self.state.subtractBalance(msg.sender, msg.value);
    try self.state.addBalance(create_address, msg.value);
    try self.state.setNonce(create_address, if (self.spec.isImpl(.spurious_dragon)) 1 else 0);
    try self.state.clearCode(create_address);
    try self.state.markCreatedContract(create_address);

    const child_msg = Host.Message{
        .depth = msg.depth,
        .kind = .call,
        .gas = msg.gas,
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
        .msg = child_msg,
        .init_code = msg.input_data,
    } };
}

fn finishCreate(self: *Executor, child: ChildCreate, result: Interpreter.Result) !Host.Result {
    var checkpoint_open = true;
    errdefer {
        if (checkpoint_open) self.state.revertToCheckpoint(child.checkpoint_state) catch {};
    }

    const output = try setLastOutput(self, result.output_data);
    if (result.status != .success) {
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return Host.Result.fromCreate(child.address, .{
            .status = result.status,
            .output_data = output,
            .gas_left = result.gas_left,
            .gas_refund = result.gas_refund,
        });
    }

    if (self.spec.isImpl(.spurious_dragon) and output.len > Executor.max_code_size) {
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return createFailure(self, child.address, 0, .out_of_gas);
    }
    if (self.spec.isImpl(.london) and output.len > 0 and output[0] == 0xef) {
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return createFailure(self, child.address, 0, .invalid);
    }

    const runtime_size = std.math.cast(i64, output.len) orelse {
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return createFailure(self, child.address, 0, .out_of_gas);
    };
    const deposit_cost = std.math.mul(i64, runtime_size, Executor.code_deposit_gas) catch {
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return createFailure(self, child.address, 0, .out_of_gas);
    };
    if (result.gas_left < deposit_cost) {
        if (!self.spec.isImpl(.homestead)) {
            self.state.commitCheckpoint(child.checkpoint_state);
            checkpoint_open = false;
            return Host.Result.fromCreate(child.address, .{
                .status = .success,
                .output_data = output,
                .gas_left = result.gas_left,
                .gas_refund = result.gas_refund,
            });
        }
        try self.state.revertToCheckpoint(child.checkpoint_state);
        checkpoint_open = false;
        return createFailure(self, child.address, 0, .out_of_gas);
    }

    try self.state.setCode(child.address, output);
    self.state.commitCheckpoint(child.checkpoint_state);
    checkpoint_open = false;

    return Host.Result.fromCreate(child.address, .{
        .status = .success,
        .output_data = output,
        .gas_left = result.gas_left - deposit_cost,
        .gas_refund = result.gas_refund,
    });
}

fn createFailure(self: *Executor, create_address: Address, gas_left: i64, status: Interpreter.Status) Host.Result {
    self.clearLastOutput();
    return Host.Result.fromCreate(create_address, .{
        .status = status,
        .output_data = &.{},
        .gas_left = gas_left,
        .gas_refund = 0,
    });
}

fn createCollision(self: *Executor, address: Address) !bool {
    if (evmz.precompile.activeAt(self.spec, address) != null) return true;
    const account = try self.state.getAccountOrLoad(address) orelse return false;
    return account.nonce != 0 or account.code.len != 0 or try self.state.accountHasStorage(address);
}
