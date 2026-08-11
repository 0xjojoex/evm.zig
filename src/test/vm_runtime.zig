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
const SystemCall = support.SystemCall;
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
    changes: evmz.state.TrackedState.ChangesView,
    target: evmz.Address,
) ?evmz.state.TrackedState.AccountChange {
    var index: u32 = 0;
    while (index < changes.accounts.len()) : (index += 1) {
        const change = changes.accounts.at(index);
        if (std.mem.eql(u8, &change.address, &target)) return change;
    }
    return null;
}

fn storageChange(
    changes: evmz.state.TrackedState.ChangesView,
    target: evmz.Address,
    key: u256,
) ?evmz.state.TrackedState.StorageChange {
    var index: u32 = 0;
    while (index < changes.storage_writes.len()) : (index += 1) {
        const change = changes.storage_writes.at(index);
        if (std.mem.eql(u8, &change.address, &target) and change.key == key) return change;
    }
    return null;
}

test "Executor account code remains overlay-owned and traced with a prepared backend entry" {
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const contract = addr(0xc0de);
    const code = [_]u8{ 0x60, 0x00 };
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, contract, .{ .code = &code });

    const Observer = struct {
        address: evmz.Address,
        code_hash: [32]u8,
        calls: usize = 0,

        pub fn observe(self: *@This(), observation: Osaka.Executor.Observation) !void {
            self.calls += 1;
            const view = observation.observations();
            var index: u32 = 0;
            while (index < view.accounts.len()) : (index += 1) {
                const fact = view.accounts.at(index);
                if (!std.mem.eql(u8, &fact.address, &self.address)) continue;
                try std.testing.expect(fact.observation.code_read);
                const loaded_account = switch (fact.current orelse return error.ExpectedLoadedAccount) {
                    .loaded => |value| value,
                    .absent, .exists_only => return error.ExpectedLoadedAccount,
                };
                try std.testing.expectEqualSlices(u8, &self.code_hash, &loaded_account.code_hash);
                return;
            }
            return error.ExpectedCodeObservationMissing;
        }
    };
    var prepared_pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer prepared_pool.deinit();
    var executor = Osaka.Executor.init(std.testing.allocator, .{
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
    )).expectCall();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status());

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 1), changes.storage_writes.len());
    try std.testing.expectEqual(
        evmz.state.TrackedState.StorageChange{
            .address = contract,
            .key = 0,
            .value = 0x2a,
        },
        changes.storage_writes.at(0),
    );
}

test "Executor runs low-level standalone create" {
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Berlin.Executor.init(std.testing.allocator, .{
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
    )).expectCreate();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);

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
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction STF forwards BLOCKHASH to the Executor source" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
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
    var executor = Prague.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try transact(Prague, &executor, .{
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
    const Berlin = evmz.t.Vm(.berlin) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });

    var executor = Berlin.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try transact(Berlin, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .gas_limit = 300_000,
            .input = init_code,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.created_address.?);

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
    const Osaka = evmz.t.Vm(.osaka) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .nonce = 7, .balance = 10_000_000 });

    var executor = Osaka.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const result = try transact(Osaka, &executor, .{
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

    _ = try expectExecuted(try transact(Osaka, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    const rejected = try transact(Osaka, &executor, .{
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

    const executed = switch (try transact(Osaka, &executor, .{
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
    try memory.committer().commit(executed.changes());
    executed.retain();
    executor.discardAccepted();

    try std.testing.expect(!executor.acceptedChanges().hasChanges());
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
    try std.testing.expectEqual(@as(u256, 0x2a), try executor.getStorage(contract, 0));
}

test "Executor discardAccepted drops retained overlay without touching its reader" {
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

    _ = try expectExecuted(try transact(Osaka, &executor, .{
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
    const Amsterdam = evmz.t.Vm(.amsterdam) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 1_000_000 });
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(&.{ 0x5f, 0x5f, 0x55, 0x00 });

    var executor = Amsterdam.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const result = try expectExecuted(try transact(Amsterdam, &executor, .{
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
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &logs.get(0).address);
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
    const London = evmz.t.Vm(.london) orelse return error.SkipZigTest;
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = London.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_result = try transact(London, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    const default_execution = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    default_execution.discard();

    const Overrides = struct {
        fn intrinsicBaseGas(_: transaction.IntrinsicGasOptions) ?u64 {
            return 42_000;
        }
    };
    const HighIntrinsicVm = evmz.t.CustomVm(.london, .{
        .transaction = .{
            .intrinsicBaseGas = Overrides.intrinsicBaseGas,
        },
    }) orelse return error.SkipZigTest;
    var custom_executor = HighIntrinsicVm.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer custom_executor.deinit();

    var high_intrinsic_vm = HighIntrinsicVm.init(&custom_executor);
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
    var strict_executor = Strict.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer strict_executor.deinit();

    const input: London.TransactInput = .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        },
    };
    var strict_vm = Strict.init(&strict_executor);
    const strict_result = try strict_vm.transact(input);
    try std.testing.expectEqual(
        EthValidationError.gas_allowance_exceeded,
        try expectRejected(strict_result),
    );

    var standard_executor = London.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer standard_executor.deinit();
    var default_vm = London.init(&standard_executor);
    const default_result = try default_vm.transact(input);
    const executed = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    executed.discard();
}

test "exact spec owns block hooks as static dispatch" {
    const recipient = addr(0xcafe);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, recipient, .{
        .code = &.{
            0x60, 0x2a, // PUSH1 42
            0x5f, // PUSH0
            0x55, // SSTORE
            0x00, // STOP
        },
    });

    const hooks = struct {
        fn beforeBlock(_: system.BeforeBlockContext) system.BlockSystemCalls {
            var calls: system.BlockSystemCalls = .{};
            calls.append(.{
                .sender = addr(0),
                .recipient = addr(0xcafe),
                .gas = 100_000,
                .require_code = true,
            });
            return calls;
        }
    };
    const Hooked = evmz.t.CustomVm(.cancun, .{
        .block = .{ .beforeBlock = hooks.beforeBlock },
    }) orelse return error.SkipZigTest;
    var executor = Hooked.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();
    var block = try Hooked.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();

    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 42), try executor.getStorage(recipient, 0));
}

test "Sequential validation rejection skips rollback snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    try std.testing.expect((try executor.getAccountOrLoad(sender)) != null);
    failing_allocator.fail_index = failing_allocator.alloc_index;

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const rejected = try block.transact(.{
        .sender = sender,
        .nonce = 99,
        .to = recipient,
        .gas_limit = 300_000,
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));
    try std.testing.expect(!failing_allocator.has_induced_failure);
    try std.testing.expectEqual(@as(u64, 0), (try block.finish()).tx_count);
}

test "Sequential systemCall updates embedded block gas and restores overflow" {
    const Prague = evmz.t.Vm(.prague) orelse return error.SkipZigTest;
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    try evmz.t.seedStoreAccount(&memory, recipient, .{ .code = &.{ 0x60, 0x00, 0x50, 0x00 } });

    var executor = Prague.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();
    var block = try Prague.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 9 },
    });
    defer block.discardIfUnfinished();

    const call = SystemCall{
        .sender = addr(0xaaaa),
        .recipient = recipient,
        .gas = 9,
    };
    const result = try block.systemCall(call);

    try std.testing.expectEqual(interpreter_module.Status.success, result.status());
    try std.testing.expectEqualSlices(u8, &.{}, result.outputData());
    const progress = block.progress();
    try std.testing.expectEqual(@as(u64, 5), progress.gas_used);
    try std.testing.expectEqual(@as(u64, 5), progress.block_gas.total);

    try std.testing.expectError(error.GasAllowanceExceeded, block.systemCall(call));
    const restored = block.progress();
    try std.testing.expectEqual(@as(u64, 5), restored.gas_used);
    try std.testing.expectEqual(@as(u64, 5), restored.block_gas.total);
}

test "Sequential includes each transaction before returning" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const first = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, first.result.status);
    try std.testing.expectEqual(@as(u64, 1), block.progress().tx_count);

    const second = switch (try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    try std.testing.expectEqual(TxStatus.success, second.result.status);
    try std.testing.expectEqual(@as(u64, 2), block.progress().tx_count);
    try std.testing.expectEqual(@as(u64, 2), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 2), (try block.finish()).tx_count);
}

test "Sequential discardIfUnfinished drops included executions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    _ = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    });
    _ = try block.transact(.{
        .sender = sender,
        .nonce = 1,
        .to = recipient,
        .gas_limit = 100_000,
    });

    block.discardIfUnfinished();
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expect(!executor.acceptedChanges().hasChanges());
}

