//! One process boundary for evmz's native execution tools.
const std = @import("std");
const t8n = @import("t8n");
const statetest = @import("statetest");
const blocktest = @import("blocktest");
const debug = @import("debug");

const Command = enum { t8n, statetest, blocktest, debug };
const usage =
    \\usage: evmz <command> [options]
    \\
    \\  t8n        Apply transactions to alloc/environment inputs
    \\  statetest  Observe a General State Test vector
    \\  blocktest  Observe encoded-block acceptance and committed state
    \\  debug      Inspect execution interactively or run one debugger command
    \\
    \\  evmz help <command>   Show command options
    \\  evmz --version        Show the binary version
    \\
;

pub fn main(init: std.process.Init) void {
    var args = init.minimal.args.iterateAllocator(init.arena.allocator()) catch |err| fail(null, err);
    defer args.deinit();
    _ = args.next();
    const first = args.next() orelse {
        print(init.io, usage) catch |err| fail(null, err);
        return;
    };
    if (std.mem.eql(u8, first, "--version")) {
        version(init.io) catch |err| fail(null, err);
        return;
    }
    const help = std.mem.eql(u8, first, "help");
    if (std.mem.eql(u8, first, "--help") or std.mem.eql(u8, first, "-h")) {
        print(init.io, usage) catch |err| fail(null, err);
        return;
    }
    const name = if (help) args.next() orelse {
        print(init.io, usage) catch |err| fail(null, err);
        return;
    } else first;
    const command = std.meta.stringToEnum(Command, name) orelse {
        std.debug.print("evmz: unknown command '{s}'; use evmz --help\n", .{name});
        std.process.exit(1);
    };
    var scan = args;
    while (scan.next()) |arg| {
        if (std.mem.eql(u8, arg, "--")) break;
        if (std.mem.eql(u8, arg, "--version")) {
            version(init.io) catch |err| fail(command, err);
            return;
        }
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            print(init.io, commandUsage(command)) catch |err| fail(command, err);
            return;
        }
    }
    if (help) {
        print(init.io, commandUsage(command)) catch |err| fail(command, err);
        return;
    }
    (switch (command) {
        .t8n => t8n.run(init, &args),
        .statetest => statetest.run(init, &args),
        .blocktest => blocktest.run(init, &args),
        .debug => debug.run(init, &args),
    }) catch |err| fail(command, err);
}

fn commandUsage(command: Command) []const u8 {
    return switch (command) {
        .t8n => t8n.usage,
        .statetest => statetest.usage,
        .blocktest => blocktest.usage,
        .debug => "usage: evmz debug [command] [-x | --exit]\n\n" ++ debug.usage,
    };
}

fn print(io: std.Io, text: []const u8) !void {
    var buffer: [4096]u8 = undefined;
    var out = std.Io.File.stdout().writer(io, &buffer);
    try out.interface.writeAll(text);
    try out.interface.flush();
}

fn version(io: std.Io) !void {
    try print(io, "evmz 0.0.0 (zig " ++ @import("builtin").zig_version_string ++ ")\n");
}

fn fail(command: ?Command, err: anyerror) noreturn {
    std.debug.print("evmz{s}: {s}\n", .{ if (command) |value| switch (value) {
        .t8n => " t8n",
        .statetest => " statetest",
        .blocktest => " blocktest",
        .debug => " debug",
    } else "", @errorName(err) });
    std.process.exit(if (command == .t8n) t8n.exitCode(err) else 1);
}
