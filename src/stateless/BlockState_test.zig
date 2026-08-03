const std = @import("std");

const address = @import("../address.zig");
const bal = @import("../eth/bal/model.zig");
const claim_plan = @import("../eth/bal/ClaimPlan.zig");
const crypto = @import("../crypto.zig");
const trie = @import("../eth/trie.zig");
const records = @import("ParentFacts.zig");
const StatelessCommit = @import("commit.zig");
const StatelessBlockState = @import("BlockState.zig");

test "sealed dense views retain effects and observations with distinct lifetimes" {
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{
        .address = target,
        .storage_reads = &.{7},
    }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);

    const parent_code = [_]u8{ 0x60, 0x00 };
    const parent_hash = crypto.keccak256(&parent_code);
    const account_facts = [_]records.AccountFact{.{
        .parent = .{ .present = .{
            .nonce = 1,
            .balance = 10,
            .code_hash = parent_hash,
        } },
    }};
    const storage_facts = [_]records.StorageFact{.{
        .value = 3,
    }};
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &storage_facts);
    var state = try StatelessBlockState.initWithCodes(
        std.testing.allocator,
        plan,
        facts,
        &.{&parent_code},
    );
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectEqualSlices(u8, &parent_code, try state.getCode(target));

    const nested = state.checkpoint();
    const replacement_code = [_]u8{0x5f};
    try state.setCode(target, &replacement_code);
    try state.setTransientStorage(target, 8, 12);
    var topics = [_]u256{1};
    var data = [_]u8{ 2, 3 };
    try state.emitLog(.{ .address = target, .topics = &topics, .data = &data });
    _ = try state.setStorage(target, 7, 9);
    state.revertToCheckpoint(nested);

    try std.testing.expectEqualSlices(u8, &parent_code, try state.getCode(target));
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(target, 8));
    try std.testing.expectEqual(@as(usize, 0), state.logView().len());
    try std.testing.expectEqual(@as(u256, 3), try state.getStorage(target, 7));
    try std.testing.expectEqual(@as(usize, 1), state.observed_accounts.items.len);
    try std.testing.expectEqual(@as(usize, 1), state.observed_storage.items.len);
    try std.testing.expect(!state.observed_accounts.items[0].effect.code_written);
    try std.testing.expect(!state.observed_storage.items[0].effect.written);

    try state.setCode(target, &replacement_code);
    try state.setTransientStorage(target, 8, 12);
    try state.emitLog(.{ .address = target, .topics = &topics, .data = &data });
    topics[0] = 9;
    data[0] = 9;
    _ = try state.setStorage(target, 7, 9);
    state.closeScope();
    state.seal(attempt);

    const pending = state.pendingView();
    try std.testing.expectEqual(@as(u32, 1), pending.changes().accounts.len());
    try std.testing.expectEqual(@as(u32, 1), pending.changes().storage_writes.len());
    try std.testing.expectEqual(@as(u32, 0), pending.changes().storage_wipes.len());
    const replacement_hash = crypto.keccak256(&replacement_code);
    try std.testing.expectEqualSlices(
        u8,
        &replacement_code,
        pending.changes().introducedCode(replacement_hash).?.bytes,
    );
    try std.testing.expectEqual(@as(u32, 1), pending.observations().accounts.len());
    try std.testing.expectEqual(@as(u32, 1), pending.observations().storage.len());
    try std.testing.expect(pending.observations().accounts.at(0).observation.code_read);
    try std.testing.expect(pending.observations().accounts.at(0).effect.code_written);
    try std.testing.expect(pending.observations().storage.at(0).?.effect.written);
    try std.testing.expectEqual(@as(usize, 1), pending.logs().len());
    try std.testing.expectEqual(@as(u256, 1), pending.logs().get(0).topics[0]);
    try std.testing.expectEqual(@as(u8, 2), pending.logs().get(0).data[0]);

    state.retain(attempt);
    try std.testing.expectEqual(@as(usize, 1), state.logView().len());
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().accounts.len());
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());

    const next_attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectEqual(@as(usize, 0), state.logView().len());
    try std.testing.expectEqual(@as(u256, 0), state.getTransientStorage(target, 8));
    state.closeScope();
    state.discard(next_attempt);
}

