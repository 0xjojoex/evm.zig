const std = @import("std");
const evmz = @import("../evm.zig");
const call_runtime = @import("../executor/call_runtime.zig");
const session = @import("./session.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

fn finishCanonical(controlled: anytype) !Host.Result {
    var pause = try controlled.pause();
    while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .suspended => pause = try controlled.dispatchSuspension(),
            .finished => |finished| return switch (finished) {
                .canonical => |result| result,
                .intervened => unreachable,
            },
        }
    }
}

fn expectCallParity(
    comptime Exact: type,
    name: []const u8,
    code: []const u8,
    gas: i64,
    is_static: bool,
    expected_status: Interpreter.Status,
    expected_cause: evmz.execution.TerminalCause,
) !void {
    errdefer std.log.err("debug parity case failed: {s}", .{name});

    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = gas,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .is_static = is_static,
        .code_address = recipient,
    };
    const context = evmz.t.defaultExecutionContext(sender, @intCast(gas));

    var normal_executor = Executor.init(std.testing.allocator, .{});
    defer normal_executor.deinit();
    try normal_executor.beginTransaction(context, sender, recipient);
    defer normal_executor.discardStateTransition();
    normal_executor.beginPreparedCodeExecution();
    defer normal_executor.endPreparedCodeExecution();
    var normal_code = try normal_executor.prepareBytecode(code);
    defer normal_code.deinit(std.testing.allocator);
    const normal = try runtime.executePreparedCallMessage(&normal_executor, message, normal_code.view());

    var controlled_executor = Executor.init(std.testing.allocator, .{});
    defer controlled_executor.deinit();
    try controlled_executor.beginTransaction(context, sender, recipient);
    defer controlled_executor.discardStateTransition();
    var controlled_code = try controlled_executor.prepareBytecode(code);
    defer controlled_code.deinit(std.testing.allocator);
    var controlled: driver.Session = undefined;
    try controlled.init(&controlled_executor, message, controlled_code.view());
    defer controlled.deinit();
    const stepped = try finishCanonical(&controlled);

    try std.testing.expectEqual(expected_status, normal.status());
    try std.testing.expectEqual(expected_cause, normal.terminalCause());
    try std.testing.expectEqual(normal.status(), stepped.status());
    try std.testing.expectEqual(normal.terminalCause(), stepped.terminalCause());
    try std.testing.expectEqual(normal.checkpointReverted(), stepped.checkpointReverted());
    try std.testing.expectEqual(normal.gasLeft(), stepped.gasLeft());
    try std.testing.expectEqual(normal.gasRefund(), stepped.gasRefund());
    try std.testing.expectEqual(normal.gasReservoir(), stepped.gasReservoir());
    try std.testing.expectEqual(normal.stateGasSpent(), stepped.stateGasSpent());
    try std.testing.expectEqual(normal.stateGasFromGasLeft(), stepped.stateGasFromGasLeft());
    try std.testing.expectEqualSlices(u8, normal.outputData(), stepped.outputData());
}

/// Example debugger policy composed outside the execution session.
fn stepOver(controlled: anytype, current: session.Pause) !session.Pause {
    const depth = switch (current) {
        .opcode => |event| event.site.depth,
        else => unreachable,
    };
    var next = try controlled.step();
    while (true) {
        switch (next) {
            .opcode => |event| {
                if (event.site.depth <= depth) return next;
                next = try controlled.step();
            },
            .suspended => next = try controlled.dispatchSuspension(),
            .finished => return next,
        }
    }
}

/// Example debugger policy composed outside the execution session.
fn stepOut(controlled: anytype, current: session.Pause) !session.Pause {
    const depth = switch (current) {
        .opcode => |event| event.site.depth,
        else => unreachable,
    };
    var next = try controlled.step();
    while (true) {
        switch (next) {
            .opcode => |event| {
                if (event.site.depth < depth) return next;
                next = try controlled.step();
            },
            .suspended => next = try controlled.dispatchSuspension(),
            .finished => return next,
        }
    }
}

