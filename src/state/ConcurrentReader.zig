//! State reader capability safe for overlapping calls.
//!
//! This is a concurrency contract, not synchronization machinery. The backing
//! snapshot must not mutate or be destroyed while any copied handle is in use,
//! and every borrowed slice returned by `Reader.loadCode` must remain stable for
//! that complete lifetime. Concrete backends should expose this only after they
//! can uphold those guarantees; external adapters may opt in explicitly.

const Reader = @import("Reader.zig");

const ConcurrentReader = @This();

value: Reader,

/// Assert that `value` and its borrowed results are safe for overlapping reads
/// until the caller ends the concurrent lifetime.
pub fn initAssumeSafe(value: Reader) ConcurrentReader {
    return .{ .value = value };
}

pub fn reader(self: ConcurrentReader) Reader {
    return self.value;
}

test "concurrent reader preserves the wrapped interface" {
    const wrapped = Reader.empty();
    const concurrent = ConcurrentReader.initAssumeSafe(wrapped);

    try @import("std").testing.expectEqual(wrapped.ptr, concurrent.reader().ptr);
    try @import("std").testing.expectEqual(wrapped.vtable, concurrent.reader().vtable);
}
