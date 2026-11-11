//! Transaction-level lane: one complete transaction per call on a long-lived VM.
//!
//! The VM-loop lane times the interpreter from a prepared call frame. This lane times what a
//! block executor pays per transaction around it: validation, the fee debit, nonce advance,
//! the top-level call, refund, coinbase payment, and acceptance of the state transition.
//!
//! `evm2/src/tx_loop.rs` runs the same workloads through EVM2. The addresses, fees and setup
//! transactions below must stay identical in both files.
const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");

const Address = evmz.Address;

const sender = evmz.addr(0x1000000000000000000000000000000000000001);
const recipient = evmz.addr(0x3000000000000000000000000000000000000003);
const coinbase = evmz.addr(0xc000000000000000000000000000000000000000);

const sender_balance: u256 = 1 << 100;
const base_fee = 7;
const gas_price = 10;
const block_gas_limit = 60_000_000;
/// Below the EIP-7825 transaction gas cap of 2^24.
const setup_gas_limit = 16_000_000;
/// Covers every workload on every fork, including forks that reprice the intrinsic cost.
const workload_gas_limit = 100_000;

const env: evmz.Env = .{
    .coinbase = coinbase,
    .number = 1,
    .timestamp = 1,
    .gas_limit = block_gas_limit,
    .base_fee = base_fee,
};

const default_fixtures_dir = "fixtures/vm-loop";
const max_init_code_hex_size = 256 * 1024;

const selector_benchmark = 0x30627b7c;
const selector_balance_of = 0x70a08231;
const selector_transfer = 0xa9059cbb;

const Options = struct {
    case: Case = .eth_transfer,
    spec: evmz.eth.Revision = .osaka,
    repeats: usize = 5,
    warmups: usize = 1,
    txs: usize = 1000,
    code_cache: bool = true,
    fixtures_dir: []const u8 = default_fixtures_dir,
    header: bool = true,
    summary: bool = false,

    fn measuredTransactions(options: Options) u64 {
        return @as(u64, options.warmups + options.repeats) * options.txs;
    }
};

const Case = enum {
    /// 1 wei legacy transfer to an existing codeless account. Never enters the interpreter.
    eth_transfer,
    /// Zero-value call to a contract whose runtime is `STOP`: the smallest transaction that
    /// enters the interpreter.
    stop_call,
    /// One `transfer(address,uint256)` on the evm-bench ERC-20, both balance slots non-zero.
    erc20_transfer,
};

/// The transaction every timed call repeats. Only the nonce changes.
const Workload = struct {
    to: Address,
    value: u256 = 0,
    gas_limit: u64,
    input_buffer: [68]u8 = undefined,
    input_len: usize = 0,
    /// Gas used by one steady-state transaction, measured by the last setup transaction.
    gas_per_tx: u64 = 0,
    /// Recipient balance the timed transactions must add to, checked after the run.
    expected_before: u256 = 0,

    fn input(workload: *const Workload) []const u8 {
        return workload.input_buffer[0..workload.input_len];
    }
};

const Call = struct {
    to: ?Address,
    value: u256 = 0,
    input: []const u8 = &.{},
    gas_limit: u64,
};

const Receipt = struct {
    gas_used: u64,
    created: ?Address,
};

