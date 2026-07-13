//! Stateless validation and adapter surface.
//!
//! The Ethereum block transition function lives in `eth.block_stf`; this module
//! owns normalized stateless validation plus wire and runtime adapters.

pub const Input = @import("./stateless/input.zig").Input;
pub const input = @import("./stateless/input.zig");
const validator = @import("./stateless/validate.zig");
pub const validate = validator.validate;
pub const validateWithTrace = validator.validateWithTrace;
pub const wire = @import("./stateless/wire.zig");
pub const ere = @import("./stateless/ere.zig");
pub const tx = @import("./stateless/tx.zig");

test {
    _ = input;
    _ = validator;
    _ = wire;
    _ = ere;
    _ = tx;
}
