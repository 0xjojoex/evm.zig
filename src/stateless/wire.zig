//! Versioned stateless guest wire contracts.

pub const v1 = @import("./wire/v1.zig");
const v1_smoke = @import("./wire/v1_smoke.zig");

pub const Error = v1.Error;
pub const schema_id = v1.schema_id;
pub const schema_id_size = v1.schema_id_size;
pub const ValidationOptions = v1.ValidationOptions;
pub const StatelessInput = v1.StatelessInput;
pub const StatelessValidationResult = v1.StatelessValidationResult;

pub const validateStatelessBytes = v1.validateStatelessBytes;
pub const validateStatelessBytesWithOptions = v1.validateStatelessBytesWithOptions;
pub const validateStatelessStatusBytes = v1.validateStatelessStatusBytes;
pub const validateStatelessResultBytes = v1.validateStatelessResultBytes;
pub const validateStatelessResultBytesWithOptions = v1.validateStatelessResultBytesWithOptions;
pub const validateStatelessResultBytesWithTrace = v1.validateStatelessResultBytesWithTrace;
pub const validateStatelessResultBytesWithTraceAndOptions = v1.validateStatelessResultBytesWithTraceAndOptions;
pub const smokeInput = v1_smoke.smokeInput;
pub const smokeInputBytes = v1_smoke.smokeInputBytes;

test {
    _ = v1;
    _ = @import("./wire/v1_test.zig");
}
