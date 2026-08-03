//! Non-MPT artifacts owned by the dense stateless execution lane.
//!
//! Parent code bytes remain borrowed from the sealed witness and are indexed
//! once by full hash. Code created during execution is copied into stable
//! block-lifetime storage. Logs own packed topic/data bytes so host borrows
//! never escape their callback lifetime.

const std = @import("std");
const checkpoint_types = @import("../state/checkpoint.zig");
const Address = @import("../address.zig").Address;
const crypto = @import("../crypto.zig");
const Host = @import("../Host.zig");
const SparseHashMap = @import("../state/sparse_hash_map.zig").Auto;

const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const IntroducedCodeMap = SparseHashMap(Hash, []const u8);

pub const ParentCode = struct {
    hash: Hash,
    bytes: []const u8,
};

pub const CodeView = struct {
    code_hash: Hash,
    bytes: []const u8,
};

pub const IntroducedCodeId = enum(u32) { _ };

/// Stable block-lifetime index into `CodeStore`. Parent and introduced code
/// share one numeric namespace; the two highest values are reserved for the
/// canonical empty code and an unresolved non-empty commitment.
pub const CodeRef = enum(u32) {
    missing = std.math.maxInt(u32) - 1,
    empty = std.math.maxInt(u32),
    _,

    pub const max_indexed: usize = @intFromEnum(CodeRef.missing);

    pub fn fromIndex(index: usize) CodeRef {
        std.debug.assert(index < CodeRef.max_indexed);
        return @enumFromInt(@as(u32, @intCast(index)));
    }
};

