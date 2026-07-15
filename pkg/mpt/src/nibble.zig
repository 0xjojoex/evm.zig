//! Nibble addressing and hex-prefix (compact) path encoding for trie keys.
//!
//! Keys are treated as big-endian nibble sequences (two nibbles per byte).
//! `Path` views a window of a key; `CompactPath` decodes the hex-prefix form
//! stored in leaf and extension nodes.

const errors = @import("error.zig");

/// A window of `len` nibbles into `key`, beginning at nibble `start`.
pub const Path = struct {
    key: []const u8,
    start: usize,
    len: usize,

    /// The nibble at `index` within the window.
    pub fn nibbleAt(self: Path, index: usize) u8 {
        return keyNibbleAt(self.key, self.start + index);
    }
};

/// A hex-prefix-encoded path decoded from a node, carrying whether it is
/// `terminal` (a leaf, ending at a value) or continues to a child (extension).
pub const CompactPath = struct {
    encoded: []const u8,
    nibble_offset: usize,
    len: usize,
    terminal: bool,

    /// Decode a hex-prefix path; errors on invalid flags or odd/even padding.
    pub fn decode(encoded: []const u8) errors.CodecError!CompactPath {
        if (encoded.len == 0) return error.InvalidCompactPath;
        const flags = encoded[0] >> 4;
        if (flags > 3) return error.InvalidCompactPath;

        const odd = (flags & 1) != 0;
        if (!odd and (encoded[0] & 0x0f) != 0) return error.InvalidCompactPath;
        const nibble_offset: usize = if (odd) 1 else 2;
        return .{
            .encoded = encoded,
            .nibble_offset = nibble_offset,
            .len = encoded.len * 2 - nibble_offset,
            .terminal = (flags & 2) != 0,
        };
    }

    /// Whether the whole path matches `key` starting at nibble `depth`.
    pub fn matchesKey(self: CompactPath, key: []const u8, depth: usize) bool {
        if (depth > keyNibbleLen(key) or self.len > keyNibbleLen(key) - depth) return false;
        for (0..self.len) |index| {
            if (self.nibbleAt(index) != keyNibbleAt(key, depth + index)) return false;
        }
        return true;
    }

    /// The nibble at `index` within the decoded path.
    pub fn nibbleAt(self: CompactPath, index: usize) u8 {
        const absolute = self.nibble_offset + index;
        const byte = self.encoded[absolute / 2];
        return if (absolute % 2 == 0) byte >> 4 else byte & 0x0f;
    }
};

/// Number of nibbles in `key` (two per byte).
pub fn keyNibbleLen(key: []const u8) usize {
    return key.len * 2;
}

/// The nibble at `index` in `key`, high nibble first.
pub fn keyNibbleAt(key: []const u8, index: usize) u8 {
    const byte = key[index / 2];
    return if (index % 2 == 0) byte >> 4 else byte & 0x0f;
}

/// Byte length of the hex-prefix encoding of a path of `path_len` nibbles.
pub fn compactLen(path_len: usize) usize {
    return 1 + path_len / 2;
}

/// Hex-prefix-encode `path` into `out`, flagged `terminal` for a leaf or not
/// for an extension. Returns the written slice.
pub fn encodeCompact(out: []u8, path: Path, terminal: bool) errors.BuildError![]const u8 {
    const encoded_len = compactLen(path.len);
    if (out.len < encoded_len) return error.WorkspaceTooSmall;

    const odd = path.len % 2 == 1;
    const flags: u8 = (@as(u8, @intFromBool(terminal)) << 1) |
        @as(u8, @intFromBool(odd));
    out[0] = flags << 4;

    var path_index: usize = 0;
    var out_index: usize = 1;
    if (odd) {
        out[0] |= path.nibbleAt(0);
        path_index = 1;
    }
    while (path_index < path.len) : ({
        path_index += 2;
        out_index += 1;
    }) {
        out[out_index] = (path.nibbleAt(path_index) << 4) |
            path.nibbleAt(path_index + 1);
    }
    return out[0..encoded_len];
}
