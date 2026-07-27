const std = @import("std");
const evmz = @import("evmz");
const payload = @import("guest_payload_stateless_ere");

test "stateless ERE payload emits canonical SSZ output" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);

    const actual = try payload.runStatelessEreInput(std.testing.allocator, input);
    defer std.testing.allocator.free(actual);
    const expected = try evmz.stateless.wire.validateStatelessBytes(std.testing.allocator, input);
    defer std.testing.allocator.free(expected);
    try std.testing.expectEqualSlices(u8, expected, actual);
}
