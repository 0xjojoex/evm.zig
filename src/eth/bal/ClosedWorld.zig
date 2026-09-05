//! Closed execution world: the universe is what the block access list
//! declares.
//!
//! The world for the BAL lane and the guest. Rows are dense arrays indexed by
//! claim id and exist from admission, seeded from parent facts authenticated
//! against the witness. Anything undeclared is invalid: an observed resolution
//! of an unlisted key is `error.Undeclared*`, a warm-only one resolves to
//! nothing. Trie order and trie keys are the plan's, so the state hands out a
//! commit view directly. Parent code is not cached here: it arrives with the
//! witness and lives in the state's code store from init, bound by index into
//! every row.
//!
//! The translation memo is the one piece of execution state the world keeps:
//! `ClaimPlan` is immutable for the block, so a remembered key→id entry can
//! never go stale and the state machine's revert, retain, and discard never
//! touch it.

const std = @import("std");

const address = @import("../../address.zig");
const world_state = @import("../../state/world_state.zig");
const state_types = @import("../../state.zig");
const Account = @import("../../state/Account.zig");
const artifacts = @import("claim_artifacts.zig");
const claim_plan = @import("ClaimPlan.zig");
const ParentFacts = @import("ParentFacts.zig");

const Allocator = std.mem.Allocator;
const Address = address.Address;
const AddressWord = address.AddressWord;
const CodeView = state_types.CodeView;
const AccountRow = world_state.AccountRow;
const StorageRow = world_state.StorageRow;
const RowSnapshot = world_state.RowSnapshot;
const ResolutionPolicy = world_state.ResolutionPolicy;
const CodeHash = [32]u8;

const ClosedWorld = @This();

pub const State = world_state.WorldState(ClosedWorld);

pub const AccountId = claim_plan.AccountId;
pub const StorageId = claim_plan.StorageId;

pub const ResolutionError = error{
    UndeclaredAccount,
    UndeclaredStorage,
};

pub const options: world_state.Options = .{
    // Every row exists from admission, sized by the claim plan. There is nothing
    // to reserve or reuse.
    .grows_on_touch = false,
    // Parent facts were authenticated against the witness at admission.
    .authenticated_parents = true,
    // Parent code is the witness's, handed to the state's code store at init.
    .caches_parent_code = false,
};

plan: claim_plan.ClaimPlan,
facts: ParentFacts,
accounts: []AccountRow,
storage: []StorageRow,
/// Hot-translation memo: two remembered address→id entries and one
/// (account, slot)→id entry. Full-key equality decides a hit. An account miss
/// falls back to `ClaimPlan`'s deterministic linear-probe table and evicts a
/// memo entry round-robin; a storage miss binary searches the account's slot
/// window and replaces the one storage entry. Two account entries cover the
/// caller/callee alternation of nested calls, which a single entry misses on
/// every step. Memo keys are pre-assembled address words: the probe is
/// assembled once per resolution and then compares in registers, instead of
/// paying an align-1 byte ladder on every hit.
translation_account_keys: [2]AddressWord = undefined,
translation_account_ids: [2]AccountId = undefined,
translation_account_valid: [2]bool = .{ false, false },
translation_account_victim: u1 = 0,
translation_storage_slot: u256 = undefined,
translation_storage_account: AccountId = undefined,
translation_storage_id: StorageId = undefined,
translation_storage_valid: bool = false,

/// Take ownership of `plan` and `facts`; both are released on failure.
pub fn init(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: ParentFacts,
) Allocator.Error!ClosedWorld {
    var owned_plan = plan;
    var owned_facts = facts;
    errdefer owned_plan.deinit(allocator);
    errdefer owned_facts.deinit(allocator);
    std.debug.assert(owned_plan.accountCount() == owned_facts.accounts.len);
    std.debug.assert(owned_plan.storageCount() == owned_facts.storage.len);

    const accounts = try allocator.alloc(AccountRow, owned_facts.accounts.len);
    errdefer allocator.free(accounts);
    const storage = try allocator.alloc(StorageRow, owned_facts.storage.len);
    errdefer allocator.free(storage);

    var world: ClosedWorld = .{
        .plan = owned_plan,
        .facts = owned_facts,
        .accounts = accounts,
        .storage = storage,
    };
    world.resetRows();
    return world;
}

/// State over this world with the witness's parent code bytes. Neither
/// constructor inlines: admission builds the claim plan in the same frame,
/// and that loop's register allocation is not something a state
/// constructor should be able to move.
pub noinline fn initState(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: ParentFacts,
    codes: []const []const u8,
) artifacts.CodeStore.InitError!State {
    var world = try init(allocator, plan, facts);
    errdefer world.deinit(allocator);
    const code = try artifacts.CodeStore.init(allocator, codes);
    return State.initWithCodeStore(allocator, world, code);
}

/// State over this world with parent codes the witness already hashed.
pub noinline fn initStateHashed(
    allocator: Allocator,
    plan: claim_plan.ClaimPlan,
    facts: ParentFacts,
    codes: []const artifacts.ParentCode,
) artifacts.CodeStore.InitError!State {
    var world = try init(allocator, plan, facts);
    errdefer world.deinit(allocator);
    const code = try artifacts.CodeStore.initHashed(allocator, codes);
    return State.initWithCodeStore(allocator, world, code);
}

pub fn deinit(self: *ClosedWorld, allocator: Allocator) void {
    allocator.free(self.accounts);
    allocator.free(self.storage);
    self.facts.deinit(allocator);
    self.plan.deinit(allocator);
    self.* = undefined;
}

pub fn accountCount(self: *const ClosedWorld) u32 {
    return @intCast(self.accounts.len);
}

pub inline fn accountRow(self: *const ClosedWorld, id: AccountId) *AccountRow {
    return &self.accounts[@intFromEnum(id)];
}

