const std = @import("std");
const guest_options = @import("guest_options");

pub const Error = error{
    MissingGuestInput,
};

pub fn readInput() Error![]const u8 {
    if (comptime guest_options.use_ziskos_staticlib) {
        var ptr: ?[*]const u8 = null;
        var len: usize = 0;
        read_input(&ptr, &len);
        if (len == 0) return &.{};
        const actual = ptr orelse return error.MissingGuestInput;
        return actual[0..len];
    }

    return error.MissingGuestInput;
}

pub fn writeOutput(bytes: []const u8) void {
    if (comptime guest_options.use_ziskos_staticlib) {
        if (bytes.len == 0) return;
        write_output(bytes.ptr, bytes.len);
    }
}

extern fn read_input(buf_ptr: *?[*]const u8, buf_size: *usize) callconv(.c) void;
extern fn write_output(output: [*]const u8, size: usize) callconv(.c) void;
