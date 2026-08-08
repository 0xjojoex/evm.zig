const std = @import("std");
const evmz = @import("../evm.zig");

const execution = evmz.execution;

const StatefulRuntime = struct {
    tx_kind: u8,
    fail: bool = false,
    service_error: ?anyerror = null,
    invalid_borrow: bool = false,
    borrowed: [1]u8 = .{0xff},

    fn service(self: *StatefulRuntime) execution.PrecompileRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: execution.PrecompileCall) !evmz.precompile.Result {
        const self: *StatefulRuntime = @ptrCast(@alignCast(ptr));
        if (self.service_error) |err| return err;
        _ = try call.host.setStorage(call.message.recipient, 7, self.tx_kind);
        if (self.invalid_borrow) return .{
            .status = .success,
            .output_data = &self.borrowed,
            .gas_left = call.message.gas - 9,
            .output_owned = false,
        };
        const output = if (call.output_buffer) |buffer| blk: {
            if (buffer.len < 1) return error.OutputBufferTooSmall;
            buffer[0] = self.tx_kind;
            break :blk buffer[0..1];
        } else blk: {
            const owned = try call.allocator.alloc(u8, 1);
            owned[0] = self.tx_kind;
            break :blk owned;
        };
        return .{
            .status = if (self.fail) .failure else .success,
            .output_data = output,
            .gas_left = call.message.gas - 9,
            .output_owned = call.output_buffer == null,
        };
    }
};

const ReentrantRuntime = struct {
    child: evmz.Address,
    called: bool = false,

    fn service(self: *ReentrantRuntime) execution.PrecompileRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: execution.PrecompileCall) !evmz.precompile.Result {
        const self: *ReentrantRuntime = @ptrCast(@alignCast(ptr));
        const result = (try call.host.call(.{
            .depth = call.message.depth + 1,
            .kind = .call,
            .gas = call.message.gas,
            .recipient = self.child,
            .sender = call.message.recipient,
            .input_data = &.{},
            .value = 0,
            .is_static = call.message.is_static,
            .code_address = self.child,
        })).expectCall();
        self.called = true;
        return .{
            .status = if (result.status() == .success) .success else .failure,
            // Keep this empty and unowned: this test isolates stack-arena
            // rebinding from the separate borrowed precompile-output lifetime.
            .output_data = &.{},
            .gas_left = result.gas_left,
            .output_owned = false,
        };
    }
};

const ReentrantOutputRuntime = struct {
    saw_borrowed_output: bool = false,

    fn service(self: *ReentrantOutputRuntime) execution.PrecompileRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(ptr: *anyopaque, call: execution.PrecompileCall) !evmz.precompile.Result {
        const self: *ReentrantOutputRuntime = @ptrCast(@alignCast(ptr));
        self.saw_borrowed_output = self.saw_borrowed_output or call.output_buffer != null;

        const output = if (call.output_buffer) |buffer| blk: {
            if (buffer.len < 1) return error.OutputBufferTooSmall;
            break :blk buffer[0..1];
        } else try call.allocator.alloc(u8, 1);
        const outer = call.message.input_data.len == 0;
        output[0] = if (outer) 0xaa else 0xbb;

        if (outer) {
            const nested = (try call.host.call(.{
                .depth = call.message.depth + 1,
                .kind = .call,
                .gas = call.message.gas,
                .gas_reservoir = call.message.gas_reservoir,
                .recipient = call.message.recipient,
                .sender = call.message.recipient,
                .input_data = &.{0x01},
                .value = 0,
                .code_address = call.message.code_address,
            })).expectCall();
            try std.testing.expectEqualSlices(u8, &.{0xbb}, nested.output_data);
        }

        return .{
            .status = .success,
            .output_data = output,
            .gas_left = call.message.gas,
            .output_owned = call.output_buffer == null,
        };
    }
};

const StatefulPrecompile = struct {
    const target = evmz.addr(0x1234);

    pub const Entry = enum { family };

    pub fn resolve(address: evmz.Address) ?Entry {
        return if (std.mem.eql(u8, &address, &target)) .family else null;
    }

    pub fn active(address: evmz.Address) bool {
        return resolve(address) != null;
    }

    pub fn execute(
        _: Entry,
        call: execution.PrecompileCall,
    ) evmz.precompile.Error!execution.PrecompileOutcome {
        return call.executeRuntime();
    }
};

const StatefulVm = evmz.Vm(evmz.eth.cancun.extend(.{
    .precompile = StatefulPrecompile,
}));

