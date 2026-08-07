const builtin = @import("builtin");
const guest_options = @import("guest_options");

pub fn evmz_guest_entry() callconv(.c) c_int {
    return 1;
}

comptime {
    if (!builtin.is_test) @export(&evmz_guest_entry, .{ .name = "evmz_guest_entry" });
    switch (guest_options.backend) {
        .native => {},
        .zisk, .sp1 => @export(&guestMain, .{ .name = "main" }),
    }
}

fn guestMain() callconv(.c) c_int {
    return evmz_guest_entry();
}