pub const CodeStore = struct {
    const Entry = ParentCode;

    pub const CacheResult = struct {
        view: CodeView,
        ref: CodeRef,
        newly_introduced: ?IntroducedCodeId,
    };

    parent: std.ArrayList(Entry) = .empty,
    introduced: IntroducedCodeMap,

    pub const InitError = Allocator.Error || error{
        CodeHashCollision,
        ResourceLimitExceeded,
    };
    pub const CacheError = Allocator.Error || error{
        CodeHashCollision,
        ResourceLimitExceeded,
    };

    pub fn init(allocator: Allocator, codes: []const []const u8) InitError!CodeStore {
        if (codes.len > CodeRef.max_indexed) return error.ResourceLimitExceeded;
        var hashed: std.ArrayList(ParentCode) = .empty;
        defer hashed.deinit(allocator);
        try hashed.ensureTotalCapacity(allocator, codes.len);
        for (codes) |bytes| hashed.appendAssumeCapacity(.{
            .hash = crypto.keccak256(bytes),
            .bytes = bytes,
        });
        return initHashed(allocator, hashed.items);
    }

    pub fn initHashed(allocator: Allocator, codes: []const ParentCode) InitError!CodeStore {
        if (codes.len > CodeRef.max_indexed) return error.ResourceLimitExceeded;
        var result = CodeStore{ .introduced = .init(allocator) };
        errdefer result.deinit(allocator);
        try result.parent.ensureTotalCapacity(allocator, codes.len);
        result.parent.appendSliceAssumeCapacity(codes);
        std.mem.sort(Entry, result.parent.items, {}, entryLessThan);
        if (result.parent.items.len > 1) {
            for (result.parent.items[1..], result.parent.items[0 .. result.parent.items.len - 1]) |current, previous| {
                if (!std.mem.eql(u8, &current.hash, &previous.hash)) continue;
                if (!std.mem.eql(u8, current.bytes, previous.bytes)) return error.CodeHashCollision;
            }
        }
        return result;
    }

    pub fn deinit(self: *CodeStore, allocator: Allocator) void {
        var introduced = self.introduced.valueIterator();
        while (introduced.next()) |bytes| allocator.free(@constCast(bytes.*));
        self.parent.deinit(allocator);
        self.introduced.deinit();
        self.* = undefined;
    }

    pub fn lookup(self: *const CodeStore, hash: Hash) ?CodeView {
        return self.view(self.bind(hash));
    }

    /// Resolve a commitment once when an account row is materialized or its
    /// code changes. Execution reads use `view` and never search by hash.
    pub fn bind(self: *const CodeStore, hash: Hash) CodeRef {
        if (std.mem.eql(u8, &hash, &crypto.keccak256_empty)) return .empty;
        if (self.parentIndex(hash)) |index| return .fromIndex(index);
        if (self.introduced.getEntryId(hash)) |id|
            return .fromIndex(self.parent.items.len + @intFromEnum(id));
        return .missing;
    }

    /// Direct-index a previously bound commitment. A missing reference is a
    /// valid row state until execution actually requests its bytes.
    pub fn view(self: *const CodeStore, ref: CodeRef) ?CodeView {
        if (ref == .empty) return .{
            .code_hash = crypto.keccak256_empty,
            .bytes = &.{},
        };
        if (ref == .missing) return null;
        const index: usize = @intFromEnum(ref);
        const entry = if (index < self.parent.items.len)
            self.parent.items[index]
        else blk: {
            const introduced_index: u32 = @intCast(index - self.parent.items.len);
            const introduced = self.introduced.entryAt(introduced_index);
            break :blk Entry{ .hash = introduced.key_ptr.*, .bytes = introduced.value_ptr.* };
        };
        return .{ .code_hash = entry.hash, .bytes = entry.bytes };
    }

    pub fn cacheIntroduced(
        self: *CodeStore,
        allocator: Allocator,
        bytes: []const u8,
    ) CacheError!CacheResult {
        const hash = crypto.keccak256(bytes);
        const existing_ref = self.bind(hash);
        if (self.view(existing_ref)) |existing| {
            if (!std.mem.eql(u8, existing.bytes, bytes)) return error.CodeHashCollision;
            return .{
                .view = existing,
                .ref = existing_ref,
                .newly_introduced = null,
            };
        }

        if (self.parent.items.len + @as(usize, self.introduced.count()) == CodeRef.max_indexed)
            return error.ResourceLimitExceeded;
        const owned = try allocator.dupe(u8, bytes);
        errdefer allocator.free(owned);
        self.introduced.ensureUnusedCapacity(1) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => return error.ResourceLimitExceeded,
        };
        const id: IntroducedCodeId = @enumFromInt(self.introduced.count());
        self.introduced.putAssumeCapacityNoClobber(hash, owned);
        return .{
            .view = .{ .code_hash = hash, .bytes = owned },
            .ref = .fromIndex(self.parent.items.len + @intFromEnum(id)),
            .newly_introduced = id,
        };
    }

    pub fn introducedView(self: *const CodeStore, id: IntroducedCodeId) CodeView {
        const entry = self.introduced.entryAt(@intFromEnum(id));
        return .{ .code_hash = entry.key_ptr.*, .bytes = entry.value_ptr.* };
    }

    pub fn truncateIntroduced(self: *CodeStore, allocator: Allocator, len: usize) void {
        std.debug.assert(len <= @as(usize, self.introduced.count()));
        while (@as(usize, self.introduced.count()) > len) {
            const last = self.introduced.entryAt(self.introduced.count() - 1);
            const hash = last.key_ptr.*;
            const bytes = last.value_ptr.*;
            std.debug.assert(self.introduced.remove(hash));
            allocator.free(@constCast(bytes));
        }
    }

    pub fn introducedLen(self: *const CodeStore) usize {
        return self.introduced.count();
    }

    pub fn allocationBytes(self: *const CodeStore) usize {
        var bytes = self.parent.capacity * @sizeOf(Entry) +
            self.introduced.allocationBytes();
        for (0..self.introduced.count()) |index|
            bytes += self.introduced.entryAt(@intCast(index)).value_ptr.*.len;
        return bytes;
    }

    fn parentIndex(self: *const CodeStore, hash: Hash) ?usize {
        var low: usize = 0;
        var high = self.parent.items.len;
        while (low < high) {
            const mid = low + (high - low) / 2;
            switch (std.mem.order(u8, &self.parent.items[mid].hash, &hash)) {
                .lt => low = mid + 1,
                .gt => high = mid,
                .eq => return mid,
            }
        }
        return null;
    }

    fn entryLessThan(_: void, lhs: Entry, rhs: Entry) bool {
        return std.mem.order(u8, &lhs.hash, &rhs.hash) == .lt;
    }
};

// TODO: Range() utils candidate
pub const ByteRange = struct {
    offset: u32 = 0,
    len: u32 = 0,

    fn slice(self: ByteRange, bytes: []const u8) []const u8 {
        const offset: usize = self.offset;
        const len: usize = self.len;
        std.debug.assert(offset + len <= bytes.len);
        return bytes[offset..][0..len];
    }
};

pub const TopicRange = struct {
    offset: u32 = 0,
    len: u8 = 0,

    fn slice(self: TopicRange, topics: []const u256) []const u256 {
        const offset: usize = self.offset;
        const len: usize = self.len;
        std.debug.assert(offset + len <= topics.len);
        return topics[offset..][0..len];
    }
};

