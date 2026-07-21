//! Minimal BAL parallel verification demo.
//!
//! The transactions are constructed locally, so this example uses the
//! trusted-decoded entry points. Callers receiving untrusted envelopes should
//! use `produce` and `eth.bal.Executor.init`, which decode raw bytes internally.

const std = @import("std");
const evmz = @import("evmz");

const block_stf = evmz.eth.block_stf;

const sender = evmz.addr(0x1000);
const target = evmz.addr(0x2000);

const target_code = [_]u8{
    0x36, // CALLDATASIZE
    0x15, // ISZERO
    0x60, 0x0b, // PUSH1 read
    0x57, // JUMPI
    0x60, 0x07, // PUSH1 7
    0x60, 0x02, // PUSH1 slot 2
    0x55, // SSTORE
    0x00, // STOP
    0x5b, // read: JUMPDEST
    0x60, 0x02, // PUSH1 slot 2
    0x54, // SLOAD
    0x00, // STOP
};

const transactions = [_]evmz.eth.bal.TransactionInput{
    .initAssumeDecoded(.{
        .sender = sender,
        .nonce = 0,
        .gas_limit = 1_000_000,
        .to = target,
        .input = &.{1},
    }, "bal-parallel-write"),
    .initAssumeDecoded(.{
        .sender = sender,
        .nonce = 1,
        .gas_limit = 1_000_000,
        .to = target,
    }, "bal-parallel-read"),
};

pub fn main(init: std.process.Init) !void {
    // Zig's process runtime is one valid choice. A caller that already owns an
    // Evented runtime can use `runEvented`; Threaded and custom implementations
    // pass their type-erased handle directly to `run` in the same way.
    try run(init.io, init.gpa);
}

/// Select a caller-owned target-native `std.Io.Evented` runtime explicitly.
/// The outer application retains responsibility for its initialization and
/// shutdown; this block operation only borrows its `std.Io` handle.
pub fn runEvented(evented: *std.Io.Evented, allocator: std.mem.Allocator) !void {
    try run(evented.io(), allocator);
}

/// Execute the demo with any caller-owned `std.Io` implementation.
pub fn run(io: std.Io, allocator: std.mem.Allocator) !void {
    // Build the independent payload claim that a verifier would normally
    // receive from the network.
    var producer_state = evmz.state.MemoryStore.init(allocator);
    defer producer_state.deinit();
    try initState(&producer_state);

    var outcome = try block_stf.produceAssumeDecoded(allocator, .{
        .revision = .amsterdam,
        .env = .{ .gas_limit = 2_000_000 },
        .state_backend = producer_state.backend(),
        .transactions = &transactions,
        .parent_blob_gas = parentBlobGas(),
    });
    defer outcome.deinit(allocator);
    const produced = switch (outcome) {
        .produced => |*value| value,
        .rejected => |result| {
            std.debug.print("producer rejected block: {s}\n", .{@tagName(result.status)});
            return error.ExampleBlockRejected;
        },
    };

    // The authoritative serial fold owns `state_backend`. Candidate lanes get
    // only a caller-certified concurrent view of the frozen pre-state.
    var verifier_state = evmz.state.MemoryStore.init(allocator);
    defer verifier_state.deinit();
    try initState(&verifier_state);
    const concurrent_reader = verifier_state.concurrentReader();

    var report = evmz.eth.bal.Report{};
    var bal_executor = evmz.eth.bal.Executor.initAssumeDecoded(
        io,
        allocator,
        .{
            .revision = .amsterdam,
            .env = .{ .gas_limit = 2_000_000 },
            .state_backend = verifier_state.backend(),
            .transactions = &transactions,
            .parent_blob_gas = parentBlobGas(),
            .block_access_list = produced.encoded_block_access_list,
            .root_checks = rootChecks(produced.output),
            .header_claims = .{
                .block_access_list_hash = produced.output.block_access_list_hash,
            },
            .bal_differential = &report,
        },
        .{
            .max_in_flight = 2,
            // Require real overlap from the supplied runtime. Use `.async`
            // for best-effort scheduling that may execute lanes eagerly.
            .submission = .concurrent,
        },
        .{
            .lane_allocator = std.heap.smp_allocator,
            .state_reader = concurrent_reader,
        },
    );
    defer bal_executor.deinit();

    const result = try bal_executor.run();

    if (result.status != .valid) return error.ExampleBlockInvalid;
    if (report.status != .matched) return error.ExampleBalMismatch;

    std.debug.print("block: {s}\n", .{@tagName(result.status)});
    std.debug.print("BAL lane: {s}\n", .{@tagName(report.status)});
    std.debug.print("submitted: {d}, batches: {d}, max batch: {d}\n", .{
        report.parallel_submitted_lanes,
        report.parallel_batches,
        report.parallel_max_batch_size,
    });
}

fn initState(store: *evmz.state.MemoryStore) !void {
    (try store.getOrCreateAccount(sender)).balance = 1_000_000;
    try (try store.getOrCreateAccount(target)).setCode(&target_code);
}

fn parentBlobGas() evmz.eth.bal.ParentBlobGas {
    return .{
        .parent_excess_blob_gas = 0,
        .parent_blob_gas_used = 0,
        .parent_base_fee_per_gas = 0,
    };
}

fn rootChecks(output: evmz.eth.bal.DerivedBlockOutput) evmz.eth.bal.RootChecks {
    return .{
        .payload_header = .{
            .state = .fromHash(output.state_root),
            .receipts = .fromHash(output.receipts_root),
        },
        .reconstructed_header = .{
            .transactions = .fromHash(output.transactions_root),
            .withdrawals = .fromHash(output.withdrawals_root),
        },
    };
}