test "dense introduced code is reclaimed across rollback and discard" {
    const targets = [_]address.Address{ address.addr(1), address.addr(2), address.addr(3) };
    const claims = [_]bal.AccountChanges{
        .{ .address = targets[0] },
        .{ .address = targets[1] },
        .{ .address = targets[2] },
    };
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .absent = .empty_trie } },
        .{ .parent = .{ .absent = .empty_trie } },
        .{ .parent = .{ .absent = .empty_trie } },
    };
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &.{});
    var state = try StatelessBlockState.init(std.testing.allocator, plan, facts);
    defer state.deinit();

    const first_code = [_]u8{ 0x60, 0x01 };
    const first_attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.markCreatedContract(targets[0]);
    try state.setCode(targets[0], &first_code);
    const first_ref = state.accounts[0].code_ref;
    state.closeScope();
    state.seal(first_attempt);
    state.retain(first_attempt);
    try std.testing.expectEqual(@as(usize, 1), state.code.introducedLen());

    const second_code = [_]u8{ 0x60, 0x02 };
    const third_code = [_]u8{ 0x60, 0x03 };
    const discarded = state.beginObservedTransaction();
    state.beginScope();
    const outer = state.checkpoint();
    try state.markCreatedContract(targets[1]);
    try state.setCode(targets[1], &second_code);
    const second_ref = state.accounts[1].code_ref;
    try state.markCreatedContract(targets[2]);
    try state.setCode(targets[2], &second_code);
    try std.testing.expectEqual(second_ref, state.accounts[2].code_ref);
    try std.testing.expectEqual(@as(usize, 2), state.code.introducedLen());

    const inner = state.checkpoint();
    try state.setCode(targets[2], &third_code);
    try std.testing.expectEqual(@as(usize, 3), state.code.introducedLen());
    state.revertToCheckpoint(inner);
    try std.testing.expectEqual(@as(usize, 2), state.code.introducedLen());
    try std.testing.expectEqual(second_ref, state.accounts[2].code_ref);

    state.revertToCheckpoint(outer);
    try std.testing.expectEqual(@as(usize, 1), state.code.introducedLen());
    try std.testing.expectEqual(first_ref, state.accounts[0].code_ref);
    try std.testing.expectEqualSlices(u8, &first_code, state.code.view(first_ref).?.bytes);

    try state.markCreatedContract(targets[1]);
    try state.setCode(targets[1], &second_code);
    try std.testing.expectEqual(second_ref, state.accounts[1].code_ref);
    try state.markCreatedContract(targets[2]);
    try state.setCode(targets[2], &second_code);
    try std.testing.expectEqual(second_ref, state.accounts[2].code_ref);
    try std.testing.expectEqual(@as(usize, 2), state.code.introducedLen());

    state.closeScope();
    state.seal(discarded);
    state.discard(discarded);
    try std.testing.expectEqual(@as(usize, 1), state.code.introducedLen());
    try std.testing.expectEqual(first_ref, state.accounts[0].code_ref);
    try std.testing.expectEqualSlices(u8, &first_code, state.code.view(first_ref).?.bytes);
}

test "dense code reference preserves lazy missing-code rejection" {
    const target = address.addr(1);
    const missing_hash = [_]u8{0x77} ** 32;
    const claims = [_]bal.AccountChanges{.{ .address = target }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{.{
        .parent = .{ .present = .{ .nonce = 1, .code_hash = missing_hash } },
    }};
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &.{});
    var state = try StatelessBlockState.initWithCodes(
        std.testing.allocator,
        plan,
        facts,
        &.{},
    );
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    try std.testing.expectError(error.MissingCode, state.getCode(target));
    try state.setBalance(target, 1);
    try std.testing.expectError(error.MissingCode, state.getCode(target));
    try state.clearCode(target);
    try std.testing.expectEqual(@as(usize, 0), (try state.getCode(target)).len);
    state.closeScope();
    state.discard(attempt);
}

