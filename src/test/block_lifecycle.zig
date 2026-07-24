const std = @import("std");
const evmz = @import("../evm.zig");

const Address = evmz.Address;
const system = evmz.eth.system;
const BeforeBlockContext = system.BeforeBlockContext;
const AfterTransactionContext = evmz.AfterTransactionContext;
const FinalizeBlockContext = evmz.FinalizeBlockContext;
const MemoryStore = evmz.state.MemoryStore;

fn VmFor(comptime base: evmz.eth.Spec, comptime block_patch: evmz.eth.spec.BlockSpec.Patch) type {
    return evmz.Vm(base.extend(.{ .block = block_patch }));
}

const lifecycle_code = [_]u8{
    0x5f, 0x35, 0x80, 0x5f, 0x55,
    0x5f, 0x52, 0x60, 0x20, 0x5f,
    0xf3,
};

const LifecycleBlock = struct {
    const before_block_address = evmz.addr(0x1001);
    const before_transaction_address = evmz.addr(0x1002);
    const after_transaction_address = evmz.addr(0x1003);
    const finalize_block_address = evmz.addr(0x1004);

    fn beforeBlock(context: BeforeBlockContext) system.BlockSystemCalls {
        if (context.number != 7 or context.timestamp != 9) return failingCalls();
        return calls(before_block_address, 1);
    }

    fn beforeTransaction(context: system.BeforeTransactionContext) system.BlockSystemCalls {
        if (context.number != 7 or context.timestamp != 9) return failingCalls();
        return calls(before_transaction_address, std.math.cast(u8, context.transaction_index + 2) orelse 0xff);
    }

    fn afterTransaction(context: AfterTransactionContext) system.BlockSystemCalls {
        if (context.number != 7 or
            context.timestamp != 9 or
            context.status != .success or
            context.gas_used == 0 or
            context.cumulative_gas_used != context.gas_used or
            context.cumulative_block_gas == 0)
        {
            return failingCalls();
        }
        return calls(after_transaction_address, std.math.cast(u8, context.transaction_index + 3) orelse 0xff);
    }

    fn finalizeBlock(context: FinalizeBlockContext) system.FinalizeSystemCalls {
        var result = system.FinalizeSystemCalls{};
        if (context.number != 7 or
            context.timestamp != 9 or
            context.transaction_count != 1 or
            context.gas_used == 0 or
            context.block_gas == 0)
        {
            result.append(.{ .call = failingCall(), .output_prefix = 0xff });
            return result;
        }
        result.append(.{
            .call = systemCall(finalize_block_address, 4),
            .output_prefix = 0x99,
        });
        return result;
    }

    fn calls(recipient: Address, marker: u8) system.BlockSystemCalls {
        var result = system.BlockSystemCalls{};
        result.append(systemCall(recipient, marker));
        return result;
    }

    fn failingCalls() system.BlockSystemCalls {
        var result = system.BlockSystemCalls{};
        result.append(failingCall());
        return result;
    }

    fn systemCall(recipient: Address, marker: u8) system.BlockSystemCall {
        var input = [_]u8{0} ** 32;
        input[31] = marker;
        return .{
            .sender = evmz.eth.system_address,
            .recipient = recipient,
            .input = .{ .word = input },
            .gas = 100_000,
            .require_code = true,
        };
    }

    fn failingCall() system.BlockSystemCall {
        return .{
            .sender = evmz.eth.system_address,
            .recipient = evmz.addr(0xffff),
            .gas = 100_000,
            .require_code = true,
        };
    }
};

const LifecycleVm = VmFor(evmz.eth.prague, .{
    .beforeBlock = LifecycleBlock.beforeBlock,
    .beforeTransaction = LifecycleBlock.beforeTransaction,
    .afterTransaction = LifecycleBlock.afterTransaction,
    .finalizeBlock = LifecycleBlock.finalizeBlock,
});

const RejectingBeforeTransactionBlock = struct {
    fn beforeTransaction(_: system.BeforeTransactionContext) system.BlockSystemCalls {
        return LifecycleBlock.failingCalls();
    }
};

const RejectingBeforeTransactionVm = VmFor(evmz.eth.prague, .{
    .beforeTransaction = RejectingBeforeTransactionBlock.beforeTransaction,
});

