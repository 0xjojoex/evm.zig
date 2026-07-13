//! SSZ container codecs and host-type schema inference.

const typed_container = @import("container/typed_container.zig");
const progressive_container = @import("container/progressive_container.zig");

pub const Container = typed_container.Container;
pub const codecFor = typed_container.codecFor;
pub const ProgressiveContainer = progressive_container.ProgressiveContainer;