fn Runner(comptime Engine: type) type {
    return struct {
        const Self = @This();

        vm: Engine,
        nonce: u64 = 0,

        /// Executes one transaction, requires success, and retains its state transition.
        /// Copies the first return word into `return_word` when one is requested.
        fn send(self: *Self, call: Call, return_word: ?*[32]u8) !Receipt {
            const outcome = try self.vm.transact(.{ .env = env, .tx = .{
                .sender = sender,
                .nonce = self.nonce,
                .to = call.to,
                .value = call.value,
                .input = call.input,
                .gas_limit = call.gas_limit,
                .gas_price = gas_price,
            } });
            const executed = switch (outcome) {
                .executed => |executed| executed,
                .rejected => |rejection| {
                    std.debug.print("transaction rejected: {s}\n", .{@tagName(rejection)});
                    return error.TransactionRejected;
                },
            };
            const result = executed.result();
            if (result.status != .success) {
                std.debug.print("transaction failed: {s}\n", .{@tagName(result.status)});
                executed.discard();
                return error.TransactionFailed;
            }
            if (return_word) |word| {
                if (result.output.len < 32) {
                    executed.discard();
                    return error.ShortReturnData;
                }
                word.* = result.output[0..32].*;
            }
            const receipt: Receipt = .{
                .gas_used = result.gas.used,
                .created = result.created_address,
            };
            executed.retain();
            self.nonce += 1;
            return receipt;
        }

        fn deploy(
            self: *Self,
            io: std.Io,
            allocator: std.mem.Allocator,
            fixtures_dir: []const u8,
            name: []const u8,
        ) !Address {
            const path = try std.fmt.allocPrint(
                allocator,
                "{s}/{s}/init.hex",
                .{ fixtures_dir, name },
            );
            defer allocator.free(path);
            const init_code_hex = try std.Io.Dir.cwd().readFileAlloc(
                io,
                path,
                allocator,
                .limited(max_init_code_hex_size),
            );
            defer allocator.free(init_code_hex);
            const init_code = try common.decodeHexAlloc(allocator, init_code_hex);
            defer allocator.free(init_code);

            const receipt = try self.send(
                .{ .to = null, .input = init_code, .gas_limit = setup_gas_limit },
                null,
            );
            return receipt.created orelse error.MissingCreatedAddress;
        }

        fn tokenBalance(self: *Self, token: Address, holder: Address) !u256 {
            var word: [32]u8 = undefined;
            _ = try self.send(.{
                .to = token,
                .input = &abiCall(selector_balance_of, holder, null),
                .gas_limit = workload_gas_limit,
            }, &word);
            return std.mem.readInt(u256, &word, .big);
        }

        /// Brings state to the steady point the timed loop repeats and measures its gas.
        fn prepare(
            self: *Self,
            io: std.Io,
            allocator: std.mem.Allocator,
            options: Options,
        ) !Workload {
            const dir = options.fixtures_dir;
            var workload: Workload = switch (options.case) {
                .eth_transfer => .{ .to = recipient, .value = 1, .gas_limit = workload_gas_limit },
                .stop_call => .{
                    .to = try self.deploy(io, allocator, dir, "stop-target"),
                    .gas_limit = workload_gas_limit,
                },
                .erc20_transfer => workload: {
                    const token = try self.deploy(io, allocator, dir, "erc20-transfer");
                    // `Benchmark()` mints to the caller before its own transfer loop.
                    var selector: [4]u8 = undefined;
                    std.mem.writeInt(u32, &selector, selector_benchmark, .big);
                    _ = try self.send(
                        .{ .to = token, .input = &selector, .gas_limit = setup_gas_limit },
                        null,
                    );
                    // Two priming transfers follow, then the timed ones.
                    if (try self.tokenBalance(token, sender) < options.measuredTransactions() + 2) {
                        return error.InsufficientTokenBalance;
                    }
                    break :workload .{
                        .to = token,
                        .gas_limit = workload_gas_limit,
                        .input_buffer = abiCall(selector_transfer, recipient, 1),
                        .input_len = 68,
                    };
                },
            };
            const call: Call = .{
                .to = workload.to,
                .value = workload.value,
                .input = workload.input(),
                .gas_limit = workload.gas_limit,
            };
            // The first call creates the recipient account or balance slot and the coinbase
            // account, which forks with state gas price far above the workload limit. The
            // second already runs in the steady state, so its gas is the reference.
            var first = call;
            first.gas_limit = setup_gas_limit;
            _ = try self.send(first, null);
            workload.gas_per_tx = (try self.send(call, null)).gas_used;
            workload.expected_before = try self.recipientBalance(options.case, workload.to);
            return workload;
        }

        fn recipientBalance(self: *Self, case: Case, target: Address) !u256 {
            return switch (case) {
                .eth_transfer => try self.vm.executor.getBalance(recipient),
                .stop_call => 0,
                .erc20_transfer => try self.tokenBalance(target, recipient),
            };
        }

        /// Runs `txs` workload transactions and returns the elapsed time.
        fn runBatch(self: *Self, workload: *const Workload, txs: usize) !u64 {
            const call: Call = .{
                .to = workload.to,
                .value = workload.value,
                .input = workload.input(),
                .gas_limit = workload.gas_limit,
            };
            var gas_used: u64 = 0;
            const start_ns = try common.monotonicNowNs();
            for (0..txs) |_| gas_used += (try self.send(call, null)).gas_used;
            const end_ns = try common.monotonicNowNs();
            if (gas_used != workload.gas_per_tx * txs) return error.UnsteadyGas;
            return end_ns - start_ns;
        }
    };
}