test "debug session matches uninterrupted execution" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const code = [_]u8{
        0x60, 0x02, // PUSH1 2
        0x60, 0x03, // PUSH1 3
        0x01, // ADD
        0x5f, // PUSH0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x5f, // PUSH0
        0xf3, // RETURN
    };
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var normal_executor = Executor.init(std.testing.allocator, .{});
    defer normal_executor.deinit();
    try normal_executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
    );
    defer normal_executor.discardStateTransition();
    normal_executor.beginPreparedCodeExecution();
    defer normal_executor.endPreparedCodeExecution();
    var normal_code = try normal_executor.prepareBytecode(&code);
    defer normal_code.deinit(std.testing.allocator);
    const normal = (try runtime.executePreparedCallMessage(&normal_executor, message, normal_code.view())).expectCall();

    var controlled_executor = Executor.init(std.testing.allocator, .{});
    defer controlled_executor.deinit();
    try controlled_executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
    );
    defer controlled_executor.discardStateTransition();
    var controlled_code = try controlled_executor.prepareBytecode(&code);
    defer controlled_code.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&controlled_executor, message, controlled_code.view());
    defer controlled.deinit();
    const root_frame = controlled.call_runtime.frames.frame(controlled.call_runtime.frame_base);
    try std.testing.expectEqual(
        @intFromPtr(&controlled.call_runtime.host_iface),
        @intFromPtr(root_frame.host),
    );

    var pause = try controlled.pause();
    switch (pause) {
        .opcode => |event| {
            try std.testing.expectEqual(@as(usize, 0), event.pc);
            try std.testing.expectEqual(@as(u8, 0x60), event.opcode);
        },
        else => unreachable,
    }

    var opcode_count: usize = 0;
    const result = run: while (true) {
        switch (pause) {
            .opcode => {
                opcode_count += 1;
                pause = try controlled.step();
            },
            .suspended => unreachable,
            .finished => |finished| break :run switch (finished) {
                .canonical => |result| result.expectCall(),
                .intervened => unreachable,
            },
        }
    };

    try std.testing.expectEqual(@as(usize, 8), opcode_count);
    try std.testing.expectEqual(normal.status(), result.status());
    try std.testing.expectEqual(normal.gas_left, result.gas_left);
    try std.testing.expectEqualSlices(u8, normal.output_data, result.output_data);
}

test "debug session matches call, create, precompile, and terminal outcomes" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const empty = [_]u8{};
    const create = evmz.t.bytecode(.{
        .PUSH0, .PUSH0,  .PUSH0, .CREATE,
        .PUSH0, .MSTORE, .PUSH1, 0x20,
        .PUSH0, .RETURN,
    });
    const precompile = evmz.t.bytecode(.{
        .PUSH1, 0x2a,
        .PUSH0, .MSTORE,
        .PUSH1, 0x20,
        .PUSH0, .PUSH1,
        0x20,   .PUSH0,
        .PUSH0, .PUSH1,
        0x04,   .PUSH2,
        0x27,   0x10,
        .CALL,  .POP,
        .PUSH1, 0x20,
        .PUSH0, .RETURN,
    });
    const revert = evmz.t.bytecode(.{
        .PUSH1, 0xaa, .PUSH0, .MSTORE8,
        .PUSH1, 0x01, .PUSH0, .REVERT,
    });
    const out_of_gas = evmz.t.bytecode(.{ .PUSH1, 0x2a });
    const invalid_jump = evmz.t.bytecode(.{ .PUSH0, .JUMP });
    const stack_underflow = evmz.t.bytecode(.{.ADD});
    const stack_overflow = [_]u8{evmz.Opcode.PUSH0.toByte()} ** 1025;
    const static_violation = evmz.t.bytecode(.{ .PUSH0, .PUSH0, .SSTORE });

    try expectCallParity(Exact, "empty code", &empty, 100, false, .success, .none);
    try expectCallParity(Exact, "CREATE child", &create, 200_000, false, .success, .none);
    try expectCallParity(Exact, "identity precompile child", &precompile, 200_000, false, .success, .none);
    try expectCallParity(Exact, "revert output", &revert, 100, false, .revert, .revert);
    try expectCallParity(Exact, "out of gas", &out_of_gas, 2, false, .out_of_gas, .out_of_gas);
    try expectCallParity(Exact, "invalid jump", &invalid_jump, 100, false, .invalid, .invalid_jump);
    try expectCallParity(Exact, "stack underflow", &stack_underflow, 100, false, .invalid, .stack_underflow);
    try expectCallParity(Exact, "stack overflow", &stack_overflow, 200_000, false, .invalid, .stack_overflow);
    try expectCallParity(Exact, "static write protection", &static_violation, 100, true, .invalid, .write_protection);
}

