const std = @import("std");
const evmz = @import("../evm.zig");

const AccountState = evmz.state.Account;
const Address = evmz.Address;
const Executor = evmz.executor;
const Host = evmz.Host;
const Interpreter = evmz.interpreter;

test "runtime allocation audit sees no traffic for bounded prepared stop after setup" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{.STOP});
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "bounded child call preserves semantic scratch requirement" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const target = evmz.addr(0xbeef);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{
        .bounded = .{
            .max_live_frames = 2,
            .memory_bytes_per_frame = 0,
            .io_bytes_per_frame = 0,
            // The raw one-byte code and jump map fit; a readable tail does not.
            .scratch_bytes_per_frame = evmz.Bytecode.zero_padding_len - 1,
            .result_bytes = 0,
        },
    });
    defer executor.deinit();

    var sender_account = AccountState.init(allocator);
    sender_account.balance = 1_000_000;
    try executor.state.accounts.put(sender, sender_account);

    const code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,   0xef,   .GAS,   .CALL,
        .STOP,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var target_account = AccountState.init(allocator);
    try target_account.setCode(allocator, &.{@intFromEnum(evmz.Opcode.STOP)});
    try executor.state.accounts.put(target, target_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    const warmup = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, warmup.status);
    executor.closeTransaction();

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "runtime allocation audit exposes omitted top-level scratch cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{.STOP});
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(audit.stats.alloc_calls > 0 or audit.stats.remap_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded top-level scratch" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 256,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{.STOP});
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "bounded executor reports scratch capacity exhaustion" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 0,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{.STOP});
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    defer executor.closeTransaction();
    try std.testing.expectError(
        error.OutOfMemory,
        executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0),
    );
}

test "runtime allocation audit exposes omitted evm memory cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .io_bytes_per_frame = 32,
        .result_bytes = 32,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x2a, .PUSH0, .MSTORE,
        .PUSH1, 0x20, .PUSH0, .RETURN,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(audit.stats.alloc_calls > 0 or audit.stats.remap_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded evm memory return" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 32,
        .io_bytes_per_frame = 32,
        .result_bytes = 32,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x2a, .PUSH0, .MSTORE,
        .PUSH1, 0x20, .PUSH0, .RETURN,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "runtime allocation audit exposes omitted log cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 32,
        .io_bytes_per_frame = 0,
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x2a, .PUSH0, .MSTORE,
        .PUSH1, 0x20, .PUSH0, .LOG0,
        .STOP,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(audit.stats.alloc_calls > 0 or audit.stats.remap_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded log storage" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 32,
        .io_bytes_per_frame = 0,
        .logs = .{ .entries = 1, .data_bytes = 32 },
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x2a, .PUSH0, .MSTORE,
        .PUSH1, 0x20, .PUSH0, .LOG0,
        .STOP,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    var bytecode = try executor.prepareBytecode(&code);
    defer bytecode.deinit(allocator);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executePreparedCallTransaction(.{
        .bytecode = &bytecode,
        .sender = sender,
        .recipient = contract,
        .gas = 100_000,
        .value = 0,
    });
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    try std.testing.expectEqual(@as(usize, 1), executor.logs().len);
    try std.testing.expectEqual(@as(usize, 32), executor.logs()[0].data.len);
    executor.closeTransaction();
}

test "runtime allocation audit exposes omitted state overlay cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 256,
        .journal_entries = 8,
        .access = .{ .accounts = 3, .storage_keys = 1 },
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x0b, .PUSH1, 0x01, .SSTORE, .STOP,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expect(audit.stats.alloc_calls > 0 or audit.stats.remap_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded state overlay storage maps" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const contract = evmz.addr(0xd83874a1c62a78b10ae86b27b59b21c4d34f6d30);
    const tx_context = testTxContext(sender, 100_000);
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .memory_bytes_per_frame = 0,
        .io_bytes_per_frame = 0,
        .scratch_bytes_per_frame = 256,
        .journal_entries = 8,
        .access = .{ .accounts = 3, .storage_keys = 1 },
        .state = .{
            .accounts = 2,
            .original_storage_entries = 1,
            .storage_overlay_entries = 1,
        },
        .result_bytes = 0,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    const code = evmz.t.bytecode(.{
        .PUSH1, 0x0b, .PUSH1, 0x01, .SSTORE, .STOP,
    });
    var contract_account = AccountState.init(allocator);
    try contract_account.setCode(allocator, &code);
    try executor.state.accounts.put(contract, contract_account);

    try executor.beginTransaction(tx_context, sender, contract);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, contract, &.{}, .legacy(100_000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "runtime allocation audit exposes omitted precompile result cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &input, result.output_data);
    try std.testing.expect(audit.stats.alloc_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded identity precompile output" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .result_bytes = input.len,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &input, result.output_data);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded sha256 precompile output" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.sha256.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .result_bytes = 32,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0);

    var expected: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&input, &expected, .{});
    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &expected, result.output_data);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "runtime allocation audit exposes omitted precompile scratch cap as growth" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.modexp.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = smallModexpInput();
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .byzantium,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .result_bytes = 1,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, result.output_data);
    try std.testing.expect(audit.stats.alloc_calls > 0);
    executor.closeTransaction();
}

