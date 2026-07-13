//! Basic SSZ codecs: eager fixed-size values, the `Fixed` adapter, and `IntEnum`.

const eager = @import("basic/eager.zig");
const fixed = @import("basic/fixed.zig");
const int_enum = @import("basic/int_enum.zig");

pub const Error = eager.Error;
pub const encodedSize = eager.encodedSize;
pub const encode = eager.encode;
pub const encodeInto = eager.encodeInto;
pub const decode = eager.decode;
pub const decodeSlice = eager.decodeSlice;
pub const Fixed = fixed.Fixed;
pub const IntEnum = int_enum.IntEnum;
