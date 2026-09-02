//! Coherent Ethereum execution-state and block-lifecycle pairings.
//!
//! The completed Ethereum VM selects one domain atomically. Its `Execution`
//! namespace feeds the generic execution engine; `Lifecycle` remains at the block/STF
//! layer for admission, witness handling, observation, and commitment.

const std = @import("std");

const address = @import("../address.zig");
const Backend = @import("../backend.zig").Backend;
const bal = @import("bal/model.zig");
const bal_witness = @import("bal/witness.zig");
const ClaimPlan = @import("bal/ClaimPlan.zig").ClaimPlan;
const DenseClaimVerifier = @import("bal/DenseClaimVerifier.zig");
const Spec = @import("../spec.zig").Spec;
const Reader = @import("../state/Reader.zig");
const StateDelta = @import("../state/StateDelta.zig");
const TrackedState = @import("../state/TrackedState.zig");
const ClaimState = @import("bal/ClaimState.zig");
const tracked_state_projector = @import("bal/tracked_state_projector.zig");
const trie = @import("trie.zig");

pub const AdmissionInput = struct {
    backend: *Backend,
    validated_claim: ?bal.BlockAccessList,
    precheck_claim_state: bool,
};

pub const AdmissionError = error{
    InfrastructureFailure,
    InvalidBlockAccessList,
    InvalidWitness,
    OutOfMemory,
    ResourceLimitExceeded,
};

pub const CommitError = error{
    InfrastructureFailure,
    InvalidWitness,
    OutOfMemory,
    ResourceLimitExceeded,
};

/// Optional accepted block-final output, detached from execution: the owned
/// semantic delta plus, on witness lanes, the content-addressed dirty MPT
/// nodes produced while deriving the accepted root. External backends own
/// their commitment, so they never populate `mpt_nodes`.
pub const CommitOutput = struct {
    delta: ?StateDelta = null,
    mpt_nodes: ?trie.NodeUpdates = null,

    /// Release output with the allocator supplied to block validation.
    pub fn deinit(self: *CommitOutput) void {
        if (self.mpt_nodes) |*nodes| nodes.deinit();
        if (self.delta) |*delta| delta.deinit();
        self.* = .{};
    }
};

pub const Tracked = struct {
    pub const Execution = struct {
        pub const State = TrackedState;
        pub const StateAddress = address.Address;
        pub const Init = struct {
            reader: ?Reader = null,
        };
        pub const default_init: ?Init = .{};

        pub fn checkSpec(comptime _: Spec) void {}

        pub fn init(comptime spec: Spec, allocator: std.mem.Allocator, options: Init) State {
            return State.initForSpec(allocator, spec, options.reader);
        }

        pub inline fn stateAddress(value: address.Address) StateAddress {
            return value;
        }

        pub inline fn executionAddress(value: address.AddressWord) StateAddress {
            return value.address();
        }
    };

    pub const Lifecycle = struct {
        pub const supports_block_production = true;
        pub const supports_external_observation_capture = true;
        pub const BalClaimVerifier = tracked_state_projector.ClaimVerifier;

        pub fn initBalClaimVerifier(
            allocator: std.mem.Allocator,
            _: *const Execution.State,
            expected: bal.BlockAccessList,
        ) !BalClaimVerifier {
            return BalClaimVerifier.init(allocator, expected);
        }

        pub fn witnessBackend(
            allocator: std.mem.Allocator,
            state_root: [32]u8,
            nodes: []const []const u8,
            codes: []const []const u8,
        ) !Backend {
            return Backend.fromWitness(allocator, state_root, nodes, codes);
        }

        pub fn admit(
            allocator: std.mem.Allocator,
            input: AdmissionInput,
        ) AdmissionError!Execution.Init {
            if (input.precheck_claim_state) {
                if (input.validated_claim) |claim| try precheckClaim(allocator, input.backend, claim);
            }
            return .{ .reader = input.backend.reader() };
        }

        pub fn stateRoot(
            allocator: std.mem.Allocator,
            backend: *Backend,
            accepted: Execution.State.AcceptedView,
            node_updates: ?*trie.NodeUpdates,
        ) CommitError![32]u8 {
            return backend.stateRootAfterChanges(allocator, accepted.changes(), node_updates) catch |err|
                return normalizeCommitError(err);
        }

        pub fn commit(
            backend: *Backend,
            accepted: Execution.State.AcceptedView,
        ) CommitError!void {
            backend.commit(accepted.changes()) catch |err|
                return normalizeCommitError(err);
        }

        pub fn consumeObservationTarget(
            target: anytype,
            block_access_index: bal.BlockAccessIndex,
            observations: Execution.State.ObservationsView,
        ) !void {
            try target.consume(block_access_index, observations);
        }
    };
};