pub fn main(init: std.process.Init) !void {
    const allocator = try common.benchmarkAllocator(init);

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--case")) {
            const value = args.next() orelse return error.MissingCase;
            options.case = parseCase(value) orelse return error.InvalidCase;
        } else if (common.stripPrefix(arg, "--case=")) |value| {
            options.case = parseCase(value) orelse return error.InvalidCase;
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--repeats")) {
            const value = args.next() orelse return error.MissingRepeats;
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--repeats=")) |value| {
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try common.parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmups=")) |value| {
            options.warmups = try common.parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--txs")) {
            const value = args.next() orelse return error.MissingTxs;
            options.txs = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--txs=")) |value| {
            options.txs = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--fixtures-dir")) {
            options.fixtures_dir = args.next() orelse return error.MissingFixturesDir;
        } else if (common.stripPrefix(arg, "--fixtures-dir=")) |value| {
            options.fixtures_dir = value;
        } else if (std.mem.eql(u8, arg, "--no-code-cache")) {
            options.code_cache = false;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.header = false;
        } else if (std.mem.eql(u8, arg, "--summary")) {
            options.summary = true;
        } else {
            return error.UnknownArgument;
        }
    }

    var stdout_buffer: [4096]u8 = undefined;
    // Streaming, so a shell `>>` appends: a positional writer starts every run at offset 0.
    var stdout_writer = std.Io.File.stdout().writerStreaming(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    switch (options.spec) {
        inline else => |revision| try run(
            evmz.Vm(evmz.eth.specAt(revision)),
            init.io,
            allocator,
            options,
            stdout,
        ),
    }
    try stdout.flush();
}

fn run(
    comptime Engine: type,
    io: std.Io,
    allocator: std.mem.Allocator,
    options: Options,
    stdout: *std.Io.Writer,
) !void {
    var memory = evmz.state.MemoryStore.init(allocator);
    defer memory.deinit();
    (try memory.getOrCreateAccount(sender)).account.balance = sender_balance;

    // Block execution keeps prepared code across transactions through a pool. A VM without a
    // backend prepares the callee's code again on every transaction.
    var pool = evmz.InMemoryPreparedPool.init(allocator);
    defer pool.deinit();
    var runner: Runner(Engine) = .{ .vm = .init(allocator, .{
        .state = .{ .reader = memory.reader() },
        .prepared_code_backend = if (options.code_cache) pool.backend() else null,
    }) };
    defer runner.vm.deinit();

    const workload = try runner.prepare(io, allocator, options);

    for (0..options.warmups) |_| _ = try runner.runBatch(&workload, options.txs);

    if (options.header) {
        try stdout.print(
            "suite,engine,case,spec,code_cache,repeat,txs,elapsed_ns,ns_per_tx,gas_per_tx\n",
            .{},
        );
    }
    for (0..options.repeats) |repeat| {
        const elapsed_ns = try runner.runBatch(&workload, options.txs);
        const txs: f64 = @floatFromInt(options.txs);
        const ns_per_tx = @as(f64, @floatFromInt(elapsed_ns)) / txs;
        try stdout.print("tx-loop,evmz,{s},{s},{s},{d},{d},{d},{d:.3},{d}\n", .{
            caseName(options.case),
            @tagName(options.spec),
            if (options.code_cache) "true" else "false",
            repeat,
            options.txs,
            elapsed_ns,
            ns_per_tx,
            workload.gas_per_tx,
        });
    }

    // Each timed transaction moves one unit to the recipient, so a lost state transition shows.
    if (options.case != .stop_call) {
        const balance = try runner.recipientBalance(options.case, workload.to);
        if (balance != workload.expected_before + options.measuredTransactions()) {
            return error.RecipientBalanceMismatch;
        }
    }

    if (options.summary) {
        std.debug.print(
            "engine=evmz case={s} spec={s} code_cache={s} warmups={d} repeats={d} txs={d} " ++
                "gas_per_tx={d}\n",
            .{
                caseName(options.case),
                @tagName(options.spec),
                if (options.code_cache) "true" else "false",
                options.warmups,
                options.repeats,
                options.txs,
                workload.gas_per_tx,
            },
        );
    }
}

