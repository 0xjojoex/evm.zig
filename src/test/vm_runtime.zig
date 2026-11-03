const std = @import("std");
const support = @import("vm_support.zig");

const evmz = support.evmz;
const address = support.address;
const executor_module = support.executor_module;
const interpreter_module = support.interpreter_module;
const system = support.system;
const transaction = support.transaction;
const Default = support.Default;
const EthValidationError = support.EthValidationError;
const addr = support.addr;
const BlockHashSource = support.BlockHashSource;
const Call = support.Call;
const Create = support.Create;
const Env = support.Env;
const MemoryStore = support.MemoryStore;
const TxStatus = support.TxStatus;
const transact = support.transact;
const expectExecuted = support.expectExecuted;
const expectRejected = support.expectRejected;

const store_42_code = evmz.t.bytecode(.{ .PUSH1, 0x2a, .PUSH0, .SSTORE, .STOP });

fn executeStandalone(
    executor: anytype,
    context: evmz.execution.ExecutionContext,
    message: evmz.execution.Message,
    gas: evmz.execution.ExecutionGas,
) @TypeOf(executor.executeStandalone(.{
    .context = context,
    .message = message,
    .gas = gas,
}, .{})) {
    return executor.executeStandalone(.{
        .context = context,
        .message = message,
        .gas = gas,
    }, .{});
}

fn accountChange(
    changes: evmz.state.OpenState.ChangesView,
    target: evmz.Address,
) ?evmz.state.AccountChange {
    var index: u32 = 0;
    while (index < changes.accounts.len()) : (index += 1) {
        const change = changes.accounts.at(index);
        if (evmz.Address.eql(change.address, target)) return change;
    }
    return null;
}

fn storageChange(
    changes: evmz.state.OpenState.ChangesView,
    target: evmz.Address,
    key: u256,
) ?evmz.state.StorageChange {
    var index: u32 = 0;
    while (index < changes.storage_writes.len()) : (index += 1) {
        const change = changes.storage_writes.at(index);
        if (evmz.Address.eql(change.address, target) and change.key == key) return change;
    }
    return null;
}

test "Executor account code remains overlay-owned and traced with a prepared backend entry" {
    const Latest = evmz.t.Vm(.latest).?;
    const contract = addr(0xc0de);
    const code = [_]u8{ 0x60, 0x00 };
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &code });

    const Observer = struct {
        address: evmz.Address,
        code_hash: [32]u8,
        calls: usize = 0,

        pub fn observe(self: *@This(), observation: Latest.Executor.Observation) !void {
            self.calls += 1;
            const view = observation.observations();
            var index: u32 = 0;
            while (index < view.accounts.len()) : (index += 1) {
                const record = view.accounts.at(index);
                if (!evmz.Address.eql(record.address, self.address)) continue;
                try std.testing.expect(record.observation.code_read);
                const loaded_account = record.current orelse return error.ExpectedLoadedAccount;
                try std.testing.expectEqualSlices(u8, &self.code_hash, &loaded_account.code_hash);
                return;
            }
            return error.ExpectedCodeObservationMissing;
        }
    };
    var prepared_pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer prepared_pool.deinit();
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
        .prepared_code_backend = prepared_pool.backend(),
    });
    defer executor.deinit();

    const code_hash = evmz.crypto.keccak256(&code);
    var observations = Observer{
        .address = contract,
        .code_hash = code_hash,
    };
    const prepared = try prepared_pool.getOrPrepare(code_hash, &code);
    const observed = executor.observe(&observations);
    try observed.beginStateTransition(evmz.t.defaultExecutionContext(contract, 100_000));
    defer executor.discardStateTransition();
    const view = try executor.getCode(contract);
    try observed.retainStateTransition();

    try std.testing.expect(view.ptr != prepared.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &code, view);
    try std.testing.expectEqual(@as(usize, 1), observations.calls);

    try prepared_pool.clearRetainingCapacity();
    try std.testing.expectEqualSlices(u8, &code, view);
}

