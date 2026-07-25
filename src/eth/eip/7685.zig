//! EIP-7685 execution request bytes and commitment hash.

const std = @import("std");

const crypto = @import("../../crypto.zig");
const t = @import("../../t.zig");
/// sha256("")
pub const empty_requests_hash = [_]u8{
    0xe3, 0xb0, 0xc4, 0x42, 0x98, 0xfc, 0x1c, 0x14,
    0x9a, 0xfb, 0xf4, 0xc8, 0x99, 0x6f, 0xb9, 0x24,
    0x27, 0xae, 0x41, 0xe4, 0x64, 0x9b, 0x93, 0x4c,
    0xa4, 0x95, 0x99, 0x1b, 0x78, 0x52, 0xb8, 0x55,
};

pub fn requestBytes(allocator: std.mem.Allocator, request_type: u8, request_data: []const u8) ![]const u8 {
    const request_len = std.math.add(usize, request_data.len, 1) catch return error.OutOfMemory;
    const request = try allocator.alloc(u8, request_len);
    request[0] = request_type;
    @memcpy(request[1..], request_data);
    return request;
}

pub fn requestsHash(allocator: std.mem.Allocator, requests: []const []const u8) ![32]u8 {
    if (requests.len == 0) return empty_requests_hash;

    var non_empty: std.ArrayList([]const u8) = .empty;
    defer non_empty.deinit(allocator);
    try non_empty.ensureTotalCapacity(allocator, requests.len);

    for (requests) |request| {
        if (request.len == 0) return error.InvalidRequest;
        if (request.len == 1) continue;
        non_empty.appendAssumeCapacity(request);
    }

    if (non_empty.items.len == 0) return empty_requests_hash;

    std.mem.sort([]const u8, non_empty.items, {}, requestLessThan);
    for (non_empty.items[1..], 1..) |request, index| {
        if (request[0] == non_empty.items[index - 1][0]) return error.InvalidRequest;
    }

    const digest_bytes = try allocator.alloc(u8, non_empty.items.len * 32);
    defer allocator.free(digest_bytes);
    for (non_empty.items, 0..) |request, index| {
        const digest = crypto.sha256(request);
        @memcpy(digest_bytes[index * 32 ..][0..32], &digest);
    }
    return crypto.sha256(digest_bytes);
}

fn requestLessThan(_: void, lhs: []const u8, rhs: []const u8) bool {
    return lhs[0] < rhs[0];
}

test "EIP-7685 commitment hashes non-empty requests by type" {
    const requests = [_][]const u8{
        &.{ 0x02, 0xaa },
        &.{0x01},
        &.{ 0x00, 0xbb },
    };
    const digest = try requestsHash(std.testing.allocator, &requests);
    try t.expectHex(&digest, "bce7fa6eb1b970ae3d6c85193b9adb99aa19f5178fe09f55e96344bcbf68ee62");

    const empty_requests = [_][]const u8{ &.{0x00}, &.{0x01} };
    try std.testing.expectEqualSlices(u8, &empty_requests_hash, &(try requestsHash(std.testing.allocator, &.{})));
    try std.testing.expectEqualSlices(u8, &empty_requests_hash, &(try requestsHash(std.testing.allocator, &empty_requests)));

    const malformed = [_][]const u8{&.{}};
    try std.testing.expectError(error.InvalidRequest, requestsHash(std.testing.allocator, &malformed));

    const duplicate_type = [_][]const u8{ &.{ 0x01, 0xaa }, &.{ 0x01, 0xbb } };
    try std.testing.expectError(error.InvalidRequest, requestsHash(std.testing.allocator, &duplicate_type));
}
