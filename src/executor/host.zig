const std = @import("std");
const evmz = @import("../evm.zig");
const eip7702 = @import("./eip7702.zig");

const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const Host = evmz.Host;
const execution = evmz.execution;

pub fn Callbacks(
    comptime specification: evmz.Spec,
    comptime World: type,
    comptime options_value: evmz.executor.CompileOptions,
) type {
    const Executor = evmz.executor.ExecutorType(specification, World, options_value);

    return struct {
        const Self = @This();
        const spec = specification;

        /// Executor handle for one native entry: the journaled paths `Host` uses,
        /// with mutation rejected in a static entry and no call, since children
        /// are requested through the returned step. Entry-scoped; never retain it.
        pub const NativeContext = struct {
            /// The executor's own spec. Price EVM-like effects from it, so they
            /// never disagree with the executor, including `Spec.extend` overrides.
            pub const spec = specification;

            /// Not a capability: effects that bypass these methods skip the guard.
            executor: *Executor,
            guard: *Guard,

            pub const Guard = struct {
                is_static: bool,
                violated_static: bool = false,
            };

            /// A caught error cannot clear the entry's terminal violation.
            fn mutate(self: NativeContext) !void {
                if (!self.guard.is_static and !self.guard.violated_static) return;
                self.guard.violated_static = true;
                return error.StaticModeViolation;
            }

            pub fn accountExists(self: NativeContext, address: Address) !bool {
                return Self.accountExists(self.executor, .fromAddress(address));
            }
            pub fn getBalance(self: NativeContext, address: Address) !u256 {
                return Self.getBalance(self.executor, .fromAddress(address));
            }
            /// Issuance: no transfer log. `error.BalanceOverflow` changes nothing.
            pub fn addBalance(self: NativeContext, address: Address, value: u256) !void {
                try self.mutate();
                try self.executor.addBalance(address, value);
            }
            /// Burn. False, with nothing changed, when the balance is short.
            pub fn subtractBalance(self: NativeContext, address: Address, value: u256) !bool {
                try self.mutate();
                return self.executor.subtractBalance(address, value);
            }
            pub fn getNonce(self: NativeContext, address: Address) !u64 {
                return Self.getNonce(self.executor, .fromAddress(address));
            }
            pub fn getCode(self: NativeContext, address: Address) ![]const u8 {
                return Self.getCode(self.executor, .fromAddress(address));
            }
            pub fn getCodeHash(self: NativeContext, address: Address) !u256 {
                return Self.getCodeHash(self.executor, .fromAddress(address));
            }
            pub fn getStorage(self: NativeContext, address: Address, key: u256) !u256 {
                return Self.hostGetStorage(self.executor, .fromAddress(address), key);
            }
            pub fn setStorage(self: NativeContext, address: Address, key: u256, value: u256) !execution.StorageStatus {
                try self.mutate();
                return Self.setStorage(self.executor, .fromAddress(address), key, value);
            }
            pub fn loadStorage(self: NativeContext, address: Address, key: u256) !Host.StorageLoadResult {
                return Self.loadStorage(self.executor, .fromAddress(address), key);
            }
            pub fn storeStorage(self: NativeContext, address: Address, key: u256, value: u256) !Host.StorageStoreResult {
                try self.mutate();
                return Self.storeStorage(self.executor, .fromAddress(address), key, value);
            }
            pub fn getTransientStorage(self: NativeContext, address: Address, key: u256) !u256 {
                return Self.getTransientStorage(self.executor, .fromAddress(address), key);
            }
            pub fn setTransientStorage(self: NativeContext, address: Address, key: u256, value: u256) !void {
                try self.mutate();
                return Self.setTransientStorage(self.executor, .fromAddress(address), key, value);
            }
            pub fn emitLog(self: NativeContext, event_log: Host.Log) !void {
                try self.mutate();
                return Self.emitLog(self.executor, event_log);
            }
            pub fn selfDestruct(self: NativeContext, address: Address, beneficiary: Address) !bool {
                try self.mutate();
                return Self.selfDestruct(self.executor, .fromAddress(address), .fromAddress(beneficiary));
            }
            pub fn getBlockHash(self: NativeContext, number: u256) !u256 {
                return Self.getBlockHash(self.executor, number);
            }
            pub fn accessAccount(self: NativeContext, address: Address) !execution.AccessStatus {
                return Self.accessAccount(self.executor, .fromAddress(address));
            }
            pub fn accessDelegatedAccount(self: NativeContext, address: Address) !?execution.AccessStatus {
                return Self.accessDelegatedAccount(self.executor, .fromAddress(address));
            }
            pub fn accessStorage(self: NativeContext, address: Address, key: u256) !execution.AccessStatus {
                return Self.accessStorage(self.executor, .fromAddress(address), key);
            }
        };

        pub fn host(self: *Executor) Host {
            return Host{ .ptr = self, .vtable = &.{
                .call = call,
                .accountExists = accountExists,
                .getBalance = getBalance,
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
            return self.state.setStorage(address, key, value);
        }

        fn loadStorage(ptr: *anyopaque, address: AddressWord, key: u256) !Host.StorageLoadResult {
            const self = fromHost(ptr);
            return self.state.loadStorage(address, key);
        }

        fn storeStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !Host.StorageStoreResult {
            const self = fromHost(ptr);
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
            try self.state.setTransientStorage(address, key, value);
        }
    };
}
