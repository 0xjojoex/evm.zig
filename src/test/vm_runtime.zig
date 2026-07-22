const std = @import("std");
const support = @import("vm_support.zig");

const evmz = support.evmz;
const address = support.address;
const executor_module = support.executor_module;
const interpreter_module = support.interpreter_module;
const protocol_module = support.protocol_module;
const transaction = support.transaction;
const Default = support.Default;
const EthValidationError = support.EthValidationError;
const addr = support.addr;
const BlockHashSource = support.BlockHashSource;
const Call = support.Call;
const Changeset = support.Changeset;
const Committer = support.Committer;
const Create = support.Create;
const Env = support.Env;
const MemoryStore = support.MemoryStore;
const SystemCall = support.SystemCall;
const TxStatus = support.TxStatus;
const defaultTransact = support.defaultTransact;
const expectExecuted = support.expectExecuted;
const expectRejected = support.expectRejected;

test "block claim cannot authorize another Executor" {
    const Bound = Default.BlockExecution;
    var claimed_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer claimed_executor.deinit();
    var other_executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer other_executor.deinit();

    var block = try Bound.init(
        &claimed_executor,
        .{ .gas_limit = 100_000 },
    );
    defer block.discardIfUnfinished();
    var other_vm = Default.init(&other_executor);
    try std.testing.expectError(error.WrongBlockExecution, other_vm.transactInBlock(
        .{
            .env = .{ .gas_limit = 100_000 },
            .tx = .{ .sender = addr(0xaaaa), .to = addr(0xbbbb), .gas_limit = 30_000 },
        },
        block.claim,
    ));
}

test "Executor initializes with an empty changeset" {
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
    });
    defer executor.deinit();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Executor account code remains overlay-owned and traced with a prepared backend entry" {
    const contract = addr(0xc0de);
    const code = [_]u8{ 0x60, 0x00 };
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var account = try memory.getOrCreateAccount(contract);
    try account.setCode(&code);

    const Recorder = struct {
        reads: usize = 0,
        last: evmz.trace.CodeRead = undefined,

        fn target(self: *@This()) executor_module.CaptureStateTarget {
            return executor_module.CaptureStateTarget.init(self, &.{ .state_read = stateRead });
        }

        fn stateRead(ptr: *anyopaque, event: evmz.trace.StateRead) !void {
            const self: *@This() = @ptrCast(@alignCast(ptr));
            self.last = switch (event) {
                .code => |payload| payload,
                else => return,
            };
            self.reads += 1;
        }
    };
    var recorder = Recorder{};
    var prepared_pool = evmz.prepared_code.InMemoryPreparedPool.init(std.testing.allocator);
    defer prepared_pool.deinit();
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
        .prepared_code_backend = prepared_pool.backend(),
    });
    defer executor.deinit();

    const code_hash = evmz.crypto.keccak256(&code);
    const prepared = try prepared_pool.getOrPrepare(executor.preparedCodeKey(), code_hash, &code);
    var context = executor_module.CaptureContext.init(
        std.testing.allocator,
        null,
        recorder.target(),
    );
    defer context.deinit();
    executor.setCaptureContext(&context);
    try context.begin();
    defer {
        if (context.isActive()) context.abort() catch {};
        executor.setCaptureContext(null);
    }
    const view = try executor.getCode(contract);
    _ = try context.finish();

    try std.testing.expect(view.ptr != prepared.bytes.ptr);
    try std.testing.expectEqualSlices(u8, &code, view);
    try std.testing.expectEqual(@as(usize, 1), recorder.reads);
    try std.testing.expectEqualSlices(u8, &contract, &recorder.last.address);
    try std.testing.expectEqual(code.len, recorder.last.size);

    try prepared_pool.clearRetainingCapacity();
    try std.testing.expectEqualSlices(u8, &code, view);
}

