//! Opt-in differential runner for curated call fixtures.
//!
//! It executes the same message through evmz and a locally supplied Geth
//! `evm t8n` binary. Successful traces are deleted; mismatches retain inputs,
//! engine versions, raw trace, and normalized observations under the work root.

const std = @import("std");
const evmz = @import("../evm.zig");
const cases = @import("../test/call_fixture_cases.zig");

const Default = evmz.Evm.Executor;
const MemoryAccount = evmz.state.MemoryAccount;

const Options = struct {
    evm_bin: ?[]const u8 = null,
    case_filter: ?[]const u8 = null,
    work_root: []const u8 = ".zig-cache/call-fixture-oracle",
    keep_success: bool = false,
};

const TraceEvent = struct {
    from: ?[]const u8 = null,
    to: ?[]const u8 = null,
    input: ?[]const u8 = null,
    gas: ?[]const u8 = null,
    gasUsed: ?[]const u8 = null,
    output: ?[]const u8 = null,
    value: ?[]const u8 = null,
    type: ?[]const u8 = null,
    @"error": ?[]const u8 = null,
};

const GethRow = struct {
    parent_index: ?u32,
    child_ordinal: u32,
    depth: u16,
    kind: evmz.trace.CallKind,
    from: evmz.Address,
    to: evmz.Address,
    value: u256,
    gas: i64,
    gas_used: i64 = 0,
    input: []const u8,
    output: []const u8 = &.{},
    error_text: ?[]const u8 = null,
    child_count: u32 = 0,
};

const CaptureHarness = struct {
    arena: evmz.trace.CallArena,
    context: evmz.executor.CaptureContext,

    fn init(self: *CaptureHarness, allocator: std.mem.Allocator, executor: *Default) void {
        self.* = .{
            .arena = evmz.trace.CallArena.init(allocator),
            .context = undefined,
        };
        self.context = evmz.executor.CaptureContext.initWithCalls(
            allocator,
            null,
            .{ .arena = &self.arena },
            null,
        );
        executor.setCaptureContext(&self.context);
    }

    fn finish(self: *CaptureHarness, executor: *Default) !evmz.trace.CallSpan {
        _ = try self.context.finish();
        executor.setCaptureContext(null);
        return self.arena.latest().?;
    }

    fn deinit(self: *CaptureHarness, executor: *Default) void {
        if (executor.capture_context != null) executor.setCaptureContext(null);
        self.context.deinit();
        self.arena.deinit();
        self.* = undefined;
    }
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();
    const options = try parseOptions(init, arena);
    const evm_bin = options.evm_bin orelse {
        printUsage();
        return error.MissingEvmBinary;
    };

    const version = try runVersion(allocator, init.io, evm_bin);
    defer allocator.free(version);
    const local_version = try runLocalVersion(allocator, init.io);
    defer allocator.free(local_version);
    std.debug.print("external engine:\n{s}\n", .{version});

    var selected: usize = 0;
    var passed: usize = 0;
    for (cases.all) |case| {
        if (!case.external) continue;
        if (options.case_filter) |filter| {
            if (!std.mem.eql(u8, filter, case.id)) continue;
        }
        selected += 1;
        try runCase(allocator, init.io, evm_bin, version, local_version, options, case);
        passed += 1;
        std.debug.print("PASS {s}\n", .{case.id});
    }
    if (selected == 0) return error.UnknownOrNonExternalCase;
    std.debug.print("call fixture oracle: {d}/{d} passed\n", .{ passed, selected });
}

fn parseOptions(init: std.process.Init, allocator: std.mem.Allocator) !Options {
    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "--evm-bin")) {
            options.evm_bin = (args.next() orelse return error.MissingEvmBinary)[0..];
        } else if (std.mem.eql(u8, arg, "--case")) {
            options.case_filter = (args.next() orelse return error.MissingCaseFilter)[0..];
        } else if (std.mem.eql(u8, arg, "--work-root")) {
            options.work_root = (args.next() orelse return error.MissingWorkRoot)[0..];
        } else if (std.mem.eql(u8, arg, "--keep-success")) {
            options.keep_success = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            return error.UnknownArgument;
        }
    }
    return options;
}

