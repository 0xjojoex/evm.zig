//! The `evmz-eest` CLI. Every fixture runner is a subcommand under `cmd/`,
//! and each `zig build <step>` alias forwards to one of them.
//!
//! The SSZ conformance runner and the ERE benchmark runner stay separate
//! executables: the first builds without evmz, the second builds at its own
//! optimize mode.

const std = @import("std");

const commands = struct {
    pub const statetest = @import("cmd/statetest.zig");
    pub const blocktest = @import("cmd/blocktest.zig");
    pub const zkevmtest = @import("cmd/zkevmtest.zig");
    pub const zkevm = @import("cmd/zkevm.zig");
    pub const @"zkevm-mutations" = @import("cmd/zkevm_mutations.zig");
    pub const @"zkevm-input" = @import("cmd/zkevm_input.zig");
    pub const @"zkevm-ere" = @import("cmd/zkevm_ere.zig");
};

pub fn main(init: std.process.Init) !void {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
    defer args.deinit();
    _ = args.next();

    const name_z = args.next() orelse {
        printUsage();
        return error.MissingCommand;
    };
    const name = name_z[0..name_z.len];
    if (std.mem.eql(u8, name, "--help") or std.mem.eql(u8, name, "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, name, "--version")) {
        var buffer: [128]u8 = undefined;
        var stdout = std.Io.File.stdout().writerStreaming(init.io, &buffer);
        try stdout.interface.print("evmz-eest 0.0.0 (zig {s})\n", .{@import("builtin").zig_version_string});
        try stdout.interface.flush();
        return;
    }

    inline for (@typeInfo(commands).@"struct".decls) |decl| {
        if (std.mem.eql(u8, decl.name, name)) {
            return @field(commands, decl.name).run(init, &args);
        }
    }

    std.debug.print("unknown command '{s}'\n\n", .{name});
    printUsage();
    return error.UnknownCommand;
}

fn printUsage() void {
    std.debug.print("usage: evmz-eest <command> [options] [path ...]\n\ncommands:\n", .{});
    inline for (@typeInfo(commands).@"struct".decls) |decl| {
        std.debug.print("  {s:<22} {s}\n", .{ decl.name, @field(commands, decl.name).about });
    }
    std.debug.print("\nRun `evmz-eest <command> --help` for command options.\n", .{});
}

test {
    inline for (@typeInfo(commands).@"struct".decls) |decl| {
        _ = @field(commands, decl.name);
    }
}