test "Executor runs low-level standalone call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const call = Call{
        .sender = sender,
        .recipient = contract,
    };
    const result = (try executor.runStandalone(
        (Env{}).txContext(call.sender, 0, 100_000, &.{}),
        .{ .call = call },
        .legacy(100_000),
    )).expectCall();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0), diff.storage_writes.items[0].key);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "Executor runs low-level standalone create" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const create = Create{
        .sender = sender,
        .recipient = create_address,
        .init_code = init_code,
    };
    const result = (try executor.runStandalone(
        (Env{}).txContext(create.sender, 0, 100_000, &.{}),
        .{ .create = create },
        .legacy(100_000),
    )).expectCreate();
    try std.testing.expectEqual(interpreter_module.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.address);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqual(@as(usize, 1), diff.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.codeBytes(diff.code_inserts.items[0]));
    try std.testing.expectEqualSlices(
        u8,
        &diff.account_updates.items[1].code_hash,
        &diff.code_inserts.items[0].code_hash,
    );
}

test "transaction STF validates and executes a call" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
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
    const result = try executed.result();
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try std.testing.expectEqual(result.gas.used, result.gas.block.total);

    var diff = try executed.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "transaction STF needs only an Executor and explicit input" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
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

    const result = try executed.result();
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expect(result.gas.used > 21_000);
    try executed.discard();
    try std.testing.expect(!executor.hasCurrentTransaction());
}

test "Sequential needs only a stable Executor and explicit environment" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
    });
    defer block.discardIfUnfinished();
    const included = switch (try block.transact(.{
        .sender = sender,
        .to = recipient,
        .gas_limit = 100_000,
    })) {
        .included => |value| value,
        .rejected => return error.UnexpectedRejection,
    };

    try std.testing.expectEqual(TxStatus.success, included.result.status);
    try std.testing.expectEqual(@as(u64, 1), (try block.finish()).tx_count);
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expect(!@hasField(Default.Sequential, "vm"));
}

test "executed transaction discards without allocating" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const outcome = try defaultTransact(&executor, .{
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

    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try std.testing.expectEqual(@as(usize, 1), (try executed.logs()).len);
    try std.testing.expectError(
        error.ExecutedTransactionActive,
        defaultTransact(&executor, .{
            .env = .{ .gas_limit = 1_000_000 },
            .tx = .{
                .sender = sender,
                .to = contract,
                .gas_limit = 300_000,
            },
        }),
    );

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try executed.discard();
    try std.testing.expect(!failing_allocator.has_induced_failure);
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(@as(u256, 0), try executor.getStorage(contract, 0));
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
    var diff = try executor.changeset();
    defer diff.deinit(failing_allocator.allocator());
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "changeset failure leaves the current execution discardable" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
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

    failing_allocator.fail_index = failing_allocator.alloc_index;
    try std.testing.expectError(error.OutOfMemory, executed.changeset());
    failing_allocator.fail_index = std.math.maxInt(usize);

    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try executed.discard();
}

test "backend commit failure leaves the current execution discardable" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var committer_anchor: u8 = 0;
    const failing_committer = Committer{ .ptr = &committer_anchor, .vtable = &.{
        .commit = struct {
            fn commit(_: *anyopaque, _: *const Changeset) !void {
                return error.CommitFailed;
            }
        }.commit,
    } };
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
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

    var diff = try executed.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectError(error.CommitFailed, failing_committer.commit(&diff));
    try std.testing.expectEqual(TxStatus.success, (try executed.result()).status);
    try executed.discard();
}

