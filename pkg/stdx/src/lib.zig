//! Domain-free extensions to the Zig standard library.
//!
//! Membership test: the code could plausibly live in `std`. It names no
//! Ethereum concept and encodes no execution rule. One mechanical rule keeps
//! that boundary honest — **`stdx` imports `std` and nothing else.** A utility
//! that needs an evmz, MPT, or RLP type is not a `stdx` utility; it belongs
//! with the domain that gives it meaning.
//!
//! `stdx` is internal. It is not exported under `-Dcore=false` and carries no
//! release compatibility promise, so callers inside this repository may move
//! with it.

const std = @import("std");
pub const ExactSlab = @import("ExactSlab.zig");
pub const ScopedArenaAllocator = @import("ScopedArenaAllocator.zig");
pub const range = @import("range.zig");
pub const Range = @import("range.zig").Range;

pub const no_growth_allocator: std.mem.Allocator = .{
    .ptr = undefined,
    .vtable = &.{
        .alloc = std.mem.Allocator.noAlloc,
        .resize = std.mem.Allocator.noResize,
        .remap = std.mem.Allocator.noRemap,
        .free = std.mem.Allocator.noFree,
    },
};
