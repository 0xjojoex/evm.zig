//! SSZ union codecs: canonical tagged unions, compatible unions, and the optional form.

const tagged_union = @import("union/tagged_union.zig");
const compatible_union = @import("union/compatible_union.zig");
const optional_union = @import("union/optional_union.zig");

pub const None = tagged_union.None;
pub const Union = tagged_union.Union;
pub const CompatibleUnion = compatible_union.CompatibleUnion;
pub const OptionalUnion = optional_union.OptionalUnion;
