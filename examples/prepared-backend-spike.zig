//! Caller-owned prepared-code backend with a real nested VM call.
//!
//! `MemoryStore` serves canonical account/code reads. `InMemoryPreparedPool`
//! independently retains derived execution artifacts. Omitting
//! `prepared_code_backend` leaves the VM with transaction-scoped preparation
//! only and no hidden cross-transaction cache.

const std = @import("std");
const evmz = @import("evmz");

const InvalidationProbe = struct {
    pool: *evmz.InMemoryPreparedPool,
    invalidation_rejected: bool = false,

    fn sink(self: *@This()) evmz.trace.Sink {
        return evmz.trace.Sink.init(self, .{
            .step_start = evmz.trace.StepStartFields.initMany(&.{.opcode}),
        }, &.{ .stepStart = stepStart });
    }

    fn stepStart(ptr: *anyopaque, event: evmz.trace.StepStart) void {
        const self: *@This() = @ptrCast(@alignCast(ptr));
        _ = event;
        if (self.invalidation_rejected) return;

        self.pool.clearRetainingCapacity() catch |err| {
            std.debug.assert(err == error.ActivePreparedCodeExecution);
            self.invalidation_rejected = true;
            return;
        };
        @panic("prepared-code backend invalidated during execution");
    }
};

const Proof = struct {
    retained_entries: usize,
    invalidation_rejected_while_frame_live: bool,
};

fn runSpike(allocator: std.mem.Allocator) !Proof {
    const sender = evmz.addr(0xaaaa);
    const root = evmz.addr(0xbbbb);
    const child = evmz.addr(0xbeef);
    const gas_limit: u64 = 100_000;

    const root_code = evmz.t.bytecode(.{
        .PUSH0, .PUSH0, .PUSH0, .PUSH0, .PUSH0,
        .PUSH2, 0xbe,   0xef,   .GAS,   .CALL,
        .STOP,
    });
    const child_code = evmz.t.bytecode(.{.STOP});

    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();
    const sender_account = try memory.getOrCreateAccount(sender);
    sender_account.balance = 1_000_000;
    try (try memory.getOrCreateAccount(root)).setCode(&root_code);
    try (try memory.getOrCreateAccount(child)).setCode(&child_code);

    // The embedding owns both services and may keep the prepared pool alive
    // across VM resets or replace it with a persistent implementation.
    var prepared_pool = evmz.InMemoryPreparedPool.init(allocator);
    defer prepared_pool.deinit();
    var probe = InvalidationProbe{ .pool = &prepared_pool };
    var trace_sink = probe.sink();

    var vm = evmz.Evm.init(allocator, .{
        .revision = .latest,
        .state_reader = memory.reader(),
        .prepared_code_backend = prepared_pool.backend(),
        .trace_sink = &trace_sink,
        .env = .{ .gas_limit = gas_limit },
    });
    defer vm.deinit();

    const outcome = try vm.transact(.{
        .sender = sender,
        .to = root,
        .gas_limit = gas_limit,
    });
    var pending = switch (outcome) {
        .pending => |value| value,
        .rejected => return error.ExampleTransactionRejected,
    };
    defer pending.deinit();
    const execution = try pending.accept();
    if (execution.status != .success) return error.ExampleTransactionFailed;
    if (!probe.invalidation_rejected) return error.ExecutionPinMissing;

    const retained_entries = prepared_pool.count();
    if (retained_entries != 2) return error.PreparedEntriesMissing;

    // The top-level execution scope has ended, so maintenance is safe again.
    try prepared_pool.clearRetainingCapacity();
    return .{
        .retained_entries = retained_entries,
        .invalidation_rejected_while_frame_live = probe.invalidation_rejected,
    };
}

pub fn main(init: std.process.Init) !void {
    const proof = try runSpike(init.gpa);
    std.debug.print(
        "prepared entries: {d}\ninvalidation rejected while frame live: {any}\n",
        .{ proof.retained_entries, proof.invalidation_rejected_while_frame_live },
    );
}

test "caller-owned backend spans root and nested frames" {
    const proof = try runSpike(std.testing.allocator);
    try std.testing.expectEqual(@as(usize, 2), proof.retained_entries);
    try std.testing.expect(proof.invalidation_rejected_while_frame_live);
}
