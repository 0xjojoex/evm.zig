//! Block-lifetime state capability consumed by higher-level transition drivers.

const std = @import("std");

const Changeset = @import("Changeset.zig");
const Committer = @import("Committer.zig");
const Reader = @import("Reader.zig");
const WitnessStateReader = @import("WitnessStateReader.zig");
const trie = @import("../eth/trie.zig");

pub const RootProvider = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        afterChangeset: *const fn (ptr: *anyopaque, allocator: std.mem.Allocator, changeset: *const Changeset) anyerror![32]u8,
    };

    pub fn afterChangeset(self: RootProvider, allocator: std.mem.Allocator, changeset: *const Changeset) ![32]u8 {
        return self.vtable.afterChangeset(self.ptr, allocator, changeset);
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

    pub fn stateRootAfterChangeset(self: *Backend, allocator: std.mem.Allocator, changeset: *const Changeset) ![32]u8 {
        return switch (self.*) {
            .witness => |witness| trie.stateRootAfterChangesetIndexed(
                allocator,
                witness.state_root,
                witness.indexed,
                changeset,
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
            .external => |external| external.root_provider.afterChangeset(allocator, changeset),
        };
    }

    pub fn commit(self: *Backend, changeset: *const Changeset) !void {
        switch (self.*) {
            .witness => {},
            .external => |external| if (external.committer) |committer| try committer.commit(changeset),
        }
    }
};

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
