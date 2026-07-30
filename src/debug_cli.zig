//! Interactive front end for the internal controlled-execution session.
//!
//! Paste bytecode, then either walk it a boundary at a time or run it out. Every
//! opcode executes through `Instruction(spec).execute`, the same route the
//! production interpreter falls to for host-bound opcodes, so what this prints
//! is what the engine does.
//!
//! This is deliberately not an example of a public API: it imports the internal
//! session directly so the POC can be driven without exporting debugger
//! vocabulary from `evm.zig`.
//!
//! It stays at `src/` rather than under `src/debug/` because it is its own build
//! root: Zig scopes a module to its root source file's directory, and from
//! `src/debug/` the `../evm.zig` import is outside the module path.

const std = @import("std");
const evmz = @import("./evm.zig");
const session = @import("./debug/session.zig");

const Address = evmz.Address;
const Host = evmz.Host;
const Status = evmz.execution.Status;
const Executor = evmz.Evm.Executor;
const Driver = session.bind(Executor);
const instruction_spec = evmz.Evm.specification.instruction;
const disassemble = evmz.instruction.disassemble;

const Words = std.mem.TokenIterator(u8, .any);
const Hex = std.fmt.Alt([]const u8, formatHex);

const sender = evmz.addr(0x1111);
const recipient = evmz.addr(0x2222);
const default_gas: u63 = 1_000_000;

const usage =
    \\  load <hex> [--gas N] [--input HEX] [--run]  load root bytecode and arm a session
    \\  step [n]                                    execute n opcodes (default 1)
    \\  over                                        run the pending call out, back to here
    \\  out                                         run until the current frame returns
    \\  run                                         run to completion, dispatching calls
    \\  trace                                       run to completion, printing every boundary
    \\  sub [ok|revert|fail] [hex]                  resolve the pending call yourself
    \\  abort                                       abort the session, restoring child writes
    \\  disasm [hex]                                disassemble the active code, or given hex
    \\  stack                                       print the active stack, top first
    \\  mem                                         hexdump the active memory
    \\  storage <key> [address]                     read storage, default the active account
    \\  where                                       reprint the current boundary
    \\  reset                                       drop the session and its transaction
    \\  help / quit
    \\
    \\`step` at a pending call dispatches it, entering the child. `sub` resolves
    \\it from outside instead, which forfeits canonical authority for the rest of
    \\the run.
    \\
;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var executor = Executor.init(allocator, .{});
    defer executor.deinit();

    var out_buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writerStreaming(init.io, &out_buffer);

    var repl = Repl{
        .allocator = allocator,
        .out = &out.interface,
        .executor = &executor,
    };
    defer repl.unload();

    if (try initialCommand(init, allocator)) |command| {
        defer allocator.free(command);
        if (!try repl.dispatch(command)) return;
    }

    var in_buffer: [64 * 1024]u8 = undefined;
    var in = std.Io.File.stdin().readerStreaming(init.io, &in_buffer);
    while (true) {
        try repl.out.writeAll("evmz> ");
        try repl.out.flush();
        const line = try in.interface.takeDelimiter('\n') orelse break;
        if (!try repl.dispatch(line)) break;
    }
    try repl.out.writeAll("\n");
    try repl.out.flush();
}

/// Rejoin argv into one command line, so `evmz-debug 6001600101 --run` behaves
/// exactly like typing it. A leading non-command word is assumed to be bytecode.
fn initialCommand(init: std.process.Init, allocator: std.mem.Allocator) !?[]u8 {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var command: std.Io.Writer.Allocating = .init(allocator);
    defer command.deinit();
    var count: usize = 0;
    while (args.next()) |arg_z| : (count += 1) {
        const arg = arg_z[0..arg_z.len];
        if (count == 0 and Command.parse(arg) == null) try command.writer.writeAll("load ");
        if (count != 0) try command.writer.writeByte(' ');
        try command.writer.writeAll(arg);
    }
    if (count == 0) return null;
    return try command.toOwnedSlice();
}

