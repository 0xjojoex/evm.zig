const std = @import("std");
const smoke = @import("guest_payload_stateless_ssz_smoke");

test "stateless SSZ smoke payload runs schema-prefixed ABI" {
    const proof = try smoke.runStatelessSszSmoke(std.testing.allocator);
    try std.testing.expect(proof.successful_validation);
    try std.testing.expect(proof.output_len > 0);
    try std.testing.expect(proof.payload_root_low != 0);
    try std.testing.expectEqual(@as(u32, 1), proof.chain_id_low);
    try std.testing.expectEqual(@as(u32, 13), proof.fork);
}
