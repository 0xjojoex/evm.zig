//! Library-facing namespace for the EVMC C-API submodules.
//! The standalone shared-library entry point lives in `evmc.zig`.

pub const common = @import("./c_api/common.zig");
pub const evmc = common.evmc;

pub const testing = struct {
    pub const host2c = @import("./c_api/host2c.zig");
};