test "copied execution leases cannot discard a stale transaction" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const first = switch (try defaultTransact(&executor, .{
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
    var first_diff = try first.changeset();
    first_diff.deinit(std.testing.allocator);
    try first.retain();
    try std.testing.expectError(error.NoCurrentTransaction, copied.discard());

    const second = switch (try defaultTransact(&executor, .{
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

    try std.testing.expectError(error.StaleTransactionExecution, copied.result());
    copied.discardIfCurrent();
    try std.testing.expectEqual(TxStatus.success, (try second.result()).status);
    try second.discard();
}

test "Executed retainResult retains state and returns the validated output" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .cancun });
    defer executor.deinit();
    try executor.addBalance(sender, 1_000_000);

    const executed = switch (try defaultTransact(&executor, .{
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
    const output = try executed.retainResult();

    try std.testing.expectEqual(TxStatus.success, output.status);
    try std.testing.expectError(error.NoCurrentTransaction, copied.result());
    try std.testing.expectEqual(@as(u256, 7), try executor.getBalance(recipient));
    try std.testing.expectEqual(@as(u64, 1), (try executor.getAccountOrLoad(sender)).?.nonce);
}

test "transaction status shares the interpreter status vocabulary" {
    try std.testing.expect(Default.TxStatus == Default.Interpreter.Status);
}

test "transaction STF forwards BLOCKHASH to the Executor source" {
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

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x61, 0x03, 0xe7, 0x40, 0x5f, 0x55, 0x00 });

    var block_hashes = TestBlockHashSource{};
    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
        .block_hash_source = block_hashes.source(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .number = 1000, .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqual(@as(?u64, 999), block_hashes.last_number);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0xab), diff.storage_writes.items[0].value);
}

test "transaction STF reports successful create address" {
    const sender = addr(0xaaaa);
    const create_address = address.create(sender, 0);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .berlin,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const init_code = &.{ 0x60, 0x00, 0x60, 0x00, 0x53, 0x60, 0x01, 0x60, 0x00, 0xf3 };
    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .gas_limit = 300_000,
            .input = init_code,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    try std.testing.expectEqualSlices(u8, &create_address, &result.created_address.?);

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 2), diff.account_updates.items.len);
    try std.testing.expectEqual(sender, diff.account_updates.items[0].address);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(create_address, diff.account_updates.items[1].address);
    try std.testing.expectEqual(@as(usize, 1), diff.code_inserts.items.len);
    try std.testing.expectEqualSlices(u8, &.{0x00}, diff.codeBytes(diff.code_inserts.items[0]));
    try std.testing.expectEqualSlices(
        u8,
        &diff.account_updates.items[1].code_hash,
        &diff.code_inserts.items[0].code_hash,
    );
}

test "transaction STF returns rejected validation result" {
    const sender = addr(0xaaaa);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    sender_account.nonce = 7;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 1,
            .to = addr(0xbbbb),
            .gas_limit = 300_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_low, try expectRejected(result));

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "rejected transaction preserves the retained Executor overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    _ = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    const rejected = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .nonce = 99,
            .to = contract,
            .gas_limit = 100_000,
        },
    });
    try std.testing.expectEqual(EthValidationError.nonce_too_high, try expectRejected(rejected));

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.storage_writes.items.len);
    try std.testing.expectEqual(contract, diff.storage_writes.items[0].address);
    try std.testing.expectEqual(@as(u256, 0x2a), diff.storage_writes.items[0].value);
}

test "explicit backend commit persists then rebases the Executor overlay" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
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
    var committed = try executed.changeset();
    defer committed.deinit(std.testing.allocator);
    try memory.committer().commit(&committed);
    try executed.retain();
    executor.discardChanges();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0x2a), memory.getAccount(contract).?.getStorage(0));
}

test "Executor discardChanges drops retained overlay without touching its reader" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&.{ 0x60, 0x2a, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .osaka,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    _ = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = 300_000,
        },
    }));
    executor.discardChanges();

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
    try std.testing.expectEqual(@as(u256, 0), memory.getAccount(contract).?.getStorage(0));
}

test "Amsterdam transaction reports gross block gas separately from receipt gas" {
    const sender = addr(0xaaaa);
    const contract = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    var contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.storage.put(0, 1);
    try contract_account.setCode(&.{ 0x5f, 0x5f, 0x55, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
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

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const result = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, result.status);
    const logs = executor.logs();
    try std.testing.expectEqual(@as(usize, 1), logs.len);
    try std.testing.expectEqualSlices(u8, &evmz.eth.system_address, &logs[0].address);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, logs[0].topics[0]);
}

test "rejected transaction clears the Executor log surface" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const accepted = try expectExecuted(try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 300_000,
            .value = 7,
        },
    }));
    try std.testing.expectEqual(TxStatus.success, accepted.status);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);

    const rejected = try defaultTransact(&executor, .{
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
    try std.testing.expectEqual(@as(usize, 0), executor.logs().len);
}

test "transaction STF uses comptime transaction gas policy" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const tx = Default.Transaction{
        .sender = sender,
        .to = recipient,
        .gas_limit = 21_000,
    };

    const default_result = try defaultTransact(&executor, .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = tx,
    });
    const default_execution = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try default_execution.discard();

    const Overrides = struct {
        fn intrinsicBaseGas(_: evmz.eth.Revision, _: transaction.IntrinsicGasOptions) ?u64 {
            return 42_000;
        }
    };
    const HighIntrinsicVm = evmz.eth.extend(.{
        .support = .at(.london),
        .transaction = .{
            .intrinsicBaseGas = Overrides.intrinsicBaseGas,
        },
    });
    var custom_executor = HighIntrinsicVm.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
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

