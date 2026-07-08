//! Bytecode container, jumpdest analysis, and code scanning.

const std = @import("std");

pub const Bytecode = @import("./code/Bytecode.zig");
pub const JumpDestMap = @import("./code/JumpDestMap.zig");
pub const scanner = @import("./code/scanner.zig");

test {
    std.testing.refAllDecls(@This());
}
