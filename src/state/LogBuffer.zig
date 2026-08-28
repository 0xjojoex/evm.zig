//! Packed log storage shared by every execution state model.
//!
//! Like `checkpoint`, this belongs to neither the tracked nor the dense lane.
//! Emitted logs are protocol output — receipts, blooms, and EIP-6110 deposit
//! decoding read them the same way regardless of which lane produced them.
//!
//! Rows own their topic and data bytes, copied out of the host's borrowed
//! `Host.Log` so nothing escapes the callback lifetime. Scope rollback is a
//! three-length truncation, so reverting a frame frees nothing and reuses the
//! capacity the next frame will ask for.

const std = @import("std");

const Address = @import("../address.zig").Address;
const Host = @import("../Host.zig");
const checkpoint_types = @import("./checkpoint.zig");
const range = @import("stdx").range;

const Allocator = std.mem.Allocator;
const LogBuffer = @This();

/// Consensus caps a log at four topics; `append` rejects anything wider.
pub const max_topics = 4;

/// Log topics. Consensus caps a log at four topics, so `u8` is generous.
const TopicRange = range.Range(u256, u8);

pub const Row = struct {
    address: Address,
    topics: TopicRange,
    data: range.Bytes,
};

pub const Checkpoint = checkpoint_types.LogCheckpoint;

pub const AppendError = Allocator.Error || error{TooManyLogTopics};

rows: std.ArrayList(Row) = .empty,
topics: std.ArrayList(u256) = .empty,
data: std.ArrayList(u8) = .empty,

pub fn deinit(self: *LogBuffer, allocator: Allocator) void {
    self.rows.deinit(allocator);
    self.topics.deinit(allocator);
    self.data.deinit(allocator);
    self.* = undefined;
}

pub fn clone(self: *const LogBuffer, allocator: Allocator) Allocator.Error!LogBuffer {
    var result: LogBuffer = .{};
    errdefer result.deinit(allocator);
    try result.rows.appendSlice(allocator, self.rows.items);
    try result.topics.appendSlice(allocator, self.topics.items);
    try result.data.appendSlice(allocator, self.data.items);
    return result;
}

pub fn checkpoint(self: *const LogBuffer) Checkpoint {
    return .{
        .rows_len = @intCast(self.rows.items.len),
        .topics_len = @intCast(self.topics.items.len),
        .data_len = @intCast(self.data.items.len),
    };
}

pub fn truncate(self: *LogBuffer, value: Checkpoint) void {
    std.debug.assert(value.rows_len <= self.rows.items.len);
    std.debug.assert(value.topics_len <= self.topics.items.len);
    std.debug.assert(value.data_len <= self.data.items.len);
    self.rows.items.len = value.rows_len;
    self.topics.items.len = value.topics_len;
    self.data.items.len = value.data_len;
}

pub fn clearRetainingCapacity(self: *LogBuffer) void {
    self.truncate(.{ .rows_len = 0, .topics_len = 0, .data_len = 0 });
}

pub fn append(self: *LogBuffer, allocator: Allocator, event_log: Host.Log) AppendError!void {
    if (event_log.topics.len > max_topics) return error.TooManyLogTopics;
    std.debug.assert(self.rows.items.len < std.math.maxInt(u32));
    const topics: TopicRange = .init(self.topics.items.len, event_log.topics.len);
    const data: range.Bytes = .init(self.data.items.len, event_log.data.len);
    try self.rows.ensureUnusedCapacity(allocator, 1);
    try self.topics.ensureUnusedCapacity(allocator, event_log.topics.len);
    try self.data.ensureUnusedCapacity(allocator, event_log.data.len);

    self.topics.appendSliceAssumeCapacity(event_log.topics);
    self.data.appendSliceAssumeCapacity(event_log.data);
    self.rows.appendAssumeCapacity(.{
        .address = event_log.address,
        .topics = topics,
        .data = data,
    });
}

/// Pack a caller-owned `Host.Log` slice. Callers holding logs as a flat slice
/// (the BAL differential lane's detached copies, test fixtures) enter through
/// here rather than through a second view shape — one representation keeps
/// `get` branch-free on the guest's receipt and bloom paths.
pub fn fromLogs(allocator: Allocator, logs: []const Host.Log) AppendError!LogBuffer {
    var result: LogBuffer = .{};
    errdefer result.deinit(allocator);
    for (logs) |event_log| try result.append(allocator, event_log);
    return result;
}

