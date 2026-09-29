const std = @import("std");
const evmz = @import("../evm.zig");
const eip7702 = @import("./eip7702.zig");

const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const Host = evmz.Host;
const execution = evmz.execution;

pub fn Callbacks(
    comptime spec: evmz.Spec,
    comptime World: type,
    comptime options_value: evmz.executor.CompileOptions,
) type {
    const Executor = evmz.executor.ExecutorType(spec, World, options_value);

    return struct {
        pub fn host(self: *Executor) Host {
            return Host{ .ptr = self, .vtable = &.{
                .call = call,
                .accountExists = accountExists,
                .getBalance = getBalance,
                .changeBalance = changeBalance,
                .getNonce = getNonce,
                .getCode = getCode,
                .getCodeHash = getCodeHash,
                .getStorage = hostGetStorage,
                .setStorage = setStorage,
                .loadStorage = loadStorage,
                .storeStorage = storeStorage,
                .emitLog = emitLog,
                .getBlockHash = getBlockHash,
                .selfDestruct = selfDestruct,
                .accessStorage = accessStorage,
                .accessDelegatedAccount = accessDelegatedAccount,
                .accessAccount = accessAccount,
                .observeAccountAccess = observeAccountAccess,
                .getTransientStorage = getTransientStorage,
                .setTransientStorage = setTransientStorage,
            } };
        }

        fn fromHost(ptr: *anyopaque) *Executor {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            std.debug.assert(self.execution_context != null);
            std.debug.assert(self.execution_phase != .closed);
            return self;
        }

        fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
            const self = fromHost(ptr);
            // A native entry requests children through its returned step.
            if (comptime spec.native_contract != execution.NoNativeContracts) {
                if (self.native_guard != null) return error.NativeHostCallUnsupported;
            }
            return self.resolveHostCall(msg);
        }

        fn accessAccount(ptr: *anyopaque, address: AddressWord) !execution.AccessStatus {
            const self = fromHost(ptr);
            if (nativeTargetActive(address)) return .warm;
            if (self.state.isAccountWarm(address)) return .warm;
            try self.state.warmAccount(address);
            return .cold;
        }

        fn accessDelegatedAccount(ptr: *anyopaque, address: AddressWord) !?execution.AccessStatus {
            const self = fromHost(ptr);
            const target = eip7702.delegationTarget(
                try self.state.getCode(address),
            ) orelse return null;
            const state_target: AddressWord = .fromAddress(target);
            if (nativeTargetActive(state_target)) return .warm;
            if (self.state.isAccountWarm(state_target)) return .warm;
            try self.state.warmAccount(state_target);
            return .cold;
        }

        fn selfDestruct(ptr: *anyopaque, address: AddressWord, beneficiary: AddressWord) !bool {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            const call_capture = try self.beginSelfDestructCapture(address, beneficiary);
            const policy = spec.self_destruct.policy(.{
                .same_address = address.eql(beneficiary),
                .created_in_transaction = self.state.createdInTransaction(address),
            });
            const effect = try self.state.applySelfDestruct(
                address,
                beneficiary,
                policy,
                spec.self_destruct.touches_beneficiary_on_zero_transfer,
            );
            if (effect.transferred_value != 0) {
                try self.emitTransferLog(.{
                    .from = address.address(),
                    .to = beneficiary.address(),
                    .amount = effect.transferred_value,
                });
            }
            if (call_capture) |token| try self.finishSelfDestructCapture(token);
            return !effect.previously_marked;
        }

        inline fn nativeTargetActive(address: AddressWord) bool {
            if (spec.precompile.activeWord(address)) return true;
            // Native-contract sets keep the Address-domain `active` contract; the
            // default empty set must not force canonical unpacking here.
            if (spec.native_contract == execution.NoNativeContracts) return false;
            return spec.native_contract.active(address.address());
        }

        fn accountExists(ptr: *anyopaque, address: AddressWord) !bool {
            const self = fromHost(ptr);
            return self.state.accountExists(address);
        }

        fn observeAccountAccess(ptr: *anyopaque, address: AddressWord, depth: u16) !void {
            const self = fromHost(ptr);
            _ = depth;
            try self.state.observeAccountAccess(address);
        }

        fn getBalance(ptr: *anyopaque, address: AddressWord) !u256 {
            const self = fromHost(ptr);
            return self.state.getBalance(address);
        }

        fn changeBalance(ptr: *anyopaque, change: Host.BalanceChange) !Host.BalanceChangeStatus {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            // Effect-local scope: native entries call this while dispatch runs.
            var scope = Executor.ExecutionCheckpoint.begin(self);
            defer scope.deinit();
            const address = change.address;
            const balance = try self.state.getBalance(address);
            const updated = switch (change.kind) {
                .credit => std.math.add(u256, balance, change.amount) catch return .overflow,
                .debit => std.math.sub(u256, balance, change.amount) catch return .insufficient_balance,
            };
            if (change.amount != 0) try self.state.setBalance(address, updated);
            if (change.event_log) |event_log| try self.state.emitLog(event_log);
            scope.commit();
            return .applied;
        }

        fn getNonce(ptr: *anyopaque, address: AddressWord) !u64 {
            const self = fromHost(ptr);
            return self.state.getNonce(address);
        }

        fn hostGetStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
            const self = fromHost(ptr);
            return self.state.getStorage(address, key);
        }

        fn setStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !execution.StorageStatus {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            return self.state.setStorage(address, key, value);
        }

        fn loadStorage(ptr: *anyopaque, address: AddressWord, key: u256) !Host.StorageLoadResult {
            const self = fromHost(ptr);
            return self.state.loadStorage(address, key);
        }

        fn storeStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !Host.StorageStoreResult {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            return self.state.storeStorage(address, key, value);
        }

        fn getCode(ptr: *anyopaque, address: AddressWord) ![]const u8 {
            const self = fromHost(ptr);
            return self.state.getCode(address);
        }

        fn getCodeHash(ptr: *anyopaque, address: AddressWord) !u256 {
            const self = fromHost(ptr);
            return self.state.getCodeHash(address);
        }

        fn emitLog(ptr: *anyopaque, event_log: Host.Log) !void {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            try self.state.emitLog(event_log);
        }

        fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
            const self = fromHost(ptr);
            const source = self.block_hash_source orelse return 0;
            const block_number = std.math.cast(u64, number) orelse return 0;
            return (try source.getBlockHash(block_number)) orelse 0;
        }

        fn accessStorage(ptr: *anyopaque, address: AddressWord, key: u256) !execution.AccessStatus {
            const self = fromHost(ptr);
            return self.state.accessStorage(address, key);
        }

        fn getTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
            const self = fromHost(ptr);
            return self.state.getTransientStorage(address, key);
        }

        fn setTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !void {
            const self = fromHost(ptr);
            try self.guardNativeMutation();
            try self.state.setTransientStorage(address, key, value);
        }
    };
}
