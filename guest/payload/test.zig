const std = @import("std");
const guest_allocator = @import("guest_allocator");
const guest_options = @import("guest_options");

test {
    _ = @import("basic_test.zig");
    _ = @import("stateless_ere_test.zig");
}

test "native fixed buffer follows configured heap capacity" {
    try std.testing.expectEqual(guest_options.heap_bytes, guest_allocator.fixedBuffer().len);
}
