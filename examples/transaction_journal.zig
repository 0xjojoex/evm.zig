//! Application-owned state journal composed with an exact evmz Engine.
//!
//! This example uses a counter to show the ownership boundary:
//!
//! - `CounterProgram` owns its transaction carrier and execution semantics.
//! - `CounterRuntime` implements a reentrant native contract.
//! - `CounterJournal` follows EVM transaction and CALL/CREATE rollback.
//! - `CounterBlock` owns accepted EVM and sidecar snapshots together.

const std = @import("std");
const evmz = @import("evmz");

/// Minimal off-trie counter state with transaction-local undo positions.
///
/// A production implementation may journal any application-owned state.
/// The six public lifecycle methods are the contract selected by
/// `CompileOptions.transaction_journal`.
pub const CounterJournal = struct {
    pub const BranchCheckpoint = struct {
        value: u64,
    };

    value: u64 = 0,
    undo: [32]u64 = undefined,
    undo_len: usize = 0,
    checkpoints: [32]usize = undefined,
    checkpoints_len: usize = 0,
    transaction_start: ?usize = null,

    pub fn increase(self: *CounterJournal, increment: u64) error{Overflow}!void {
        const next = try std.math.add(u64, self.value, increment);
        std.debug.assert(self.transaction_start != null);
        std.debug.assert(self.undo_len < self.undo.len);
        self.undo[self.undo_len] = self.value;
        self.undo_len += 1;
        self.value = next;
    }

    pub fn beginTransaction(self: *CounterJournal) void {
        std.debug.assert(self.transaction_start == null);
        std.debug.assert(self.undo_len == 0);
        self.transaction_start = self.undo_len;
    }

    pub fn checkpoint(self: *CounterJournal) void {
        std.debug.assert(self.transaction_start != null);
        std.debug.assert(self.checkpoints_len < self.checkpoints.len);
        self.checkpoints[self.checkpoints_len] = self.undo_len;
        self.checkpoints_len += 1;
    }

    pub fn commitCheckpoint(self: *CounterJournal) void {
        std.debug.assert(self.transaction_start != null);
        std.debug.assert(self.checkpoints_len != 0);
        self.checkpoints_len -= 1;
    }

    pub fn revertCheckpoint(self: *CounterJournal) void {
        std.debug.assert(self.checkpoints_len != 0);
        self.checkpoints_len -= 1;
        self.revertTo(self.checkpoints[self.checkpoints_len]);
    }

    pub fn retainTransaction(self: *CounterJournal) void {
        std.debug.assert(self.transaction_start.? == 0);
        std.debug.assert(self.checkpoints_len == 0);
        self.undo_len = 0;
        self.transaction_start = null;
    }

    pub fn discardTransaction(self: *CounterJournal) void {
        std.debug.assert(self.checkpoints_len == 0);
        self.revertTo(self.transaction_start.?);
        std.debug.assert(self.undo_len == 0);
        self.transaction_start = null;
    }

    pub fn branchCheckpoint(self: *const CounterJournal) BranchCheckpoint {
        std.debug.assert(self.transaction_start == null);
        std.debug.assert(self.checkpoints_len == 0);
        return .{ .value = self.value };
    }

    pub fn restoreBranch(self: *CounterJournal, checkpoint_value: BranchCheckpoint) void {
        std.debug.assert(self.transaction_start == null);
        std.debug.assert(self.checkpoints_len == 0);
        self.value = checkpoint_value.value;
    }

    fn revertTo(self: *CounterJournal, undo_len: usize) void {
        std.debug.assert(self.transaction_start != null);
        std.debug.assert(undo_len <= self.undo_len);
        while (self.undo_len > undo_len) {
            self.undo_len -= 1;
            self.value = self.undo[self.undo_len];
        }
    }
};

/// Address reserved by this example for its native counter runtime.
pub const CounterContract = struct {
    pub const address = evmz.addr(0x1000);

    pub fn active(candidate: evmz.Address) bool {
        return candidate.eql(address);
    }
};

/// Native code mutates the counter and may call back into the EVM. This example
/// mirrors the counter into EVM storage so rollback is visible in both domains.
pub const CounterRuntime = struct {
    journal: *CounterJournal,

    pub fn service(self: *CounterRuntime) evmz.execution.ReentrantNativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(
        ptr: *anyopaque,
        call: evmz.execution.ReentrantNativeContractCall,
    ) !evmz.execution.ReentrantNativeContractResult {
        const self: *CounterRuntime = @ptrCast(@alignCast(ptr));
        if (call.message.input_data.len != 2) return revert(call.message.gas);

        const increment = call.message.input_data[0];
        const force_revert = call.message.input_data[1] != 0;
        try self.journal.increase(increment);
        _ = try call.host.setStorage(
            .fromAddress(call.message.recipient),
            0,
            self.journal.value,
        );

        return .{
            .status = if (force_revert) .revert else .success,
            .output_data = &.{},
            .gas_left = call.message.gas,
        };
    }

    fn revert(gas_left: i64) evmz.execution.ReentrantNativeContractResult {
        return .{
            .status = .revert,
            .output_data = &.{},
            .gas_left = gas_left,
        };
    }
};