const Command = enum {
    load,
    step,
    over,
    out,
    run,
    trace,
    sub,
    abort,
    disasm,
    stack,
    mem,
    storage,
    where,
    reset,
    help,
    quit,

    const aliases = .{
        .{ "l", Command.load },
        .{ "s", Command.step },
        .{ "n", Command.over },
        .{ "r", Command.run },
        .{ "d", Command.disasm },
        .{ "h", Command.help },
        .{ "?", Command.help },
        .{ "-h", Command.help },
        .{ "--help", Command.help },
        .{ "q", Command.quit },
        .{ "exit", Command.quit },
    };

    fn parse(word: []const u8) ?Command {
        inline for (aliases) |alias| {
            if (std.mem.eql(u8, word, alias[0])) return alias[1];
        }
        return std.meta.stringToEnum(Command, word);
    }
};

const Repl = struct {
    allocator: std.mem.Allocator,
    out: *std.Io.Writer,
    executor: *Executor,
    loaded: ?Loaded = null,

    /// One armed session plus everything it borrows. The driver must not move
    /// once initialized, so this is installed whole and dropped whole; it is
    /// never reassigned while a session is live.
    const Loaded = struct {
        bytecode: evmz.Bytecode,
        /// Borrowed by the root message for the life of the session.
        input: []u8,
        driver: Driver.Session,
        pause: session.Pause,
        /// The driver closed itself: finished, aborted, or dropped after an
        /// error. State stays readable, nothing advances.
        closed: bool,
    };

    /// Returns false when the session should end.
    fn dispatch(self: *Repl, line: []const u8) !bool {
        var words = std.mem.tokenizeAny(u8, line, " \t\r");
        const verb = words.next() orelse return true;
        const command = Command.parse(verb) orelse {
            try self.out.print("unknown command '{s}'; try help\n", .{verb});
            try self.out.flush();
            return true;
        };
        switch (command) {
            .help => try self.out.writeAll(usage),
            .quit => return false,
            .reset => self.unload(),
            .load => try self.load(&words),
            .disasm => try self.disasm(&words),
            .storage => try self.storage(&words),
            else => try self.advance(command, &words),
        }
        try self.out.flush();
        return true;
    }

    /// Every command that needs an armed session.
    fn advance(self: *Repl, command: Command, words: *Words) !void {
        if (self.loaded == null) return self.out.writeAll("no code loaded; try load <hex>\n");
        const loaded = &self.loaded.?;
        switch (command) {
            .step => {
                const count = parseInt(usize, words.next() orelse "1") orelse
                    return self.out.writeAll("step takes a count\n");
                for (0..count) |_| {
                    if (loaded.closed) break;
                    try self.stepOnce(loaded);
                }
            },
            .over => {
                const depth = depthOf(loaded.pause) orelse return self.out.writeAll("already finished\n");
                try self.runBelow(loaded, depth);
            },
            .out => {
                const depth = depthOf(loaded.pause) orelse return self.out.writeAll("already finished\n");
                if (depth == 0) return self.out.writeAll("already at the root frame; try run\n");
                try self.runBelow(loaded, depth - 1);
            },
            .run, .trace => while (!loaded.closed) {
                if (command == .trace) try self.printPause(loaded);
                try self.stepOnce(loaded);
            },
            .sub => return self.substitute(loaded, words),
            .abort => {
                if (loaded.closed) return self.out.writeAll("session already closed\n");
                loaded.driver.abort();
                loaded.closed = true;
                return self.out.writeAll("aborted: child writes restored, root attempt still the caller's\n");
            },
            .stack => return self.printStack(loaded),
            .mem => return self.printMemory(loaded),
            .where => {},
            else => unreachable,
        }
        try self.printPause(loaded);
    }

    fn load(self: *Repl, words: *Words) !void {
        const code_hex = words.next() orelse return self.out.writeAll("load takes bytecode hex\n");
        var gas = default_gas;
        var input_hex: []const u8 = "";
        var run_now = false;
        while (words.next()) |flag| {
            if (std.mem.eql(u8, flag, "--run")) {
                run_now = true;
            } else if (std.mem.eql(u8, flag, "--gas")) {
                // Bounded by the gas counter's own width, so the cast below and
                // the executor's i64 accounting can never trap.
                gas = parseInt(u63, words.next() orelse "") orelse
                    return self.out.writeAll("--gas takes a number under 2^63\n");
            } else if (std.mem.eql(u8, flag, "--input")) {
                input_hex = words.next() orelse "";
            } else {
                return self.out.print("unknown load flag '{s}'\n", .{flag});
            }
        }

        const code = self.parseHex(code_hex) catch return self.out.writeAll("bytecode is not hex\n");
        defer self.allocator.free(code);
        const input = self.parseHex(input_hex) catch return self.out.writeAll("--input is not hex\n");
        errdefer self.allocator.free(input);

        self.unload();
        try self.executor.beginTransaction(
            evmz.t.defaultExecutionContext(sender, gas),
            sender,
            recipient,
        );
        errdefer self.executor.discardStateTransition();

        self.loaded = .{
            .bytecode = try self.executor.prepareBytecode(code),
            .input = input,
            .driver = undefined,
            .pause = undefined,
            .closed = false,
        };
        const loaded = &self.loaded.?;
        errdefer {
            // A no-op if the driver never opened; otherwise it closes the
            // prepared-code scope before `discardStateTransition` demands it.
            loaded.driver.deinit();
            loaded.bytecode.deinit(self.allocator);
            self.loaded = null;
        }

        try loaded.driver.init(self.executor, .{
            .depth = 0,
            .kind = .call,
            .gas = @intCast(gas),
            .recipient = recipient,
            .sender = sender,
            .input_data = loaded.input,
            .value = 0,
            .code_address = recipient,
        }, loaded.bytecode.view());

        try self.settle(loaded, loaded.driver.pause());
        if (run_now) while (!loaded.closed) try self.stepOnce(loaded);
        try self.printPause(loaded);
    }

    fn unload(self: *Repl) void {
        if (self.loaded == null) return;
        const loaded = &self.loaded.?;
        // A no-op once the driver closed itself; otherwise it restores every
        // unresolved child checkpoint before the transaction goes.
        loaded.driver.deinit();
        loaded.bytecode.deinit(self.allocator);
        self.allocator.free(loaded.input);
        self.loaded = null;
        self.executor.discardStateTransition();
    }

    /// Advance one boundary: execute an opcode, or dispatch a pending call.
    ///
    /// The single chokepoint for touching a closed driver: after an abort the
    /// last pause still names an opcode the driver can no longer execute.
    fn stepOnce(self: *Repl, loaded: *Loaded) !void {
        if (loaded.closed) return;
        switch (loaded.pause) {
            .opcode => try self.settle(loaded, loaded.driver.step()),
            .action => try self.settle(loaded, loaded.driver.dispatchAction()),
            .finished => {},
        }
    }

    /// Advance until the session is back at `depth` or shallower.
    fn runBelow(self: *Repl, loaded: *Loaded, depth: u16) !void {
        try self.stepOnce(loaded);
        while (!loaded.closed) {
            if (depthOf(loaded.pause)) |current| {
                if (current <= depth) break;
            }
            try self.stepOnce(loaded);
        }
    }

    fn substitute(self: *Repl, loaded: *Loaded, words: *Words) !void {
        const action = switch (loaded.pause) {
            .action => |event| event.value,
            else => return self.out.writeAll("no pending call to substitute\n"),
        };
        const status: Status = blk: {
            const word = words.next() orelse break :blk .success;
            if (std.mem.eql(u8, word, "ok")) break :blk .success;
            if (std.mem.eql(u8, word, "revert")) break :blk .revert;
            if (std.mem.eql(u8, word, "fail")) break :blk .invalid;
            return self.out.writeAll("substitute status is ok, revert, or fail\n");
        };

        const output = self.parseHex(words.next() orelse "") catch
            return self.out.writeAll("substitute output is not hex\n");
        defer self.allocator.free(output);

        const result: Host.CallResult = .{
            .status = status,
            .output_data = output,
            // A hard failure burns the child's gas; success and revert return it.
            .gas_left = if (status == .invalid) 0 else switch (action) {
                .call => |call| call.continuation.gas_limit,
                .create => |create| create.continuation.gas_limit,
            },
            .gas_refund = 0,
        };
        try self.settle(loaded, loaded.driver.substituteAction(switch (action) {
            .call => Host.Result.fromCall(result),
            // The CREATE handler derived the address before suspending, so a
            // substituted create still deploys where the canonical one would.
            .create => |create| Host.Result.fromCreate(create.msg.recipient, result),
        }));
        try self.printPause(loaded);
    }

    /// Record a driver transition. A driver error leaves execution at no
    /// well-defined boundary, so the session is dropped rather than resumed.
    fn settle(self: *Repl, loaded: *Loaded, next: anyerror!session.Pause) !void {
        loaded.pause = next catch |err| {
            loaded.driver.deinit();
            loaded.closed = true;
            return self.out.print("driver error: {s}; session dropped\n", .{@errorName(err)});
        };
        if (loaded.pause == .finished) loaded.closed = true;
    }

    fn disasm(self: *Repl, words: *Words) !void {
        if (words.next()) |hex| {
            const code = self.parseHex(hex) catch return self.out.writeAll("not hex\n");
            defer self.allocator.free(code);
            return self.printDisassembly(code, null);
        }
        if (self.loaded == null) return self.out.writeAll("no code loaded; try disasm <hex>\n");
        const loaded = &self.loaded.?;
        if (loaded.closed) return self.printDisassembly(loaded.bytecode.bytes, null);
        try self.printDisassembly(loaded.driver.code(), switch (loaded.pause) {
            .opcode => |event| event.pc,
            else => null,
        });
    }

    fn storage(self: *Repl, words: *Words) !void {
        // Reads resolve against the state transition `load` opened, which stays
        // open until `reset` so writes remain visible after a run finishes.
        if (self.loaded == null) return self.out.writeAll("no code loaded; try load <hex>\n");
        const loaded = &self.loaded.?;
        const key = parseU256(words.next() orelse "") orelse
            return self.out.writeAll("storage takes a key\n");
        var account = recipient;
        if (words.next()) |word| {
            account = self.parseAddress(word) catch return self.out.writeAll("address is not 20 hex bytes\n");
        } else if (!loaded.closed) {
            account = loaded.driver.message().recipient;
        }
        try self.out.print("0x{f}[0x{x}] = 0x{x}\n", .{
            Hex{ .data = &account },
            key,
            try self.executor.getStorage(account, key),
        });
    }

    fn printPause(self: *Repl, loaded: *Loaded) !void {
        switch (loaded.pause) {
            .opcode => |event| {
                if (loaded.closed) return self.out.writeAll("session closed\n");
                var name_buffer: [24]u8 = undefined;
                const name = std.fmt.bufPrint(&name_buffer, "{f}", .{
                    instruction_spec.fmt(event.opcode),
                }) catch "UNKNOWN";
                // Signed values take no width spec: an explicit alignment makes
                // Zig print a leading `+`.
                try self.out.print("d{d} pc={x:0>4} {s:<10} gas={d} stack[{d}]", .{
                    event.site.depth,
                    event.pc,
                    name,
                    event.gas_left,
                    loaded.driver.stack().len,
                });
                try self.printStackSummary(loaded.driver.stack());
            },
            .action => |event| {
                if (loaded.closed) return self.out.writeAll("session closed\n");
                const msg = switch (event.value) {
                    .call => |call| call.msg,
                    .create => |create| create.msg,
                };
                try self.out.print("d{d} {s} -> 0x{f} gas={d} value={d} input={d}B  (step dispatches, sub replaces)\n", .{
                    event.site.depth,
                    @tagName(msg.kind),
                    Hex{ .data = &msg.recipient },
                    msg.gas,
                    msg.value,
                    msg.input_data.len,
                });
            },
            .finished => |completion| {
                const result = switch (completion) {
                    .canonical, .intervened => |value| value,
                };
                try self.out.print("finished {s}: {s} gas_left={d} output=0x{f}\n", .{
                    @tagName(completion),
                    @tagName(result.status()),
                    result.gasLeft(),
                    Hex{ .data = result.outputData() },
                });
            },
        }
    }

    fn printStackSummary(self: *Repl, values: []const u256) !void {
        const shown = @min(values.len, 4);
        for (0..shown) |offset| try self.out.print(" 0x{x}", .{values[values.len - 1 - offset]});
        if (shown != values.len) try self.out.writeAll(" ..");
        try self.out.writeAll("\n");
    }

    fn printStack(self: *Repl, loaded: *Loaded) !void {
        if (loaded.closed) return self.out.writeAll("session closed\n");
        const values = loaded.driver.stack();
        if (values.len == 0) return self.out.writeAll("stack empty\n");
        for (0..values.len) |offset| {
            try self.out.print("  {d:>2} 0x{x}\n", .{ offset, values[values.len - 1 - offset] });
        }
    }

    fn printMemory(self: *Repl, loaded: *Loaded) !void {
        if (loaded.closed) return self.out.writeAll("session closed\n");
        const bytes = loaded.driver.memory();
        if (bytes.len == 0) return self.out.writeAll("memory empty\n");
        var offset: usize = 0;
        while (offset < bytes.len) : (offset += 32) {
            try self.out.print("  {x:0>4}  {f}\n", .{
                offset,
                Hex{ .data = bytes[offset..@min(offset + 32, bytes.len)] },
            });
        }
    }

    fn printDisassembly(self: *Repl, code: []const u8, current_pc: ?usize) !void {
        if (code.len == 0) return self.out.writeAll("no code\n");
        var iterator = disassemble.iterate(instruction_spec, code);
        while (iterator.next()) |decoded| {
            const marker: []const u8 = if (current_pc == decoded.pc) "->" else "  ";
            try self.out.print("{s} {x:0>4}  {f}", .{
                marker,
                decoded.pc,
                instruction_spec.fmt(decoded.opcode),
            });
            if (decoded.immediate.len != 0) try self.out.print(" 0x{f}", .{Hex{ .data = decoded.immediate }});
            if (!decoded.active) try self.out.writeAll("  ; inactive in this fork");
            try self.out.writeAll("\n");
        }
    }

    fn parseHex(self: *Repl, text: []const u8) ![]u8 {
        const digits = if (std.mem.startsWith(u8, text, "0x")) text[2..] else text;
        if (digits.len % 2 != 0) return error.InvalidLength;
        const bytes = try self.allocator.alloc(u8, digits.len / 2);
        errdefer self.allocator.free(bytes);
        _ = try std.fmt.hexToBytes(bytes, digits);
        return bytes;
    }

    fn parseAddress(self: *Repl, text: []const u8) !Address {
        const bytes = try self.parseHex(text);
        defer self.allocator.free(bytes);
        if (bytes.len != @sizeOf(Address)) return error.InvalidLength;
        var address: Address = undefined;
        @memcpy(&address, bytes);
        return address;
    }
};

fn depthOf(pause: session.Pause) ?u16 {
    return switch (pause) {
        .opcode => |event| event.site.depth,
        .action => |event| event.site.depth,
        .finished => null,
    };
}

fn formatHex(bytes: []const u8, writer: *std.Io.Writer) std.Io.Writer.Error!void {
    for (bytes) |byte| try writer.print("{x:0>2}", .{byte});
}

fn parseInt(comptime T: type, text: []const u8) ?T {
    return std.fmt.parseInt(T, text, 10) catch null;
}

fn parseU256(text: []const u8) ?u256 {
    if (std.mem.startsWith(u8, text, "0x")) return std.fmt.parseInt(u256, text[2..], 16) catch null;
    return std.fmt.parseInt(u256, text, 10) catch null;
}
