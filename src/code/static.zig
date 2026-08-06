//! Compile-time construction of immutable execution-ready bytecode views.
//!
//! This module is internal to protocol-constant artifacts. It runs the same
//! scan as runtime preparation, at comptime.

const std = @import("std");
const Bytecode = @import("Bytecode.zig");
const scanner = @import("scanner.zig");
const t = @import("../t.zig");

pub fn View(comptime source: []const u8) type {
    const mask_count = @max(1, std.math.divCeil(
        usize,
        source.len,
        @bitSizeOf(usize),
    ) catch unreachable);
    const masks: [mask_count]usize = masks: {
        @setEvalBranchQuota(20_000);
        var result = [_]usize{0} ** mask_count;
        scanner.markJumpDestWords(&result, source);
        break :masks result;
    };

    return struct {
        pub const read_bytes = source[0..source.len].* ++
            [_]u8{0} ** Bytecode.zero_padding_len;
        pub const view = Bytecode.View{
            .bytes = read_bytes[0..source.len],
            .jumpdest_masks = &masks,
        };
    };
}

test "static view matches runtime preparation" {
    const raw = comptime t.bytecode(.{
        .PUSH2,
        .JUMPDEST,
        .CALL,
        .JUMPDEST,
        .PUSH1,
        .STATICCALL,
        .STOP,
    });
    const Prepared = View(&raw);
    var runtime = try Bytecode.init(std.testing.allocator, &raw);
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectEqualSlices(u8, &raw, Prepared.view.bytes);
    const mask_count = std.math.divCeil(
        usize,
        raw.len,
        @bitSizeOf(usize),
    ) catch unreachable;
    try std.testing.expectEqualSlices(
        usize,
        runtime.jumpdests.bits.masks[0..mask_count],
        Prepared.view.jumpdest_masks[0..mask_count],
    );
    try std.testing.expectEqualSlices(
        u8,
        &([_]u8{0} ** Bytecode.zero_padding_len),
        Prepared.read_bytes[raw.len..],
    );
}
