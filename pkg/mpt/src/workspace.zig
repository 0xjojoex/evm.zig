//! Advanced caller-owned scratch buffer for exact reuse across trie operations.

/// Advanced scratch memory for one trie operation. Primary APIs use the
/// allocator retained by `Trie`. Back this with a buffer sized by
/// `rootWorkspaceSize`. Each operation resets it, so a
/// workspace can be reused sequentially but not shared across concurrent calls.
pub const Workspace = struct {
    buffer: []u8,
    /// High-water mark of bytes used by the most recent operation.
    peak_used_bytes: usize = 0,

    /// Wrap `buffer` as a workspace.
    pub fn init(buffer: []u8) Workspace {
        return .{ .buffer = buffer };
    }

    /// Clear the usage high-water mark; called at the start of each operation.
    pub fn reset(self: *Workspace) void {
        self.peak_used_bytes = 0;
    }

    /// Total size of the backing buffer in bytes.
    pub fn capacity(self: Workspace) usize {
        return self.buffer.len;
    }
};
