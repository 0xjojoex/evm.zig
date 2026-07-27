const std = @import("std");
const evmz = @import("../evm.zig");
const call_runtime = @import("../executor/call_runtime.zig");
const session = @import("./session.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

test "debug session matches uninterrupted execution" {
    const Exact = evmz.Vm(evmz.eth.cancun);
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
    controlled_executor.beginPreparedCodeExecution();
    defer controlled_executor.endPreparedCodeExecution();
    var controlled_code = try controlled_executor.prepareBytecode(&code);
    defer controlled_code.deinit(std.testing.allocator);

    var controlled = runtime.CallRuntime.init(&controlled_executor);
    defer controlled.deinit();
    try controlled.prepare();
    try controlled.pushRootCall(message, controlled_code.view());

    var pause = try driver.pause(&controlled);
    switch (pause) {
        .opcode => |event| {
            try std.testing.expectEqual(@as(usize, 0), event.pc);
            try std.testing.expectEqual(@as(u8, 0x60), event.opcode);
            try std.testing.expectEqual(@as(?u256, null), controlled.frames.frame(event.site.frame_index).stack.peek());
        },
        else => unreachable,
    }

    var opcode_count: usize = 0;
    const result = run: while (true) {
        switch (pause) {
            .opcode => {
                opcode_count += 1;
                pause = try driver.step(&controlled);
            },
            .action => unreachable,
            .finished => |finished| break :run finished.expectCall(),
        }
    };

    try std.testing.expectEqual(@as(usize, 8), opcode_count);
    try std.testing.expectEqual(normal.status, result.status);
    try std.testing.expectEqual(normal.gas_left, result.gas_left);
    try std.testing.expectEqualSlices(u8, normal.output_data, result.output_data);
}

test "debug session dispatches a child and resumes its parent" {
    const Exact = evmz.Vm(evmz.eth.cancun);
    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
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
        0x00, // STOP
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
    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled = runtime.CallRuntime.init(&executor);
    defer controlled.deinit();
    try controlled.prepare();
    try controlled.pushRootCall(.{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    }, bytecode.view());

    var pause = try driver.pause(&controlled);
    while (pause == .opcode) pause = try driver.step(&controlled);
    switch (pause) {
        .action => |event| {
            try std.testing.expectEqual(@as(u16, 0), event.site.depth);
            const call = switch (event.value) {
                .call => |value| value,
                .create => unreachable,
            };
            try std.testing.expectEqual(child, call.msg.recipient);
        },
        else => unreachable,
    }

    pause = try driver.dispatchAction(&controlled);
    switch (pause) {
        .opcode => |event| try std.testing.expectEqual(@as(u16, 1), event.site.depth),
        else => unreachable,
    }
    while (true) {
        switch (pause) {
            .opcode => |event| {
                if (event.site.depth == 0) break;
                pause = try driver.step(&controlled);
            },
            else => unreachable,
        }
    }

    const resumed = switch (pause) {
        .opcode => |event| blk: {
            try std.testing.expectEqual(@as(usize, root_code.len - 1), event.pc);
            break :blk controlled.frames.frame(event.site.frame_index);
        },
        else => unreachable,
    };
    try std.testing.expectEqualSlices(u8, &.{0xaa}, resumed.memory.readBytes(0, 1));
    try std.testing.expectEqualSlices(u8, &.{0xaa}, resumed.return_data);
    try std.testing.expectEqual(@as(?u256, 1), resumed.stack.peek());

    const finished = try driver.step(&controlled);
    switch (finished) {
        .finished => |result| try std.testing.expectEqual(Interpreter.Status.success, result.expectCall().status),
        else => unreachable,
    }
}

test "debug session can substitute and mutate before continuing" {
    const Exact = evmz.Vm(evmz.eth.cancun);
    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
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
        0x5f, // PUSH0
        0x52, // MSTORE
        0x60, 0x20, // PUSH1 32
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
    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled = runtime.CallRuntime.init(&executor);
    defer controlled.deinit();
    try controlled.prepare();
    try controlled.pushRootCall(.{
        .depth = 0,
        .kind = .call,
        .gas = 200_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    }, bytecode.view());

    var pause = try driver.pause(&controlled);
    while (pause == .opcode) pause = try driver.step(&controlled);
    const call = switch (pause) {
        .action => |event| switch (event.value) {
            .call => |value| value,
            .create => unreachable,
        },
        else => unreachable,
    };
    const replacement = [_]u8{0xbb};
    pause = try driver.substituteAction(&controlled, Host.Result.fromCall(.{
        .status = .success,
        .output_data = &replacement,
        .gas_left = call.continuation.gas_limit,
        .gas_refund = 0,
    }));

    const frame = switch (pause) {
        .opcode => |event| controlled.frames.frame(event.site.frame_index),
        else => unreachable,
    };
    try std.testing.expectEqualSlices(u8, &replacement, frame.memory.readBytes(0, 1));
    try std.testing.expectEqualSlices(u8, &replacement, frame.return_data);
    try frame.stack.replaceTop(42);

    const result = run: while (true) {
        switch (pause) {
            .opcode => pause = try driver.step(&controlled),
            .action => unreachable,
            .finished => |finished| break :run finished.expectCall(),
        }
    };
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqual(@as(usize, 32), result.output_data.len);
    try std.testing.expectEqual(@as(u8, 42), result.output_data[31]);
}

test "debug session cancellation restores child then transaction state" {
    const Exact = evmz.Vm(evmz.eth.cancun);
    const Executor = Exact.Executor;
    const runtime = call_runtime.bind(Executor);
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
    executor.beginPreparedCodeExecution();
    defer executor.endPreparedCodeExecution();
    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(std.testing.allocator);

    var controlled = runtime.CallRuntime.init(&executor);
    defer controlled.deinit();
    try controlled.prepare();
    try controlled.pushRootCall(.{
        .depth = 0,
        .kind = .call,
        .gas = 500_000,
        .recipient = recipient,
        .sender = sender,
        .input_data = &.{},
        .value = 0,
        .code_address = recipient,
    }, bytecode.view());

    var pause = try driver.pause(&controlled);
    while (pause == .opcode) pause = try driver.step(&controlled);
    pause = try driver.dispatchAction(&controlled);
    while (true) {
        switch (pause) {
            .opcode => |event| {
                if (event.site.depth == 1 and event.opcode == 0x00) break;
                pause = try driver.step(&controlled);
            },
            else => unreachable,
        }
    }

    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 7), try executor.getStorage(child, 0));
    driver.abort(&controlled);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(recipient, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(child, 0));

    executor.discardStateTransition();
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(recipient, 0));
}