test "Executor runs low-level standalone call" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const call = Call{
        .sender = sender,
        .recipient = contract,
    };
    const result = (try executeStandalone(
        &executor,
        (Env{}).executionContext(.{ .origin = call.sender }),
        .{ .call = call },
        .legacy(100_000),
    ));
    try std.testing.expectEqual(interpreter_module.Status.success, result.status());

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(
        evmz.state.StorageChange{
            .address = contract,
            .key = 0,
            .value = 0x2a,
        },
        changes.storage_writes.at(0),
    );
}

test "Executor runs low-level standalone create" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create = Create{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    };
    const result = (try executeStandalone(
        &executor,
        (Env{}).executionContext(.{ .origin = create.sender }),
        .{ .create = create },
        .legacy(100_000),
    ));
    try std.testing.expectEqual(interpreter_module.Status.success, result.status());

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 2), changes.accounts.len());
    try std.testing.expectEqual(@as(u64, 1), accountChange(changes, sender).?.account.?.nonce);
    const created = accountChange(changes, create_address).?.account.?;
    const code = changes.introducedCode(created.code_hash).?;
    try std.testing.expectEqualSlices(u8, &.{0x00}, code.bytes);
}

test "transaction STF validates and executes a call" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const outcome = try transact(Osaka, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    const result = executed.result();
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try std.testing.expectEqual(result.gas.used, result.gas.block.total);

    const changes = executed.changes();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(@as(u64, 1), accountChange(changes, sender).?.account.?.nonce);
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(@as(u256, 0x2a), storageChange(changes, contract, 0).?.value);
}

test "Vm owns transaction and block execution runtime" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });

    var vm = Default.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer vm.deinit();

    const standalone = try vm.transact(.{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        },
    });
    switch (standalone) {
        .executed => |executed| executed.discard(),
        .rejected => return error.UnexpectedRejection,
    }

    var block = try Default.BlockExecution.init(&vm.executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, included.result.status);
    const result = block.finish();
    try std.testing.expectEqual(@as(u64, 1), result.tx_count);
    try std.testing.expectEqual(included.receipt.gas_used, result.gas_used);
    try std.testing.expectError(
        error.UncommittedChanges,
        Default.BlockExecution.init(&vm.executor, .{ .gas_limit = 1_000_000 }),
    );
    vm.executor.discardAccepted();
}

test "Ethereum block observation fails before retain and fold mutation" {
    const ObserverError = error{ObservationRejected};
    const Observer = struct {
        pub fn observe(_: *@This(), _: anytype) ObserverError!void {
            return error.ObservationRejected;
        }
    };
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });

    var vm = Default.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer vm.deinit();
    var block = try Default.BlockExecution.init(&vm.executor, .{ .gas_limit = 1_000_000 });
    defer block.discardIfUnfinished();
    var observer = Observer{};

    const Observed = @TypeOf(block.observe(&observer));
    comptime std.debug.assert(
        @typeInfo(@TypeOf(Observed.transact)).@"fn".return_type.? ==
            (Default.BlockExecution.Error || ObserverError)!Default.BlockExecution.Outcome,
    );
    try std.testing.expectError(
        error.ObservationRejected,
        block.observe(&observer).transact(.{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        }),
    );
    try std.testing.expectEqual(@as(u64, 0), block.progress().tx_count);
    try std.testing.expect(!vm.executor.hasCurrentTransaction());
    try std.testing.expect(!vm.executor.acceptedView().hasChanges());
}

test "executed transaction discards without allocating" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const outcome = try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
            .value = 7,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();

    try std.testing.expectEqual(TxStatus.success, executed.result().status);
    try std.testing.expectEqual(@as(usize, 1), executed.logs().len());
    try std.testing.expect(executor.hasCurrentTransaction());

    failing_allocator.fail_index = failing_allocator.alloc_index;
    executed.discard();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(usize, 0), executor.logView().len());
    try std.testing.expect(!executor.acceptedChanges().hasChanges());
}

test "copied execution handles cannot discard a newer transaction" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const first = switch (try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    const copied = first;
    try std.testing.expect(first.changes().hasChanges());
    first.retain();
    copied.discardIfCurrent();

    const second = switch (try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 1,
            .to = recipient,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |executed| executed,
        .rejected => return error.UnexpectedRejection,
    };
    defer second.discardIfCurrent();

    copied.discardIfCurrent();
    try std.testing.expectEqual(TxStatus.success, second.result().status);
    second.discard();
}

