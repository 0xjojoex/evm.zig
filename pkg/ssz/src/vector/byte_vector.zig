const fixed = @import("../basic/fixed.zig");

/// Return the inline codec for SSZ `ByteVector[length]`.
pub fn ByteVector(comptime length: usize) type {
    if (length == 0) @compileError("SSZ byte vectors cannot be empty");
    return fixed.Fixed([length]u8);
}
