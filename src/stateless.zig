//! Executing a block from a sealed witness rather than from a client database.
//!
//! "Stateless" is a property of the driver, not of the execution state: both
//! execution-state lanes — `evmz.state.OpenState` and `evmz.eth.bal.ClosedState`
//! — run from a witness through `evmz.Backend`. Two layers live here, on
//! opposite sides of that backend:
//!
//! - `WitnessReader` is the witness-backed backend implementation `Backend`
//!   dispatches *to*; it imports the state lanes and never `backend`;
//! - the driver — `validate`, `input`, `wire` — constructs a `Backend` and runs
//!   the transition, so it sits *above* it.
//!
//! The Ethereum block transition function itself lives in `eth.block_stf`.

const std = @import("std");
const builtin = @import("builtin");

pub const WitnessReader = @import("./stateless/WitnessReader.zig");

pub const Input = @import("./stateless/input.zig").Input;
pub const input = @import("./stateless/input.zig");
const validator = @import("./stateless/validate.zig");
pub const ValidationOptions = validator.Options;
pub const CompileOptions = validator.CompileOptions;
pub const CommitOutput = validator.CommitOutput;
pub const Validator = validator.Validator;
pub const ValidatorWithOptions = validator.ValidatorWithOptions;
pub const RevisionValidator = validator.RevisionValidator;
pub const RevisionValidatorWithOptions = validator.RevisionValidatorWithOptions;
/// Test-only validator variants. Exists only in test builds and is not part
/// of the package's API.
pub const testing = if (builtin.is_test) struct {
    pub const TrackedValidator = validator.TrackedValidator;
} else @compileError("evmz.stateless.testing only exists in test builds");
pub const wire = @import("./stateless/wire.zig");
pub const tx = @import("./stateless/tx.zig");

test {
    _ = input;
    _ = validator;
    _ = wire;
    _ = tx;
    std.testing.refAllDecls(@This());
}
