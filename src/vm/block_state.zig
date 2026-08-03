//! Compile-time block-state representations the engine is parameterized on.
//!
//! Each owns representation-specific admission and commitment while the
//! executor sees only its concrete `State` type.

const std = @import("std");

const Backend = @import("../backend.zig").Backend;
const bal = @import("../eth/bal/model.zig");
const bal_witness = @import("../eth/bal/witness.zig");
const ClaimPlan = @import("../eth/bal/ClaimPlan.zig").ClaimPlan;
const Reader = @import("../state/Reader.zig");
const TrackedState = @import("../state/TrackedState.zig");
const BlockState = @import("../stateless/BlockState.zig");

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

pub fn Tracked(comptime spec: anytype) type {
    return struct {
        pub const State = TrackedState;
        pub const external_observation_capture = true;

        pub fn checkSpec(_: @TypeOf(spec)) void {}

        pub fn initState(allocator: std.mem.Allocator, reader: ?Reader) State {
            return State.initForSpec(allocator, spec, reader);
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
        ) AdmissionError!State {
            if (input.precheck_claim_state) {
                const claim = input.validated_claim orelse return error.InvalidBlockAccessList;
                try precheckClaim(allocator, input.backend, claim);
            }
            return initState(allocator, input.backend.reader());
        }

        pub fn stateRoot(
            allocator: std.mem.Allocator,
            backend: *Backend,
            accepted: State.AcceptedView,
        ) CommitError![32]u8 {
            return backend.stateRootAfterChanges(allocator, accepted.changes()) catch |err|
                return normalizeCommitError(err);
        }

        pub fn commit(backend: *Backend, accepted: State.AcceptedView) CommitError!void {
            backend.commit(accepted.changes()) catch |err|
                return normalizeCommitError(err);
        }

        pub fn consumeObservationTarget(
            target: anytype,
            block_access_index: bal.BlockAccessIndex,
            observations: State.ObservationsView,
        ) !void {
            try target.consume(block_access_index, observations);
        }
    };
}

/// State closed over a validated block access list and authenticated against a
/// witness — no reader, no fork name in the contract.
///
/// The BAL fixes the exact account/slot set up front, so admission can build a
/// dense `ClaimPlan` and resolve every access by index. Authentication happens
/// once, in bulk, against the parent root; there is nothing to commit back
/// afterwards, only a dense root to recompute. `checkSpec` enforces the BAL
/// requirement — any fork whose spec carries `block.block_access_list` is
/// admissible, which today means Amsterdam but is not scoped to it.
pub const BalStateless = struct {
    pub const State = BlockState;
    pub const external_observation_capture = false;

    pub fn checkSpec(comptime spec: anytype) void {
        if (!spec.block.block_access_list) {
            @compileError("BalStateless requires a block-access-list specification");
        }
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
    ) AdmissionError!State {
        const claim = input.validated_claim orelse return error.InvalidBlockAccessList;
        var plan = ClaimPlan.initAssumeValidated(allocator, claim) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.ResourceLimitExceeded, error.TrieKeyCollision => return error.InvalidBlockAccessList,
        };
        const authenticated = input.backend.authenticateClaimPlan(allocator, plan) catch |err| {
            plan.deinit(allocator);
            return switch (err) {
                error.OutOfMemory => error.OutOfMemory,
                else => error.InvalidWitness,
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
        return State.initWithParentCodes(allocator, plan, facts, codes) catch |err| switch (err) {
            error.OutOfMemory => error.OutOfMemory,
            error.ResourceLimitExceeded => error.ResourceLimitExceeded,
            error.CodeHashCollision => error.InvalidWitness,
        };
    }

    pub fn stateRoot(
        allocator: std.mem.Allocator,
        backend: *Backend,
        accepted: State.AcceptedView,
    ) CommitError![32]u8 {
        return backend.stateRootAfterDenseCommit(allocator, accepted.commit()) catch |err|
            return normalizeCommitError(err);
    }

    pub fn commit(_: *Backend, _: State.AcceptedView) CommitError!void {}

    pub fn consumeObservationTarget(
        _: anytype,
        _: bal.BlockAccessIndex,
        _: State.ObservationsView,
    ) !void {
        unreachable;
    }
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