test "family instance owns its transaction policy snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const hooks = struct {
        fn strictTotalGasLimit(_: evmz.eth.Revision) ?u64 {
            return 20_000;
        }
    };
    var source_policy = Default.transaction_policy;
    source_policy.transaction.totalGasLimit = hooks.strictTotalGasLimit;
    var strict_vm = Default.initWithPolicy(&executor, source_policy);

    // The runtime owns a value snapshot, not a pointer to caller storage.
    source_policy = Default.transaction_policy;

    const input: Default.TransactInput = .{
        .env = .{ .gas_limit = 1_000_000 },
        .tx = .{
            .sender = sender,
            .to = recipient,
            .gas_limit = 21_000,
        },
    };
    const strict_result = try strict_vm.transact(input);
    try std.testing.expectEqual(
        EthValidationError.gas_allowance_exceeded,
        try expectRejected(strict_result),
    );

    // The same generated family and Executor can run with another policy value.
    var default_vm = Default.init(&executor);
    const default_result = try default_vm.transact(input);
    const executed = switch (default_result) {
        .executed => |value| value,
        .rejected => return error.UnexpectedRejection,
    };
    try executed.discard();
}

test "BlockExecution owns its block policy snapshot" {
    const recipient = addr(0xcafe);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&.{
        0x60, 0x2a, // PUSH1 42
        0x5f, // PUSH0
        0x55, // SSTORE
        0x00, // STOP
    });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .cancun,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const hooks = struct {
        fn beforeBlock(
            _: evmz.eth.Revision,
            _: protocol_module.BeforeBlockContext,
        ) protocol_module.BlockSystemCalls {
            var calls: protocol_module.BlockSystemCalls = .{};
            calls.append(.{
                .sender = addr(0),
                .recipient = addr(0xcafe),
                .gas = 100_000,
                .require_code = true,
            });
            return calls;
        }
    };
    var source_policy = Default.block_policy;
    source_policy.beforeBlock = hooks.beforeBlock;
    var block = try Default.Sequential.initWithPolicies(
        &executor,
        Default.transaction_policy,
        source_policy,
        .{ .env = .{ .gas_limit = 1_000_000 } },
    );
    defer block.discardIfUnfinished();

    // Resetting the source does not change the block-owned value snapshot.
    source_policy = Default.block_policy;
    try block.beforeBlock(.{});
    try std.testing.expectEqual(@as(u256, 42), try executor.getStorage(recipient, 0));
}

test "Sequential validation rejection skips rollback snapshot" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var failing_allocator = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var executor = Default.Executor.init(failing_allocator.allocator(), .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
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
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();
    var recipient_account = try memory.getOrCreateAccount(recipient);
    try recipient_account.setCode(&.{ 0x60, 0x00, 0x50, 0x00 });

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .prague,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    var block = try Default.Sequential.init(&executor, .{
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
    const progress = try block.progress();
    try std.testing.expectEqual(@as(u64, 5), progress.gas_used);
    try std.testing.expectEqual(@as(u64, 5), progress.block_gas.total);

    try std.testing.expectError(error.GasAllowanceExceeded, block.systemCall(call));
    const restored = try block.progress();
    try std.testing.expectEqual(@as(u64, 5), restored.gas_used);
    try std.testing.expectEqual(@as(u64, 5), restored.block_gas.total);
}

test "system call finalization failure restores block state" {
    const contract = addr(0xbbbb);
    const beneficiary = addr(0xbeef);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var contract_account = try memory.getOrCreateAccount(contract);
    contract_account.balance = 5;
    try contract_account.setCode(&.{ 0x61, 0xbe, 0xef, 0xff });
    var beneficiary_account = try memory.getOrCreateAccount(beneficiary);
    beneficiary_account.balance = 7;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .london,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();
    try executor.state.configureStateResources(.{
        .accounts = 2,
        .selfdestructed_accounts = 1,
        .deleted_accounts = 0,
        .dirty_accounts = 2,
    });

    const call = SystemCall{
        .sender = addr(0xaaaa),
        .recipient = contract,
        .gas = 100_000,
    };
    var block = try Default.Sequential.init(&executor, .{
        .env = .{ .gas_limit = 100_000 },
    });
    defer block.discardIfUnfinished();
    try std.testing.expectError(error.DeletedAccountCapacityExceeded, block.systemCall(call));
    try std.testing.expectEqual(@as(u64, 0), (try block.progress()).gas_used);
    try std.testing.expectEqual(@as(u256, 5), (try executor.getAccountOrLoad(contract)).?.balance);
    try std.testing.expectEqual(@as(u256, 7), (try executor.getAccountOrLoad(beneficiary)).?.balance);
    _ = try block.finish();
}

test "Sequential includes each transaction before returning" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
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
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);

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
    try std.testing.expectEqual(@as(u64, 2), (try block.progress()).tx_count);
    try std.testing.expectEqual(@as(u64, 2), (try executor.getAccountOrLoad(sender)).?.nonce);
    try std.testing.expectEqual(@as(u64, 2), (try block.finish()).tx_count);
}

