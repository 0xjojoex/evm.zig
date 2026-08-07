const std = @import("std");
const evmz = @import("evmz");
const payload = @import("guest_payload_stateless_ere");

test "stateless ERE entry returns failure when input is unavailable" {
    try std.testing.expectEqual(@as(c_int, 1), payload.evmz_guest_entry());
    try std.testing.expect(payload.evmz_guest_error != 0);
}

test "stateless ERE payload emits canonical SSZ output" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);

    const expected = try evmz.stateless.wire.validateStatelessBytesReusable(std.testing.allocator, input);
    defer std.testing.allocator.free(expected);

    for (0..2) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const actual = try payload.runStatelessEreInput(arena.allocator(), input);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}

test "stateless ERE guest path releases malformed-input scratch" {
    const malformed = [_]u8{0};
    const expected = try evmz.stateless.wire.validateStatelessBytesReusable(std.testing.allocator, &malformed);
    defer std.testing.allocator.free(expected);

    for (0..2) |_| {
        var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer arena.deinit();
        const actual = try payload.runStatelessEreInput(arena.allocator(), &malformed);
        try std.testing.expectEqualSlices(u8, expected, actual);
    }
}