pub const counter_spec = evmz.eth.latest.extend(.{
    .reentrant_native_contract = CounterContract,
});

/// The journal implementation is part of the generated Executor type.
pub const CounterEngine = evmz.EngineWithOptions(counter_spec, .{
    .transaction_journal = CounterJournal,
});

pub const CounterTransaction = struct {
    sender: evmz.Address,
    increment: u8,
    force_revert: bool = false,
};

pub const CounterOutput = struct {
    status: evmz.execution.Status,
};

pub const CounterRejection = enum {
    zero_increment,
};

pub const CounterInput = struct {
    tx: CounterTransaction,
};

pub const CounterContext = CounterEngine.Context(CounterInput);
pub const CounterError = CounterContext.Error;
pub const CounterOutcome = evmz.transaction.TransitionOutcomeType(CounterOutput, CounterRejection);

pub const CounterFamily = struct {
    pub fn transact(context: *CounterContext, tx: CounterTransaction) CounterError!CounterOutcome {
        if (tx.increment == 0) return .{ .rejected = .zero_increment };

        const input = [_]u8{ tx.increment, @intFromBool(tx.force_revert) };
        const request = executionRequest(tx.sender, &input);

        try context.beginTransaction();
        try context.beginExecution(request, .{});
        const result = (try context.runPayload(request)).result;
        try context.finalizeState();
        return .{ .completed = .{ .status = result.status() } };
    }
};

pub const CounterProgram = CounterEngine.Program(
    CounterInput,
    CounterOutput,
    CounterRejection,
    CounterError,
    CounterFamily,
);

/// Concrete chain fold. Accepted snapshots pair the two state domains here,
/// above the reusable EVM Engine.
pub const CounterBlock = struct {
    pub const Executor = CounterEngine.Executor;
    pub const InitError = CounterError || error{UncommittedChanges};
    pub const CheckpointError = CounterError;

    pub const Checkpoint = struct {
        evm: Executor.BranchCheckpoint,
        sidecar: CounterJournal.BranchCheckpoint,

        pub fn deinit(self: *Checkpoint) void {
            self.evm.deinit();
            self.* = undefined;
        }
    };

    pub const Outcome = union(enum) {
        included: CounterOutput,
        rejected: CounterRejection,
    };

    executor: *Executor,
    journal: *CounterJournal,
    claim: evmz.block.Claim,
    initial: ?Checkpoint,

    pub fn init(executor: *Executor, journal: *CounterJournal) InitError!CounterBlock {
        const claim = try evmz.block.Claim.begin(executor);
        errdefer claim.release(executor);
        return .{
            .executor = executor,
            .journal = journal,
            .claim = claim,
            .initial = try capture(executor, journal),
        };
    }

    pub fn transact(self: *CounterBlock, tx: CounterTransaction) CounterError!Outcome {
        self.claim.requireActive(self.executor);
        const outcome = try CounterProgram.transactInBlock(
            self.executor,
            self.claim,
            .{ .tx = tx },
            .normal,
        );
        return switch (outcome) {
            .rejected => |reason| .{ .rejected = reason },
            .executed => |executed_value| blk: {
                var executed = executed_value;
                defer executed.discardIfCurrent();
                break :blk .{ .included = executed.retainResult() };
            },
        };
    }

    pub fn checkpoint(self: *CounterBlock) CheckpointError!Checkpoint {
        self.claim.requireActive(self.executor);
        return capture(self.executor, self.journal);
    }

    pub fn restore(self: *CounterBlock, checkpoint_value: *Checkpoint) void {
        self.claim.requireActive(self.executor);
        self.executor.restoreBranch(&checkpoint_value.evm);
        self.journal.restoreBranch(checkpoint_value.sidecar);
    }

    pub fn finish(self: *CounterBlock) void {
        const initial = if (self.initial) |*value| value else unreachable;
        self.claim.requireActive(self.executor);
        initial.deinit();
        self.initial = null;
        self.claim.release(self.executor);
    }

    pub fn discardIfUnfinished(self: *CounterBlock) void {
        const initial = if (self.initial) |*value| value else return;
        self.restore(initial);
        initial.deinit();
        self.initial = null;
        self.claim.release(self.executor);
    }

    fn capture(
        executor: *Executor,
        journal: *const CounterJournal,
    ) CheckpointError!Checkpoint {
        return .{
            .evm = executor.branchCheckpoint() catch |err|
                return evmz.executor.errors.normalize(err),
            .sidecar = journal.branchCheckpoint(),
        };
    }

    fn include(
        block: *CounterBlock,
        tx: CounterTransaction,
    ) (CounterError || error{UnexpectedRejection})!CounterOutput {
        return switch (try block.transact(tx)) {
            .included => |output| output,
            .rejected => return error.UnexpectedRejection,
        };
    }
};