test "Executed retainResult retains state and returns the validated output" {
    const Cancun = evmz.t.Vm(.cancun) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var executor = Cancun.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 1_000_000 });

    const executed = switch (try transact(Cancun, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 30_000,
            .value = 7,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    const copied = executed;
    const output = executed.retainResult();

    try std.testing.expectEqual(TxStatus.success, output.status);
    copied.discardIfCurrent();
    try std.testing.expect(!executor.hasCurrentTransaction());
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(recipient));
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccount(sender)).?.nonce);
}

test "transaction STF forwards BLOCKHASH to the Executor source" {
    const Latest = evmz.t.Vm(.latest).?;
    const TestBlockHashSource = struct {
        const Self = @This();

        last_number: ?u64 = null,

        fn source(self: *Self) BlockHashSource {
            return .{ .ptr = self, .vtable = &.{
                .getBlockHash = getBlockHash,
            } };
        }

        fn getBlockHash(ptr: *anyopaque, number: u64) !?u256 {
            const self: *Self = @ptrCast(@alignCast(ptr));
            self.last_number = number;
            return if (number == 999) 0xab else null;
        }
    };

    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &.{ 0x61, 0x03, 0xe7, 0x40, 0x5f, 0x55, 0x00 } });

    var block_hashes = TestBlockHashSource{};
    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try transact(Latest, &executor, .{
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(@as(u256, 0xab), storageChange(changes, contract, 0).?.value);
}

test "transaction STF reports successful create address" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .gas_limit = 300_000,
            .input = init_code,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(create_address, result.created_address.?);

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 2), changes.accounts.len());
    try std.testing.expectEqual(@as(u64, 1), accountChange(changes, sender).?.account.?.nonce);
    const created = accountChange(changes, create_address).?.account.?;
    try std.testing.expectEqualSlices(
        u8,
        &.{0x00},
        changes.introducedCode(created.code_hash).?.bytes,
    );
}

test "transaction STF returns rejected validation result" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .nonce = 7, .balance = 10_000_000 });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const result = try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 1,
            .to = addr(0xbbbb),
            .gas_limit = 300_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_low, try expectRejected(result));

    try std.testing.expect(!executor.acceptedChanges().hasChanges());
}

test "rejected transaction preserves the retained Executor overlay" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    _ = try expectExecuted(try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    const rejected = try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 99,
            .to = contract,
            .gas_limit = 100_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(@as(u256, 0x2a), storageChange(changes, contract, 0).?.value);
}

test "explicit backend commit persists then rebases the Executor overlay" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const executed = switch (try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    var delta = try evmz.state.StateDelta.init(std.testing.allocator, executed.changes());
    defer delta.deinit();
    try memory.committer().commit(delta.view());
    executed.retain();
    executor.discardAccepted();

    try std.testing.expect(!executor.acceptedChanges().hasChanges());
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "Executor discardAccepted drops retained overlay without touching its reader" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &store_42_code });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    _ = try expectExecuted(try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    executor.discardAccepted();

    try std.testing.expect(!executor.acceptedChanges().hasChanges());
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Amsterdam transaction reports gross block gas separately from receipt gas" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(&.{ 0x5f, 0x5f, 0x55, 0x00 });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const result = try expectExecuted(try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 100_000,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.refunded > 0);
    try std.testing.expect(result.gas.block.total > result.gas.used);
}

test "Executor exposes borrowed logs after transaction retention" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const result = try expectExecuted(try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    const logs = executor.logView();
    try std.testing.expectEqual(@as(usize, 1), logs.len());
    try std.testing.expectEqual(evmz.eth.system_address, logs.get(0).address);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, logs.get(0).topics[0]);
}

test "rejected transaction clears the Executor log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const accepted = try expectExecuted(try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logView().len());

    const rejected = try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 99,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));
    try std.testing.expectEqual(@as(usize, 0), executor.logView().len());
}

