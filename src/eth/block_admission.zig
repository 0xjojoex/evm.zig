//! Block access-list claim admission for Ethereum BlockSTF.
//!
//! The accepted claim spans decode, state admission, capacity hints, and the
//! final claim-versus-observed comparison. It does not execute or commit state.

const std = @import("std");

const bal = @import("bal/model.zig");
const bal_witness = @import("bal/witness.zig");
const execution_resources = @import("../execution/resources.zig");
const rlp = @import("rlp");
const Backend = @import("../backend.zig").Backend;
const ClaimPlan = @import("bal/ClaimPlan.zig").ClaimPlan;
const ClosedWorld = @import("bal/ClosedWorld.zig");

pub const AdmissionError = error{
    InfrastructureFailure,
    InvalidBlockAccessList,
    InvalidWitness,
    OutOfMemory,
    ResourceLimitExceeded,
};

pub const Claim = struct {
    decoded: ?bal.Decoded = null,
    counts: ?bal.Counts = null,

    pub const DecodeError = error{ OutOfMemory, BlockAccessListTooLarge, MalformedBlockAccessList, InvalidBlockAccessList };

    pub fn decode(
        allocator: std.mem.Allocator,
        encoded_claim: ?[]const u8,
        transaction_count: bal.BlockAccessIndex,
        gas_limit: u64,
    ) DecodeError!Claim {
        const encoded = encoded_claim orelse return .{};
        var budget = rlp.Budget.init(bal.blockDecodeLimits(
            encoded.len,
            transaction_count,
            gas_limit,
        ));
        var decoded = bal.decodeWithBudget(allocator, encoded, &budget) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            error.DecodeAllocationLimitExceeded,
            error.DecodeItemLimitExceeded,
            => return error.BlockAccessListTooLarge,
            else => return error.MalformedBlockAccessList,
        };
        errdefer decoded.deinit(allocator);
        const counts = validate(decoded.accounts, transaction_count, gas_limit) catch |err| switch (err) {
            error.BlockAccessListGasLimitExceeded => return error.BlockAccessListTooLarge,
            error.AccountsOutOfOrder, error.DuplicateAccount => return error.MalformedBlockAccessList,
            else => return error.InvalidBlockAccessList,
        };
        return .{ .decoded = decoded, .counts = counts };
    }

    /// Best-effort resource-plan hook. Failure falls back to authoritative lazy
    /// reads and never changes block validity.
    pub fn prepareResources(
        self: *const Claim,
        allocator: std.mem.Allocator,
        preparer: ?execution_resources.Preparer,
    ) !void {
        const service = preparer orelse return;
        const claimed_accounts = self.accounts() orelse return;
        var plan = try bal_witness.planAllocAssumeValidated(allocator, claimed_accounts);
        defer plan.deinit(allocator);
        service.prepare(plan.resources) catch {};
    }

    pub fn accounts(self: *const Claim) ?bal.BlockAccessList {
        const decoded = self.decoded orelse return null;
        return decoded.accounts;
    }

    pub fn deinit(self: *Claim, allocator: std.mem.Allocator) void {
        if (self.decoded) |*decoded| decoded.deinit(allocator);
        self.* = undefined;
    }
};

pub fn transactionCount(count: usize) !bal.BlockAccessIndex {
    return std.math.cast(bal.BlockAccessIndex, count) orelse error.BlockAccessIndexOverflow;
}

pub fn validateCounts(counts: bal.Counts, gas_limit: u64) bal.ValidationError!void {
    if (gas_limit != 0 and counts.blockAccessItems() > gas_limit / bal.item_cost)
        return error.BlockAccessListGasLimitExceeded;
}

fn validate(
    block_access_list: bal.BlockAccessList,
    transaction_count: bal.BlockAccessIndex,
    gas_limit: u64,
) bal.ValidationError!bal.Counts {
    try bal.validate(block_access_list, .{ .transaction_count = transaction_count });
    const counts = bal.count(block_access_list);
    try validateCounts(counts, gas_limit);
    return counts;
}

/// Authenticate a validated claim and take ownership of its execution state.
/// Plan and parent facts are released on every failure path.
pub fn closedState(
    allocator: std.mem.Allocator,
    backend: *Backend,
    claim: bal.BlockAccessList,
) AdmissionError!ClosedWorld.State {
    var plan = ClaimPlan.initAssumeValidated(allocator, claim) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimitExceeded, error.TrieKeyCollision => return error.InvalidBlockAccessList,
    };
    const authenticated = backend.authenticateClaimPlan(allocator, plan) catch |err| {
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
    const codes = backend.parentCodes() orelse {
        facts.deinit(allocator);
        plan.deinit(allocator);
        return error.InvalidWitness;
    };
    return ClosedWorld.initStateHashed(allocator, plan, facts, codes) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.ResourceLimitExceeded => return error.ResourceLimitExceeded,
        error.CodeHashCollision => return error.InvalidWitness,
    };
}

pub fn precheckClaim(
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
