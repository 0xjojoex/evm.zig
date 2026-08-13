//! Operand-byte decoding for opcodes that carry an immediate.
//!
//! PUSH immediates are read straight from the code stream; these are the
//! encodings that need arithmetic. Both reject the JUMPDEST and PUSH byte
//! ranges so an immediate can never alias a real opcode ([EIP-8024]).
//!
//! [EIP-8024]: https://eips.ethereum.org/EIPS/eip-8024

/// Stack depth addressed by a DUPN or SWAPN immediate.
pub fn decodeDepthImmediate(x: u8) ?usize {
    if (x > 90 and x < 128) return null;
    return (@as(usize, x) + 145) % 256;
}

/// The two stack positions addressed by an EXCHANGE immediate.
pub fn decodeExchangeImmediate(x: u8) ?struct { usize, usize } {
    if (x > 81 and x < 128) return null;

    const k = x ^ 143;
    const q: usize = k >> 4;
    const r: usize = k & 0x0f;
    if (q < r) {
        return .{ q + 1, r + 1 };
    }
    return .{ r + 1, 29 - q };
}