test "transaction STF uses comptime transaction gas policy" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Latest.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_result = try transact(Latest, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    const default_execution = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    default_execution.discard();

    const Overrides = struct {
        fn intrinsicBaseGas(_: transaction.IntrinsicGasOptions) error{Overflow}!u64 {
            return 42_000;
        }
    };
    const HighIntrinsicVm = evmz.t.CustomVm(.latest, .{
        .transaction = .{
            .intrinsicBaseGas = Overrides.intrinsicBaseGas,
        },
    }).?;
    var high_intrinsic_vm = HighIntrinsicVm.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer high_intrinsic_vm.deinit();

    const custom_result = try high_intrinsic_vm.transact(.{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    switch (custom_result) {
        .executed => |value| {
            value.discardIfCurrent();
            try std.testing.expect(false);
        },
        .rejected => |err| try std.testing.expectEqual(EthValidationError.intrinsic_gas_too_low, err),
    }
    try std.testing.expectEqual(transaction.Transaction, HighIntrinsicVm.Transaction);
}

test "exact spec owns total transaction gas limit as a value" {
    const London = evmz.t.Vm(.london) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    const Strict = evmz.t.CustomVm(.london, .{
        .transaction = .{ .total_gas_limit = .{ .replace = 20_000 } },
    }) orelse return error.SkipZigTest;
    var strict_vm = Strict.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer strict_vm.deinit();

    const input: London.TransactInput = .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        },
    };
    const strict_result = try strict_vm.transact(input);
    try std.testing.expectEqual(
        EthValidationError.gas_limit_exceeds_maximum,
        try expectRejected(strict_result),
    );

    var default_vm = London.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer default_vm.deinit();
    const default_result = try default_vm.transact(input);
    const executed = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    executed.discard();
}

fn creationStorageTransaction(
    comptime revision: evmz.eth.Revision,
    initial: u256,
    init_code: []const u8,
) !struct { status: TxStatus, gas_used: u64, slot: u256, deployed_word: u256 } {
    const Vm = evmz.t.Vm(revision).?;
    const sender = addr(0xaaaa);
    const target = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
    try evmz.t.seedStoreAccount(&memory, target, .{ .balance = 1 });
    try (try memory.getOrCreateAccount(target)).storage.put(7, initial);
    var executor = Vm.Executor.init(std.testing.allocator, .{ .state = .{ .reader = memory.reader() } });
    defer executor.deinit();
    const result = try expectExecuted(try transact(Vm, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{ .sender = sender, .gas_limit = 500_000, .gas_price = 1, .input = init_code },
    }));
    // Creation rollback does not undo transaction nonce advancement or gas settlement.
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccount(sender)).?.nonce);
    try std.testing.expectEqual(@as(u256, 10_000_000 - result.gas.used), try executor.getBalance(sender));
    try std.testing.expectEqual(@as(u256, 1), try executor.getBalance(target));
    const code = try executor.getCode(target);
    return .{
        .status = result.status,
        .gas_used = result.gas.used,
        .slot = try executor.getStorage(target, 7),
        .deployed_word = if (code.len == 32) std.mem.readInt(u256, code[0..32], .big) else 0,
    };
}

test "transaction CREATE resets eligible storage before initcode and SSTORE gas classification" {
    // All enabled forks share reset-before-initcode, including forks predating EIP-2200.
    inline for (evmz.t.enabled_revisions) |revision| {
        const read = try creationStorageTransaction(revision, 10, &.{
            0x60, 7, 0x54, 0x60, 0, 0x52, 0x60, 32, 0x60, 0, 0xf3,
        });
        try std.testing.expectEqual(TxStatus.success, read.status);
        try std.testing.expectEqual(@as(u256, 0), read.deployed_word);
        try std.testing.expectEqual(@as(u256, 0), read.slot);
        const writes = &.{ 0x60, 7, 0x60, 7, 0x55, 0x60, 0, 0x60, 7, 0x55, 0x00 };
        const existing = try creationStorageTransaction(revision, 10, writes);
        const fresh = try creationStorageTransaction(revision, 0, writes);
        try std.testing.expectEqual(TxStatus.success, existing.status);
        try std.testing.expectEqual(TxStatus.success, fresh.status);
        try std.testing.expectEqual(fresh.gas_used, existing.gas_used);
        try std.testing.expectEqual(@as(u256, 0), existing.slot);
    }
}

