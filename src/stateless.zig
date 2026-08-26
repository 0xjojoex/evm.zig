//! Everything specific to executing a block from a sealed witness rather than
//! from a client database. The generic lane is `evmz.state`.
//!
//! Two layers live here, and they sit on opposite sides of `evmz.Backend`:
//!
//! - the state lane — `WitnessReader`, `ParentFacts`, `BlockState`, `artifacts`,
//!   `commit`, `views` — depends only on the `state` vocabulary and is what
//!   `Backend` dispatches *to*;
//! - the driver — `validate`, `input`, `wire` — constructs a `Backend` and runs
//!   the transition, so it sits *above* it.
//!
//! The file-level graph stays acyclic: driver → `backend` → state lane. Nothing
//! in the state lane may import `backend`.
//!
//! The Ethereum block transition function itself lives in `eth.block_stf`.

const std = @import("std");

pub const WitnessReader = @import("./stateless/WitnessReader.zig");
pub const ParentFacts = @import("./stateless/ParentFacts.zig");
pub const BlockState = @import("./stateless/BlockState.zig");
pub const artifacts = @import("./stateless/artifacts.zig");
pub const commit = @import("./stateless/commit.zig");
pub const views = @import("./stateless/views.zig");

pub const Input = @import("./stateless/input.zig").Input;
pub const input = @import("./stateless/input.zig");
const validator = @import("./stateless/validate.zig");
pub const ValidationOptions = validator.Options;
pub const CommitOutput = validator.CommitOutput;
pub const Validator = validator.Validator;
pub const ValidatorWithOptions = validator.ValidatorWithOptions;
pub const RevisionValidator = validator.RevisionValidator;
pub const RevisionValidatorWithOptions = validator.RevisionValidatorWithOptions;
pub const testing = struct {
    pub const TrackedValidator = validator.TrackedValidator;
};
pub const wire = @import("./stateless/wire.zig");
pub const tx = @import("./stateless/tx.zig");

test {
    std.testing.refAllDecls(ParentFacts);
    std.testing.refAllDecls(BlockState);
    _ = @import("./stateless/BlockState_test.zig");
    _ = input;
    _ = validator;
    _ = wire;
    _ = tx;
    std.testing.refAllDecls(@This());
}