test "debug session dispatches a child and resumes its parent" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const child = evmz.addr(0x1234);
    const root_code = [_]u8{
        0x60, 0x01, // return size
        0x5f, // return offset
        0x5f, // input size
        0x5f, // input offset
        0x5f, // value
        0x61, 0x12, 0x34, // child
        0x5a, // GAS
        0xf1, // CALL
        0x60, 0x01, // return size
        0x5f, // return offset
        0xf3, // RETURN
    };
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&.{
        0x60, 0xaa, // PUSH1 aa
        0x5f, // PUSH0
        0x53, // MSTORE8
        0x60, 0x01, // PUSH1 1
        0x5f, // PUSH0
        0xf3, // RETURN
    });
    try executor.state.seedAccount(child, child_account);
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, message, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (pause == .opcode) pause = try controlled.step();
    switch (pause) {
        .suspended => |event| {
            try std.testing.expectEqual(@as(u16, 0), event.site.depth);
            const call = switch (event.value.*) {
                .call => |value| value,
                .create => unreachable,
            };
            try std.testing.expectEqual(child, call.msg.recipient);
        },
        else => unreachable,
    }

    pause = try controlled.dispatchSuspension();
    switch (pause) {
        .opcode => |event| try std.testing.expectEqual(@as(u16, 1), event.site.depth),
        else => unreachable,
    }
    pause = try stepOut(&controlled, pause);
    switch (pause) {
        .opcode => |event| try std.testing.expectEqual(@as(u16, 0), event.site.depth),
        else => unreachable,
    }

    const result = run: while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .suspended => unreachable,
            .finished => |finished| break :run switch (finished) {
                .canonical => |value| value.expectCall(),
                .intervened => unreachable,
            },
        }
    };
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);

    var over: driver.Session = undefined;
    try over.init(&executor, message, bytecode.view());
    defer over.deinit();
    pause = try over.pause();
    while (pause.opcode.opcode != 0xf1) pause = try over.step();
    pause = try stepOver(&over, pause);
    switch (pause) {
        .opcode => |event| {
            try std.testing.expectEqual(@as(u16, 0), event.site.depth);
            try std.testing.expectEqual(@as(u8, 0x60), event.opcode);
        },
        else => unreachable,
    }
    try std.testing.expectEqual(@as(u256, 1), over.stack()[over.stack().len - 1]);
}

test "debug session can substitute a call before continuing" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const root_code = [_]u8{
        0x60, 0x01, // return size
        0x5f, // return offset
        0x5f, // input size
        0x5f, // input offset
        0x5f, // value
        0x61, 0x12, 0x34, // child
        0x5a, // GAS
        0xf1, // CALL
        0x60, 0x01, // return size
        0x5f, // PUSH0
        0xf3, // RETURN
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, .{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    }, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (pause == .opcode) pause = try controlled.step();
    const call = switch (pause) {
        .suspended => |event| switch (event.value.*) {
            .call => |value| value,
            .create => unreachable,
        },
        else => unreachable,
    };
    const replacement = [_]u8{0xbb};
    try std.testing.expect(!controlled.isIntervened());
    pause = try controlled.substituteResult(Host.Result.fromCall(.{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = &replacement,
        .gas_left = call.continuation.gas_limit,
        .gas_refund = 0,
    }));
    try std.testing.expect(controlled.isIntervened());

    const result = run: while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .suspended => unreachable,
            .finished => |finished| break :run switch (finished) {
                .canonical => unreachable,
                .intervened => |value| value.expectCall(),
            },
        }
    };
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &replacement, result.output_data);
}