fn runVersion(allocator: std.mem.Allocator, io: std.Io, evm_bin: []const u8) ![]u8 {
    const result = try std.process.run(allocator, io, .{
        .argv = &.{ evm_bin, "--version" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) {
        std.debug.print("{s} version failed: {s}{s}\n", .{ evm_bin, result.stdout, result.stderr });
        return error.ExternalVersionFailed;
    }
    return allocator.dupe(u8, if (result.stdout.len != 0) result.stdout else result.stderr);
}

fn runLocalVersion(allocator: std.mem.Allocator, io: std.Io) ![]u8 {
    const result = std.process.run(allocator, io, .{
        .argv = &.{ "git", "describe", "--always", "--dirty", "--broken" },
        .stdout_limit = .limited(64 * 1024),
        .stderr_limit = .limited(64 * 1024),
    }) catch |err| return std.fmt.allocPrint(allocator, "evmz unknown ({s})\n", .{@errorName(err)});
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) return allocator.dupe(u8, "evmz unknown\n");
    return std.fmt.allocPrint(allocator, "evmz {s}zig {s}\n", .{ result.stdout, @import("builtin").zig_version_string });
}

fn runCase(
    allocator: std.mem.Allocator,
    io: std.Io,
    evm_bin: []const u8,
    version: []const u8,
    local_version: []const u8,
    options: Options,
    case: cases.Case,
) !void {
    const run_id = try std.fmt.allocPrint(allocator, "{s}-{d}", .{ case.id, monotonicNanos(io) });
    defer allocator.free(run_id);
    const work_dir = try std.fs.path.join(allocator, &.{ options.work_root, run_id });
    defer allocator.free(work_dir);
    const out_dir = try std.fs.path.join(allocator, &.{ work_dir, "geth" });
    defer allocator.free(out_dir);
    try std.Io.Dir.cwd().createDirPath(io, out_dir);

    var clean_success = false;
    defer if (clean_success and !options.keep_success) {
        std.Io.Dir.cwd().deleteTree(io, work_dir) catch |err|
            std.debug.print("warning: failed to delete successful oracle run {s}: {s}\n", .{ work_dir, @errorName(err) });
    };
    errdefer std.debug.print("preserved failing oracle run: {s}\n", .{work_dir});

    try writeInputs(allocator, io, work_dir, case);
    const version_path = try std.fs.path.join(allocator, &.{ work_dir, "geth-version.txt" });
    defer allocator.free(version_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = version_path, .data = version });
    const local_version_path = try std.fs.path.join(allocator, &.{ work_dir, "evmz-version.txt" });
    defer allocator.free(local_version_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = local_version_path, .data = local_version });

    const alloc_path = try std.fs.path.join(allocator, &.{ work_dir, "alloc.json" });
    defer allocator.free(alloc_path);
    const env_path = try std.fs.path.join(allocator, &.{ work_dir, "env.json" });
    defer allocator.free(env_path);
    const txs_path = try std.fs.path.join(allocator, &.{ work_dir, "txs.json" });
    defer allocator.free(txs_path);
    const alloc_arg = try std.fmt.allocPrint(allocator, "--input.alloc={s}", .{alloc_path});
    defer allocator.free(alloc_arg);
    const env_arg = try std.fmt.allocPrint(allocator, "--input.env={s}", .{env_path});
    defer allocator.free(env_arg);
    const txs_arg = try std.fmt.allocPrint(allocator, "--input.txs={s}", .{txs_path});
    defer allocator.free(txs_arg);
    const fork_arg = try std.fmt.allocPrint(allocator, "--state.fork={s}", .{forkName(case.fork)});
    defer allocator.free(fork_arg);
    const out_arg = try std.fmt.allocPrint(allocator, "--output.basedir={s}", .{out_dir});
    defer allocator.free(out_arg);

    const result = try std.process.run(allocator, io, .{
        .argv = &.{
            evm_bin,   "t8n",                alloc_arg,         env_arg,          txs_arg, fork_arg,
            "--trace", "--trace.callframes", "--trace.nostack", "--trace.memory", out_arg,
        },
        .stdout_limit = .limited(4 * 1024 * 1024),
        .stderr_limit = .limited(4 * 1024 * 1024),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    try writeProcessOutput(allocator, io, work_dir, result.stdout, result.stderr);
    if (!termOk(result.term)) {
        std.debug.print("Geth t8n failed for {s}: {s}{s}\n", .{ case.id, result.stdout, result.stderr });
        return error.ExternalExecutionFailed;
    }

    const trace_path = try findTracePath(allocator, io, out_dir);
    defer allocator.free(trace_path);
    const trace = try std.Io.Dir.cwd().readFileAlloc(io, trace_path, allocator, .limited(64 * 1024 * 1024));
    defer allocator.free(trace);

    var parsed_arena = std.heap.ArenaAllocator.init(allocator);
    defer parsed_arena.deinit();
    const geth_rows = try parseTrace(parsed_arena.allocator(), trace);

    const revision = std.meta.stringToEnum(evmz.eth.Revision, case.fork) orelse
        return error.UnknownRevision;
    var executor = Default.init(allocator, .{ .revision = revision });
    defer executor.deinit();
    try seedAccount(&executor, allocator, try evmz.address.fromHex(cases.sender), try parseHexInt(u256, case.sender_balance), 0, &.{});
    for (case.accounts) |account| {
        const code = try decodeHexAlloc(allocator, account.code);
        defer allocator.free(code);
        try seedAccount(
            &executor,
            allocator,
            try evmz.address.fromHex(account.address),
            try parseHexInt(u256, account.balance),
            account.nonce,
            code,
        );
    }

    var capture: CaptureHarness = undefined;
    capture.init(allocator, &executor);
    defer capture.deinit(&executor);
    try capture.context.begin();
    errdefer capture.context.abort() catch {};
    const sender = try evmz.address.fromHex(cases.sender);
    _ = try executor.runStandalone(
        evmz.t.defaultTxContext(sender, case.gas),
        .{ .call = .{
            .sender = sender,
            .recipient = try evmz.address.fromHex(case.recipient),
            .value = try parseHexInt(u256, case.value),
        } },
        .legacy(case.gas),
    );
    const evmz_span = try capture.finish(&executor);

    if (!compareRows(case, evmz_span, geth_rows)) {
        try writeObservations(allocator, io, work_dir, evmz_span, geth_rows);
        return error.CallObservationMismatch;
    }
    clean_success = true;
    if (options.keep_success) {
        try writeObservations(allocator, io, work_dir, evmz_span, geth_rows);
        std.debug.print("kept successful oracle run: {s}\n", .{work_dir});
    }
}

fn writeInputs(allocator: std.mem.Allocator, io: std.Io, work_dir: []const u8, case: cases.Case) !void {
    var alloc_json: std.Io.Writer.Allocating = .init(allocator);
    defer alloc_json.deinit();
    try alloc_json.writer.writeAll("{");
    try writeAllocAccount(&alloc_json.writer, cases.sender, case.sender_balance, 0, "0x");
    for (case.accounts) |account| {
        try alloc_json.writer.writeByte(',');
        try writeAllocAccount(&alloc_json.writer, account.address, account.balance, account.nonce, account.code);
    }
    try alloc_json.writer.writeAll("}\n");

    const tx_gas = case.gas + 21_000;
    const protected = if (std.mem.eql(u8, case.fork, "frontier")) "false" else "true";
    const txs_json = try std.fmt.allocPrint(
        allocator,
        "[{{\"gas\":\"0x{x}\",\"gasPrice\":\"0x600\",\"input\":\"0x\",\"nonce\":\"0x0\",\"to\":\"{s}\",\"value\":\"{s}\",\"v\":\"0x0\",\"r\":\"0x0\",\"s\":\"0x0\",\"secretKey\":\"{s}\",\"protected\":{s}}}]\n",
        .{ tx_gas, case.recipient, case.value, cases.sender_secret_key, protected },
    );
    defer allocator.free(txs_json);

    const frontier_env =
        "{\"currentCoinbase\":\"0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba\",\"currentDifficulty\":\"0x20000\",\"currentNumber\":\"0x1\",\"currentTimestamp\":\"0x3e8\",\"currentGasLimit\":\"0x1000000000\"}\n";
    const cancun_env =
        "{\"currentCoinbase\":\"0x2adc25665018aa1fe0e6bc666dac8fc2697ff9ba\",\"currentNumber\":\"0x1\",\"currentTimestamp\":\"0x3e8\",\"currentGasLimit\":\"0x1000000000\",\"currentRandom\":\"0x0\",\"currentBaseFee\":\"0x7\",\"parentBeaconBlockRoot\":\"0x1dcc4de8dec75d7aab85b567b6ccd41ad312451b948a7413f0a142fd40d49347\",\"withdrawals\":[]}\n";

    try writeNamed(allocator, io, work_dir, "alloc.json", alloc_json.written());
    try writeNamed(allocator, io, work_dir, "txs.json", txs_json);
    try writeNamed(allocator, io, work_dir, "env.json", if (std.mem.eql(u8, case.fork, "frontier")) frontier_env else cancun_env);
}

fn writeAllocAccount(writer: *std.Io.Writer, address: []const u8, balance: []const u8, nonce: u64, code: []const u8) !void {
    try std.json.Stringify.encodeJsonString(address, .{}, writer);
    try writer.print(":{{\"balance\":\"{s}\",\"code\":\"{s}\",\"nonce\":\"0x{x}\",\"storage\":{{}}}}", .{
        balance, code, nonce,
    });
}

fn writeProcessOutput(allocator: std.mem.Allocator, io: std.Io, work_dir: []const u8, stdout: []const u8, stderr: []const u8) !void {
    try writeNamed(allocator, io, work_dir, "geth-stdout.txt", stdout);
    try writeNamed(allocator, io, work_dir, "geth-stderr.txt", stderr);
}

fn writeNamed(allocator: std.mem.Allocator, io: std.Io, dir: []const u8, name: []const u8, data: []const u8) !void {
    const path = try std.fs.path.join(allocator, &.{ dir, name });
    defer allocator.free(path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn findTracePath(allocator: std.mem.Allocator, io: std.Io, out_dir: []const u8) ![]u8 {
    var dir = try std.Io.Dir.cwd().openDir(io, out_dir, .{ .iterate = true });
    defer dir.close(io);
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.startsWith(u8, entry.name, "trace-") and std.mem.endsWith(u8, entry.name, ".jsonl")) {
            return std.fs.path.join(allocator, &.{ out_dir, entry.name });
        }
    }
    return error.MissingGethTrace;
}

fn parseTrace(allocator: std.mem.Allocator, trace: []const u8) ![]GethRow {
    var rows: std.ArrayList(GethRow) = .empty;
    var active: std.ArrayList(u32) = .empty;
    var root_count: u32 = 0;

    var lines = std.mem.splitScalar(u8, trace, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const parsed = try std.json.parseFromSlice(TraceEvent, allocator, line, .{ .ignore_unknown_fields = true });
        const event = parsed.value;
        if (event.type) |kind_text| {
            const parent_index: ?u32 = if (active.items.len == 0) null else active.items[active.items.len - 1];
            const ordinal = if (parent_index) |parent| ordinal: {
                const value = rows.items[parent].child_count;
                rows.items[parent].child_count += 1;
                break :ordinal value;
            } else ordinal: {
                const value = root_count;
                root_count += 1;
                break :ordinal value;
            };
            const row_index: u32 = @intCast(rows.items.len);
            try rows.append(allocator, .{
                .parent_index = parent_index,
                .child_ordinal = ordinal,
                .depth = @intCast(active.items.len),
                .kind = try callKind(kind_text),
                .from = try evmz.address.fromHex(event.from orelse return error.MissingGethFrom),
                .to = try evmz.address.fromHex(event.to orelse return error.MissingGethTo),
                .value = try parseHexInt(u256, event.value orelse "0x0"),
                .gas = try parseHexInt(i64, event.gas orelse return error.MissingGethGas),
                .input = try decodeHexAlloc(allocator, event.input orelse "0x"),
            });
            try active.append(allocator, row_index);
        } else if (event.gasUsed) |gas_used| {
            const row_index = active.pop() orelse return error.UnbalancedGethExit;
            rows.items[row_index].gas_used = try parseHexInt(i64, gas_used);
            rows.items[row_index].output = try decodeHexAlloc(allocator, event.output orelse "0x");
            rows.items[row_index].error_text = event.@"error";
        }
    }
    if (active.items.len != 0) return error.UnclosedGethFrame;
    return rows.toOwnedSlice(allocator);
}

fn compareRows(case: cases.Case, evmz_span: evmz.trace.CallSpan, geth_rows: []const GethRow) bool {
    if (evmz_span.rows.len != geth_rows.len) {
        std.debug.print("{s}: row count evmz={d} geth={d}\n", .{ case.id, evmz_span.rows.len, geth_rows.len });
        return false;
    }
    var equal = true;
    for (evmz_span.rows, geth_rows, 0..) |local, geth, index| {
        if (local.parent_index != geth.parent_index or
            local.child_ordinal != geth.child_ordinal or
            local.depth != geth.depth or
            local.kind != geth.kind or
            !std.mem.eql(u8, &local.from, &geth.from) or
            !std.mem.eql(u8, &local.to, &geth.to) or
            local.value != geth.value or
            local.gas != geth.gas or
            local.gas_used != geth.gas_used or
            !std.mem.eql(u8, evmz_span.input(local), geth.input) or
            !std.mem.eql(u8, evmz_span.output(local), normalizedGethOutput(geth, local.status)) or
            !statusMatches(local.status, geth.error_text))
        {
            equal = false;
            std.debug.print("{s}: row {d} differs (evmz status={s}, geth error={s})\n", .{
                case.id,
                index,
                @tagName(local.status),
                geth.error_text orelse "none",
            });
        }
    }
    return equal;
}

fn statusMatches(status: evmz.trace.CallStatus, error_text: ?[]const u8) bool {
    return switch (status) {
        .success => error_text == null,
        // The raw JSONL hook retains this Frontier error even though native
        // callTracer clears it when the state snapshot was not reverted.
        .code_store_out_of_gas_committed => error_text == null or eqlError(error_text, "contract creation code storage out of gas"),
        .revert => eqlError(error_text, "execution reverted"),
        .out_of_gas => eqlError(error_text, "out of gas"),
        .insufficient_balance => eqlError(error_text, "insufficient balance for transfer"),
        .nonce_overflow => eqlError(error_text, "nonce uint64 overflow"),
        .invalid_opcode => if (error_text) |text| std.mem.startsWith(u8, text, "invalid opcode:") else false,
        .contract_address_collision => eqlError(error_text, "contract address collision"),
        .max_code_size_exceeded, .code_store_out_of_gas => eqlError(error_text, "contract creation code storage out of gas"),
        .invalid_code => if (error_text) |text| std.mem.startsWith(u8, text, "invalid code:") else false,
        else => false,
    };
}

fn normalizedGethOutput(row: GethRow, status: evmz.trace.CallStatus) []const u8 {
    if (row.error_text == null or status == .revert or status == .code_store_out_of_gas_committed) {
        return row.output;
    }
    // Native callTracer only retains failing output for REVERT. The structured
    // JSONL hook is lower-level and exposes the raw output for every failure.
    return &.{};
}

fn eqlError(actual: ?[]const u8, expected: []const u8) bool {
    return if (actual) |text| std.mem.eql(u8, text, expected) else false;
}

fn writeObservations(
    allocator: std.mem.Allocator,
    io: std.Io,
    work_dir: []const u8,
    evmz_span: evmz.trace.CallSpan,
    geth_rows: []const GethRow,
) !void {
    var local: std.Io.Writer.Allocating = .init(allocator);
    defer local.deinit();
    try local.writer.writeAll("[\n");
    for (evmz_span.rows, 0..) |row, index| {
        if (index != 0) try local.writer.writeAll(",\n");
        try local.writer.writeAll("  {\"parent\":");
        try std.json.Stringify.value(row.parent_index, .{}, &local.writer);
        try local.writer.print(
            ",\"ordinal\":{d},\"depth\":{d},\"kind\":\"{s}\",\"from\":\"0x{x}\",\"to\":\"0x{x}\",\"value\":\"0x{x}\",\"gas\":\"0x{x}\",\"gasUsed\":\"0x{x}\",\"input\":\"0x{x}\",\"output\":\"0x{x}\",\"status\":\"{s}\",\"checkpointReverted\":{s}}}",
            .{
                row.child_ordinal,    row.depth,                                         @tagName(row.kind),               row.from,             row.to,
                row.value,            @as(u64, @intCast(row.gas)),                       @as(u64, @intCast(row.gas_used)), evmz_span.input(row), evmz_span.output(row),
                @tagName(row.status), if (row.checkpointReverted()) "true" else "false",
            },
        );
    }
    try local.writer.writeAll("\n]\n");

    var geth: std.Io.Writer.Allocating = .init(allocator);
    defer geth.deinit();
    try geth.writer.writeAll("[\n");
    for (geth_rows, 0..) |row, index| {
        if (index != 0) try geth.writer.writeAll(",\n");
        try geth.writer.writeAll("  {\"parent\":");
        try std.json.Stringify.value(row.parent_index, .{}, &geth.writer);
        try geth.writer.print(
            ",\"ordinal\":{d},\"depth\":{d},\"kind\":\"{s}\",\"from\":\"0x{x}\",\"to\":\"0x{x}\",\"value\":\"0x{x}\",\"gas\":\"0x{x}\",\"gasUsed\":\"0x{x}\",\"input\":\"0x{x}\",\"output\":\"0x{x}\",\"error\":",
            .{
                row.child_ordinal, row.depth,                   @tagName(row.kind),               row.from,  row.to,
                row.value,         @as(u64, @intCast(row.gas)), @as(u64, @intCast(row.gas_used)), row.input, row.output,
            },
        );
        if (row.error_text) |text| try std.json.Stringify.encodeJsonString(text, .{}, &geth.writer) else try geth.writer.writeAll("null");
        try geth.writer.writeByte('}');
    }
    try geth.writer.writeAll("\n]\n");

    try writeNamed(allocator, io, work_dir, "evmz-observation.json", local.written());
    try writeNamed(allocator, io, work_dir, "geth-observation.json", geth.written());
}

fn seedAccount(executor: *Default, allocator: std.mem.Allocator, address: evmz.Address, balance: u256, nonce: u64, code: []const u8) !void {
    var account = MemoryAccount.init(allocator);
    account.balance = balance;
    account.nonce = nonce;
    try account.setCode(code);
    try executor.state.seedAccount(address, account);
}

fn callKind(value: []const u8) !evmz.trace.CallKind {
    if (std.mem.eql(u8, value, "CALL")) return .call;
    if (std.mem.eql(u8, value, "STATICCALL")) return .staticcall;
    if (std.mem.eql(u8, value, "DELEGATECALL")) return .delegatecall;
    if (std.mem.eql(u8, value, "CALLCODE")) return .callcode;
    if (std.mem.eql(u8, value, "CREATE")) return .create;
    if (std.mem.eql(u8, value, "CREATE2")) return .create2;
    if (std.mem.eql(u8, value, "SELFDESTRUCT")) return .selfdestruct;
    return error.UnknownGethCallKind;
}

fn forkName(fork: []const u8) []const u8 {
    if (std.mem.eql(u8, fork, "frontier")) return "Frontier";
    if (std.mem.eql(u8, fork, "cancun")) return "Cancun";
    return fork;
}

fn parseHexInt(comptime T: type, value: []const u8) !T {
    const body = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
    if (body.len == 0) return 0;
    return std.fmt.parseInt(T, body, 16);
}

fn decodeHexAlloc(allocator: std.mem.Allocator, value: []const u8) ![]u8 {
    const body = if (std.mem.startsWith(u8, value, "0x")) value[2..] else value;
    if (body.len % 2 != 0) return error.InvalidHexLength;
    const bytes = try allocator.alloc(u8, body.len / 2);
    errdefer allocator.free(bytes);
    _ = try std.fmt.hexToBytes(bytes, body);
    return bytes;
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn monotonicNanos(io: std.Io) u64 {
    const timestamp = std.Io.Clock.awake.now(io).nanoseconds;
    return if (timestamp <= 0) 0 else @intCast(timestamp);
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build call-fixture-oracle -- --evm-bin PATH [--case ID] [--work-root PATH] [--keep-success]
        \\
        \\Runs curated call programs through evmz and a local Geth `evm t8n`.
        \\Success artifacts are deleted by default. Failures retain the complete
        \\case, raw trace, engine version, and normalized observations.
        \\
    , .{});
}