/// Encodes `selector(address)` or `selector(address,uint256)`. The first form reads 36 bytes.
fn abiCall(selector: u32, account: Address, amount: ?u64) [68]u8 {
    var data: [68]u8 = @splat(0);
    std.mem.writeInt(u32, data[0..4], selector, .big);
    data[16..36].* = account.bytes;
    if (amount) |value| std.mem.writeInt(u64, data[60..68], value, .big);
    return data;
}

fn parseCase(value: []const u8) ?Case {
    const info = @typeInfo(Case).@"enum";
    inline for (info.field_names, info.field_values) |field_name, field_value| {
        if (tagNameMatches(value, field_name)) return @fromBackingInt(@intCast(field_value));
    }
    return null;
}

fn caseName(case: Case) []const u8 {
    return switch (case) {
        .eth_transfer => "eth-transfer",
        .stop_call => "stop-call",
        .erc20_transfer => "erc20-transfer",
    };
}

fn tagNameMatches(value: []const u8, tag_name: []const u8) bool {
    if (value.len != tag_name.len) return false;
    for (value, tag_name) |lhs, rhs| {
        if (lhs == rhs) continue;
        if (lhs == '-' and rhs == '_') continue;
        return false;
    }
    return true;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build tx-loop -- [options]
        \\
        \\Options:
        \\  --case <name>         eth-transfer, stop-call, erc20-transfer; default eth-transfer
        \\  --spec <name>         fork spec, default osaka
        \\  --repeats <n>         measured batches, default 5
        \\  --warmups <n>         untimed batches, default 1
        \\  --txs <n>             transactions per batch, default 1000
        \\  --fixtures-dir <path> VM-loop fixture root, default fixtures/vm-loop
        \\  --no-code-cache       run without a prepared-code pool
        \\  --no-header           omit the CSV header
        \\  --summary             print resolved options to stderr
        \\  EVMZ_BENCH_ALLOCATOR=smp  opt into std.heap.smp_allocator for allocator probes
        \\
        \\One VM lives for the whole run. Deployment and priming transactions run before
        \\timing; each timed call is one legacy transaction that is executed and retained.
        \\
    , .{});
}

test "tx loop parser accepts dashed names" {
    try std.testing.expectEqual(Case.erc20_transfer, parseCase("erc20-transfer").?);
    try std.testing.expectEqual(@as(?Case, null), parseCase("erc20"));
}

test "tx loop encodes transfer calldata" {
    const data = abiCall(selector_transfer, recipient, 1);
    try std.testing.expectEqualSlices(u8, &.{ 0xa9, 0x05, 0x9c, 0xbb }, data[0..4]);
    try std.testing.expectEqual(@as(u8, 0x30), data[16]);
    try std.testing.expectEqual(@as(u8, 0x03), data[35]);
    try std.testing.expectEqual(@as(u8, 1), data[67]);
}
