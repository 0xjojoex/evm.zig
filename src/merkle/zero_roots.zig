//! Typed view over the canonical SHA-256 zero-subtree roots.
//! Using static embedding to reduce the complication time.
//! generate with `zig run tools/generate-zero-roots.zig -- src/merkle/zero_roots.bin`.

const std = @import("std");

pub const Root = [32]u8;
pub const count = 256;

const bytes = @embedFile("zero_roots.bin");

comptime {
    if (bytes.len != count * @sizeOf(Root)) {
        @compileError("invalid embedded SSZ zero-root table");
    }
}

pub const roots: []const Root = std.mem.bytesAsSlice(Root, bytes[0..bytes.len]);
