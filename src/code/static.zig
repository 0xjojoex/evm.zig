//! Compile-time construction of immutable execution-ready bytecode views.
//!
//! This module is internal to protocol-constant artifacts. Runtime bytecode
//! preparation keeps the faster scalar scanner.

const std = @import("std");
const Bytecode = @import("Bytecode.zig");
const Opcode = @import("../opcode.zig").Opcode;
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
        result.needs_action_loop = analyzeLinear(source, &result.masks);
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

fn analyzeLinear(bytes: []const u8, masks: []usize) bool {
    @memset(masks, 0);
    var needs_action_loop = false;
    var pc: usize = 0;
    while (pc < bytes.len) {
        const opcode: Opcode = @enumFromInt(bytes[pc]);
        if (opcode == .JUMPDEST) {
            const shift: std.math.Log2Int(usize) = @truncate(pc);
            masks[pc / @bitSizeOf(usize)] |= @as(usize, 1) << shift;
        }
        needs_action_loop = needs_action_loop or
            scanner.isActionBoundaryOpcode(bytes[pc]);

        var next = pc + 1;
        if (opcode.isPushN()) next += opcode.toByte() - Opcode.PUSH0.toByte();
        pc = @min(bytes.len, next);
    }
    return needs_action_loop;
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
    var runtime = try Bytecode.prepare(std.testing.allocator, &raw);
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

test "linear static analysis agrees with runtime scanner" {
    var masks: [2]usize = undefined;

    for (0..256) |byte| {
        const raw = [_]u8{@intCast(byte)};
        try expectLinearMatchesRuntime(&raw, &masks);
    }

    var prng = std.Random.DefaultPrng.init(0x5354_4154_4943);
    const random = prng.random();
    var raw: [128]u8 = undefined;
    for (0..512) |iteration| {
        random.bytes(&raw);
        const len = iteration % (raw.len + 1);
        try expectLinearMatchesRuntime(raw[0..len], &masks);
    }
}

fn expectLinearMatchesRuntime(bytes: []const u8, masks: []usize) !void {
    const needs_action_loop = analyzeLinear(bytes, masks);
    var runtime = try Bytecode.prepare(std.testing.allocator, bytes);
    defer runtime.deinit(std.testing.allocator);

    try std.testing.expectEqual(runtime.needs_action_loop, needs_action_loop);
    const mask_count = std.math.divCeil(
        usize,
        bytes.len,
        @bitSizeOf(usize),
    ) catch unreachable;
    try std.testing.expectEqualSlices(
        usize,
        runtime.jumpdests.bits.masks[0..mask_count],
        masks[0..mask_count],
    );
}
