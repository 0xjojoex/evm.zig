const std = @import("std");
const evmz = @import("../evm.zig");
const opcode_info = @import("../opcode.zig");

const Opcode = evmz.Opcode;
const OpInfo = evmz.OpcodeInfo;

pub const BuiltinHandler = Opcode;
pub const CustomHandler = type;

pub const ExecutionTarget = union(enum) {
    invalid,
    builtin: BuiltinHandler,
    custom: CustomHandler,
};

pub const ExecutionOverride = union(enum) {
    inherit,
    invalid,
    builtin: BuiltinHandler,
    custom: CustomHandler,
};

pub fn defaultTargetByte(comptime opcode_byte: u8) ExecutionTarget {
    const info = opcode_info.info(opcode_byte);
    return defaultTargetForInfoByte(opcode_byte, info);
}

pub fn defaultTargetForInfoByte(comptime opcode_byte: u8, comptime info: OpInfo) ExecutionTarget {
    if (!info.defined) return .invalid;

    const opcode: Opcode = @enumFromInt(opcode_byte);
    return switch (opcode) {
        .INVALID => .invalid,
        else => .{ .builtin = opcode },
    };
}

pub fn applyOverride(comptime default_target: ExecutionTarget, comptime override: ExecutionOverride) ExecutionTarget {
    assertValidOverride(override);
    return switch (override) {
        .inherit => default_target,
        .invalid => .invalid,
        .builtin => |handler| .{ .builtin = handler },
        .custom => |handler| .{ .custom = handler },
    };
}

pub fn assertValidOverride(comptime override: ExecutionOverride) void {
    switch (override) {
        .custom => |handler| assertValidCustomHandler(handler),
        else => {},
    }
}

pub fn assertValidTarget(comptime target: ExecutionTarget) void {
    switch (target) {
        .custom => |handler| assertValidCustomHandler(handler),
        else => {},
    }
}

fn assertValidCustomHandler(comptime Handler: type) void {
    if (!std.meta.hasFn(Handler, "execute")) {
        @compileError("custom execution handler must declare execute");
    }
}

test "execution overrides resolve from inherited builtin target" {
    const Handler = struct {
        pub fn execute() void {}
    };

    const inherited = defaultTargetByte(@intFromEnum(Opcode.ADD));
    try std.testing.expectEqual(ExecutionTarget{ .builtin = .ADD }, inherited);

    const custom = applyOverride(inherited, .{ .custom = Handler });
    switch (custom) {
        .custom => |Resolved| try std.testing.expect(Resolved == Handler),
        else => return error.ExpectedCustomTarget,
    }

    try std.testing.expectEqual(ExecutionTarget.invalid, applyOverride(inherited, .invalid));
    try std.testing.expectEqual(inherited, applyOverride(inherited, .inherit));
}

test "undefined and invalid bytes default to invalid execution" {
    try std.testing.expectEqual(ExecutionTarget.invalid, defaultTargetByte(0x0c));
    try std.testing.expectEqual(ExecutionTarget.invalid, defaultTargetByte(@intFromEnum(Opcode.INVALID)));
}
