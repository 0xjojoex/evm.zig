//! Block-lifetime state capability consumed by higher-level transition drivers.

const std = @import("std");

const Committer = @import("Committer.zig");
const Reader = @import("Reader.zig");
const TrackedState = @import("TrackedState.zig");
const WitnessStateReader = @import("WitnessStateReader.zig");
const trie = @import("../eth/trie.zig");
const ChangesView = TrackedState.ChangesView;

pub const RootProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        afterChanges: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, changes: ChangesView) anyerror![32]u8,
    };

    pub fn afterChanges(self: RootProvider, allocator: std.mem.Allocator, changes: ChangesView) ![32]u8 {
        return self.vtable.afterChanges(self.ptr, allocator, changes);
    }
};

pub const Backend = union(enum) {
    witness: WitnessStateReader,
    external: External,

    pub const External = struct {
        reader: Reader,
        root_provider: RootProvider,
        committer: ?Committer = null,
    };

    /// `allocator` and witness byte slices must outlive the returned block-lifetime backend.
    pub fn fromWitness(
        allocator: std.mem.Allocator,
        state_root: [32]u8,
        nodes: []const []const u8,
        codes: []const WitnessStateReader.Code,
    ) !Backend {
        const indexed = try trie.indexNodes(allocator, nodes);
        return .{ .witness = WitnessStateReader.init(state_root, indexed, codes) };
    }

    pub fn fromExternal(reader_value: Reader, root_provider: RootProvider, committer: ?Committer) Backend {
        return .{ .external = .{
            .reader = reader_value,
            .root_provider = root_provider,
            .committer = committer,
        } };
    }

    pub fn deinit(self: *Backend) void {
        switch (self.*) {
            .witness => |*witness| witness.deinit(),
            .external => {},
        }
        self.* = undefined;
    }

    pub fn reader(self: *Backend) Reader {
        return switch (self.*) {
            .witness => |*witness| witness.reader(),
            .external => |external| external.reader,
        };
    }

    pub fn stateRootAfterChanges(self: *Backend, allocator: std.mem.Allocator, changes: ChangesView) ![32]u8 {
        return switch (self.*) {
            .witness => |witness| witnessRootAfterChanges(
                allocator,
                witness,
                changes,
            ) catch |err| switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                error.ResourceLimitExceeded => error.ResourceLimitExceeded,
                error.MissingNode,
                error.ConflictingNode,
                error.InvalidCompactPath,
                error.InvalidNode,
                error.InvalidNodeReference,
                error.NonCanonicalNode,
                error.ExpectedBytes,
                error.ExpectedList,
                error.InputTooShort,
                error.IntTooLarge,
                error.LengthOverflow,
                error.NonCanonicalInteger,
                error.NonCanonicalLength,
                error.NonCanonicalSingleByte,
                error.TrailingBytes,
                error.UnexpectedLength,
                => error.InvalidWitness,
                else => err,
            },
            .external => |external| external.root_provider.afterChanges(allocator, changes),
        };
    }

    pub fn commit(self: *Backend, changes: ChangesView) !void {
        switch (self.*) {
            .witness => {},
            .external => |external| if (external.committer) |committer| try committer.commit(changes),
        }
    }
};

fn witnessRootAfterChanges(
    allocator: std.mem.Allocator,
    witness: WitnessStateReader,
    changes: ChangesView,
) ![32]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    return trie.stateRootAfterChangesIndexed(
        arena.allocator(),
        witness.state_root,
        witness.indexed,
        changes,
    );
}

test "witness backend releases its owned node index" {
    const nodes = [_][]const u8{"encoded witness node"};
    var backend = try Backend.fromWitness(
        std.testing.allocator,
        [_]u8{0} ** 32,
        &nodes,
        &.{},
    );
    backend.deinit();
}

test "witness backend derives root directly from tracked changes" {
    const address = @import("../address.zig");
    var state = TrackedState.init(std.testing.allocator);
    defer state.deinit();
    const attempt = state.beginTransaction();
    state.beginScope();
    try state.setBalance(address.addr(1), 1);
    _ = try state.setStorage(address.addr(1), 2, 3);
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);
    const changes = state.acceptedView().changes();

    var backend = try Backend.fromWitness(
        std.testing.allocator,
        trie.empty_root_hash,
        &.{},
        &.{},
    );
    defer backend.deinit();

    const actual = try backend.stateRootAfterChanges(std.testing.allocator, changes);
    const expected = try trie.stateRootAfterChanges(
        std.testing.allocator,
        trie.empty_root_hash,
        &.{},
        changes,
    );
    try std.testing.expectEqualSlices(u8, &expected, &actual);
}
