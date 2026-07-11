const std = @import("std");

const crypto = @import("../crypto.zig");
const stateless_wire = @import("./wire.zig");

pub const public_values_size = 32;
pub const PublicValues = [public_values_size]u8;

pub const Result = struct {
    output: []u8,
    public_values: PublicValues,

    pub fn deinit(self: Result, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn outputPublicValues(output_bytes: []const u8) PublicValues {
    return crypto.sha256(output_bytes);
}

pub fn validateStatelessPublicValues(allocator: std.mem.Allocator, input_bytes: []const u8) stateless_wire.Error!PublicValues {
    const output = try stateless_wire.validateStatelessBytes(allocator, input_bytes);
    defer allocator.free(output);
    return outputPublicValues(output);
}

pub fn runStatelessValidator(allocator: std.mem.Allocator, input_bytes: []const u8) stateless_wire.Error!Result {
    const output = try stateless_wire.validateStatelessBytes(allocator, input_bytes);
    errdefer allocator.free(output);
    return .{
        .output = output,
        .public_values = outputPublicValues(output),
    };
}

test "ERE public values are sha256 of stateless SSZ output" {
    const input = try stateless_wire.smokeInputBytes(std.testing.allocator);
    defer std.testing.allocator.free(input);

    const result = try runStatelessValidator(std.testing.allocator, input);
    defer result.deinit(std.testing.allocator);

    const expected = outputPublicValues(result.output);
    const direct = try validateStatelessPublicValues(std.testing.allocator, input);
    try std.testing.expectEqualSlices(u8, &expected, &result.public_values);
    try std.testing.expectEqualSlices(u8, &result.public_values, &direct);
}
