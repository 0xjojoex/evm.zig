//! EIP-7928 Block-Level Access List: the model, the validated claim plan, and
//! the claim-indexed execution-state lane built on it.
//!
//! - model (`model.zig`): list shape, validation, encoding, item costs.
//! - `ClaimPlan`: one validated list projected to dense account/storage IDs in
//!   trie order; `ClaimView` and `diff` read and compare lists.
//! - `ClosedWorld`: the world for the closed lane, keyed by `ClaimPlan` IDs over
//!   the universe the list declares; `ClosedState` is `state.WorldState` over
//!   it and the executor's state lane for BAL forks (the open lane is
//!   `evmz.state.OpenState`). `ParentFacts` and `claim_artifacts` are its
//!   ID-native inputs and code store; it commits through `eth.commit` like the
//!   open lane.
//!
//! Driving a block over either lane belongs to `eth.block_stf`; only the
//! BAL-parallel vocabulary and the BAL executor constructor are aliased here.
//!
//! This is experimental and subject to change.

const std = @import("std");
const model = @import("bal/model.zig");
const claim_plan = @import("bal/ClaimPlan.zig");
const Revision = @import("revision.zig").Revision;
const t = @import("../t.zig");
const block_stf = @import("block_stf.zig");
const trie = @import("trie.zig");
const state = @import("../state.zig");
const Backend = @import("../backend.zig").Backend;

pub const projector = @import("bal/projector.zig");

pub const ClaimView = @import("bal/ClaimView.zig");
pub const diff = @import("bal/diff.zig");
pub const ClosedWorld = @import("bal/ClosedWorld.zig");
pub const ClosedState = ClosedWorld.State;
pub const ParentFacts = @import("bal/ParentFacts.zig");
pub const claim_artifacts = @import("bal/claim_artifacts.zig");

pub const Address = model.Address;
pub const BlockAccessIndex = model.BlockAccessIndex;
pub const item_cost = model.item_cost;
pub const empty_hash = model.empty_hash;
pub const StorageChange = model.StorageChange;
pub const BalanceChange = model.BalanceChange;
pub const NonceChange = model.NonceChange;
pub const CodeChange = model.CodeChange;
pub const SlotChanges = model.SlotChanges;
pub const AccountChanges = model.AccountChanges;
pub const BlockAccessList = model.BlockAccessList;
pub const ValidationOptions = model.ValidationOptions;
pub const ValidationError = model.ValidationError;
pub const Counts = model.Counts;
pub const Decoded = model.Decoded;
pub const IndexError = model.IndexError;
pub const ClaimPlan = claim_plan.ClaimPlan;
pub const AccountId = claim_plan.AccountId;
pub const StorageId = claim_plan.StorageId;
pub const ClaimPlanInitError = claim_plan.InitError;

pub const transactionIndex = model.transactionIndex;
pub const postExecutionSystemIndex = model.postExecutionSystemIndex;
pub const count = model.count;
pub const validate = model.validate;
pub const validateGasLimit = model.validateGasLimit;
pub const encodeAlloc = model.encodeAlloc;
pub const hash = model.hash;
pub const decode = model.decode;
pub const decodeWithBudget = model.decodeWithBudget;
pub const blockDecodeLimits = model.blockDecodeLimits;

/// The differential BAL executor for one revision. The caller names the fork:
/// a pinned alias would silently keep meaning the first BAL fork after the
/// next one lands.
pub fn Executor(comptime revision: Revision) type {
    return block_stf.Exact(revision).BalExecutor;
}
pub const Report = block_stf.BalDifferentialReport;
pub const DifferentialStatus = block_stf.BalDifferentialStatus;
pub const ParallelStrategy = block_stf.ParallelStrategy;
pub const ParallelResources = block_stf.ParallelResources;
pub const ParallelFallback = block_stf.ParallelFallback;

test "BAL executor releases an unconsumed state backend" {
    if (comptime !t.forkEnabled(.amsterdam)) return error.SkipZigTest;
    var report = Report{};
    var executor = Executor(.amsterdam).initAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .state_backend = try Backend.fromWitness(
                std.testing.allocator,
                trie.empty_root_hash,
                &.{},
                &.{},
            ),
            .transactions = &.{},
            .root_checks = .{
                .payload_header = .{
                    .state = trie.empty_root_hash,
                    .receipts = trie.empty_root_hash,
                },
            },
            .bal_differential = &report,
        },
        .{ .max_in_flight = 1 },
        .{ .lane_allocator = std.testing.allocator },
    );
    executor.deinit();
}

test {
    std.testing.refAllDecls(claim_plan);
    std.testing.refAllDecls(projector);
    std.testing.refAllDecls(ParentFacts);
    std.testing.refAllDecls(ClosedWorld);
    _ = @import("bal/ClosedWorld_test.zig");
}