const EmptyBeforeTransactionBlock = struct {
    var invocations = std.atomic.Value(usize).init(0);

    fn beforeTransaction(_: system.BeforeTransactionContext) system.BlockSystemCalls {
        _ = invocations.fetchAdd(1, .monotonic);
        return .{};
    }
};

const EmptyBeforeTransactionVm = VmFor(evmz.eth.amsterdam, .{
    .beforeTransaction = EmptyBeforeTransactionBlock.beforeTransaction,
});

const ObservationCounter = struct {
    calls: usize = 0,

    pub fn observe(self: *@This(), _: evmz.state.TrackedState.PendingView) !void {
        self.calls += 1;
    }
};

const FailingObservation = struct {
    calls: usize = 0,

    pub fn observe(self: *@This(), _: evmz.state.TrackedState.PendingView) !void {
        self.calls += 1;
        return error.TestObservationFailure;
    }
};

const AtomicLifecycleBlock = struct {
    const recipient = evmz.addr(0x2001);

    fn beforeBlock(_: BeforeBlockContext) system.BlockSystemCalls {
        var result = system.BlockSystemCalls{};
        result.append(LifecycleBlock.systemCall(recipient, 7));
        result.append(LifecycleBlock.failingCall());
        return result;
    }

    fn finalizeBlock(_: FinalizeBlockContext) system.FinalizeSystemCalls {
        var result = system.FinalizeSystemCalls{};
        result.append(.{
            .call = LifecycleBlock.systemCall(recipient, 8),
            .output_prefix = 0x99,
        });
        result.append(.{
            .call = LifecycleBlock.failingCall(),
            .output_prefix = 0xff,
        });
        return result;
    }
};

const AtomicLifecycleVm = VmFor(evmz.eth.prague, .{
    .beforeBlock = AtomicLifecycleBlock.beforeBlock,
    .finalizeBlock = AtomicLifecycleBlock.finalizeBlock,
});

const FinishLifecycleBlock = struct {
    const recipient = evmz.addr(0x3001);

    fn afterTransaction(_: AfterTransactionContext) system.BlockSystemCalls {
        return LifecycleBlock.calls(recipient, 9);
    }
};

const FinishLifecycleVm = VmFor(evmz.eth.prague, .{
    .afterTransaction = FinishLifecycleBlock.afterTransaction,
});

const RejectingAfterTransactionBlock = struct {
    fn afterTransaction(_: AfterTransactionContext) system.BlockSystemCalls {
        return LifecycleBlock.failingCalls();
    }
};

const RejectingAfterTransactionVm = VmFor(evmz.eth.prague, .{
    .afterTransaction = RejectingAfterTransactionBlock.afterTransaction,
});

test "Sequential exposes spec-owned lifecycle phases with derived facts" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    // CALLDATALOAD(0), store it at slot 0, then return the same word.
    inline for (&.{
        LifecycleBlock.before_block_address,
        LifecycleBlock.before_transaction_address,
        LifecycleBlock.after_transaction_address,
        LifecycleBlock.finalize_block_address,
    }) |address| {
        var account = try memory.getOrCreateAccount(address);
        try account.setCode(&lifecycle_code);
    }

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 1), try executor.getStorage(LifecycleBlock.before_block_address, 0));

    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    _ = included.receipt;
    try block.endTransactions();
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 3), try executor.getStorage(LifecycleBlock.after_transaction_address, 0));

    const outputs = try block.finalizeBlock(std.testing.allocator);
    defer {
        for (outputs) |output| std.testing.allocator.free(output);
        std.testing.allocator.free(outputs);
    }
    try std.testing.expectEqual(@as(u256, 4), try executor.getStorage(LifecycleBlock.finalize_block_address, 0));
    try std.testing.expectEqual(@as(usize, 1), outputs.len);
    try std.testing.expectEqual(@as(u8, 0x99), outputs[0][0]);
    try std.testing.expectEqual(@as(u8, 4), outputs[0][32]);
    try std.testing.expectError(error.BlockAlreadyFinalized, block.finalizeBlock(std.testing.allocator));
    try std.testing.expectError(error.BlockAlreadyFinalized, block.systemCall(.{
        .sender = sender,
        .recipient = recipient,
        .gas = 100_000,
    }));
    _ = try block.finish();
}

