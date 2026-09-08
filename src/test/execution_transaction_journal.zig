const std = @import("std");
const evmz = @import("../evm.zig");

const execution = evmz.execution;

const TestJournal = struct {
    const BranchCheckpoint = struct {
        value: u64,
    };

    value: u64 = 0,
    undo: [16]u64 = undefined,
    undo_len: usize = 0,
    checkpoints: [16]usize = undefined,
    checkpoints_len: usize = 0,
    attempt_start: ?usize = null,
    begins: usize = 0,
    retains: usize = 0,
    discards: usize = 0,

    fn write(self: *TestJournal, value: u64) void {
        std.debug.assert(self.attempt_start != null);
        std.debug.assert(self.undo_len < self.undo.len);
        self.undo[self.undo_len] = self.value;
        self.undo_len += 1;
        self.value = value;
    }

    pub fn beginTransaction(self: *TestJournal) void {
        std.debug.assert(self.attempt_start == null);
        std.debug.assert(self.undo_len == 0);
        self.attempt_start = self.undo_len;
        self.begins += 1;
    }

    pub fn checkpoint(self: *TestJournal) void {
        std.debug.assert(self.attempt_start != null);
        std.debug.assert(self.checkpoints_len < self.checkpoints.len);
        self.checkpoints[self.checkpoints_len] = self.undo_len;
        self.checkpoints_len += 1;
    }

    pub fn commitCheckpoint(self: *TestJournal) void {
        std.debug.assert(self.attempt_start != null);
        std.debug.assert(self.checkpoints_len != 0);
        self.checkpoints_len -= 1;
    }

    pub fn revertCheckpoint(self: *TestJournal) void {
        std.debug.assert(self.checkpoints_len != 0);
        self.checkpoints_len -= 1;
        const checkpoint_value = self.checkpoints[self.checkpoints_len];
        self.revertTo(checkpoint_value);
    }

    pub fn retainTransaction(self: *TestJournal) void {
        std.debug.assert(self.attempt_start.? == 0);
        std.debug.assert(self.checkpoints_len == 0);
        self.undo_len = 0;
        self.attempt_start = null;
        self.retains += 1;
    }

    pub fn discardTransaction(self: *TestJournal) void {
        std.debug.assert(self.checkpoints_len == 0);
        self.revertTo(self.attempt_start.?);
        std.debug.assert(self.undo_len == 0);
        self.attempt_start = null;
        self.discards += 1;
    }

    fn revertTo(self: *TestJournal, checkpoint_value: usize) void {
        std.debug.assert(self.attempt_start != null);
        std.debug.assert(checkpoint_value <= self.undo_len);
        while (self.undo_len > checkpoint_value) {
            self.undo_len -= 1;
            self.value = self.undo[self.undo_len];
        }
    }

    fn branchCheckpoint(self: *const TestJournal) BranchCheckpoint {
        std.debug.assert(self.attempt_start == null);
        std.debug.assert(self.checkpoints_len == 0);
        return .{ .value = self.value };
    }

    fn restoreBranch(self: *TestJournal, checkpoint_value: BranchCheckpoint) void {
        std.debug.assert(self.attempt_start == null);
        std.debug.assert(self.checkpoints_len == 0);
        self.value = checkpoint_value.value;
    }
};

const NativeContract = struct {
    const target = evmz.addr(0x1000);

    pub fn active(address: evmz.Address) bool {
        return evmz.Address.eql(address, target);
    }
};

const JournalVm = evmz.VmWithOptions(
    evmz.eth.latest.extend(.{ .reentrant_native_contract = NativeContract }),
    .{ .transaction_journal = TestJournal },
);

