//! Block-lifetime state capability consumed by higher-level transition drivers.

const std = @import("std");

const Committer = @import("./state/Committer.zig");
const Reader = @import("./state/Reader.zig");
const RootProvider = @import("./state/RootProvider.zig");
const TrackedState = @import("./state/TrackedState.zig");
const MemoryStore = @import("./state/MemoryStore.zig");
const witness_reader = @import("./stateless/WitnessReader.zig");
const trie = @import("./eth/trie.zig");
const ClaimPlan = @import("./eth/bal/ClaimPlan.zig").ClaimPlan;
const ChangesView = TrackedState.ChangesView;
const DenseCommitView = @import("./stateless/BlockState.zig").CommitView;
const ParentCode = @import("./stateless/artifacts.zig").ParentCode;

pub const Backend = union(enum) {
    witness: witness_reader.Indexed,
    catalog_witness: witness_reader.Catalog,
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
        codes: []const []const u8,
    ) !Backend {
        return .{ .witness = try witness_reader.Indexed.initFromNodes(allocator, state_root, nodes, codes) };
    }

    pub fn fromCatalogWitness(
        allocator: std.mem.Allocator,
        state_root: [32]u8,
        nodes: []const []const u8,
        codes: []const []const u8,
    ) !Backend {
        return .{ .catalog_witness = try witness_reader.Catalog.initFromNodes(allocator, state_root, nodes, codes) };
    }

    /// Convenience wiring for the in-memory store used by fixtures, examples,
    /// and light integrations. The store supplies its own capabilities.
    pub fn fromMemoryStore(store: *MemoryStore) Backend {
        return fromExternal(store.reader(), store.rootProvider(), store.committer());
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
            .catalog_witness => |*witness| witness.deinit(),
            .external => {},
        }
        self.* = undefined;
    }

    pub fn reader(self: *Backend) Reader {
        return switch (self.*) {
            .witness => |*witness| witness.reader(),
            .catalog_witness => |*witness| witness.reader(),
            .external => |external| external.reader,
        };
    }

    /// Batch-authenticate a validated BAL plan when this is a witness backend.
    /// Stateful/external backends return null and retain their canonical reader.
    pub fn authenticateClaimPlan(
        self: *Backend,
        allocator: std.mem.Allocator,
        plan: ClaimPlan,
    ) !?witness_reader.ParentFacts {
        return switch (self.*) {
            .witness => |*witness| try witness.authenticateClaimPlan(allocator, plan),
            .catalog_witness => |*witness| try witness.authenticateClaimPlan(allocator, plan),
            .external => null,
        };
    }

    pub fn parentCodes(self: *const Backend) ?[]const ParentCode {
        return switch (self.*) {
            .witness => |*witness| witness.parentCodes(),
            .catalog_witness => |*witness| witness.parentCodes(),
            .external => null,
        };
    }

    /// `node_updates` retains content-addressed dirty commitment nodes; only
    /// witness lanes own an MPT, so an external backend requires null.
    pub fn stateRootAfterChanges(
        self: *Backend,
        allocator: std.mem.Allocator,
        changes: ChangesView,
        node_updates: ?*trie.NodeUpdates,
    ) ![32]u8 {
        return switch (self.*) {
            .witness => |*witness| witness.stateRootAfterChanges(allocator, changes, node_updates),
            .catalog_witness => |*witness| witness.stateRootAfterChanges(allocator, changes, node_updates),
            .external => |external| blk: {
                std.debug.assert(node_updates == null);
                break :blk external.root_provider.afterChanges(allocator, changes);
            },
        };
    }

    /// Only the dense witness lane keeps state projected as ClaimPlan IDs, so
    /// an external backend has no commit view to root.
    pub fn stateRootAfterDenseCommit(
        self: *Backend,
        allocator: std.mem.Allocator,
        commit_view: DenseCommitView,
        node_updates: ?*trie.NodeUpdates,
    ) ![32]u8 {
        return switch (self.*) {
            .catalog_witness => |*witness| witness.stateRootAfterDenseCommit(allocator, commit_view, node_updates),
            .witness => error.InvalidWitness,
            .external => error.InvalidWitness,
        };
    }

    pub fn commit(self: *Backend, changes: ChangesView) !void {
        switch (self.*) {
            .witness => {},
            .catalog_witness => {},
            .external => |external| if (external.committer) |committer| try committer.commit(changes),
        }
    }
};

test "witness backend releases its owned node index" {
    const nodes = [_][]const u8{"encoded witness node"};
    var backend = try Backend.fromWitness(
        std.testing.allocator,
        trie.empty_root_hash,
        &nodes,
        &.{},
    );
    backend.deinit();
}

test "catalog witness authenticates its root during construction" {
    const missing_root = [_]u8{0xab} ** 32;

    var indexed = try Backend.fromWitness(std.testing.allocator, missing_root, &.{}, &.{});
    indexed.deinit();
    try std.testing.expectError(
        error.InvalidNode,
        Backend.fromCatalogWitness(std.testing.allocator, missing_root, &.{}, &.{}),
    );

    var empty_catalog = try Backend.fromCatalogWitness(
        std.testing.allocator,
        trie.empty_root_hash,
        &.{},
        &.{},
    );
    empty_catalog.deinit();
}
