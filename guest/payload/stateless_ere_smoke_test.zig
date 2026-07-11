const std = @import("std");
const smoke = @import("guest_payload_stateless_ere_smoke");

test "stateless ERE smoke emits sha256 public values" {
    const proof = try smoke.runStatelessEreSmoke(std.testing.allocator);
    try std.testing.expect(proof.successful_validation);
    try std.testing.expect(proof.output_len > 0);
    try std.testing.expect(!std.mem.allEqual(u8, &proof.public_values, 0));
}
