//! Operation-specific MPT error sets.

const rlp = @import("rlp");

pub const InputError = error{
    DuplicateKey,
    EmptyValue,
    UnsortedKeys,
};

pub const CodecError = rlp.ParseError || error{
    InvalidCompactPath,
    InvalidNode,
    InvalidNodeReference,
    NonCanonicalNode,
};

pub const WitnessError = error{
    ConflictingNode,
    MissingNode,
};

pub const ResourceError = error{
    ResourceLimitExceeded,
    WorkspaceTooSmall,
};

pub const BuildError = InputError || ResourceError;
pub const IndexError = error{ConflictingNode};
pub const LookupError = CodecError || error{ MissingNode, ResourceLimitExceeded };
pub const UpdateError = InputError || CodecError || error{ MissingNode, ResourceLimitExceeded };

/// Compatibility umbrella for callers which intentionally handle every MPT
/// failure at one boundary. Public operations expose the narrower sets above.
pub const Error = BuildError || IndexError || LookupError || UpdateError;
