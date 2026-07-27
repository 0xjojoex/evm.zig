//! Stable infrastructure failures exposed above the reusable executor.
//!
//! Executor internals deliberately accept type-erased state, capture, prepared-
//! code, and precompile providers. Their arbitrary errors are normalized to
//! `InfrastructureFailure`; native failures keep their useful names. State
//! readers get one strategy-failure signal and retain provider detail locally.
//! Lifecycle misuse is asserted at its owning boundary and capture/trace
//! lifecycle errors remain local to those APIs.

pub const Error = error{
    InfrastructureFailure,
    OutOfMemory,

    StateReaderStrategyFailure,

    TraceCapacityExceeded,
    TraceIndexOverflow,

    BalanceOverflow,
    CodeHashMismatch,
    CodeUnavailable,
    InvalidPrecompileOutput,
    InvalidWitness,
    NotImplemented,
    SystemCallFailed,
};

pub fn normalize(err: anyerror) Error {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,

        error.BlockAccessListAccountNotCovered,
        error.BlockAccessListStorageNotCovered,
        error.FoldedStateStorageUnknown,
        error.PositionedAccountUnknown,
        error.PositionedStorageUnknown,
        => error.StateReaderStrategyFailure,

        error.TraceCapacityExceeded => error.TraceCapacityExceeded,
        error.TraceIndexOverflow => error.TraceIndexOverflow,

        error.BalanceOverflow => error.BalanceOverflow,
        error.CodeHashMismatch => error.CodeHashMismatch,
        error.CodeUnavailable => error.CodeUnavailable,
        error.InvalidPrecompileOutput => error.InvalidPrecompileOutput,
        error.InvalidWitness => error.InvalidWitness,
        error.NotImplemented => error.NotImplemented,
        error.SystemCallFailed => error.SystemCallFailed,
        else => error.InfrastructureFailure,
    };
}

test "normalization preserves bounded capture failures and contains provider errors" {
    const testing = @import("std").testing;
    const capture_failures = [_]anyerror{
        error.TraceCapacityExceeded,
        error.TraceIndexOverflow,
    };
    for (capture_failures) |failure| {
        try testing.expectEqualStrings(@errorName(failure), @errorName(normalize(failure)));
    }

    const state_reader_strategy_failures = [_]anyerror{
        error.BlockAccessListAccountNotCovered,
        error.BlockAccessListStorageNotCovered,
        error.FoldedStateStorageUnknown,
        error.PositionedAccountUnknown,
        error.PositionedStorageUnknown,
    };
    for (state_reader_strategy_failures) |failure| {
        try testing.expectEqual(error.StateReaderStrategyFailure, normalize(failure));
    }
    try testing.expectEqual(error.InfrastructureFailure, normalize(error.ProviderSpecificFailure));
}
