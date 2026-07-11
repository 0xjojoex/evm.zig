const std = @import("std");
const evmz = @import("evmz");
const payload = @import("guest_payload_stateless_ere");

test "stateless ERE payload hashes external input" {
    const input = try evmz.stateless.wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);

    const result = try payload.runStatelessEreInput(std.testing.allocator, input);
    const expected = try evmz.stateless.ere.validateStatelessPublicValues(std.testing.allocator, input);
    try std.testing.expectEqualSlices(u8, &expected, &result.public_values);
}