test "Sequential discardIfUnfinished drops included executions" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
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
    try std.testing.expectError(error.BlockExecutionFinished, block.finish());
    try std.testing.expectEqual(@as(u64, 0), (try executor.getAccountOrLoad(sender)).?.nonce);
    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 0), diff.account_updates.items.len);
}

test "Sequential endTransactions closes the transaction phase" {
    var executor = Default.Executor.init(std.testing.allocator, .{ .revision = .amsterdam });
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

test "Sequential delegates block progress to BlockExecution" {
    try std.testing.expect(@hasField(Default.Sequential, "block"));
    try std.testing.expectEqual(Default.BlockExecution, @FieldType(Default.Sequential, "block"));
    try std.testing.expect(!@hasField(Default.Sequential, "gas_used"));
    try std.testing.expect(!@hasField(Default.Sequential, "block_gas"));
    try std.testing.expect(!@hasField(Default.Sequential, "tx_count"));
    try std.testing.expect(@hasField(Default.Sequential, "phase"));
    try std.testing.expect(!@hasField(Default, "active_block"));
}

test "Sequential rejects an overlay retained outside its lifetime" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    const executed = switch (try defaultTransact(&executor, .{
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
    var diff = try executed.changeset();
    diff.deinit(std.testing.allocator);
    try executed.retain();

    try std.testing.expectError(
        error.UncommittedChanges,
        Default.Sequential.init(&executor, .{ .env = .{ .gas_limit = 1_000_000 } }),
    );
    executor.discardChanges();
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

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
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

    var diff = try executor.changeset();
    defer diff.deinit(std.testing.allocator);
    diff.sort();
    try std.testing.expectEqual(@as(usize, 1), diff.account_updates.items.len);
    try std.testing.expectEqual(@as(u64, 1), diff.account_updates.items[0].nonce);
    try std.testing.expectEqual(@as(usize, 0), diff.storage_writes.items.len);
}

test "Sequential returns included result and borrowed receipt view" {
    const sender = addr(0xaaaa);
    const recipient = addr(0xbbbb);
    var memory = MemoryStore.init(std.testing.allocator);
    defer memory.deinit();

    var sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 10_000_000;

    var executor = Default.Executor.init(std.testing.allocator, .{
        .revision = .amsterdam,
        .state_reader = memory.reader(),
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
    try std.testing.expectEqual(@as(u64, 1), (try block.progress()).tx_count);
    try std.testing.expectEqual(TxStatus.success, receipt.status);
    try std.testing.expectEqual(result.gas.used, receipt.gas_used);
    try std.testing.expectEqual(result.gas.used, receipt.cumulative_gas_used);
    try std.testing.expectEqual(@as(usize, 1), receipt.logs.len);
    try std.testing.expectEqual(evmz.eth.value_transfer_log_topic, receipt.logs[0].topics[0]);
    const summary = try block.finish();
    try std.testing.expectEqual(@as(u64, 1), summary.tx_count);
}