pub const Snapshot = struct {
    sidecar_value: u64,
    evm_value: u256,
};

pub const DemoResult = struct {
    after_success: Snapshot,
    after_native_revert: Snapshot,
    before_branch_restore: Snapshot,
    after_branch_restore: Snapshot,
};

pub const DemoError = CounterError || CounterBlock.InitError || error{
    UnexpectedRejection,
    UnexpectedStatus,
};

pub fn run(allocator: std.mem.Allocator) DemoError!DemoResult {
    const sender = evmz.addr(0xaaaa);
    var journal: CounterJournal = .{};
    var counter_runtime: CounterRuntime = .{ .journal = &journal };
    var executor = CounterEngine.Executor.init(allocator, .{
        .transaction_journal = &journal,
        .reentrant_native_contract_runtime = counter_runtime.service(),
    });
    defer executor.deinit();

    var block = try CounterBlock.init(&executor, &journal);
    defer block.discardIfUnfinished();

    const success = try block.include(.{ .sender = sender, .increment = 7 });
    if (success.status != .success) return error.UnexpectedStatus;
    const after_success = try snapshot(&executor, &journal);

    const failed = try block.include(.{
        .sender = sender,
        .increment = 9,
        .force_revert = true,
    });
    if (failed.status != .revert) return error.UnexpectedStatus;
    const after_native_revert = try snapshot(&executor, &journal);

    var accepted = try block.checkpoint();
    defer accepted.deinit();
    const advanced = try block.include(.{ .sender = sender, .increment = 5 });
    if (advanced.status != .success) return error.UnexpectedStatus;
    const before_branch_restore = try snapshot(&executor, &journal);
    block.restore(&accepted);
    const after_branch_restore = try snapshot(&executor, &journal);

    block.finish();
    return .{
        .after_success = after_success,
        .after_native_revert = after_native_revert,
        .before_branch_restore = before_branch_restore,
        .after_branch_restore = after_branch_restore,
    };
}

pub fn main(init: std.process.Init) !void {
    const result = try run(init.gpa);
    std.debug.print("successful native call: sidecar={d}, evm={d}\n", .{
        result.after_success.sidecar_value,
        result.after_success.evm_value,
    });
    std.debug.print("reverted native call rolled back: sidecar={d}, evm={d}\n", .{
        result.after_native_revert.sidecar_value,
        result.after_native_revert.evm_value,
    });
    std.debug.print("accepted branch: sidecar {d}->{d}, evm {d}->{d}\n", .{
        result.before_branch_restore.sidecar_value,
        result.after_branch_restore.sidecar_value,
        result.before_branch_restore.evm_value,
        result.after_branch_restore.evm_value,
    });
}

test "transaction journal demo keeps EVM and sidecar rollback coherent" {
    const result = try run(std.testing.allocator);
    const expected: Snapshot = .{
        .sidecar_value = 7,
        .evm_value = 7,
    };
    try std.testing.expectEqualDeep(expected, result.after_success);
    try std.testing.expectEqualDeep(expected, result.after_native_revert);
    try std.testing.expectEqualDeep(Snapshot{
        .sidecar_value = 12,
        .evm_value = 12,
    }, result.before_branch_restore);
    try std.testing.expectEqualDeep(expected, result.after_branch_restore);
}

fn snapshot(
    executor: *CounterEngine.Executor,
    journal: *const CounterJournal,
) CounterError!Snapshot {
    const stored = executor.getStorage(CounterContract.address, 0) catch |err|
        return evmz.executor.errors.normalize(err);
    return .{
        .sidecar_value = journal.value,
        .evm_value = stored,
    };
}

fn executionRequest(
    sender: evmz.Address,
    input: []const u8,
) evmz.execution.ExecutionRequest {
    return .{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = CounterContract.address,
            .input = input,
        } },
        .gas = .legacy(100_000),
    };
}