test "transaction CREATE revert restores destination storage while settling the transaction" {
    const reverted = try creationStorageTransaction(.latest, 10, &.{
        0x60, 7, 0x60, 7, 0x55, 0x60, 0, 0x60, 0, 0xfd,
    });
    try std.testing.expectEqual(TxStatus.revert, reverted.status);
    try std.testing.expectEqual(@as(u256, 10), reverted.slot);
}

test "nested CREATE2 resets storage and enclosing REVERT restores the destination" {
    const Latest = evmz.t.Vm(.latest).?;
    const sender = addr(0xaaaa);
    const factory = addr(0xbbbb);
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 7,  .SLOAD, .PUSH0,  .MSTORE,
        .PUSH1, 7,  .PUSH1, 7,       .SSTORE,
        .PUSH1, 32, .PUSH0, .RETURN,
    });
    const target = address.create2(factory, 0, &init_code);
    for ([_]bool{ false, true }) |revert_parent| {
        var factory_code = evmz.t.bytecode(.{
            .CALLDATASIZE, .PUSH0,        .PUSH0,  .CALLDATACOPY,
            .PUSH0,        .CALLDATASIZE, .PUSH0,  .PUSH0,
            .CREATE2,      .PUSH0,        .MSTORE, .PUSH1,
            32,            .PUSH0,        .RETURN,
        });
        if (revert_parent) factory_code[factory_code.len - 1] = @backingInt(evmz.Opcode.REVERT);
        var memory = MemoryStore.init(std.testing.allocator);
        defer memory.deinit();
        try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
        try evmz.t.seedStoreAccount(&memory, factory, .{ .nonce = 1, .code = &factory_code });
        try evmz.t.seedStoreAccount(&memory, target, .{ .balance = 1 });
        try (try memory.getOrCreateAccount(target)).storage.put(7, 10);
        var executor = Latest.Executor.init(std.testing.allocator, .{ .state = .{ .reader = memory.reader() } });
        defer executor.deinit();
        const result = try expectExecuted(try transact(Latest, &executor, .{
            .env = .{ .gas_limit = 1_000_000 },
            .tx = .{ .sender = sender, .to = factory, .gas_limit = 500_000, .input = &init_code },
        }));
        try std.testing.expectEqual(if (revert_parent) TxStatus.revert else TxStatus.success, result.status);
        try std.testing.expectEqual(@as(usize, 32), result.output.len);
        try std.testing.expectEqual(target.toU256(), std.mem.readInt(u256, result.output[0..32], .big));
        try std.testing.expectEqual(@as(u256, if (revert_parent) 10 else 7), try executor.getStorage(target, 7));
        const deployed = try executor.getCode(target);
        if (revert_parent) {
            try std.testing.expectEqual(@as(usize, 0), deployed.len);
            try std.testing.expectEqual(@as(u64, 0), executor.cachedAccount(target).?.nonce);
        } else {
            try std.testing.expectEqualSlices(u8, &(@as([32]u8, @splat(0))), deployed);
        }
    }
}