test "debug session mismatch remains canonical when dispatched" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH1, 0x01,   .GAS,
        .CALL,  .STOP,
    });

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, .{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    }, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (pause == .opcode) pause = try controlled.step();
    const suspended = switch (pause) {
        .suspended => |event| event.value,
        else => unreachable,
    };
    const call = switch (suspended.*) {
        .call => |value| value,
        .create => unreachable,
    };

    try std.testing.expectError(error.ResumeKindMismatch, controlled.substituteResult(
        Host.Result.fromCreate(evmz.addr(0xdead), .{
            .outcome = .{ .status = .success, .cause = .none },
            .output_data = &.{},
            .gas_left = call.continuation.gas_limit,
            .gas_refund = 0,
        }),
    ));
    try std.testing.expect(!controlled.isIntervened());
    try std.testing.expectEqual(suspended, switch (try controlled.pause()) {
        .suspended => |event| event.value,
        else => unreachable,
    });

    const result = (try finishCanonical(&controlled)).expectCall();
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expect(!controlled.isIntervened());
}

test "debug session can substitute a create before continuing" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const deployed = evmz.addr(0xdead);
    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0,  .PUSH0, .CREATE,
        .PUSH0, .MSTORE, .PUSH1, 0x20,
        .PUSH0, .RETURN,
    });
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, message, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (pause == .opcode) pause = try controlled.step();
    const create = switch (pause) {
        .suspended => |event| switch (event.value.*) {
            .call => unreachable,
            .create => |value| value,
        },
        else => unreachable,
    };
    try std.testing.expect(!controlled.isIntervened());
    pause = try controlled.substituteResult(Host.Result.fromCreate(deployed, .{
        .outcome = .{ .status = .success, .cause = .none },
        .output_data = &.{},
        .gas_left = create.continuation.gas_limit,
        .gas_refund = 0,
    }));
    try std.testing.expect(controlled.isIntervened());
    try std.testing.expectEqual(
        evmz.address.toU256(deployed),
        controlled.stack()[controlled.stack().len - 1],
    );

    const result = run: while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .suspended => unreachable,
            .finished => |finished| break :run switch (finished) {
                .canonical => unreachable,
                .intervened => |value| value.expectCall(),
            },
        }
    };
    try std.testing.expectEqual(Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(usize, 32), result.output_data.len);
    try std.testing.expectEqual(
        evmz.address.toU256(deployed),
        std.mem.readInt(u256, result.output_data[0..32], .big),
    );
    // The substituted address was never deployed; nothing entered state.
    try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(deployed)).len);
}

test "debug session aborts at child and action boundaries" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const child = evmz.addr(0x1234);
    const root_code = [_]u8{
        0x60, 0x01, // value
        0x5f, // key
        0x55, // SSTORE
        0x5f, // return size
        0x5f, // return offset
        0x5f, // input size
        0x5f, // input offset
        0x5f, // value
        0x61, 0x12, 0x34, // child
        0x5a, // GAS
        0xf1, // CALL
        0x00, // STOP
    };
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 500_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&.{
        0x60, 0x07, // value
        0x5f, // key
        0x55, // SSTORE
        0x00, // STOP
    });
    try executor.state.seedAccount(child, child_account);
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 500_000),
        sender,
        recipient,
    );
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, message, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (pause == .opcode) pause = try controlled.step();
    pause = try controlled.dispatchSuspension();
    while (true) {
        switch (pause) {
            .opcode => |event| {
                if (event.site.depth == 1 and event.opcode == 0x00) break;
                pause = try controlled.step();
            },
            else => unreachable,
        }
    }

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 7), try executor.getStorage(child, 0));
    controlled.deinit();
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(child, 0));

    executor.discardStateTransition();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(recipient, 0));

    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 500_000),
        sender,
        recipient,
    );
    var at_action: driver.Session = undefined;
    try at_action.init(&executor, message, bytecode.view());
    defer at_action.deinit();
    pause = try at_action.pause();
    while (pause == .opcode) pause = try at_action.step();

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(child, 0));
    at_action.deinit();
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(child, 0));

    executor.discardStateTransition();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(recipient, 0));
}

