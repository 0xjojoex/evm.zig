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
    const Analysis = struct {
        masks: [mask_count]usize,
        needs_action_loop: bool,
    };
    const analysis: Analysis = analysis: {
        @setEvalBranchQuota(20_000);
        var result = Analysis{
            .masks = [_]usize{0} ** mask_count,
            .needs_action_loop = false,
        };
        result.needs_action_loop = scanner.markJumpDests(&result.masks, source);
        break :analysis result;
    };

    return struct {
        pub const read_bytes = source[0..source.len].* ++
            [_]u8{0} ** Bytecode.zero_padding_len;
        pub const view = Bytecode.View{
            .bytes = read_bytes[0..source.len],
            .jumpdest_masks = &analysis.masks,
            .needs_action_loop = analysis.needs_action_loop,
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
    try std.testing.expectEqual(
        runtime.needs_action_loop,
        Prepared.view.needs_action_loop,
    );
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
