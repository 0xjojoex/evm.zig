const std = @import("std");
const smoke = @import("guest_payload_stateless_smoke");

test "stateless smoke payload runs root checker fixture" {
    const proof = try smoke.runStatelessSmoke(std.testing.allocator);
    try std.testing.expectEqual(.valid, proof.status);
    try std.testing.expectEqual(proof.gas_used, proof.block_gas_used);
    try std.testing.expect(proof.gas_used > 0);
    try std.testing.expect(proof.state_root_low != 0);
    try std.testing.expect(proof.transactions_root_low != 0);
    try std.testing.expect(proof.receipts_root_low != 0);
}
