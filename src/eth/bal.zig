//! EIP-7928 Block-Level Access List model and claim-served parallel validation.
//! This is experimental and subject to change.

const std = @import("std");
const model = @import("bal/model.zig");
const block_stf = @import("block_stf.zig");
const state = @import("../state.zig");

pub const tracked_state_projector = @import("bal/tracked_state_projector.zig");

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
pub const IndexResources = model.IndexResources;
pub const IndexResourceMaxima = model.IndexResourceMaxima;
pub const IndexResourcePlan = model.IndexResourcePlan;
pub const Decoded = model.Decoded;
pub const IndexError = model.IndexError;

pub const transactionIndex = model.transactionIndex;
pub const postExecutionSystemIndex = model.postExecutionSystemIndex;
pub const count = model.count;
pub const planIndexResources = model.planIndexResources;
pub const validate = model.validate;
pub const validateGasLimit = model.validateGasLimit;
pub const encodeAlloc = model.encodeAlloc;
pub const hash = model.hash;
pub const decode = model.decode;
pub const decodeWithBudget = model.decodeWithBudget;
pub const blockDecodeLimits = model.blockDecodeLimits;

pub const Executor = block_stf.Exact(.amsterdam).BalExecutor;
pub const Report = block_stf.BalDifferentialReport;
pub const DifferentialStatus = block_stf.BalDifferentialStatus;
pub const Status = block_stf.Status;
pub const Result = block_stf.Result;
pub const BlockInput = block_stf.BlockInput;
pub const AssumeDecodedBlockInput = block_stf.AssumeDecodedBlockInput;
pub const TransactionInput = block_stf.TransactionInput;
pub const ParallelStrategy = block_stf.ParallelStrategy;
pub const ParallelResources = block_stf.ParallelResources;
pub const ParallelFallback = block_stf.ParallelFallback;
pub const ParentBlobGas = block_stf.ParentBlobGas;
pub const RootChecks = block_stf.RootChecks;
pub const DerivedBlockOutput = block_stf.DerivedBlockOutput;

test "BAL executor releases an unconsumed state backend" {
    var report = Report{};
    var executor = Executor.initAssumeDecoded(
        std.testing.io,
        std.testing.allocator,
        .{
            .state_backend = try state.Backend.fromWitness(
                std.testing.allocator,
                [_]u8{0} ** 32,
                &.{},
                &.{},
            ),
            .transactions = &.{},
            .root_checks = .{
                .payload_header = .{
                    .state = .fromHash([_]u8{0} ** 32),
                    .receipts = .fromHash([_]u8{0} ** 32),
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
    std.testing.refAllDecls(tracked_state_projector);
}
