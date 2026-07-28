//! Scripted demonstration of the internal controlled-execution POC.
//!
//! This is deliberately not an example of a public API. The build target imports
//! the internal session directly so the POC can be exercised without exporting
//! debugger vocabulary from `evm.zig`.
//!
//! It stays at `src/` rather than under `src/debug/` because it is its own build
//! root: Zig scopes a module to its root source file's directory, and from
//! `src/debug/` the `../evm.zig` import is outside the module path.

const std = @import("std");
const evmz = @import("./evm.zig");
const session = @import("./debug/session.zig");

const Host = evmz.Host;
const Interpreter = evmz.interpreter;

const square_byte: u8 = 0xb0;
const sstore_byte: u8 = 0x55;
const child = evmz.addr(0x1234);
const sender = evmz.addr(0x1111);
const recipient = evmz.addr(0x2222);
const gas_limit: u64 = 500_000;

const Square = struct {
    pub inline fn execute(comptime Instructions: type, frame: *Interpreter.CallFrame) anyerror!void {
        if (!frame.trackGas(comptime Instructions.table[square_byte].info.static_gas)) return;
        const value = try frame.stack.pop();
        try frame.stack.push(value *% value);
    }
};

const custom_instructions = instructions: {
    var instructions = evmz.eth.cancun.instruction;
    instructions.install(.SQUARE, square_byte, .{
        .static_gas = 5,
        .stack_in = 1,
        .stack_out = 1,
    }, .{ .custom = Square });
    break :instructions instructions;
};

const Exact = evmz.Vm(evmz.eth.cancun.extend(.{ .instruction = custom_instructions }));
const Executor = Exact.Executor;
const Driver = session.bind(Executor);

const root_code = [_]u8{
    0x60, 0x01, // PUSH1 1
    0x5f, // PUSH0
    sstore_byte, // SSTORE  root[0] = 1
    0x60, 0x07, // PUSH1 7
    square_byte, // SQUARE
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

const child_code = [_]u8{
    0x60, 0x07, // PUSH1 7
    0x5f, // PUSH0
    sstore_byte, // SSTORE  child[0] = 7
    0x60, 0xaa, // PUSH1 aa
    0x5f, // PUSH0
    0x53, // MSTORE8
    0x60, 0x01, // PUSH1 1
    0x5f, // PUSH0
    0xf3, // RETURN
};

const message = Host.Message{
    .depth = 0,
    .kind = .call,
    .gas = gas_limit,
    .recipient = recipient,
    .sender = sender,
    .input_data = &.{},
    .value = 0,
    .code_address = recipient,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    var executor = Executor.init(allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, child, .{ .code = &child_code });

    var bytecode = try executor.prepareBytecode(&root_code);
    defer bytecode.deinit(allocator);

    try canonicalRun(&executor, bytecode.view());
    try intervenedRun(&executor, bytecode.view());
    try abortedRun(&executor, bytecode.view());
}

fn canonicalRun(executor: *Executor, bytecode: evmz.Bytecode.View) !void {
    std.debug.print("\n== canonical controlled run ==\n", .{});
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, gas_limit),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();

    var controlled: Driver.Session = undefined;
    try controlled.init(executor, message, bytecode);
    defer controlled.deinit();

    var pause = try controlled.pause();
    var stepped_out = false;
    while (true) {
        switch (pause) {
            .opcode => |event| {
                printOpcode(event, controlled.stack());
                if (event.opcode == square_byte) {
                    std.debug.print("  breakpoint: custom opcode, top=0x{x}\n", .{controlled.stack()[controlled.stack().len - 1]});
                }
                if (event.site.depth == 1 and !stepped_out) {
                    std.debug.print("  command: step out\n", .{});
                    pause = try stepOut(&controlled, pause);
                    stepped_out = true;
                } else {
                    pause = try controlled.step();
                }
            },
            .action => |event| {
                printAction(event);
                std.debug.print("  command: step into\n", .{});
                pause = try controlled.dispatchAction();
            },
            .finished => |completion| switch (completion) {
                .canonical => |result| {
                    std.debug.print("finished: canonical, output=0x", .{});
                    printHex(result.outputData());
                    std.debug.print("\n", .{});
                    return;
                },
                .intervened => unreachable,
            },
        }
    }
}

