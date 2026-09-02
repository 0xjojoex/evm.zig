//! Borrowed projections over sealed claim-indexed execution state.
//!
//! Views contain no copied identities or values. `ClaimPlan` remains the sole
//! address/slot owner and `ClaimState` remains the lifecycle owner.

const std = @import("std");

const Address = @import("../../address.zig").Address;
const Account = @import("../../state/Account.zig");
const artifacts = @import("claim_artifacts.zig");
const LogBuffer = @import("../../state/LogBuffer.zig");

pub fn ViewType(comptime State: type) type {
    return struct {
        const Views = @This();

        pub const ChangeLayer = enum { accepted, transaction };

        pub const AccountChange = struct {
            address: Address,
            account: ?Account,
        };

        pub const StorageChange = struct {
            address: Address,
            key: u256,
            value: u256,
        };

        pub const AccountChanges = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: AccountChanges) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: AccountChanges, index: u32) AccountChange {
                const id = self.ids()[index];
                return .{
                    .address = self.state.plan.accountAddress(id),
                    .account = accountValue(switch (self.layer) {
                        .accepted => self.state.acceptedAccountValueForView(id),
                        .transaction => self.state.accounts[@intFromEnum(id)].current,
                    }),
                };
            }

            fn ids(self: AccountChanges) []const State.AccountId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_changed_accounts.items[0..self.state.transaction_block_changed_accounts_start]
                    else
                        self.state.block_changed_accounts.items,
                    .transaction => self.state.changed_accounts.items,
                };
            }
        };

        pub const StorageChanges = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: StorageChanges) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: StorageChanges, index: u32) StorageChange {
                const id = self.ids()[index];
                const account = self.state.plan.storageAccount(id);
                return .{
                    .address = self.state.plan.accountAddress(account),
                    .key = self.state.plan.storageSlot(id),
                    .value = switch (self.layer) {
                        .accepted => self.state.acceptedStorageValueForView(id),
                        .transaction => self.state.storageValueForView(id),
                    },
                };
            }

            fn ids(self: StorageChanges) []const State.StorageId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.dirty_storage.items[0..self.state.transaction_dirty_storage_start]
                    else
                        self.state.dirty_storage.items,
                    .transaction => self.state.changed_storage.items,
                };
            }
        };

        pub const StorageWipes = struct {
            state: *const State,
            layer: ChangeLayer,

            pub fn len(self: StorageWipes) u32 {
                return @intCast(self.ids().len);
            }

            pub fn at(self: StorageWipes, index: u32) Address {
                const id = self.ids()[index];
                return self.state.plan.accountAddress(id);
            }

            fn ids(self: StorageWipes) []const State.AccountId {
                return switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_storage_wipes.items[0..self.state.transaction_block_storage_wipes_start]
                    else
                        self.state.block_storage_wipes.items,
                    .transaction => self.state.transaction_storage_wipes.items,
                };
            }
        };

        pub const ChangesView = struct {
            state: *const State,
            layer: ChangeLayer,
            accounts: AccountChanges,
            storage_writes: StorageChanges,
            storage_wipes: StorageWipes,

            pub fn init(state: *const State, layer: ChangeLayer) ChangesView {
                return .{
                    .state = state,
                    .layer = layer,
                    .accounts = .{ .state = state, .layer = layer },
                    .storage_writes = .{ .state = state, .layer = layer },
                    .storage_wipes = .{ .state = state, .layer = layer },
                };
            }

            pub fn introducedCode(self: ChangesView, hash: [32]u8) ?artifacts.CodeView {
                const ids = switch (self.layer) {
                    .accepted => if (self.state.transaction_active)
                        self.state.block_introduced_codes.items[0..self.state.transaction_introduced_codes_start]
                    else
                        self.state.block_introduced_codes.items,
                    .transaction => self.state.transaction_introduced_codes.items,
                };
                for (ids) |id| {
                    const view = self.state.code.introducedView(id);
                    if (std.mem.eql(u8, &view.code_hash, &hash)) return view;
                }
                return null;
            }

            pub fn hasChanges(self: ChangesView) bool {
                return self.accounts.len() != 0 or
                    self.storage_writes.len() != 0 or
                    self.storage_wipes.len() != 0;
            }
        };

        pub const AccountObservationFact = struct {
            address: Address,
            original: ?Account,
            current: ?Account,
            observation: State.AccountObservation,
            effect: State.AccountEffect,
        };

        pub const StorageObservationFact = struct {
            address: Address,
            key: u256,
            original: u256,
            current: u256,
            observation: State.StorageObservation,
            effect: State.StorageEffect,
        };

        pub const StorageObservationMetadata = struct {
            address: Address,
            key: u256,
            observation: State.StorageObservation,
            effect: State.StorageEffect,
        };

        pub const AccountObservations = struct {
            state: *const State,

            pub fn len(self: AccountObservations) u32 {
                return @intCast(self.state.observed_accounts.items.len);
            }

            pub fn at(self: AccountObservations, index: u32) AccountObservationFact {
                const observed = self.state.observed_accounts.items[index];
                return .{
                    .address = self.state.plan.accountAddress(observed.account),
                    .original = accountValue(observed.original),
                    .current = accountValue(observed.effect_current),
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }

            pub fn idAt(self: AccountObservations, index: u32) State.AccountId {
                return self.state.observed_accounts.items[index].account;
            }
        };

        pub const StorageObservations = struct {
            state: *const State,

            pub fn len(self: StorageObservations) u32 {
                return @intCast(self.state.observed_storage.items.len);
            }

            pub fn at(self: StorageObservations, index: u32) ?StorageObservationFact {
                const observed = self.state.observed_storage.items[index];
                const account = self.state.plan.storageAccount(observed.storage);
                return .{
                    .address = self.state.plan.accountAddress(account),
                    .key = self.state.plan.storageSlot(observed.storage),
                    .original = observed.original,
                    .current = observed.effect_current,
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }

            pub fn idAt(self: StorageObservations, index: u32) State.StorageId {
                return self.state.observed_storage.items[index].storage;
            }

            pub fn metadataAt(self: StorageObservations, index: u32) StorageObservationMetadata {
                const observed = self.state.observed_storage.items[index];
                const account = self.state.plan.storageAccount(observed.storage);
                return .{
                    .address = self.state.plan.accountAddress(account),
                    .key = self.state.plan.storageSlot(observed.storage),
                    .observation = observed.observation,
                    .effect = observed.effect,
                };
            }
        };

        pub const ObservationsView = struct {
            state: *const State,
            accounts: AccountObservations,
            storage: StorageObservations,

            pub fn init(state: *const State) ObservationsView {
                return .{
                    .state = state,
                    .accounts = .{ .state = state },
                    .storage = .{ .state = state },
                };
            }

            pub fn code(self: ObservationsView, hash: [32]u8) ?artifacts.CodeView {
                return self.state.code.lookup(hash);
            }
        };

        pub const AcceptedView = struct {
            state: *const State,

            pub fn hasChanges(self: AcceptedView) bool {
                return self.changes().hasChanges();
            }

            pub fn changes(self: AcceptedView) ChangesView {
                return ChangesView.init(self.state, .accepted);
            }

            /// Commit projection over the same sealed dense rows. Identity,
            /// trie order, and parent facts stay borrowed; commit must not
            /// reconstruct them from address/slot change records.
            pub fn commit(self: AcceptedView) CommitView {
                return .{ .state = self.state };
            }
        };

        pub const CommitView = struct {
            state: *const State,

            pub fn accountTrieOrder(self: CommitView) []const State.AccountId {
                return self.state.plan.account_trie_order;
            }

            pub fn storageTrieOrder(
                self: CommitView,
                account: State.AccountId,
            ) []const State.StorageId {
                return self.state.plan.storageTrieOrder(account);
            }

            pub fn accountTrieKey(self: CommitView, id: State.AccountId) [32]u8 {
                return self.state.plan.accountTrieKey(id);
            }

            pub fn storageTrieKey(self: CommitView, id: State.StorageId) [32]u8 {
                return self.state.plan.storageTrieKey(id);
            }

            pub fn accountFact(self: CommitView, id: State.AccountId) *const @TypeOf(self.state.facts.accounts[0]) {
                return &self.state.facts.accounts[@intFromEnum(id)];
            }

            pub fn accountValue(self: CommitView, id: State.AccountId) State.AccountValue {
                return self.state.accounts[@intFromEnum(id)].current;
            }

            pub fn storageValue(self: CommitView, id: State.StorageId) u256 {
                return self.state.storageValueForView(id);
            }

            pub fn accountDirty(self: CommitView, id: State.AccountId) bool {
                return self.state.accounts[@intFromEnum(id)].flags.block_dirty;
            }

            pub fn accountChanged(self: CommitView, id: State.AccountId) bool {
                return self.state.accounts[@intFromEnum(id)].flags.block_changed;
            }

            pub fn accountStorageDirty(self: CommitView, id: State.AccountId) bool {
                return self.state.accounts[@intFromEnum(id)].flags.storage_dirty;
            }

            pub fn storageDirty(self: CommitView, id: State.StorageId) bool {
                const row = &self.state.storage[@intFromEnum(id)];
                const account = &self.state.accounts[@intFromEnum(self.state.plan.storageAccount(id))];
                return row.flags.block_dirty and
                    row.storage_generation == account.storage_generation;
            }

            pub fn storageWiped(self: CommitView, id: State.AccountId) bool {
                return self.state.accounts[@intFromEnum(id)].flags.storage_wiped;
            }
        };

        pub const PendingView = struct {
            state: *const State,

            pub fn accepted(self: PendingView) AcceptedView {
                self.assertSealed();
                return .{ .state = self.state };
            }

            pub fn logs(self: PendingView) LogBuffer.View {
                self.assertSealed();
                return self.state.logs.view();
            }

            pub fn changes(self: PendingView) ChangesView {
                self.assertSealed();
                return ChangesView.init(self.state, .transaction);
            }

            pub fn observations(self: PendingView) ObservationsView {
                self.assertSealed();
                std.debug.assert(self.state.observed_attempt);
                return ObservationsView.init(self.state);
            }

            fn assertSealed(self: PendingView) void {
                std.debug.assert(self.state.transaction_active);
                std.debug.assert(self.state.sealed);
                std.debug.assert(!self.state.scopeActive());
            }
        };

        fn accountValue(value: State.AccountValue) ?Account {
            return switch (value) {
                .absent => null,
                .present => |account| account,
            };
        }
    };
}