pub const BalStateless = struct {
    pub const Execution = struct {
        pub const State = ClaimState;
        pub const StateAddress = address.AddressWord;
        pub const Init = State;
        pub const default_init: ?Init = null;

        pub fn checkSpec(comptime spec: Spec) void {
            if (!spec.block.block_access_list) {
                @compileError("BalStateless requires a block-access-list specification");
            }
        }

        pub fn init(comptime _: Spec, _: std.mem.Allocator, state: Init) State {
            return state;
        }

        pub inline fn stateAddress(value: address.Address) StateAddress {
            return .fromAddress(value);
        }

        pub inline fn executionAddress(value: address.AddressWord) StateAddress {
            return value;
        }
    };

    pub const Lifecycle = struct {
        pub const supports_block_production = false;
        pub const supports_external_observation_capture = false;
        pub const BalClaimVerifier = DenseClaimVerifier;

        pub fn initBalClaimVerifier(
            allocator: std.mem.Allocator,
            state: *const Execution.State,
            expected: bal.BlockAccessList,
        ) !BalClaimVerifier {
            return BalClaimVerifier.init(allocator, &state.plan, expected);
        }

        pub fn witnessBackend(
            allocator: std.mem.Allocator,
            state_root: [32]u8,
            nodes: []const []const u8,
            codes: []const []const u8,
        ) !Backend {
            return Backend.fromCatalogWitness(allocator, state_root, nodes, codes);
        }

        pub fn admit(
            allocator: std.mem.Allocator,
            input: AdmissionInput,
        ) AdmissionError!Execution.Init {
            const claim = input.validated_claim orelse return error.InvalidBlockAccessList;
            var plan = ClaimPlan.initAssumeValidated(allocator, claim) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResourceLimitExceeded, error.TrieKeyCollision => return error.InvalidBlockAccessList,
            };
            const authenticated = input.backend.authenticateClaimPlan(allocator, plan) catch |err| {
                plan.deinit(allocator);
                return switch (err) {
                    error.OutOfMemory => return error.OutOfMemory,
                    else => return error.InvalidWitness,
                };
            };
            var facts = authenticated orelse {
                plan.deinit(allocator);
                return error.InvalidWitness;
            };
            const codes = input.backend.parentCodes() orelse {
                facts.deinit(allocator);
                plan.deinit(allocator);
                return error.InvalidWitness;
            };
            return Execution.State.initWithParentCodes(allocator, plan, facts, codes) catch |err| switch (err) {
                error.OutOfMemory => return error.OutOfMemory,
                error.ResourceLimitExceeded => return error.ResourceLimitExceeded,
                error.CodeHashCollision => return error.InvalidWitness,
            };
        }

        pub fn stateRoot(
            allocator: std.mem.Allocator,
            backend: *Backend,
            accepted: Execution.State.AcceptedView,
            node_updates: ?*trie.NodeUpdates,
        ) CommitError![32]u8 {
            return backend.stateRootAfterDenseCommit(allocator, accepted.commit(), node_updates) catch |err|
                return normalizeCommitError(err);
        }

        pub fn commit(_: *Backend, _: Execution.State.AcceptedView) CommitError!void {}

        pub fn consumeObservationTarget(
            _: anytype,
            _: bal.BlockAccessIndex,
            _: Execution.State.ObservationsView,
        ) !void {
            unreachable;
        }
    };
};

fn precheckClaim(
    allocator: std.mem.Allocator,
    backend: *Backend,
    claim: bal.BlockAccessList,
) AdmissionError!void {
    var claim_plan = ClaimPlan.initAssumeValidated(allocator, claim) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimitExceeded, error.TrieKeyCollision => return error.InvalidBlockAccessList,
    };
    defer claim_plan.deinit(allocator);

    const authenticated = backend.authenticateClaimPlan(allocator, claim_plan) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        else => return error.InvalidWitness,
    };
    if (authenticated) |records_value| {
        var records = records_value;
        records.deinit(allocator);
        return;
    }

    var resources = bal_witness.planAllocAssumeValidated(allocator, claim) catch
        return error.OutOfMemory;
    defer resources.deinit(allocator);
    bal_witness.probeState(backend.reader(), resources.resources.state) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.InvalidWitness => return error.InvalidWitness,
        else => return error.InfrastructureFailure,
    };
}

fn normalizeCommitError(err: anyerror) CommitError {
    return switch (err) {
        error.OutOfMemory => error.OutOfMemory,
        error.ResourceLimitExceeded => error.ResourceLimitExceeded,
        error.InvalidWitness => error.InvalidWitness,
        else => error.InfrastructureFailure,
    };
}
