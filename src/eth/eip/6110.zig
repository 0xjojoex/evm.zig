//! EIP-6110 deposit request constants and log decoding.

const std = @import("std");

const address = @import("../../address.zig");
const Host = @import("../../Host.zig");

pub const request_type: u8 = 0x00;
pub const deposit_contract_address = address.addr(0x00000000219ab540356cbb839cbe05303d7705fa);
pub const deposit_event_signature_hash: u256 = 0x649bbc62d0e31342afea4e5cd82d4049e7e1ee912fc0889aa790803be39038c5;

pub const event_data_len = 576;
pub const request_data_len = 192;

const pubkey_offset = 160;
const withdrawal_credentials_offset = 256;
const amount_offset = 320;
const signature_offset = 384;
const index_offset = 512;

pub fn appendRequestDataFromLogs(allocator: std.mem.Allocator, out: *std.ArrayList(u8), logs: []const Host.Log) !void {
    for (logs) |event_log| {
        if (!std.mem.eql(u8, &event_log.address, &deposit_contract_address)) continue;
        if (event_log.topics.len == 0 or event_log.topics[0] != deposit_event_signature_hash) continue;
        try appendRequestData(allocator, out, event_log.data);
    }
}

pub fn appendRequestData(allocator: std.mem.Allocator, out: *std.ArrayList(u8), event_data: []const u8) !void {
    if (event_data.len != event_data_len) return error.InvalidRequest;
    if (!wordEquals(event_data, 0, pubkey_offset)) return error.InvalidRequest;
    if (!wordEquals(event_data, 32, withdrawal_credentials_offset)) return error.InvalidRequest;
    if (!wordEquals(event_data, 64, amount_offset)) return error.InvalidRequest;
    if (!wordEquals(event_data, 96, signature_offset)) return error.InvalidRequest;
    if (!wordEquals(event_data, 128, index_offset)) return error.InvalidRequest;

    if (!wordEquals(event_data, pubkey_offset, 48)) return error.InvalidRequest;
    if (!wordEquals(event_data, withdrawal_credentials_offset, 32)) return error.InvalidRequest;
    if (!wordEquals(event_data, amount_offset, 8)) return error.InvalidRequest;
    if (!wordEquals(event_data, signature_offset, 96)) return error.InvalidRequest;
    if (!wordEquals(event_data, index_offset, 8)) return error.InvalidRequest;

    try out.ensureUnusedCapacity(allocator, request_data_len);
    out.appendSliceAssumeCapacity(event_data[pubkey_offset + 32 ..][0..48]);
    out.appendSliceAssumeCapacity(event_data[withdrawal_credentials_offset + 32 ..][0..32]);
    out.appendSliceAssumeCapacity(event_data[amount_offset + 32 ..][0..8]);
    out.appendSliceAssumeCapacity(event_data[signature_offset + 32 ..][0..96]);
    out.appendSliceAssumeCapacity(event_data[index_offset + 32 ..][0..8]);
}

fn wordEquals(data: []const u8, offset: usize, expected: u256) bool {
    return std.mem.readInt(u256, data[offset..][0..32], .big) == expected;
}

test "EIP-6110 derives deposit request bytes from logs" {
    var event_data = [_]u8{0} ** event_data_len;
    writeWord(&event_data, 0, pubkey_offset);
    writeWord(&event_data, 32, withdrawal_credentials_offset);
    writeWord(&event_data, 64, amount_offset);
    writeWord(&event_data, 96, signature_offset);
    writeWord(&event_data, 128, index_offset);
    writeWord(&event_data, pubkey_offset, 48);
    writeWord(&event_data, withdrawal_credentials_offset, 32);
    writeWord(&event_data, amount_offset, 8);
    writeWord(&event_data, signature_offset, 96);
    writeWord(&event_data, index_offset, 8);

    for (event_data[pubkey_offset + 32 ..][0..48], 0..) |*byte, index| byte.* = @intCast(index + 1);
    for (event_data[withdrawal_credentials_offset + 32 ..][0..32], 0..) |*byte, index| byte.* = @intCast(0x40 + index);
    for (event_data[amount_offset + 32 ..][0..8], 0..) |*byte, index| byte.* = @intCast(0x80 + index);
    for (event_data[signature_offset + 32 ..][0..96], 0..) |*byte, index| byte.* = @intCast(index);
    for (event_data[index_offset + 32 ..][0..8], 0..) |*byte, index| byte.* = @intCast(0xc0 + index);

    const topics = [_]u256{deposit_event_signature_hash};
    const logs = [_]Host.Log{.{
        .address = deposit_contract_address,
        .topics = &topics,
        .data = &event_data,
    }};

    var request_data: std.ArrayList(u8) = .empty;
    defer request_data.deinit(std.testing.allocator);
    try appendRequestDataFromLogs(std.testing.allocator, &request_data, &logs);
    try std.testing.expectEqual(@as(usize, request_data_len), request_data.items.len);
    try std.testing.expectEqualSlices(u8, event_data[pubkey_offset + 32 ..][0..48], request_data.items[0..48]);
    try std.testing.expectEqualSlices(u8, event_data[withdrawal_credentials_offset + 32 ..][0..32], request_data.items[48..80]);
    try std.testing.expectEqualSlices(u8, event_data[amount_offset + 32 ..][0..8], request_data.items[80..88]);
    try std.testing.expectEqualSlices(u8, event_data[signature_offset + 32 ..][0..96], request_data.items[88..184]);
    try std.testing.expectEqualSlices(u8, event_data[index_offset + 32 ..][0..8], request_data.items[184..192]);

    var ignored: std.ArrayList(u8) = .empty;
    defer ignored.deinit(std.testing.allocator);
    const wrong_topic = [_]u256{0};
    const ignored_logs = [_]Host.Log{.{
        .address = deposit_contract_address,
        .topics = &wrong_topic,
        .data = &event_data,
    }};
    try appendRequestDataFromLogs(std.testing.allocator, &ignored, &ignored_logs);
    try std.testing.expectEqual(@as(usize, 0), ignored.items.len);

    var invalid = event_data;
    writeWord(&invalid, amount_offset, 7);
    try std.testing.expectError(error.InvalidRequest, appendRequestData(std.testing.allocator, &ignored, &invalid));
}

fn writeWord(event_data: *[event_data_len]u8, offset: usize, value: u256) void {
    std.mem.writeInt(u256, event_data[offset..][0..32], value, .big);
}