test "family precompile runtime can use host state and keeps EVM rollback semantics" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    var runtime = StatefulRuntime{ .tx_kind = 0x7e };
    var executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .state = .{},
        .services = .{ .precompile_runtime = runtime.service() },
    });
    defer executor.deinit();

    const success = (try executor.executeStandalone(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqual(StatefulVm.Interpreter.Status.success, success.status());
    try std.testing.expectEqualSlices(u8, &.{0x7e}, success.output_data);
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulPrecompile.target, 7));

    runtime.tx_kind = 0x99;
    runtime.fail = true;
    const failure = (try executor.executeStandalone(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqual(StatefulVm.Interpreter.Status.invalid, failure.status());
    try std.testing.expectEqual(@as(u256, 0x7e), try executor.getStorage(StatefulPrecompile.target, 7));

    runtime.fail = false;
    runtime.service_error = error.NotImplemented;
    try std.testing.expectError(
        error.NotImplemented,
        executor.executeStandalone(request(sender, StatefulPrecompile.target, &.{}), .{}),
    );

    runtime.service_error = null;
    runtime.invalid_borrow = true;
    try std.testing.expectError(
        error.InvalidPrecompileOutput,
        executor.executeStandalone(request(sender, StatefulPrecompile.target, &.{}), .{}),
    );
}

test "executor construction selects the supplied precompile runtime" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    var first_runtime = StatefulRuntime{ .tx_kind = 0x11 };
    var first_executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .state = .{},
        .services = .{ .precompile_runtime = first_runtime.service() },
    });
    defer first_executor.deinit();

    const first = (try first_executor.executeStandalone(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqualSlices(u8, &.{0x11}, first.output_data);

    var second_runtime = StatefulRuntime{ .tx_kind = 0x22 };
    var second_executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .state = .{},
        .services = .{ .precompile_runtime = second_runtime.service() },
    });
    defer second_executor.deinit();

    const second = (try second_executor.executeStandalone(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();
    try std.testing.expectEqualSlices(u8, &.{0x22}, second.output_data);
}

test "runtime precompile output survives synchronous host reentry" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    var runtime = ReentrantOutputRuntime{};
    var executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .state = .{},
        .services = .{ .precompile_runtime = runtime.service() },
    });
    defer executor.deinit();

    const result = (try executor.executeStandalone(
        request(sender, StatefulPrecompile.target, &.{}),
        .{},
    )).expectCall();

    try std.testing.expectEqualSlices(u8, &.{0xaa}, result.output_data);
    try std.testing.expect(!runtime.saw_borrowed_output);
}

test "reentrant precompile call preserves parent stack across arena growth" {
    if (comptime !evmz.t.forkEnabled(.cancun)) return error.SkipZigTest;
    const sender = evmz.addr(0xaaaa);
    const parent = evmz.addr(0xbbbb);
    const child = evmz.addr(0x5678);
    const filler_words = 599;
    const parent_tail = evmz.t.bytecode(.{
        // Together with the filler, retain 600 words below CALL's operands.
        .PUSH1, 0x2a,
        .PUSH0, .PUSH0,
        .PUSH0, .PUSH0,
        .PUSH0, .PUSH2,
        0x12,   0x34,
        .GAS,   .CALL,
        .POP,   .PUSH1,
        0x2a,   .EQ,
        .PUSH0, .SSTORE,
        .STOP,
    });
    var parent_code: [filler_words + parent_tail.len]u8 = undefined;
    @memset(parent_code[0..filler_words], evmz.Opcode.PUSH0.toByte());
    @memcpy(parent_code[filler_words..], &parent_tail);

    const child_code = evmz.t.bytecode(.{
        // Leave one live word while recursively calling this same account.
        // This raises the lazy row high-water mark and grows the packed arena.
        .PUSH1, 0x77,   .PUSH1, 0x09,   .SSTORE,
        .PUSH1, 0x2a,   .PUSH0, .PUSH0, .PUSH0,
        .PUSH0, .PUSH0, .PUSH2, 0x56,   0x78,
        .GAS,   .CALL,  .POP,   .STOP,
    });

    var runtime = ReentrantRuntime{ .child = child };
    var executor = StatefulVm.Executor.init(std.testing.allocator, .{
        .state = .{},
        .services = .{ .precompile_runtime = runtime.service() },
    });
    defer executor.deinit();

    var parent_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try parent_account.setCode(&parent_code);
    try executor.state.seedAccount(parent, parent_account);
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&child_code);
    try executor.state.seedAccount(child, child_account);

    const result = (try executor.executeStandalone(request(sender, parent, &.{}), .{})).expectCall();

    try std.testing.expect(runtime.called);
    try std.testing.expectEqual(StatefulVm.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(parent, 0));
    try std.testing.expectEqual(@as(u256, 0x77), try executor.getStorage(child, 9));
    try std.testing.expect(executor.frame_store.maxStackBase() >= 600);
    try std.testing.expect(executor.frame_store.maxStackWordCount() >= 600 + 1024);
    try std.testing.expect(executor.frame_store.maxRowCount() > 8);
}

fn request(sender: evmz.Address, recipient: evmz.Address, input: []const u8) evmz.execution.EvmExecutionRequest {
    return .{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .input = input,
        } },
        .gas = .legacy(100_000),
    };
}