test "debug session resolves and executes a custom instruction" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const square_byte: u8 = 0xb0;
    const Square = struct {
        pub inline fn execute(comptime Instructions: type, frame: *Interpreter.CallFrame) anyerror!void {
            if (!frame.trackGas(comptime Instructions.table[square_byte].info.static_gas)) return;
            const value = frame.pop() orelse return;
            _ = frame.push(value *% value);
        }
    };
    const custom_instructions = comptime instructions: {
        var instructions = evmz.eth.cancun.instruction;
        instructions.install(.SQUARE, square_byte, .{
            .static_gas = 5,
            .stack_in = 1,
            .stack_out = 1,
        }, .{ .custom = Square });
        break :instructions instructions;
    };
    const Exact = evmz.t.CustomVm(.cancun, .{ .instruction = custom_instructions }) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const code = [_]u8{
        0x60, 0x07, // PUSH1 7
        square_byte, // SQUARE
        0x5f, // PUSH0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
        0x5f, // PUSH0
        0xf3, // RETURN
    };
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var normal_executor = Executor.init(std.testing.allocator, .{});
    defer normal_executor.deinit();
    try normal_executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
    );
    defer normal_executor.discardStateTransition();
    normal_executor.beginPreparedCodeExecution();
    defer normal_executor.endPreparedCodeExecution();
    var normal_code = try normal_executor.prepareBytecode(&code);
    defer normal_code.deinit(std.testing.allocator);
    const normal = (try runtime.executePreparedCallMessage(&normal_executor, message, normal_code.view())).expectCall();

    var controlled_executor = Executor.init(std.testing.allocator, .{});
    defer controlled_executor.deinit();
    try controlled_executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
    );
    defer controlled_executor.discardStateTransition();
    var controlled_code = try controlled_executor.prepareBytecode(&code);
    defer controlled_code.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&controlled_executor, message, controlled_code.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (true) {
        const event = switch (pause) {
            .opcode => |value| value,
            else => unreachable,
        };
        var name_buffer: [16]u8 = undefined;
        const name = try std.fmt.bufPrint(
            &name_buffer,
            "{f}",
            .{Exact.specification.instruction.fmt(event.opcode)},
        );
        if (std.mem.eql(u8, name, "SQUARE")) break;
        pause = try controlled.step();
    }

    const square = pause.opcode;
    try std.testing.expectEqual(square_byte, square.opcode);
    try std.testing.expectEqualSlices(u256, &.{7}, controlled.stack());

    const entry = Exact.specification.instruction.entry(square_byte);
    try std.testing.expect(entry.defined());
    try std.testing.expectEqual(@as(i64, 5), entry.info.static_gas);
    try std.testing.expectEqual(@as(u8, 1), entry.info.stack_in);
    try std.testing.expectEqual(@as(u8, 1), entry.info.stack_out);
    pause = try controlled.step();

    const result = run: while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .suspended => unreachable,
            .finished => |finished| break :run switch (finished) {
                .canonical => |value| value.expectCall(),
                .intervened => unreachable,
            },
        }
    };
    try std.testing.expectEqual(normal.status(), result.status());
    try std.testing.expectEqual(normal.gas_left, result.gas_left);
    try std.testing.expectEqualSlices(u8, normal.output_data, result.output_data);
}

test "debug session rejects an active capture context" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const code = [_]u8{0x00};
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 100_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    var capture = evmz.executor.CaptureContext.init(std.testing.allocator, null);
    defer capture.deinit();
    try capture.begin();
    defer capture.abort() catch {};
    try executor.beginCapturedTransaction(
        evmz.t.defaultExecutionContext(sender, 100_000),
        sender,
        recipient,
        &capture,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try std.testing.expectError(error.CaptureActive, controlled.init(&executor, message, bytecode.view()));
}