test "sealed storage wipe removes stale point writes" {
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{7} }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{.{
        .parent = .{ .present = .{ .nonce = 1, .storage_root = [_]u8{0x77} ** 32 } },
    }};
    const storage_facts = [_]records.StorageFact{.{
        .value = 3,
    }};
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &storage_facts);
    var state = try StatelessBlockState.init(std.testing.allocator, plan, facts);
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    _ = try state.setStorage(target, 7, 9);
    try state.wipeStorage(@enumFromInt(0));
    try std.testing.expect(!try state.accountHasStorage(target));
    state.closeScope();
    state.seal(attempt);
    try std.testing.expectEqual(@as(u32, 0), state.pendingView().changes().storage_writes.len());
    try std.testing.expectEqual(@as(u32, 1), state.pendingView().changes().storage_wipes.len());
    state.discard(attempt);
}

test "sealed discard preserves prior accepted storage projection" {
    const target = address.addr(1);
    const claims = [_]bal.AccountChanges{.{ .address = target, .storage_reads = &.{7} }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);
    const account_facts = [_]records.AccountFact{.{
        .parent = .{ .present = .{ .nonce = 1, .storage_root = [_]u8{0x77} ** 32 } },
    }};
    const storage_facts = [_]records.StorageFact{.{
        .value = 3,
    }};
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &storage_facts);
    var state = try StatelessBlockState.init(std.testing.allocator, plan, facts);
    defer state.deinit();

    const accepted_attempt = state.beginObservedTransaction();
    state.beginScope();
    _ = try state.setStorage(target, 7, 9);
    state.closeScope();
    state.seal(accepted_attempt);
    state.retain(accepted_attempt);
    try std.testing.expectEqual(@as(u32, 0), state.acceptedView().changes().accounts.len());
    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());
    try std.testing.expectEqual(@as(u256, 9), state.acceptedView().changes().storage_writes.at(0).value);

    const account_attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 12);
    state.closeScope();
    state.seal(account_attempt);
    state.retain(account_attempt);

    const rejected_attempt = state.beginObservedTransaction();
    state.beginScope();
    try state.setBalance(target, 13);
    try state.wipeStorage(@enumFromInt(0));
    state.closeScope();
    state.seal(rejected_attempt);
    const pending = state.pendingView();
    try std.testing.expectEqual(@as(u32, 1), pending.accepted().changes().storage_writes.len());
    try std.testing.expectEqual(
        @as(u256, 9),
        pending.accepted().changes().storage_writes.at(0).value,
    );
    try std.testing.expectEqual(
        @as(u256, 12),
        pending.accepted().changes().accounts.at(0).account.?.balance,
    );
    try std.testing.expectEqual(@as(u256, 13), pending.changes().accounts.at(0).account.?.balance);
    try std.testing.expectEqual(@as(u32, 0), pending.changes().storage_writes.len());
    try std.testing.expectEqual(@as(u32, 1), pending.changes().storage_wipes.len());
    state.discard(rejected_attempt);

    try std.testing.expectEqual(@as(u32, 1), state.acceptedView().changes().storage_writes.len());
    try std.testing.expectEqual(@as(u256, 9), state.acceptedView().changes().storage_writes.at(0).value);
    try std.testing.expectEqual(
        @as(u256, 12),
        state.acceptedView().changes().accounts.at(0).account.?.balance,
    );
}

test "dense commit projection matches generic catalog commit across account lifecycles" {
    inline for (.{
        DenseCommitCase.update,
        DenseCommitCase.delete,
        DenseCommitCase.wipe_recreate,
        DenseCommitCase.storage_only,
    }) |case| try expectDenseCommitMatches(case);
}

const DenseCommitCase = enum {
    update,
    delete,
    wipe_recreate,
    storage_only,
};