test "transaction journal is a compile-time executor capability" {
    const DefaultExecutor = evmz.Engine(evmz.eth.latest).Executor;

    try std.testing.expectEqual(void, @FieldType(DefaultExecutor, "transaction_journal"));
    try std.testing.expect(!@hasField(DefaultExecutor.Init, "transaction_journal"));
    try std.testing.expectEqual(
        *TestJournal,
        @FieldType(JournalVm.Executor, "transaction_journal"),
    );
    try std.testing.expectEqual(
        *TestJournal,
        @FieldType(JournalVm.Executor.Init, "transaction_journal"),
    );
}

const NativeRuntime = struct {
    journal: *TestJournal,
    reentry_target: evmz.Address,

    fn service(self: *NativeRuntime) execution.ReentrantNativeContractRuntime {
        return .{ .ptr = self, .vtable = &.{ .execute = execute } };
    }

    fn execute(
        ptr: *anyopaque,
        call: execution.ReentrantNativeContractCall,
    ) !execution.ReentrantNativeContractResult {
        const self: *NativeRuntime = @ptrCast(@alignCast(ptr));
        const command = if (call.message.input_data.len == 0) @as(u8, 1) else call.message.input_data[0];
        const value: u64 = switch (command) {
            0xff => 0xff,
            0x30 => 0x30,
            else => 1,
        };
        self.journal.write(value);
        _ = try call.host.setStorage(.fromAddress(call.message.recipient), 1, value);

        if (command == 0x30) {
            const nested = try call.host.call(.{
                .depth = call.message.depth + 1,
                .kind = .call,
                .gas = call.message.gas,
                .gas_reservoir = call.message.gas_reservoir,
                .recipient = self.reentry_target,
                .sender = call.message.recipient,
                .input_data = &.{},
                .value = 0,
                .is_static = call.message.is_static,
                .code_address = self.reentry_target,
            });
            if (nested.status() != .revert) return error.ExpectedNestedRevert;
        }

        if (command == 0xff) return .{
            .status = .revert,
            .output_data = try call.allocator.dupe(u8, &.{0xde}),
            .gas_left = call.message.gas,
        };
        return .{
            .status = .success,
            .output_data = &.{},
            .gas_left = call.message.gas,
        };
    }
};

test "transaction journal follows native call and parent frame rollback" {
    const sender = evmz.addr(0xaaaa);
    const reverting_child = evmz.addr(0xbbbb);
    var journal: TestJournal = .{};
    var native: NativeRuntime = .{
        .journal = &journal,
        .reentry_target = reverting_child,
    };
    var executor = JournalVm.Executor.init(std.testing.allocator, .{
        .reentrant_native_contract_runtime = native.service(),
        .transaction_journal = &journal,
    });
    defer executor.deinit();
    const reverting_child_code = revertingNativeCaller();
    var child_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try child_account.setCode(&reverting_child_code);
    try executor.state.seedAccount(reverting_child, child_account);

    const success = try executor.executeStandalone(
        request(sender, NativeContract.target, &.{}),
        .{},
    );
    try std.testing.expectEqual(JournalVm.Interpreter.Status.success, success.status());
    try std.testing.expectEqual(@as(u64, 1), journal.value);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(NativeContract.target, 1));

    const failure = try executor.executeStandalone(
        request(sender, NativeContract.target, &.{0xff}),
        .{},
    );
    try std.testing.expectEqual(JournalVm.Interpreter.Status.revert, failure.status());
    try std.testing.expectEqualSlices(u8, &.{0xde}, failure.output_data);
    try std.testing.expectEqual(@as(u64, 1), journal.value);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(NativeContract.target, 1));

    const reentered = try executor.executeStandalone(
        request(sender, NativeContract.target, &.{0x30}),
        .{},
    );
    try std.testing.expectEqual(JournalVm.Interpreter.Status.success, reentered.status());
    try std.testing.expectEqual(@as(u64, 0x30), journal.value);
    try std.testing.expectEqual(@as(u256, 0x30), try executor.getStorage(NativeContract.target, 1));
    try std.testing.expectEqual(journal.begins, journal.retains);
    try std.testing.expectEqual(@as(usize, 0), journal.discards);
}