test "Sequential does not run before-transaction hooks for rejected transactions" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    });
    switch (rejected) {
        .included => {
            return error.UnexpectedExecution;
        },
        .rejected => |err| try std.testing.expectEqual(
            evmz.Evm.Rejection.nonce_too_high,
            err,
        ),
    }
}

test "Sequential failing before-transaction prelude discards the opened attempt" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.SystemCallFailed, block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    }));
    try std.testing.expect(!executor.hasCurrentTransaction());
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 0), (try block.progress()).tx_count);
}

test "Sequential empty before-transaction prelude stays in one observed transition" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    EmptyBeforeTransactionBlock.invocations.store(0, .monotonic);
    var observations = ObservationCounter{};
    var executor = EmptyBeforeTransactionVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(EmptyBeforeTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transactObserved(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    }, &observations)) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try block.endTransactions();

    try std.testing.expectEqual(@as(usize, 1), EmptyBeforeTransactionBlock.invocations.load(.monotonic));
    try std.testing.expectEqual(@as(usize, 1), observations.calls);
    _ = try block.finish();
}

test "Sequential before-transaction prelude shares one journal lifetime with payload" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);

    const Observer = struct {
        address: Address,
        found: bool = false,
        calls: usize = 0,

        pub fn observe(self: *@This(), pending: evmz.state.TrackedState.PendingView) !void {
            self.calls += 1;
            const storage = pending.observations().storage;
            var index: u32 = 0;
            while (index < storage.len()) : (index += 1) {
                const fact = storage.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.address) or fact.key != 0) continue;
                try std.testing.expectEqual(@as(u256, 2), fact.current);
                try std.testing.expect(fact.effect.written);
                self.found = true;
                return;
            }
        }
    };
    var observations = Observer{ .address = LifecycleBlock.before_transaction_address };
    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    _ = switch (try block.transactObserved(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    }, &observations)) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };

    try std.testing.expectEqual(@as(usize, 1), observations.calls);
    try std.testing.expect(observations.found);
    try std.testing.expectEqual(@as(u256, 2), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    block.discardIfUnfinished();
}

test "Sequential block rejection restores before-transaction hook and payload writes" {
    const sender = evmz.addr(0xaaaa);
    const payload = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);
    var payload_account = try memory.getOrCreateAccount(payload);
    try payload_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    block.block.state.block_gas = evmz.transaction.BlockGas.legacy(std.math.maxInt(u64));

    var input = [_]u8{0} ** 32;
    input[31] = 5;
    try std.testing.expectError(error.BlockGasExceeded, block.transact(.{
        .sender = sender,
        .to = payload,
        .input = &input,
        .gas_limit = 300_000,
    }));

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(payload, 0));
    const progress = try block.progress();
    try std.testing.expectEqual(@as(u64, 0), progress.tx_count);
    try std.testing.expectEqual(std.math.maxInt(u64), progress.block_gas.total);
}

test "Sequential discard restores included hook and payload without allocating" {
    const sender = evmz.addr(0xaaaa);
    const payload = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);
    var payload_account = try memory.getOrCreateAccount(payload);
    try payload_account.setCode(&lifecycle_code);

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = LifecycleVm.Executor.init(failing_allocator.allocator(), .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    var input = [_]u8{0} ** 32;
    input[31] = 5;
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = payload,
        .input = &input,
        .gas_limit = 300_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    const receipt = included.receipt;
    try std.testing.expectEqual(receipt.gas_used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);

    failing_allocator.fail_index = failing_allocator.alloc_index;
    block.discardIfUnfinished();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(payload, 0));
    try std.testing.expectError(error.BlockExecutionFinished, block.progress());
}

test "Sequential restores a system call when outer commit observation fails" {
    const recipient = evmz.addr(0x2201);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var failing = FailingObservation{};

    var block = try beginBlock(LifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    var input = [_]u8{0} ** 32;
    input[31] = 5;
    try std.testing.expectError(
        error.TestObservationFailure,
        block.systemCallObserved(.{
            .sender = evmz.eth.system_address,
            .recipient = recipient,
            .input = &input,
            .gas = 100_000,
        }, &failing),
    );
    try std.testing.expectEqual(@as(usize, 1), failing.calls);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(recipient, 0));
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
}

