//! SSZ vector codecs: composite-element vectors and the byte specialization.

const variable_vector = @import("vector/variable_vector.zig");
const byte_vector = @import("vector/byte_vector.zig");

pub const VectorOf = variable_vector.VectorOf;
pub const VectorSliceOf = variable_vector.VectorSliceOf;
pub const ByteVector = byte_vector.ByteVector;
