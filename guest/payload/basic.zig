const std = @import("std");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_allocator = @import("guest_allocator");

const sender = evmz.addr(0xaaaa);
const contract = evmz.addr(0xbbbb);
const gas_limit: u64 = 1_000_000;
const magic: u32 = 0x4556_4d5a; // EVMZ
const zisk_output_addr: usize = 0xa0010000;

const bytecode = [_]u8{
    0x60, 0x2a, // PUSH1 42
    0x60, 0x00, // PUSH1 0
    0x55, // SSTORE
    0x60, 0x2a, // PUSH1 42
    0x60, 0x00, // PUSH1 0
    0x52, // MSTORE
    0x60, 0x20, // PUSH1 32
    0x60, 0x00, // PUSH1 0
    0xf3, // RETURN
};

pub const output_word_count = 8;
pub export var evmz_guest_output: [output_word_count]u32 = .{
    magic,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
};

pub const ProofStatus = enum(u32) {
    success = 1,
    revert = 2,
    invalid = 3,
    out_of_gas = 4,
    rejected = 5,
};

pub const BasicProof = struct {
    status: ProofStatus,
    gas_used: u64,
    output_len: u32,
    return_word_low: u32,
    storage_slot0_low: u32,
};

export fn evmz_guest_entry() callconv(.c) void {
    var fixed = guest_allocator.fixedBufferAllocator();
    const proof = runBasicFixture(fixed.allocator()) catch |err| {
        evmz_guest_output = .{
            magic,
            0,
            0,
            0,
            0,
            0,
            0,
            @truncate(@intFromError(err)),
        };
        return;
    };

    evmz_guest_output = .{
        magic,
        @intFromEnum(proof.status),
        @truncate(proof.gas_used),
        proof.output_len,
        proof.return_word_low,
        proof.storage_slot0_low,
        cryptoSmokeWord(),
        0,
    };
}

comptime {
    if (guest_options.use_ziskos_staticlib) {
        @export(&ziskMain, .{ .name = "main" });
    }
}

fn ziskMain() callconv(.c) void {
    evmz_guest_entry();
    writeZiskOutput();
}

pub fn runBasicFixture(allocator: std.mem.Allocator) !BasicProof {
    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();

    const sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;

    const contract_account = try memory.getOrCreateAccount(contract);
    try contract_account.setCode(&bytecode);

    var executor = evmz.Evm.Executor.init(allocator, .{
        .revision = .latest,
        .state_reader = memory.reader(),
    });
    defer executor.deinit();

    var vm = evmz.Evm.init(&executor);
    const outcome = try vm.transact(.{
        .env = .{ .gas_limit = gas_limit },
        .tx = .{
            .sender = sender,
            .to = contract,
            .gas_limit = gas_limit,
        },
    });
    const executed = switch (outcome) {
        .executed => |value| value,
        .rejected => return .{
            .status = .rejected,
            .gas_used = 0,
            .output_len = 0,
            .return_word_low = 0,
            .storage_slot0_low = 0,
        },
    };
    defer executed.discardIfCurrent();
    const result = try executed.result();
    var diff = try executed.changeset();
    defer diff.deinit(allocator);

    return .{
        .status = proofStatus(result.status),
        .gas_used = result.gas.used,
        .output_len = @intCast(result.output.len),
        .return_word_low = returnWordLow(result.output),
        .storage_slot0_low = @truncate(storageValue(&diff, contract, 0)),
    };
}

fn proofStatus(status: evmz.TxStatus) ProofStatus {
    return switch (status) {
        .success => .success,
        .revert => .revert,
        .invalid => .invalid,
        .out_of_gas => .out_of_gas,
    };
}

fn returnWordLow(output: []const u8) u32 {
    if (output.len < 32) return 0;
    return std.mem.readInt(u32, output[28..32], .big);
}

fn storageValue(diff: *const evmz.state.Changeset, address: evmz.Address, key: u256) u256 {
    for (diff.storage_writes.items) |write| {
        if (std.mem.eql(u8, &write.address, &address) and write.key == key) return write.value;
    }
    return 0;
}

fn cryptoSmokeWord() u32 {
    const digest = evmz.crypto.keccak256("");
    return std.mem.readInt(u32, digest[28..32], .big);
}

fn writeZiskOutput() void {
    for (evmz_guest_output, 0..) |word, i| {
        const output_word: *volatile u32 = @ptrFromInt(zisk_output_addr + i * @sizeOf(u32));
        output_word.* = word;
    }
}
