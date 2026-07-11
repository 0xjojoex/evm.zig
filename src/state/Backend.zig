//! Block-lifetime state capability consumed by higher-level transition drivers.

const std = @import("std");

const Changeset = @import("Changeset.zig");
const Committer = @import("Committer.zig");
const Reader = @import("Reader.zig");
const WitnessStateReader = @import("WitnessStateReader.zig");
const mpt = @import("../mpt.zig");

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

    pub fn fromWitness(state_root: [32]u8, nodes: []const []const u8, codes: []const WitnessStateReader.Code) Backend {
        return .{ .witness = WitnessStateReader.init(state_root, nodes, codes) };
    }

    pub fn fromExternal(reader_value: Reader, root_provider: RootProvider, committer: ?Committer) Backend {
        return .{ .external = .{
            .reader = reader_value,
            .root_provider = root_provider,
            .committer = committer,
        } };
    }

    pub fn reader(self: *Backend) Reader {
        return switch (self.*) {
            .witness => |*witness| witness.reader(),
            .external => |external| external.reader,
        };
    }

    pub fn stateRootAfterChangeset(self: *Backend, allocator: std.mem.Allocator, changeset: *const Changeset) ![32]u8 {
        return switch (self.*) {
            .witness => |witness| mpt.stateRootAfterChangeset(allocator, witness.state_root, witness.nodes, changeset) catch |err| switch (err) {
                error.MissingNode, error.InvalidNode, error.InvalidNodeReference, error.InvalidCompactPath => error.InvalidWitness,
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
