//! Shared one-transaction runner for the custom-fork demos: seed accounts,
//! transact through one exact VM, and copy out what the demos assert on.

const std = @import("std");
const evmz = @import("evmz");

pub const Account = struct {
    address: evmz.Address,
    balance: u256 = 0,
    code: []const u8 = &.{},
};

pub const Slot = struct {
    address: evmz.Address,
    key: u256,
};

pub const Request = struct {
    accounts: []const Account,
    sender: evmz.Address,
    /// `null` runs a create transaction with `input` as initcode.
    to: ?evmz.Address,
    input: []const u8 = &.{},
    gas_limit: u64 = 1_000_000,
    read_storage: ?Slot = null,
};

pub const Result = struct {
    status: evmz.TxStatus,
    gas_used: u64,
    output: []u8,
    deployed_code_len: usize,
    storage: u256,

    pub fn deinit(self: *const Result, allocator: std.mem.Allocator) void {
        allocator.free(self.output);
    }
};

pub fn transact(comptime VmType: type, allocator: std.mem.Allocator, request: Request) !Result {
    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();
    for (request.accounts) |account| {
        const stored = try memory.getOrCreateAccount(account.address);
        stored.balance = account.balance;
        if (account.code.len != 0) try stored.setCode(account.code);
    }

    var executor = VmType.Executor.init(allocator, .{
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var vm = VmType.init(&executor);
    const outcome = try vm.transact(.{
        .env = .{ .gas_limit = request.gas_limit },
        .tx = .{
            .sender = request.sender,
            .to = request.to,
            .input = request.input,
            .gas_limit = request.gas_limit,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return error.TransactionRejected,
    };
    defer executed.discardIfCurrent();

    // Read pending post-transaction state while the outcome is still current.
    const execution = executed.result();
    var deployed_code_len: usize = 0;
    if (execution.created_address) |created| {
        deployed_code_len = (try executor.getCode(created)).len;
    }

    var storage_value: u256 = 0;
    if (request.read_storage) |slot| {
        storage_value = try executor.getStorage(slot.address, slot.key);
    }

    return .{
        .status = execution.status,
        .gas_used = execution.gas.used,
        .output = try allocator.dupe(u8, execution.output),
        .deployed_code_len = deployed_code_len,
        .storage = storage_value,
    };
}