test "EVM caller observes native revert data and continues after paired rollback" {
    const sender = evmz.addr(0xaaaa);
    const caller = evmz.addr(0xbbbb);
    var journal: TestJournal = .{};
    var native: NativeRuntime = .{
        .journal = &journal,
        .reentry_target = caller,
    };
    var executor = JournalVm.Executor.init(std.testing.allocator, .{
        .reentrant_native_contract_runtime = native.service(),
        .transaction_journal = &journal,
    });
    defer executor.deinit();

    const caller_code = evmz.t.bytecode(.{
        // Put the native command at memory[0], then copy one byte of return data
        // to memory[1] so input and output remain independently observable.
        .PUSH1, 0xff,   .PUSH0,  .MSTORE8,
        .PUSH1, 0x01,   .PUSH1,  0x01,
        .PUSH1, 0x01,   .PUSH0,  .PUSH0,
        .PUSH2, 0x10,   0x00,    .GAS,
        .CALL,  .PUSH0, .SSTORE,
        // Store the first returned byte at slot 1, then prove execution
        // continued by writing the marker at slot 2.
        .PUSH1,
        0x01,   .MLOAD, .PUSH0,  .BYTE,
        .PUSH1, 0x01,   .SSTORE, .PUSH1,
        0x2a,   .PUSH1, 0x02,    .SSTORE,
        .STOP,
    });
    var caller_account = evmz.state.MemoryAccount.init(std.testing.allocator);
    try caller_account.setCode(&caller_code);
    try executor.state.seedAccount(caller, caller_account);

    const baseline = try executor.executeStandalone(
        request(sender, NativeContract.target, &.{}),
        .{},
    );
    try std.testing.expectEqual(JournalVm.Interpreter.Status.success, baseline.status());

    var caller_request = request(sender, caller, &.{});
    caller_request.gas = .legacy(1_000_000);
    const result = try executor.executeStandalone(caller_request, .{});

    try std.testing.expectEqual(JournalVm.Interpreter.Status.success, result.status());
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(caller, 0));
    try std.testing.expectEqual(@as(u256, 0xde), try executor.getStorage(caller, 1));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(caller, 2));
    try std.testing.expectEqual(@as(u64, 1), journal.value);
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(NativeContract.target, 1));
}

test "Program result owns journal retain and discard" {
    const Engine = evmz.EngineWithOptions(
        evmz.eth.latest,
        .{ .transaction_journal = TestJournal },
    );
    const Input = struct {
        tx: u8,
        journal: *TestJournal,
    };
    const Context = Engine.Context(Input);
    const Rejection = enum { zero };
    const FamilyError = Context.Error || error{InjectedFailure};
    const Outcome = evmz.transaction.TransitionOutcomeType(u8, Rejection);
    const Family = struct {
        pub fn transact(context: *Context, tx: u8) FamilyError!Outcome {
            if (tx == 0) return .{ .rejected = .zero };
            try context.beginTransaction();
            context.input().journal.write(tx);
            if (tx == 0xff) return error.InjectedFailure;
            return .{ .completed = tx };
        }
    };
    const Program = Engine.Program(Input, u8, Rejection, FamilyError, Family);

    var journal: TestJournal = .{};
    var executor = Engine.Executor.init(std.testing.allocator, .{
        .transaction_journal = &journal,
    });
    defer executor.deinit();

    const discarded = try Program.transact(&executor, .{ .tx = 7, .journal = &journal });
    switch (discarded) {
        .rejected => return error.UnexpectedRejection,
        .executed => |executed| executed.discard(),
    }
    try std.testing.expectEqual(@as(u64, 0), journal.value);

    const retained = try Program.transact(&executor, .{ .tx = 8, .journal = &journal });
    switch (retained) {
        .rejected => return error.UnexpectedRejection,
        .executed => |executed| try std.testing.expectEqual(@as(u8, 8), executed.retainResult()),
    }
    try std.testing.expectEqual(@as(u64, 8), journal.value);

    try std.testing.expectError(
        error.InjectedFailure,
        Program.transact(&executor, .{ .tx = 0xff, .journal = &journal }),
    );
    try std.testing.expectEqual(@as(u64, 8), journal.value);
    try std.testing.expectEqual(@as(usize, 3), journal.begins);
    try std.testing.expectEqual(@as(usize, 1), journal.retains);
    try std.testing.expectEqual(@as(usize, 2), journal.discards);
}