test "Sequential endTransactions closes the transaction phase" {
    var executor = Default.Executor.init(std.testing.allocator, .{});
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    try block.endTransactions();
    try std.testing.expectError(error.TransactionPhaseClosed, block.transact(.{
        .sender = addr(0xaaaa),
        .to = addr(0xbbbb),
        .gas_limit = 100_000,
    }));
    try std.testing.expectEqual(@as(u64, 0), (try block.finish()).tx_count);
}

test "Sequential rejects an overlay retained outside its lifetime" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    const executed = switch (try transact(Default, &executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 100_000,
        },
    })) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    defer executed.discardIfCurrent();
    try std.testing.expect(executed.changes().hasChanges());
    executed.retain();

    try std.testing.expectError(
        error.UncommittedChanges,
        Default.Sequential.init(&executor, .{ .env = .{ .gas_limit = 1_000_000 } }),
    );
    executor.discardAccepted();
    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    _ = try block.finish();
}

test "Sequential rejects transaction whose gas limit exceeds remaining block dimensions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 29_000 },
    });
    defer block.discardIfUnfinished();
    const first = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    })) {
        .included => |included| included,
        .rejected => return error.UnexpectedRejection,
    };
    const first_result = first.result;
    try std.testing.expectEqual(TxStatus.success, first_result.status);
    try std.testing.expectEqual(@as(u64, 15_000), first_result.gas.block.total);

    const rejected = try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 29_000,
    });
    try std.testing.expectEqual(EthValidationError.gas_allowance_exceeded, try expectRejected(rejected));
    try std.testing.expectEqual(@as(u64, 1), (try block.finish()).tx_count);

    const changes = executor.acceptedChanges();
    try std.testing.expectEqual(@as(u32, 1), changes.accounts.len());
    try std.testing.expectEqual(@as(u64, 1), accountChange(changes, sender).?.account.?.nonce);
    try std.testing.expectEqual(@as(u32, 0), changes.storage_writes.len());
}

test "Sequential returns included result and borrowed receipt view" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    try evmz.t.seedStoreAccount(&memory, sender, .{ .balance = 10_000_000 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .state = .{ .reader = memory.reader() },
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 300_000,
        .value = 7,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    const receipt = included.receipt;
    const result = included.result;
    try std.testing.expectEqual(@as(u64, 1), block.progress().tx_count);
    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas.used, receipt.gas_used);
    try std.testing.expectEqual(result.gas.used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len());
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, receipt.logs.get(0).topics[0]);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
}