fn expectDenseCommitMatches(case: DenseCommitCase) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const allocator = arena.allocator();
    const target = address.addr(1);
    const slot: u256 = 7;

    const storage_value = try trie.storageValue(allocator, 3);
    const storage_leaf = try denseCommitLeaf(allocator, trie.hashedStorageKey(slot), storage_value);
    const storage_root = crypto.keccak256(storage_leaf);
    const parent = trie.Account{
        .nonce = if (case == .storage_only) 0 else 1,
        .balance = if (case == .storage_only) 0 else 10,
        .storage_root = storage_root,
    };
    const account_value = try trie.accountValueFrom(allocator, parent);
    const account_leaf = try denseCommitLeaf(allocator, trie.hashedAddressKey(target), account_value);
    const state_root = crypto.keccak256(account_leaf);
    const nodes = [_][]const u8{ account_leaf, storage_leaf };
    var indexed = try trie.indexNodes(allocator, &nodes);
    defer indexed.deinit();
    var catalog = try trie.buildWitnessCatalog(allocator, state_root, indexed);
    defer catalog.deinit();

    const claims = [_]bal.AccountChanges{.{
        .address = target,
        .storage_reads = &.{slot},
    }};
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(allocator, &claims);
    const authenticated = try records.authenticate(allocator, plan, &catalog);
    var state = try StatelessBlockState.init(allocator, plan, authenticated);
    defer state.deinit();

    const attempt = state.beginObservedTransaction();
    state.beginScope();
    const account_id: StatelessBlockState.AccountId = @enumFromInt(0);
    const storage_id: StatelessBlockState.StorageId = @enumFromInt(0);
    switch (case) {
        .update => {
            try state.setBalance(target, 12);
            try state.writeStorage(storage_id, 9);
        },
        .delete => try state.writeAccount(account_id, .absent),
        .wipe_recreate => {
            try state.writeAccount(account_id, .absent);
            try state.wipeStorage(account_id);
            try state.writeAccount(account_id, .{ .present = .{ .nonce = 2, .balance = 5 } });
            try state.writeStorage(storage_id, 9);
        },
        .storage_only => try state.writeStorage(storage_id, 9),
    }
    state.closeScope();
    state.seal(attempt);
    state.retain(attempt);

    var account_facts = trie.AccountFacts.init(allocator);
    defer account_facts.deinit();
    try account_facts.put(target, parent);
    const accepted = state.acceptedView();
    const generic = try trie.stateRootAfterChangesCatalog(
        allocator,
        state_root,
        &catalog,
        &account_facts,
        accepted.changes(),
    );
    const dense = try StatelessCommit.stateRootAfterCatalog(
        allocator,
        state_root,
        &catalog,
        accepted.commit(),
    );
    try std.testing.expectEqualSlices(u8, &generic, &dense);
}

fn denseCommitLeaf(
    allocator: std.mem.Allocator,
    key: [32]u8,
    value: []const u8,
) ![]u8 {
    const rlp = @import("rlp");
    var compact: [33]u8 = undefined;
    compact[0] = 0x20;
    @memcpy(compact[1..], &key);
    var payload = rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(&compact);
    try payload.bytes(value);
    var out = rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return out.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => error.OutOfMemory,
    };
}

test "translation memo resolves alternating and evicted addresses to plan ids" {
    // Three declared accounts exercise both memo entries plus round-robin
    // eviction; every resolution must agree with the plan's binary search.
    const targets = [_]address.Address{ address.addr(0x0a), address.addr(0x0b), address.addr(0x0c) };
    const claims = [_]bal.AccountChanges{
        .{ .address = targets[0] },
        .{ .address = targets[1] },
        .{ .address = targets[2] },
    };
    const plan = try claim_plan.ClaimPlan.initAssumeValidated(std.testing.allocator, &claims);

    const account_facts = [_]records.AccountFact{
        .{ .parent = .{ .absent = .empty_trie } },
        .{ .parent = .{ .absent = .empty_trie } },
        .{ .parent = .{ .absent = .empty_trie } },
    };
    const facts = try records.initCopy(std.testing.allocator, &account_facts, &.{});
    var state = try StatelessBlockState.init(std.testing.allocator, plan, facts);
    defer state.deinit();

    // A,B alternation (both entries), then C forcing eviction, then a sweep
    // revisiting every address after each eviction pattern.
    const sequence = [_]usize{ 0, 1, 0, 1, 0, 1, 2, 0, 1, 2, 2, 1, 0 };
    for (sequence) |index| {
        const resolved = (try state.resolveAccount(targets[index], .required_observed)).?;
        try std.testing.expectEqual(plan.accountId(targets[index]).?, resolved);
    }
    try std.testing.expectEqual(
        @as(?StatelessBlockState.AccountId, null),
        try state.resolveAccount(address.addr(0xff), .optional_warm_only),
    );
    try std.testing.expectError(
        error.UndeclaredAccount,
        state.resolveAccount(address.addr(0xff), .required_observed),
    );
    // Undeclared misses must not corrupt the remembered entries.
    for (targets) |target| {
        const resolved = (try state.resolveAccount(target, .required_observed)).?;
        try std.testing.expectEqual(plan.accountId(target).?, resolved);
    }
}