const BlockEngine = evmz.EngineWithOptions(
    evmz.eth.latest,
    .{ .transaction_journal = TestJournal },
);
const BlockTransaction = struct {
    account: evmz.Address,
    delta: u64,
};
const BlockInput = struct {
    tx: BlockTransaction,
    journal: *TestJournal,
};
const BlockContext = BlockEngine.Context(BlockInput);
const BlockRejection = enum { invalid };
const BlockFamilyError = BlockContext.Error;
const BlockOutcome = evmz.transaction.TransitionOutcomeType(u64, BlockRejection);
const BlockFamily = struct {
    pub fn transact(
        context: *BlockContext,
        tx: BlockTransaction,
    ) BlockFamilyError!BlockOutcome {
        try context.beginTransaction();
        try context.addBalance(tx.account, tx.delta);
        context.input().journal.write(context.input().journal.value + tx.delta);
        return .{ .completed = tx.delta };
    }
};
const BlockProgram = BlockEngine.Program(
    BlockInput,
    u64,
    BlockRejection,
    BlockFamilyError,
    BlockFamily,
);

const SidecarBlock = struct {
    const Executor = BlockEngine.Executor;
    const BranchCheckpointResult = @typeInfo(@TypeOf(Executor.branchSnapshot)).@"fn".return_type.?;
    const BranchCheckpointError = @typeInfo(BranchCheckpointResult).error_union.error_set;

    const Checkpoint = struct {
        evm: Executor.BranchSnapshot,
        journal: TestJournal.BranchCheckpoint,

        fn deinit(self: *Checkpoint) void {
            self.evm.deinit();
            self.* = undefined;
        }
    };

    executor: *Executor,
    journal: *TestJournal,
    claim: evmz.block.Claim,
    initial: ?Checkpoint,

    fn init(executor: *Executor, journal: *TestJournal) !SidecarBlock {
        const claim = try evmz.block.Claim.begin(executor);
        errdefer claim.release(executor);
        return .{
            .executor = executor,
            .journal = journal,
            .claim = claim,
            .initial = try capture(executor, journal),
        };
    }

    fn transact(self: *SidecarBlock, tx: BlockTransaction) BlockFamilyError!u64 {
        self.claim.requireActive(self.executor);
        const outcome = try BlockProgram.transactInBlock(
            self.executor,
            self.claim,
            .{ .tx = tx, .journal = self.journal },
            .normal,
        );
        return switch (outcome) {
            .rejected => unreachable,
            .executed => |executed_value| blk: {
                var executed = executed_value;
                defer executed.discardIfCurrent();
                break :blk executed.retainResult();
            },
        };
    }

    fn checkpoint(self: *SidecarBlock) BranchCheckpointError!Checkpoint {
        self.claim.requireActive(self.executor);
        return capture(self.executor, self.journal);
    }

    fn restore(self: *SidecarBlock, checkpoint_value: *Checkpoint) void {
        self.claim.requireActive(self.executor);
        self.executor.restoreBranch(&checkpoint_value.evm);
        self.journal.restoreBranch(checkpoint_value.journal);
    }

    fn transactThenFail(
        self: *SidecarBlock,
        tx: BlockTransaction,
    ) (BlockFamilyError || BranchCheckpointError || error{InjectedBlockFailure})!void {
        var checkpoint_value = try self.checkpoint();
        defer checkpoint_value.deinit();
        errdefer self.restore(&checkpoint_value);

        _ = try self.transact(tx);
        return error.InjectedBlockFailure;
    }

    fn finish(self: *SidecarBlock) void {
        const initial = if (self.initial) |*value| value else unreachable;
        self.claim.requireActive(self.executor);
        initial.deinit();
        self.initial = null;
        self.claim.release(self.executor);
    }

    fn discardIfUnfinished(self: *SidecarBlock) void {
        const initial = if (self.initial) |*value| value else return;
        self.restore(initial);
        initial.deinit();
        self.initial = null;
        self.claim.release(self.executor);
    }

    fn capture(
        executor: *Executor,
        journal: *const TestJournal,
    ) BranchCheckpointError!Checkpoint {
        return .{
            .evm = try executor.branchSnapshot(),
            .journal = journal.branchCheckpoint(),
        };
    }
};