// These are VM transaction tests: fork policy, rollback, and finalization all
// participate. State tests that select effect flags only test reversible mechanics.
fn selfDestructTransition(comptime revision: evmz.eth.Revision, deletes_existing: bool) !void {
    const Vm = evmz.t.Vm(revision) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const parent = addr(0xbbbb);
    const target = addr(0xcccc);
    const beneficiary = addr(0xdddd);
    for ([_]bool{ false, true }) |same_beneficiary| {
        for ([_]bool{ false, true }) |revert_parent| {
            const code: []const u8 = if (same_beneficiary)
                &evmz.t.bytecode(.{ .ADDRESS, .SELFDESTRUCT })
            else
                &evmz.t.bytecode(.{ .PUSH2, 0xdd, 0xdd, .SELFDESTRUCT });
            var parent_code = evmz.t.bytecode(.{
                .PUSH0,  .PUSH0, .PUSH0, .PUSH0, .PUSH0,  .PUSH2, 0xcc,         0xcc,
                .GAS,    .CALL,  .POP,
                // Deletion is deferred: code remains visible after the child halts.
                  .PUSH2, 0xcc,    0xcc,   .EXTCODESIZE, .PUSH0,
                .MSTORE, .PUSH1, 32,     .PUSH0, .RETURN,
            });
            if (revert_parent) parent_code[parent_code.len - 1] = evmz.Opcode.REVERT.toByte();
            var memory = MemoryStore.init(std.testing.allocator);
            defer memory.deinit();
            try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });
            try evmz.t.seedStoreAccount(&memory, parent, .{ .nonce = 1, .code = &parent_code });
            try evmz.t.seedStoreAccount(&memory, target, .{ .nonce = 1, .balance = 7, .code = code });
            try evmz.t.seedStoreAccount(&memory, beneficiary, .{ .balance = 1 });
            try (try memory.getOrCreateAccount(target)).storage.put(7, 10);
            var executor = Vm.Executor.init(std.testing.allocator, .{ .state = .{ .reader = memory.reader() } });
            defer executor.deinit();
            const result = try expectExecuted(try transact(Vm, &executor, .{
                .env = .{ .gas_limit = 1_000_000 },
                .tx = .{ .sender = sender, .to = parent, .gas_limit = 500_000 },
            }));
            try std.testing.expectEqual(if (revert_parent) TxStatus.revert else TxStatus.success, result.status);
            try std.testing.expectEqual(@as(usize, 32), result.output.len);
            try std.testing.expectEqual(@as(u256, code.len), std.mem.readInt(u256, result.output[0..32], .big));
            const deleted = deletes_existing and !revert_parent;
            if (deleted) {
                try std.testing.expect((try executor.getAccount(target)) == null);
            } else {
                try std.testing.expectEqualSlices(u8, code, try executor.getCode(target));
                try std.testing.expectEqual(@as(u64, 1), (try executor.getAccount(target)).?.nonce);
            }
            try std.testing.expectEqual(@as(u256, if (deleted) 0 else 10), try executor.getStorage(target, 7));
            const keeps_balance = revert_parent or (same_beneficiary and !deletes_existing);
            try std.testing.expectEqual(@as(u256, if (keeps_balance) 7 else 0), try executor.getBalance(target));
            try std.testing.expectEqual(@as(u256, if (revert_parent or same_beneficiary) 1 else 8), try executor.getBalance(beneficiary));
            try std.testing.expectEqual(@as(u64, 1), (try executor.getAccount(sender)).?.nonce);
            try std.testing.expect(executor.execution_context == null);
        }
    }
}

test "Shanghai transaction SELFDESTRUCT deletes only at finalization and parent revert restores it" {
    try selfDestructTransition(.shanghai, true);
}

test "Cancun transaction SELFDESTRUCT preserves existing storage and self-beneficiary balance" {
    try selfDestructTransition(.cancun, false);
}

test "latest transaction SELFDESTRUCT preserves existing storage and self-beneficiary balance" {
    try selfDestructTransition(.latest, false);
}

fn createdSelfDestructTransition(comptime revision: evmz.eth.Revision, preserves_balance: bool) !void {
    const Vm = evmz.t.Vm(revision) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const target = address.create(sender, 0);
    var executor = Vm.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();
    try evmz.t.seedExecutorAccount(&executor, sender, .{ .balance = 10_000_000 });
    // A prefunded address still counts as created in this transaction (EIP-6780).
    try evmz.t.seedExecutorAccount(&executor, target, .{ .balance = 7 });
    const init_code = evmz.t.bytecode(.{
        .PUSH1, 11, .PUSH1, 7, .SSTORE, .ADDRESS, .SELFDESTRUCT,
    });
    const result = try expectExecuted(try transact(Vm, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{ .sender = sender, .gas_limit = 500_000, .input = &init_code },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    if (preserves_balance) {
        try std.testing.expectEqual(@as(u64, 0), (try executor.getAccount(target)).?.nonce);
        try std.testing.expectEqual(@as(usize, 0), (try executor.getCode(target)).len);
    } else {
        try std.testing.expect((try executor.getAccount(target)) == null);
    }
    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(target, 7));
    try std.testing.expectEqual(@as(u256, if (preserves_balance) 7 else 0), try executor.getBalance(target));
}

test "Cancun transaction creation followed by SELFDESTRUCT deletes the new account" {
    try createdSelfDestructTransition(.cancun, false);
}

test "latest transaction creation followed by SELFDESTRUCT resets storage and preserves balance" {
    try createdSelfDestructTransition(.latest, true);
}
