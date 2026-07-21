//! Stateless compatibility alias for the canonical raw transaction decoder.

const raw = @import("../transaction/raw.zig");

pub const Error = raw.Error;
pub const decodeRaw = raw.decodeRaw;

test {
    _ = raw;
}
