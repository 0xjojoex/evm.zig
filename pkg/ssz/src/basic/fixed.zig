const codec = @import("../codec.zig");
const eager = @import("eager.zig");
const Error = @import("../error.zig").Error;

/// Adapt an unambiguous fixed-size Zig type to the composable codec interface.
pub fn Fixed(comptime T: type) type {
    const size = eager.encodedSize(T);

    return struct {
        pub const Value = T;
        pub const schema_type = T;
        pub const kind: codec.Kind = switch (@typeInfo(T)) {
            .array => .vector,
            .@"struct" => .container,
            else => .basic,
        };
        pub const is_variable_size = false;
        pub const fixed_size: ?usize = size;
        pub const requires_allocator = false;

        pub fn encodedLen(_: T) Error!usize {
            return size;
        }

        pub fn encode(out: []u8, value: T) Error![]u8 {
            if (out.len < size) return error.BufferTooSmall;
            const target: *[size]u8 = @ptrCast(out.ptr);
            eager.encodeInto(target, value);
            return out[0..size];
        }

        pub fn decode(bytes: []const u8) Error!T {
            return eager.decodeSlice(T, bytes);
        }

        pub fn validate(bytes: []const u8) Error!void {
            _ = try decode(bytes);
        }
    };
}
