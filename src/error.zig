pub const Error = error{
    BufferTooSmall,
    EncodedLengthOverflow,
    InvalidBitlistDelimiter,
    InvalidBitvectorPadding,
    InvalidBoolean,
    InvalidByteLength,
    InvalidFirstOffset,
    InvalidEnumValue,
    InvalidUnionSelector,
    ListLimitExceeded,
    OffsetOutOfBounds,
    OffsetsNotMonotonic,
};