pub inline fn storageRow(self: *const ClosedWorld, id: StorageId) *StorageRow {
    return &self.storage[@intFromEnum(id)];
}

pub fn accountAddress(self: *const ClosedWorld, id: AccountId) Address {
    return self.plan.accountAddress(id);
}

pub fn storageAccount(self: *const ClosedWorld, id: StorageId) AccountId {
    return self.plan.storageAccount(id);
}

pub fn storageSlot(self: *const ClosedWorld, id: StorageId) u256 {
    return self.plan.storageSlot(id);
}

/// Every declared row exists, so a find is a resolution that never fails.
pub inline fn findAccount(self: *ClosedWorld, address_word: AddressWord) ?AccountId {
    return self.lookupAccount(address_word);
}

pub fn findStorage(self: *ClosedWorld, account: AccountId, slot: u256) ?StorageId {
    return self.lookupStorage(account, slot);
}

pub inline fn resolveAccount(
    self: *ClosedWorld,
    address_word: AddressWord,
    policy: ResolutionPolicy,
) ResolutionError!?AccountId {
    if (self.lookupAccount(address_word)) |id| return id;
    return switch (policy) {
        .required_observed => error.UndeclaredAccount,
        .optional_warm_only => null,
    };
}

pub fn resolveStorage(
    self: *ClosedWorld,
    account: AccountId,
    slot: u256,
    policy: ResolutionPolicy,
) ResolutionError!?StorageId {
    if (self.lookupStorage(account, slot)) |id| return id;
    return switch (policy) {
        .required_observed => error.UndeclaredStorage,
        .optional_warm_only => null,
    };
}

inline fn lookupAccount(self: *ClosedWorld, address_word: AddressWord) ?AccountId {
    inline for (0..2) |entry| {
        if (self.translation_account_valid[entry] and
            AddressWord.eql(self.translation_account_keys[entry], address_word))
        {
            return self.translation_account_ids[entry];
        }
    }
    const id = self.plan.accountIdWord(address_word) orelse return null;
    const victim = self.translation_account_victim;
    self.translation_account_keys[victim] = address_word;
    self.translation_account_ids[victim] = id;
    self.translation_account_valid[victim] = true;
    self.translation_account_victim +%= 1;
    return id;
}

fn lookupStorage(self: *ClosedWorld, account: AccountId, slot: u256) ?StorageId {
    if (self.translation_storage_valid and
        self.translation_storage_account == account and
        self.translation_storage_slot == slot)
    {
        return self.translation_storage_id;
    }
    const id = self.plan.storageId(account, slot) orelse return null;
    self.translation_storage_account = account;
    self.translation_storage_slot = slot;
    self.translation_storage_id = id;
    self.translation_storage_valid = true;
    return id;
}

pub inline fn cachedCode(_: *const ClosedWorld, _: CodeHash) ?CodeView {
    return null;
}

/// Code the store does not hold was not in the witness.
pub fn loadCode(_: *ClosedWorld, _: CodeHash) error{InvalidWitness}!CodeView {
    return error.InvalidWitness;
}

/// Every row goes back to the value its parent fact admits; code binds on
/// first fetch through the state's store.
pub fn resetRows(self: *ClosedWorld) void {
    for (self.facts.accounts, self.accounts) |fact, *row| {
        row.* = .admitted(accountExecutionValue(fact));
    }
    for (self.facts.storage, self.storage) |fact, *row| {
        row.* = .{ .current = fact.value };
    }
}

pub fn allocationBytes(self: *const ClosedWorld) usize {
    return self.accounts.len * @sizeOf(AccountRow) +
        self.storage.len * @sizeOf(StorageRow) +
        self.plan.allocationBytes() +
        self.facts.allocationBytes();
}

pub fn accountTrieOrder(self: *const ClosedWorld) []const AccountId {
    return self.plan.account_trie_order;
}

pub fn storageTrieOrder(self: *const ClosedWorld, account: AccountId) []const StorageId {
    return self.plan.storageTrieOrder(account);
}

pub fn accountTrieKey(self: *const ClosedWorld, id: AccountId) [32]u8 {
    return self.plan.accountTrieKey(id);
}

pub fn storageTrieKey(self: *const ClosedWorld, id: StorageId) [32]u8 {
    return self.plan.storageTrieKey(id);
}

pub fn accountFact(self: *const ClosedWorld, id: AccountId) *const ParentFacts.AccountFact {
    return &self.facts.accounts[@intFromEnum(id)];
}

/// The value execution sees for a parent fact. Dropping `storage_root` is the
/// point: liveness here is EIP-161, which ignores storage.
fn accountExecutionValue(fact: ParentFacts.AccountFact) ?Account {
    const parent = switch (fact.parent) {
        .absent => return null,
        .present => |parent| parent,
    };
    const account: Account = .{
        .nonce = parent.nonce,
        .balance = parent.balance,
        .code_hash = parent.code_hash,
    };
    return if (account.isEip161Empty()) null else account;
}

/// Capture a heap copy of every dense row.
pub fn captureSnapshot(self: *const ClosedWorld, allocator: Allocator) Allocator.Error!RowSnapshot {
    const accounts = try allocator.dupe(AccountRow, self.accounts);
    errdefer allocator.free(accounts);
    return .{
        .accounts = accounts,
        .storage = try allocator.dupe(StorageRow, self.storage),
    };
}

/// Restore captured values over the same fixed dense arrays.
pub fn restoreSnapshot(self: *ClosedWorld, snapshot: *const RowSnapshot) void {
    @memcpy(self.accounts, snapshot.accounts);
    @memcpy(self.storage, snapshot.storage);
}

comptime {
    world_state.checkWorld(ClosedWorld);
}