test "Sequential restores included transaction progress when outer observation fails" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(LifecycleBlock.before_transaction_address);
    try hook_account.setCode(&lifecycle_code);

    var executor = LifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var failing = FailingObservation{};

    var block = try beginBlock(LifecycleVm, &executor, .{
        .number = 7,
        .timestamp = 9,
        .gas_limit = 1_000_000,
    });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.TestObservationFailure, block.transactObserved(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
    }, &failing));
    try std.testing.expectEqual(@as(usize, 1), failing.calls);
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(LifecycleBlock.before_transaction_address, 0));
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 0), summary.gas_used);
    try std.testing.expectEqual(@as(u64, 0), summary.block_gas.total);
    try std.testing.expectEqual(@as(u64, 0), summary.tx_count);
}

test "block lifecycle hook batches restore earlier calls when a later call fails" {
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient = try memory.getOrCreateAccount(AtomicLifecycleBlock.recipient);
    try recipient.setCode(&lifecycle_code);

    var executor = AtomicLifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(AtomicLifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.SystemCallFailed, block.beforeBlock(.{}));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(AtomicLifecycleBlock.recipient, 0));

    try std.testing.expectError(error.SystemCallFailed, block.finalizeBlock(std.testing.allocator));
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(AtomicLifecycleBlock.recipient, 0));
}

test "Sequential finish flushes the final included transaction after hook" {
    const sender = evmz.addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var hook_account = try memory.getOrCreateAccount(FinishLifecycleBlock.recipient);
    try hook_account.setCode(&lifecycle_code);

    var executor = FinishLifecycleVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(FinishLifecycleVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = evmz.addr(0xbbbb),
        .gas_limit = 300_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };

    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
    try std.testing.expectEqual(@as(u256, 9), try executor.getStorage(FinishLifecycleBlock.recipient, 0));
}

test "Sequential next transaction stops when the previous after hook fails" {
    const sender = evmz.addr(0xaaaa);
    const recipient = evmz.addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = RejectingAfterTransactionVm.Executor.init(std.testing.allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try beginBlock(RejectingAfterTransactionVm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    _ = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };

    try std.testing.expectError(error.SystemCallFailed, block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);

    block.discardIfUnfinished();
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "one Executor admits only one active Sequential" {
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var block = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    var vm = evmz.Evm.init(&executor);

    try std.testing.expectError(
        error.BlockExecutionActive,
        beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 }),
    );
    try std.testing.expectError(
        error.BlockExecutionActive,
        vm.transact(.{
            .env = .{ .gas_limit = 1_000_000 },
            .tx = .{
                .sender = evmz.addr(0xaaaa),
                .to = evmz.addr(0xbbbb),
                .gas_limit = 21_000,
            },
        }),
    );
    try std.testing.expectError(
        error.BlockExecutionActive,
        executor.reset(.{}),
    );
}

test "independent Executors admit independent Sequential lifetimes" {
    var first_executor = evmz.Evm.Executor.init(std.testing.allocator, .{});
    defer first_executor.deinit();
    var second_executor = evmz.Evm.Executor.init(std.testing.allocator, .{});
    defer second_executor.deinit();

    var first = try beginBlock(evmz.Evm, &first_executor, .{ .gas_limit = 1_000_000 });
    defer first.discardIfUnfinished();
    var second = try beginBlock(evmz.Evm, &second_executor, .{ .gas_limit = 1_000_000 });
    defer second.discardIfUnfinished();

    try std.testing.expectEqual(@as(u64, 0), (try first.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 0), (try second.progress()).tx_count);
}

test "stale Sequential copy cannot resolve a later generation" {
    var executor = evmz.Evm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var first = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    var stale = first;
    first.discardIfUnfinished();

    var second = try beginBlock(evmz.Evm, &executor, .{ .gas_limit = 1_000_000 });
    defer second.discardIfUnfinished();
    stale.discardIfUnfinished();

    try std.testing.expectError(error.StaleBlockExecution, stale.progress());
    try std.testing.expectEqual(@as(u64, 0), (try second.progress()).tx_count);
}

fn beginBlock(comptime Engine: type, executor: *Engine.Executor, env: evmz.Env) !Engine.Sequential {
    return Engine.Sequential.init(
        executor,
        .{ .env = env },
    );
}
