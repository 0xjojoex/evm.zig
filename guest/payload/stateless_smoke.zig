const std = @import("std");
const builtin = @import("builtin");
const evmz = @import("evmz");
const guest_options = @import("guest_options");
const guest_allocator = @import("guest_allocator");
const block_stf = evmz.eth.block_stf;

const sender = evmz.addr(0xaaaa);
const gas_limit: u64 = 21_000;
const starting_balance: u256 = 1_000_000;
const magic: u32 = 0x5354_4c53; // STLS
const zisk_output_addr: usize = 0xa0010000;

pub const output_word_count = 8;
pub var evmz_guest_output: [output_word_count]u32 = .{
    magic,
    0,
    0,
    0,
    0,
    0,
    0,
    0,
};

pub const StatelessProof = struct {
    status: block_stf.Status,
    gas_used: u64,
    block_gas_used: u64,
    state_root_low: u32,
    transactions_root_low: u32,
    receipts_root_low: u32,
};

pub fn evmz_guest_entry() callconv(.c) void {
    var fixed = guest_allocator.fixedBufferAllocator();
    const proof = runStatelessSmoke(fixed.allocator()) catch |err| {
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
        @intFromEnum(proof.status) + 1,
        @truncate(proof.gas_used),
        @truncate(proof.block_gas_used),
        proof.state_root_low,
        proof.transactions_root_low,
        proof.receipts_root_low,
        0,
    };
}

comptime {
    if (!builtin.is_test) {
        @export(&evmz_guest_output, .{ .name = "evmz_guest_output" });
        @export(&evmz_guest_entry, .{ .name = "evmz_guest_entry" });
    }
    if (guest_options.use_ziskos_staticlib) {
        @export(&ziskMain, .{ .name = "main" });
    }
}

fn ziskMain() callconv(.c) void {
    evmz_guest_entry();
    writeZiskOutput();
}

pub fn runStatelessSmoke(allocator: std.mem.Allocator) !StatelessProof {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const scratch = arena.allocator();

    const account_key = evmz.eth.trie.hashedAddressKey(sender);
    const pre_account_value = try evmz.eth.trie.accountValueFrom(scratch, .{
        .balance = starting_balance,
    });
    const state_node = try leafNode(scratch, &account_key, pre_account_value);
    const pre_state_root = evmz.crypto.keccak256(state_node);
    const nodes = [_][]const u8{state_node};
    const tx_input = [_]block_stf.TransactionInput{.{
        .tx = .{
            .sender = sender,
            .to = sender,
            .gas_limit = gas_limit,
        },
        .encoded = "stateless-smoke-tx0",
    }};

    const post_account_value = try evmz.eth.trie.accountValueFrom(scratch, .{
        .nonce = 1,
        .balance = starting_balance,
    });
    const post_state_pairs = [_]evmz.eth.trie.Pair{.{ .key = &account_key, .value = post_account_value }};
    const expected_state_root = try evmz.eth.trie.root(scratch, &post_state_pairs);
    const first = try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = gas_limit },
        .state_backend = try evmz.state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = .{
            .payload_header = .{
                .state = .fromHash(expected_state_root),
                .receipts = .fromHash([_]u8{0xff} ** 32),
            },
        },
    });
    if (first.status != .receipts_root_mismatch) return proofFrom(first);

    return proofFrom(try block_stf.applyAssumeDecoded(scratch, .{
        .revision = .frontier,
        .env = .{ .gas_limit = gas_limit },
        .state_backend = try evmz.state.Backend.fromWitness(scratch, pre_state_root, &nodes, &.{}),
        .transactions = &tx_input,
        .root_checks = .{
            .payload_header = .{
                .state = .fromHash(expected_state_root),
                .receipts = .fromHash(first.receipts_root),
            },
        },
        .header_claims = .{
            .gas_used = first.gas_used,
            .block_gas_used = first.block_gas_used,
        },
    }));
}

fn proofFrom(result: block_stf.Result) StatelessProof {
    return .{
        .status = result.status,
        .gas_used = result.gas_used,
        .block_gas_used = result.block_gas_used,
        .state_root_low = rootLow(result.state_root),
        .transactions_root_low = rootLow(result.transactions_root),
        .receipts_root_low = rootLow(result.receipts_root),
    };
}

fn leafNode(allocator: std.mem.Allocator, key: []const u8, value: []const u8) ![]u8 {
    var payload = evmz.rlp.Writer.alloc(allocator);
    defer payload.deinit();
    try payload.bytes(try compactPath(allocator, key));
    try payload.bytes(value);

    var out = evmz.rlp.Writer.alloc(allocator);
    errdefer out.deinit();
    try out.listPayload(payload.written());
    return try writerOwned(&out);
}

fn compactPath(allocator: std.mem.Allocator, key: []const u8) ![]u8 {
    const out = try allocator.alloc(u8, key.len + 1);
    out[0] = 0x20;
    @memcpy(out[1..], key);
    return out;
}

fn writerOwned(writer: *evmz.rlp.Writer) std.mem.Allocator.Error![]u8 {
    return writer.toOwnedSlice() catch |err| switch (err) {
        error.BorrowedWriter => unreachable,
        error.OutOfMemory => return error.OutOfMemory,
    };
}

fn rootLow(root: [32]u8) u32 {
    return std.mem.readInt(u32, root[28..32], .big);
}

fn writeZiskOutput() void {
    for (evmz_guest_output, 0..) |word, i| {
        const output_word: *volatile u32 = @ptrFromInt(zisk_output_addr + i * @sizeOf(u32));
        output_word.* = word;
    }
}
