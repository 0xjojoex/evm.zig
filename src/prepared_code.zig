//! Prepared execution artifacts and caller-owned backend implementations.

const std = @import("std");

pub const Backend = @import("./prepared_code/Backend.zig");
pub const PreparationKey = Backend.PreparationKey;
pub const Execution = @import("./prepared_code/Execution.zig");
pub const InMemoryPreparedPool = @import("./prepared_code/InMemoryPreparedPool.zig");

test {
    std.testing.refAllDecls(@This());
}