pub const LogBuffer = struct {
    pub const Row = struct {
        address: Address,
        topics: TopicRange,
        data: ByteRange,
    };

    pub const Checkpoint = checkpoint_types.LogCheckpoint;

    rows: std.ArrayList(Row) = .empty,
    topics: std.ArrayList(u256) = .empty,
    data: std.ArrayList(u8) = .empty,

    pub fn deinit(self: *LogBuffer, allocator: Allocator) void {
        self.rows.deinit(allocator);
        self.topics.deinit(allocator);
        self.data.deinit(allocator);
        self.* = undefined;
    }

    pub fn checkpoint(self: *const LogBuffer) Checkpoint {
        return .{
            .rows_len = index32(self.rows.items.len),
            .topics_len = index32(self.topics.items.len),
            .data_len = index32(self.data.items.len),
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

    pub fn append(self: *LogBuffer, allocator: Allocator, event_log: Host.Log) !void {
        if (event_log.topics.len > 4) return error.TooManyLogTopics;
        const topics = topicRange(self.topics.items.len, event_log.topics.len);
        const data = byteRange(self.data.items.len, event_log.data.len);
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

    pub fn view(self: *const LogBuffer) LogView {
        return .{ .rows = self.rows.items, .topics = self.topics.items, .data = self.data.items };
    }

    pub fn allocationBytes(self: *const LogBuffer) usize {
        return self.rows.capacity * @sizeOf(Row) +
            self.topics.capacity * @sizeOf(u256) + self.data.capacity;
    }
};

pub const LogView = struct {
    rows: []const LogBuffer.Row,
    topics: []const u256,
    data: []const u8,

    pub const empty: LogView = .{ .rows = &.{}, .topics = &.{}, .data = &.{} };

    pub fn len(self: LogView) usize {
        return self.rows.len;
    }

    pub fn contiguous(_: LogView) ?[]const Host.Log {
        return null;
    }

    pub fn get(self: LogView, index: usize) Host.Log {
        const row = self.rows[index];
        return .{
            .address = row.address,
            .topics = row.topics.slice(self.topics),
            .data = row.data.slice(self.data),
        };
    }
};

fn byteRange(offset: usize, len: usize) ByteRange {
    std.debug.assert(offset <= std.math.maxInt(u32));
    std.debug.assert(len <= std.math.maxInt(u32));
    return .{ .offset = @intCast(offset), .len = @intCast(len) };
}

fn topicRange(offset: usize, len: usize) TopicRange {
    std.debug.assert(offset <= std.math.maxInt(u32));
    std.debug.assert(len <= 4);
    return .{ .offset = @intCast(offset), .len = @intCast(len) };
}

fn index32(value: usize) u32 {
    std.debug.assert(value <= std.math.maxInt(u32));
    return @intCast(value);
}

test "code store authenticates borrowed codes and owns introduced code" {
    const parent_code = [_]u8{ 0x60, 0x00 };
    var store = try CodeStore.init(std.testing.allocator, &.{&parent_code});
    defer store.deinit(std.testing.allocator);
    const parent_hash = crypto.keccak256(&parent_code);
    const parent_ref = store.bind(parent_hash);
    try std.testing.expect(parent_ref != .empty);
    try std.testing.expect(parent_ref != .missing);
    try std.testing.expectEqualSlices(u8, &parent_code, store.view(parent_ref).?.bytes);
    try std.testing.expect(store.bind([_]u8{0x99} ** 32) == .missing);
    try std.testing.expect(store.bind(crypto.keccak256_empty) == .empty);

    const introduced = [_]u8{0x5f};
    const cached = try store.cacheIntroduced(std.testing.allocator, &introduced);
    try std.testing.expect(cached.newly_introduced != null);
    try std.testing.expectEqualSlices(u8, &introduced, cached.view.bytes);
    try std.testing.expectEqualSlices(u8, &introduced, store.view(cached.ref).?.bytes);
    try std.testing.expectEqualSlices(
        u8,
        &introduced,
        store.introducedView(cached.newly_introduced.?).bytes,
    );

    const duplicate = try store.cacheIntroduced(std.testing.allocator, &introduced);
    try std.testing.expect(duplicate.newly_introduced == null);
    try std.testing.expectEqual(cached.ref, duplicate.ref);
    try std.testing.expectEqual(@as(usize, 1), store.introducedLen());

    const second = [_]u8{ 0x60, 0x01 };
    const second_hash = crypto.keccak256(&second);
    const second_cached = try store.cacheIntroduced(std.testing.allocator, &second);
    try std.testing.expect(second_cached.newly_introduced != null);
    try std.testing.expectEqual(second_cached.ref, store.bind(second_hash));
    store.truncateIntroduced(std.testing.allocator, 1);
    try std.testing.expectEqual(.missing, store.bind(second_hash));
    try std.testing.expectEqual(cached.ref, store.bind(cached.view.code_hash));

    const reintroduced = try store.cacheIntroduced(std.testing.allocator, &second);
    try std.testing.expect(reintroduced.newly_introduced != null);
    try std.testing.expectEqual(second_cached.ref, reintroduced.ref);
}

test "packed log buffer owns callback bytes and truncates to checkpoint" {
    var logs = LogBuffer{};
    defer logs.deinit(std.testing.allocator);
    var topics = [_]u256{1};
    var data = [_]u8{ 2, 3 };
    const checkpoint_value = logs.checkpoint();
    try logs.append(std.testing.allocator, .{
        .address = [_]u8{4} ** 20,
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