test "runtime allocation audit sees no traffic for bounded modexp precompile scratch" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.modexp.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = smallModexpInput();
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .byzantium,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .scratch_bytes_per_frame = 8192,
        .result_bytes = 1,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    audit.reset();
    const result = try executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0);

    try std.testing.expectEqual(Interpreter.Status.success, result.status);
    try std.testing.expectEqualSlices(u8, &[_]u8{6}, result.output_data);
    try expectNoAllocatorTraffic(audit.stats);
    executor.closeTransaction();
}

test "bounded executor reports precompile scratch capacity exhaustion" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.modexp.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = smallModexpInput();
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .byzantium,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .scratch_bytes_per_frame = 0,
        .result_bytes = 1,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    try std.testing.expectError(
        error.OutOfMemory,
        executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0),
    );
    executor.closeTransaction();
}

test "bounded executor reports precompile result output capacity exhaustion" {
    var audit = CountingAllocator.init(std.testing.allocator);
    const allocator = audit.allocator();
    const sender = evmz.addr(0x371c4d94cf9ed2e0cde964a748609b7c46ec3811);
    const precompile = evmz.precompile.Contract.identity.toAddress();
    const tx_context = testTxContext(sender, 100_000);
    const input = [_]u8{ 0xde, 0xad };
    var executor = try Executor.initWithRuntimeResources(allocator, .{
        .revision = .cancun,
    }, .{ .bounded = .{
        .max_live_frames = 1,
        .result_bytes = input.len - 1,
    } });
    defer executor.deinit();

    try executor.state.accounts.put(sender, AccountState.init(allocator));

    try executor.beginTransaction(tx_context, sender, precompile);
    try std.testing.expectError(
        error.ResultOutputCapacityExceeded,
        executor.executeCallTransaction(sender, precompile, &input, .legacy(1000), 0),
    );
    executor.closeTransaction();
}

const CountingAllocator = struct {
    child: std.mem.Allocator,
    stats: Stats = .{},

    const Stats = struct {
        alloc_calls: usize = 0,
        resize_calls: usize = 0,
        remap_calls: usize = 0,
        free_calls: usize = 0,
        alloc_bytes: usize = 0,
        resize_from_bytes: usize = 0,
        resize_to_bytes: usize = 0,
        remap_from_bytes: usize = 0,
        remap_to_bytes: usize = 0,
        free_bytes: usize = 0,
    };

    fn init(child: std.mem.Allocator) CountingAllocator {
        return .{ .child = child };
    }

    fn allocator(self: *CountingAllocator) std.mem.Allocator {
        return .{
            .ptr = self,
            .vtable = &.{
                .alloc = alloc,
                .resize = resize,
                .remap = remap,
                .free = free,
            },
        };
    }

    fn reset(self: *CountingAllocator) void {
        self.stats = .{};
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawAlloc(len, alignment, ret_addr) orelse return null;
        self.stats.alloc_calls += 1;
        self.stats.alloc_bytes += len;
        return ptr;
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        if (!self.child.rawResize(memory, alignment, new_len, ret_addr)) return false;
        self.stats.resize_calls += 1;
        self.stats.resize_from_bytes += memory.len;
        self.stats.resize_to_bytes += new_len;
        return true;
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        const ptr = self.child.rawRemap(memory, alignment, new_len, ret_addr) orelse return null;
        self.stats.remap_calls += 1;
        self.stats.remap_from_bytes += memory.len;
        self.stats.remap_to_bytes += new_len;
        return ptr;
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *CountingAllocator = @ptrCast(@alignCast(ctx));
        self.stats.free_calls += 1;
        self.stats.free_bytes += memory.len;
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

fn expectNoAllocatorTraffic(stats: CountingAllocator.Stats) !void {
    try std.testing.expectEqual(@as(usize, 0), stats.alloc_calls);
    try std.testing.expectEqual(@as(usize, 0), stats.resize_calls);
    try std.testing.expectEqual(@as(usize, 0), stats.remap_calls);
    try std.testing.expectEqual(@as(usize, 0), stats.free_calls);
}

fn smallModexpInput() [99]u8 {
    var input = [_]u8{0} ** 99;
    input[31] = 1;
    input[63] = 1;
    input[95] = 1;
    input[96] = 2;
    input[97] = 5;
    input[98] = 13;
    return input;
}

const testTxContext = evmz.t.defaultTxContext;
