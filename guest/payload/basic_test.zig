const std = @import("std");
const basic = @import("guest_payload_basic");

test "basic payload runs repo VM fixture" {
    const proof = try basic.runBasicFixture(std.testing.allocator);
    try std.testing.expectEqual(basic.ProofStatus.success, proof.status);
    try std.testing.expectEqual(@as(u32, 32), proof.output_len);
    try std.testing.expectEqual(@as(u32, 42), proof.return_word_low);
    try std.testing.expectEqual(@as(u32, 42), proof.storage_slot0_low);
    try std.testing.expect(proof.gas_used > 0);
}
