//! Non-MPT artifacts of the execution-state machine: the code store every
//! `state.WorldState` carries, and the parent-code shape the closed world
//! hands it at admission.
//!
//! Parent code bytes remain borrowed from the sealed witness and are indexed
//! once by full hash. Code created during execution is copied into stable
//! block-lifetime storage.

const std = @import("std");
const crypto = @import("../../crypto.zig");
const CodeView = @import("../../state.zig").CodeView;
const SparseHashMap = @import("../../state/sparse_hash_map.zig").Auto;

const Allocator = std.mem.Allocator;
const Hash = [32]u8;
const IntroducedCodeMap = SparseHashMap(Hash, []const u8);

pub const ParentCode = struct {
    hash: Hash,
    bytes: []const u8,

    fn hashLessThan(_: void, lhs: ParentCode, rhs: ParentCode) bool {
        return std.mem.lessThan(u8, &lhs.hash, &rhs.hash);
    }

    fn hashOrder(target: Hash, item: ParentCode) std.math.Order {
        return std.mem.order(u8, &target, &item.hash);
    }
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
        return @enumFromInt(index);
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
        std.mem.sort(Entry, result.parent.items, {}, Entry.hashLessThan);
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

    /// Bind only against the witness's parent code: `.empty`, a parent index,
    /// or null when the store would have to search introduced code.
    pub fn bindParent(self: *const CodeStore, hash: Hash) ?CodeRef {
        if (std.mem.eql(u8, &hash, &crypto.keccak256_empty)) return .empty;
        if (self.parentIndex(hash)) |index| return .fromIndex(index);
        return null;
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
        if (bytes.len == 0) return .{
            .view = .{ .code_hash = crypto.keccak256_empty, .bytes = &.{} },
            .ref = .empty,
            .newly_introduced = null,
        };
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
        return std.sort.binarySearch(Entry, self.parent.items, hash, Entry.hashOrder);
    }
};

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

    const empty = try store.cacheIntroduced(std.testing.allocator, &.{});
    try std.testing.expectEqual(CodeRef.empty, empty.ref);
    try std.testing.expectEqualSlices(u8, &crypto.keccak256_empty, &empty.view.code_hash);
    try std.testing.expectEqual(@as(usize, 0), empty.view.bytes.len);
    try std.testing.expectEqual(@as(?IntroducedCodeId, null), empty.newly_introduced);
    try std.testing.expectEqual(@as(usize, 0), store.introducedLen());

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