test "debug session inspection rebinds to the active frame" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const child = evmz.addr(0x1234);
    const child_code = [_]u8{0x00}; // STOP
    const root_code = [_]u8{
        0x60, 0xaa, // PUSH1 aa
        0x5f, // PUSH0
        0x53, // MSTORE8  memory[0] = aa
        0x5f, // return size
        0x5f, // return offset
        0x5f, // input size
        0x5f, // input offset
        0x5f, // value
        0x61, 0x12, 0x34, // child
        0x5a, // GAS
        0xf1, // CALL
        0x00, // STOP
    };
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var executor = Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, child, .{ .code = &child_code });
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled: driver.Session = undefined;
    try controlled.init(&executor, message, bytecode.view());
    defer controlled.deinit();

    var pause = try controlled.pause();
    try std.testing.expectEqual(@as(usize, 0), controlled.memory().len);
    while (pause == .opcode) pause = try controlled.step();

    try std.testing.expectEqual(recipient, controlled.message().recipient);
    try std.testing.expectEqualSlices(u8, &root_code, controlled.code());
    try std.testing.expectEqual(@as(u8, 0xaa), controlled.memory()[0]);

    pause = try controlled.dispatchSuspension();
    try std.testing.expectEqual(@as(u16, 1), pause.opcode.site.depth);
    try std.testing.expectEqual(child, controlled.message().recipient);
    try std.testing.expectEqualSlices(u8, &child_code, controlled.code());
    try std.testing.expectEqual(@as(usize, 0), controlled.memory().len);
}

/// Fails every allocation once armed, so setup can use the real allocator and
/// only the call under test sees `error.OutOfMemory`.
const ArmedFailingAllocator = struct {
    backing: std.mem.Allocator,
    armed: bool = false,

    fn allocator(self: *ArmedFailingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return null;
        return self.backing.rawAlloc(len, alignment, ra);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return false;
        return self.backing.rawResize(memory, alignment, new_len, ra);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        if (self.armed) return null;
        return self.backing.rawRemap(memory, alignment, new_len, ra);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const self: *ArmedFailingAllocator = @ptrCast(@alignCast(ctx));
        self.backing.rawFree(memory, alignment, ra);
    }
};

test "failed debug session init leaves no prepared-code execution scope" {
    const Exact = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const Executor = Exact.Executor;
    const driver = session.bind(Executor);
    const sender = evmz.addr(0x1111);
    const recipient = evmz.addr(0x2222);
    const root_code = evmz.t.bytecode(.{ .PUSH1, 0x01, .PUSH1, 0x02, .ADD, .STOP });
    const message = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    };

    var failing = ArmedFailingAllocator{ .backing = std.testing.allocator };
    var executor = Executor.init(failing.allocator(), .{});
    defer executor.deinit();
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, 200_000),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(failing.allocator());

    var controlled: driver.Session = undefined;
    failing.armed = true;
    const failed = controlled.init(&executor, message, bytecode.view());
    failing.armed = false;
    try std.testing.expectError(error.OutOfMemory, failed);

    // `init`'s errdefers already closed the scope it opened.
    try std.testing.expect(executor.prepared_code_execution == null);
    try std.testing.expectEqual(@as(usize, 0), executor.prepared_code_execution_depth);
    try std.testing.expectEqual(@as(usize, 0), executor.frame_store.len());

    // A caller that unconditionally tears down must not close it a second time.
    controlled.deinit();
    try std.testing.expect(executor.prepared_code_execution == null);
    try std.testing.expectEqual(@as(usize, 0), executor.prepared_code_execution_depth);

    // The session is reusable in place once allocation succeeds again.
    try controlled.init(&executor, message, bytecode.view());
    defer controlled.deinit();
    try std.testing.expectEqual(@as(u8, 0x60), (try controlled.pause()).opcode.opcode);
}
