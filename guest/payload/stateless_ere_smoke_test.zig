const std = @import("std");
const smoke = @import("guest_payload_stateless_ere_smoke");

test "stateless ERE smoke emits canonical output metadata" {
    const proof = try smoke.runStatelessEreSmoke(std.testing.allocator);
    try std.testing.expect(proof.successful_validation);
    try std.testing.expect(proof.output_len > 0);
}
