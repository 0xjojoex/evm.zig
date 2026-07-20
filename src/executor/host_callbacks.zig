const std = @import("std");
const evmz = @import("../evm.zig");
const call_runtime_module = @import("./call_runtime.zig");
const eip7702 = @import("./eip7702.zig");

const Address = evmz.Address;
const Host = evmz.Host;

pub fn For(comptime Executor: type) type {
    return struct {
        const Protocol = Executor.Protocol;
        const call_runtime = call_runtime_module.For(Executor);
        pub fn host(self: *Executor) Host {
            return Host{ .ptr = self, .vtable = &.{
                .call = Callbacks().call,
                .accountExists = accountExists,
                .getBalance = getBalance,
                .getNonce = getNonce,
                .copyCode = copyCode,
                .getCodeSize = getCodeSize,
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
                .getTxContext = call_runtime.getTxContext,
                .getTransientStorage = getTransientStorage,
                .setTransientStorage = setTransientStorage,
            } };
        }

        fn Callbacks() type {
            return struct {
                fn call(ptr: *anyopaque, msg: Host.Message) !Host.Result {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    return call_runtime.resolveHostCall(self, msg);
                }

                fn accessAccount(ptr: *anyopaque, address: Address) !Host.AccessStatus {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    if (Protocol.Precompile.active(self.revision(), address)) return .warm;
                    if (self.state.warm_accounts.contains(address)) return .warm;
                    try self.state.warmAccount(address);
                    return .cold;
                }

                fn accessDelegatedAccount(ptr: *anyopaque, address: Address) !?Host.AccessStatus {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    const target = eip7702.delegationTarget(try self.getCode(address)) orelse return null;
                    if (Protocol.Precompile.active(self.revision(), target)) return .warm;
                    if (self.state.warm_accounts.contains(target)) return .warm;
                    try self.state.warmAccount(target);
                    return .cold;
                }

                fn selfDestruct(ptr: *anyopaque, address: Address, beneficiary: Address) !bool {
                    const self: *Executor = @ptrCast(@alignCast(ptr));
                    const balance = try getBalance(ptr, address);
                    const same_address = std.mem.eql(u8, &address, &beneficiary);
                    const should_refund = !self.state.selfdestructed_accounts.contains(address);
                    const policy = Protocol.self_destruct.selfDestructPolicy(
                        self.revision(),
                        .{
                            .same_address = same_address,
                            .created_in_transaction = self.state.created_contracts.contains(address),
                        },
                    );
                    if (balance > 0) {
                        if (!same_address) {
                            try self.state.addBalance(beneficiary, balance);
                            try evmz.executor.transfer_logs.emit(self, .{
                                .from = address,
                                .to = beneficiary,
                                .amount = balance,
                            });
                        }
                        if (policy.clear_balance) {
                            try self.state.setBalance(address, 0);
                        }
                    } else if (!same_address and Protocol.self_destruct.touchesBeneficiaryOnZeroTransfer(self.revision())) {
                        try self.state.touchAccount(beneficiary);
                    }
                    if (policy.reset_nonce) {
                        try self.state.setNonce(address, 0);
                    }
                    if (policy.mark_selfdestructed) {
                        try self.state.markSelfdestructed(address);
                    }
                    return should_refund;
                }
            };
        }

        fn accountExists(ptr: *anyopaque, address: Address) !bool {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.accountExists(address);
        }

        fn observeAccountAccess(ptr: *anyopaque, address: Address, depth: u16) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            try self.traceAccountAccess(address, depth);
        }

        fn getBalance(ptr: *anyopaque, address: Address) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getBalance(address);
        }

        fn getNonce(ptr: *anyopaque, address: Address) !u64 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getNonce(address);
        }

        fn hostGetStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getStorage(address, key);
        }

        fn setStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStatus {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.setStorage(address, key, value);
        }

        fn loadStorage(ptr: *anyopaque, address: Address, key: u256) !Host.StorageLoadResult {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.loadStorage(address, key);
        }

        fn storeStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !Host.StorageStoreResult {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.storeStorage(address, key, value);
        }

        fn getCodeSize(ptr: *anyopaque, address: Address) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return (try self.getCode(address)).len;
        }

        fn getCodeHash(ptr: *anyopaque, address: Address) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getCodeHash(address);
        }

        fn copyCode(ptr: *anyopaque, address: Address, code_offset: usize, buffer_data: []u8) !usize {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            const code = try self.getCode(address);
            if (code_offset >= code.len) return 0;
            const size = @min(buffer_data.len, code.len - code_offset);
            @memcpy(buffer_data[0..size], code[code_offset .. code_offset + size]);
            return size;
        }

        fn emitLog(ptr: *anyopaque, address: Address, topics: []const u256, data: []const u8) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            try self.state.emitLog(.{
                .address = address,
                .topics = topics,
                .data = data,
            });
        }

        fn getBlockHash(ptr: *anyopaque, number: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            const source = self.block_hash_source orelse return 0;
            const block_number = std.math.cast(u64, number) orelse return 0;
            return (try source.getBlockHash(block_number)) orelse 0;
        }

        fn accessStorage(ptr: *anyopaque, address: Address, key: u256) !Host.AccessStatus {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.accessStorage(address, key);
        }

        fn getTransientStorage(ptr: *anyopaque, address: Address, key: u256) !u256 {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            return self.state.getTransientStorage(address, key);
        }

        fn setTransientStorage(ptr: *anyopaque, address: Address, key: u256, value: u256) !void {
            const self: *Executor = @ptrCast(@alignCast(ptr));
            try self.state.setTransientStorage(address, key, value);
        }
    };
}