test "block program pairs accepted EVM and sidecar checkpoints" {
    const account = evmz.addr(0xcccc);
    var journal: TestJournal = .{};
    var executor = BlockEngine.Executor.init(std.testing.allocator, .{
        .transaction_journal = &journal,
    });
    defer executor.deinit();
    var block = try SidecarBlock.init(&executor, &journal);
    defer block.discardIfUnfinished();

    try std.testing.expectEqual(@as(u64, 3), try block.transact(.{ .account = account, .delta = 3 }));
    try std.testing.expectEqual(@as(u64, 5), try block.transact(.{ .account = account, .delta = 5 }));

    var checkpoint_value = try block.checkpoint();
    defer checkpoint_value.deinit();
    _ = try block.transact(.{ .account = account, .delta = 7 });
    try std.testing.expectEqual(@as(u256, 15), try executor.getBalance(account));
    try std.testing.expectEqual(@as(u64, 15), journal.value);

    block.restore(&checkpoint_value);
    try std.testing.expectEqual(@as(u256, 8), try executor.getBalance(account));
    try std.testing.expectEqual(@as(u64, 8), journal.value);

    try std.testing.expectError(
        error.InjectedBlockFailure,
        block.transactThenFail(.{ .account = account, .delta = 11 }),
    );
    try std.testing.expectEqual(@as(u256, 8), try executor.getBalance(account));
    try std.testing.expectEqual(@as(u64, 8), journal.value);

    block.finish();
}

test "block program discards unfinished EVM and sidecar state" {
    const account = evmz.addr(0xdddd);
    var journal: TestJournal = .{};
    var executor = BlockEngine.Executor.init(std.testing.allocator, .{
        .transaction_journal = &journal,
    });
    defer executor.deinit();
    var block = try SidecarBlock.init(&executor, &journal);

    _ = try block.transact(.{ .account = account, .delta = 4 });
    _ = try block.transact(.{ .account = account, .delta = 6 });
    block.discardIfUnfinished();

    try std.testing.expectEqual(@as(u256, 0), try executor.getBalance(account));
    try std.testing.expectEqual(@as(u64, 0), journal.value);
    try std.testing.expect(!executor.acceptedView().hasChanges());
}

fn revertingNativeCaller() [14]u8 {
    return evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0,  .PUSH0,
        .PUSH2, 0x10,   0x00,   .GAS,    .CALL,
        .POP,   .PUSH0, .PUSH0, .REVERT,
    });
}

fn request(
    sender: evmz.Address,
    recipient: evmz.Address,
    input: []const u8,
) execution.ExecutionRequest {
    return .{
        .context = .{
            .chain = .{ .chain_id = 1 },
            .transaction = .{ .origin = sender },
        },
        .message = .{ .call = .{
            .sender = sender,
            .recipient = recipient,
            .input = input,
        } },
        .gas = .legacy(100_000),
    };
}
