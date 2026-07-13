const std = @import("std");

/// Default canonical SSZ SHA-256 implementation.
pub const StdSha256Context = struct {
    pub fn hash64(_: @This(), input: *const [64]u8) [32]u8 {
        var output: [32]u8 = undefined;
        std.crypto.hash.sha2.Sha256.hash(input, &output, .{});
        return output;
    }
};

/// Reject hash providers that do not expose the SSZ `hash64` operation.
pub fn assertHashContext(comptime Context: type) void {
    if (!std.meta.hasFn(Context, "hash64")) {
        @compileError("SSZ hash context must provide hash64(self, *const [64]u8) [32]u8");
    }
}
