const std = @import("std");
const evmz = @import("../evm.zig");
const eip7702 = @import("./eip7702.zig");

const Address = evmz.Address;
const AddressWord = evmz.AddressWord;
const Host = evmz.Host;
const execution = evmz.execution;

pub fn bind(
    comptime spec: evmz.Spec,
    comptime ExecutionState: type,
    comptime options_value: evmz.executor.CompileOptions,
) type {
    return struct {
        const Executor = evmz.executor.ExecutorType(spec, ExecutionState, options_value);
        pub fn host(self: *Executor) Host {
            return Host{ .ptr = self, .vtable = &.{
                .call = Callbacks().call,
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
                .selfDestruct = Callbacks().selfDestruct,
                .accessStorage = accessStorage,
                .accessDelegatedAccount = Callbacks().accessDelegatedAccount,
                .accessAccount = Callbacks().accessAccount,
                .observeAccountAccess = observeAccountAccess,
                .getTransientStorage = getTransientStorage,
                .setTransientStorage = setTransientStorage,
            } };
        }

        fn Callbacks() type {
            return struct {
                fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    return self.resolveHostCall(msg);
                }

                fn accessAccount(ptr: *anyopaque, address: AddressWord) !execution.AccessStatus {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    if (nativeContractActive(address)) return .warm;
                    const target = Executor.executionAddress(address);
                    if (self.state.isAccountWarm(target)) return .warm;
                    try self.state.warmAccount(target);
                    return .cold;
                }

                fn accessDelegatedAccount(ptr: *anyopaque, address: AddressWord) !?execution.AccessStatus {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    const target = eip7702.delegationTarget(
                        try self.state.getCode(Executor.executionAddress(address)),
                    ) orelse return null;
                    const target_word: AddressWord = .fromAddress(target);
                    if (nativeContractActive(target_word)) return .warm;
                    const state_target = Executor.executionAddress(target_word);
                    if (self.state.isAccountWarm(state_target)) return .warm;
                    try self.state.warmAccount(state_target);
                    return .cold;
                }

                fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    const balance = try getBalance(ptr, .fromAddress(address));
                    const call_capture = try self.beginSelfDestructCapture(
                        address,
                        beneficiary,
                        balance,
                    );
                    const same_address = Address.eql(address, beneficiary);
                    const state_address = Executor.stateAddress(address);
                    const state_beneficiary = Executor.stateAddress(beneficiary);
                    const should_refund = !self.state.wasSelfdestructed(state_address);
                    const policy = spec.self_destruct.policy(.{
                        .same_address = same_address,
                        .created_in_transaction = self.state.createdInTransaction(state_address),
                    });
                    if (balance > 0) {
                        if (!same_address) {
                            try self.state.addBalance(state_beneficiary, balance);
                            try self.emitTransferLog(.{
                                .from = address,
                                .to = beneficiary,
                                .amount = balance,
                            });
                        }
                        if (policy.clear_balance) {
                            try self.state.setBalance(state_address, 0);
                        }
                    } else if (!same_address and spec.self_destruct.touches_beneficiary_on_zero_transfer) {
                        try self.state.touchAccount(state_beneficiary);
                    }
                    if (policy.reset_nonce) {
                        try self.state.setNonce(state_address, 0);
                    }
                    if (policy.mark_selfdestructed) {
                        try self.state.markSelfdestructed(state_address);
                    }
                    if (call_capture) |token| try self.finishSelfDestructCapture(token);
                    return should_refund;
                }
            };
        }

        inline fn nativeContractActive(address: AddressWord) bool {
            const canonical = address.address();
            return spec.precompile.active(canonical) or
                spec.reentrant_native_contract.active(canonical);
        }

        fn accountExists(ptr: *anyopaque, address: AddressWord) !bool {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.accountExists(Executor.executionAddress(address));
        }

        fn observeAccountAccess(ptr: *anyopaque, address: AddressWord, depth: u16) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            _ = depth;
            try self.state.observeAccountAccess(Executor.executionAddress(address));
        }

        fn getBalance(ptr: *anyopaque, address: AddressWord) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getBalance(Executor.executionAddress(address));
        }

        fn getNonce(ptr: *anyopaque, address: AddressWord) !u64 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getNonce(Executor.executionAddress(address));
        }

        fn hostGetStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getStorage(Executor.executionAddress(address), key);
        }

        fn setStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !execution.StorageStatus {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.setStorage(Executor.executionAddress(address), key, value);
        }

        fn loadStorage(ptr: *anyopaque, address: AddressWord, key: u256) !Host.StorageLoadResult {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.loadStorage(Executor.executionAddress(address), key);
        }

        fn storeStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !Host.StorageStoreResult {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.storeStorage(Executor.executionAddress(address), key, value);
        }

        fn getCode(ptr: *anyopaque, address: AddressWord) ![]const u8 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getCode(Executor.executionAddress(address));
        }

        fn getCodeHash(ptr: *anyopaque, address: AddressWord) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getCodeHash(Executor.executionAddress(address));
        }

        fn emitLog(ptr: *anyopaque, event_log: Host.Log) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            try self.state.emitLog(event_log);
        }

        fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            const source = self.block_hash_source orelse return 0;
            const block_number = std.math.cast(u64, number) orelse return 0;
            return (try source.getBlockHash(block_number)) orelse 0;
        }

        fn accessStorage(ptr: *anyopaque, address: AddressWord, key: u256) !execution.AccessStatus {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.accessStorage(Executor.executionAddress(address), key);
        }

        fn getTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getTransientStorage(Executor.executionAddress(address), key);
        }

        fn setTransientStorage(ptr: *anyopaque, address: AddressWord, key: u256, value: u256) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            try self.state.setTransientStorage(Executor.executionAddress(address), key, value);
        }
    };
}