fn intervenedRun(executor: *Executor, bytecode: evmz.Bytecode.View) !void {
    std.debug.print("\n== intervened controlled run ==\n", .{});
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, gas_limit),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();

    var controlled: Driver.Session = undefined;
    try controlled.init(executor, message, bytecode);
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (true) {
        switch (pause) {
            .opcode => pause = try controlled.step(),
            .action => |event| {
                printAction(event);
                const call = switch (event.value) {
                    .call => |value| value,
                    .create => unreachable,
                };
                const replacement = [_]u8{0xbb};
                std.debug.print("  intervention: substitute output=0xbb\n", .{});
                pause = try controlled.substituteAction(Host.Result.fromCall(.{
                    .status = .success,
                    .output_data = &replacement,
                    .gas_left = call.continuation.gas_limit,
                    .gas_refund = 0,
                }));
                std.debug.print("  authority: {s}\n", .{if (controlled.isIntervened()) "intervened" else "canonical"});
            },
            .finished => |completion| switch (completion) {
                .canonical => unreachable,
                .intervened => |result| {
                    std.debug.print("finished: intervened, output=0x", .{});
                    printHex(result.outputData());
                    std.debug.print("\n", .{});
                    return;
                },
            },
        }
    }
}

/// Cancel from inside a live child and show which writes survive.
///
/// The session restores every unresolved child checkpoint it opened; the root
/// attempt is still the caller's to resolve, so the parent's own write is
/// untouched until `discardStateTransition` drops the whole transaction.
fn abortedRun(executor: *Executor, bytecode: evmz.Bytecode.View) !void {
    std.debug.print("\n== aborted controlled run ==\n", .{});
    try executor.beginTransaction(
        evmz.t.defaultExecutionContext(sender, gas_limit),
        sender,
        recipient,
    );
    defer executor.discardStateTransition();

    var controlled: Driver.Session = undefined;
    try controlled.init(executor, message, bytecode);
    defer controlled.deinit();

    var pause = try controlled.pause();
    while (true) {
        switch (pause) {
            .opcode => |event| {
                pause = try controlled.step();
                if (event.site.depth == 1 and event.opcode == sstore_byte) break;
            },
            .action => pause = try controlled.dispatchAction(),
            .finished => unreachable,
        }
    }

    std.debug.print("  paused inside the child, after its SSTORE\n", .{});
    try printStorage(executor, "before abort");
    controlled.abort();
    std.debug.print("  command: abort\n", .{});
    try printStorage(executor, "after abort ");
    std.debug.print("  transaction discarded by the caller, not the session\n", .{});
}

fn printStorage(executor: *Executor, label: []const u8) !void {
    std.debug.print("  {s}: root[0]={d} child[0]={d}\n", .{
        label,
        try executor.getStorage(recipient, 0),
        try executor.getStorage(child, 0),
    });
}

fn stepOut(controlled: *Driver.Session, current: session.Pause) !session.Pause {
    const depth = current.opcode.site.depth;
    var next = try controlled.step();
    while (true) {
        switch (next) {
            .opcode => |event| {
                if (event.site.depth < depth) return next;
                next = try controlled.step();
            },
            .action => next = try controlled.dispatchAction(),
            .finished => return next,
        }
    }
}

fn printOpcode(event: anytype, stack: []const u256) void {
    var name_buffer: [24]u8 = undefined;
    const name = std.fmt.bufPrint(
        &name_buffer,
        "{f}",
        .{Exact.specification.instruction.fmt(event.opcode)},
    ) catch "UNKNOWN";
    std.debug.print(
        "depth={d} pc={d:0>2} opcode={s:<10} gas={d:<6} stack=[",
        .{ event.site.depth, event.pc, name, event.gas_left },
    );
    for (stack, 0..) |value, index| {
        if (index != 0) std.debug.print(", ", .{});
        std.debug.print("0x{x}", .{value});
    }
    std.debug.print("]\n", .{});
}

fn printAction(event: anytype) void {
    const call = switch (event.value) {
        .call => |value| value,
        .create => unreachable,
    };
    std.debug.print(
        "action={s} depth={d} target=0x",
        .{ @tagName(call.msg.kind), event.site.depth },
    );
    printHex(&call.msg.recipient);
    std.debug.print("\n", .{});
}

fn printHex(bytes: []const u8) void {
    for (bytes) |byte| std.debug.print("{x:0>2}", .{byte});
}