pub fn fromView(allocator: Allocator, source: View) AppendError!LogBuffer {
    var result: LogBuffer = .{};
    errdefer result.deinit(allocator);
    for (0..source.len()) |index| try result.append(allocator, source.get(index));
    return result;
}

pub fn view(self: *const LogBuffer) View {
    return .{
        .rows = self.rows.items,
        .topics = self.topics.items,
        .data = self.data.items,
    };
}

pub fn allocationBytes(self: *const LogBuffer) usize {
    return self.rows.capacity * @sizeOf(Row) +
        self.topics.capacity * @sizeOf(u256) + self.data.capacity;
}

/// Borrowed projection over emitted logs. Stays readable until the underlying
/// buffer is truncated, cleared, or begins the next transaction.
///
/// `get` rebuilds a `Host.Log` per index rather than handing back a stored
/// slice. That is deliberate: a variant carrying a ready-made `[]const Host.Log`
/// would widen this value and put a tag test in the receipt and bloom loops,
/// which measured +0.04% guest steps across the pinned live blocks.
pub const View = struct {
    rows: []const Row,
    topics: []const u256,
    data: []const u8,

    pub const empty: View = .{ .rows = &.{}, .topics = &.{}, .data = &.{} };

    pub fn len(self: View) usize {
        return self.rows.len;
    }

    pub fn get(self: View, index: usize) Host.Log {
        const row = self.rows[index];
        return .{
            .address = row.address,
            .topics = row.topics.slice(self.topics),
            .data = row.data.slice(self.data),
        };
    }
};

comptime {
    std.debug.assert(@sizeOf(Row) == 36);
}

test "packed log buffer owns callback bytes and truncates to checkpoint" {
    var logs: LogBuffer = .{};
    defer logs.deinit(std.testing.allocator);
    var topics = [_]u256{1};
    var data = [_]u8{ 2, 3 };
    const checkpoint_value = logs.checkpoint();
    try logs.append(std.testing.allocator, .{
        .address = Address.fromBytes([_]u8{4} ** 20),
        .topics = &topics,
        .data = &data,
    });
    topics[0] = 9;
    data[0] = 9;
    try std.testing.expectEqual(@as(u256, 1), logs.view().get(0).topics[0]);
    try std.testing.expectEqual(@as(u8, 2), logs.view().get(0).data[0]);
    logs.truncate(checkpoint_value);
    try std.testing.expectEqual(@as(usize, 0), logs.view().len());
}

test "log buffer rejects a fifth topic without disturbing prior rows" {
    var logs: LogBuffer = .{};
    defer logs.deinit(std.testing.allocator);
    try logs.append(std.testing.allocator, .{
        .address = Address.fromBytes([_]u8{1} ** 20),
        .topics = &.{ 1, 2, 3, 4 },
        .data = &.{5},
    });
    try std.testing.expectError(error.TooManyLogTopics, logs.append(std.testing.allocator, .{
        .address = Address.fromBytes([_]u8{2} ** 20),
        .topics = &.{ 1, 2, 3, 4, 5 },
        .data = &.{},
    }));
    try std.testing.expectEqual(@as(usize, 1), logs.view().len());
    try std.testing.expectEqual(@as(usize, 4), logs.view().get(0).topics.len);
}

test "fromLogs packs a caller-owned slice into an equivalent buffer" {
    const logs = [_]Host.Log{
        .{ .address = Address.fromBytes([_]u8{7} ** 20), .topics = &.{9}, .data = &.{ 1, 2 } },
        .{ .address = Address.fromBytes([_]u8{8} ** 20), .topics = &.{}, .data = &.{} },
    };
    var packed_logs = try fromLogs(std.testing.allocator, &logs);
    defer packed_logs.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), packed_logs.view().len());
    try std.testing.expectEqualSlices(u8, &.{ 1, 2 }, packed_logs.view().get(0).data);
    try std.testing.expectEqualSlices(u256, &.{9}, packed_logs.view().get(0).topics);
    try std.testing.expectEqual(@as(usize, 0), packed_logs.view().get(1).topics.len);

    var round_tripped = try fromView(std.testing.allocator, packed_logs.view());
    defer round_tripped.deinit(std.testing.allocator);
    try std.testing.expectEqualSlices(Row, packed_logs.rows.items, round_tripped.rows.items);
    try std.testing.expectEqualSlices(u8, packed_logs.data.items, round_tripped.data.items);
}
