//! Node-hash type, the canonical empty-trie root, and the hash-context contract.

const std = @import("std");

/// A 32-byte node hash, also used as a trie root.
pub const Root = [32]u8;

/// Root of the empty trie: `keccak256(rlp(""))`.
pub const empty_root = [_]u8{
    0x56, 0xe8, 0x1f, 0x17, 0x1b, 0xcc, 0x55, 0xa6,
    0xff, 0x83, 0x45, 0xe6, 0x92, 0xc0, 0xf8, 0x6e,
    0x5b, 0x48, 0xe0, 0x1b, 0x99, 0x6c, 0xad, 0xc0,
    0x01, 0x62, 0x2f, 0xb5, 0xe3, 0x63, 0xb4, 0x21,
};

/// Default Keccak-256 execution context backed by std.
pub const StdKeccak256Context = struct {
    pub fn keccak256(_: @This(), input: []const u8) Root {
        var output: Root = undefined;
        std.crypto.hash.sha3.Keccak256.hash(input, &output, .{});
        return output;
    }
};

/// Compile-time check for the fixed Keccak-256 execution-provider contract.
pub fn assertKeccakContext(comptime Context: type) void {
    if (!std.meta.hasFn(Context, "keccak256")) {
        @compileError("MPT Keccak context must provide keccak256(self, []const u8) [32]u8");
    }
}
