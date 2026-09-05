//! Block-lifetime state capability consumed by higher-level transition drivers.
//!
//! Two arms: a witness authenticated into a catalog, which both execution-state
//! lanes read from and commit against, and an external integration that owns
//! its canonical state and consumes a detached `StateDelta`. Root derivation
//! is `eth.commit.stateRoot`, which switches on these arms by whether the
//! lane's world authenticated its parents.

const std = @import("std");

const Committer = @import("./state/Committer.zig");
const Reader = @import("./state/Reader.zig");
const RootProvider = @import("./state/RootProvider.zig");
const StateDelta = @import("./state/StateDelta.zig");
const MemoryStore = @import("./state/MemoryStore.zig");
const WitnessReader = @import("./stateless/WitnessReader.zig");
const trie = @import("./eth/trie.zig");
const ClaimPlan = @import("./eth/bal/ClaimPlan.zig").ClaimPlan;
const ParentCode = @import("./eth/bal/claim_artifacts.zig").ParentCode;

pub const Backend = union(enum) {
    witness: WitnessReader,
    external: External,

    pub const External = struct {
        reader: Reader,
        root_provider: RootProvider,
        committer: ?Committer = null,
    };

    /// Authenticate `state_root` over the witness nodes. `allocator` and the
    /// byte slices must outlive the returned block-lifetime backend.
    pub fn fromWitness(
        allocator: std.mem.Allocator,
        state_root: [32]u8,
        nodes: []const []const u8,
        codes: []const []const u8,
    ) !Backend {
        return .{ .witness = try WitnessReader.initFromNodes(allocator, state_root, nodes, codes) };
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

    /// Batch-authenticate a validated BAL plan when this is a witness backend.
    /// External backends return null and retain their canonical reader.
    pub fn authenticateClaimPlan(
        self: *Backend,
        allocator: std.mem.Allocator,
        plan: ClaimPlan,
    ) !?WitnessReader.ParentFacts {
        return switch (self.*) {
            .witness => |*witness| try witness.authenticateClaimPlan(allocator, plan),
            .external => null,
        };
    }

    pub fn parentCodes(self: *const Backend) ?[]const ParentCode {
        return switch (self.*) {
            .witness => |*witness| witness.parentCodes(),
            .external => null,
        };
    }

    /// Whether `commit` consumes the accepted delta: only an external backend
    /// with a committer writes anything; a witness owns no canonical state.
    pub fn commitsDelta(self: *const Backend) bool {
        return switch (self.*) {
            .witness => false,
            .external => |external| external.committer != null,
        };
    }

    /// `delta` is required exactly when `commitsDelta()`.
    pub fn commit(self: *Backend, delta: ?StateDelta.View) !void {
        switch (self.*) {
            .witness => {},
            .external => |external| if (external.committer) |committer| try committer.commit(delta.?),
        }
    }
};

test "witness backend authenticates its root during construction" {
    const missing_root = [_]u8{0xab} ** 32;
    try std.testing.expectError(
        error.InvalidNode,
        Backend.fromWitness(std.testing.allocator, missing_root, &.{}, &.{}),
    );

    var empty = try Backend.fromWitness(
        std.testing.allocator,
        trie.empty_root_hash,
        &.{},
        &.{},
    );
    empty.deinit();
}
