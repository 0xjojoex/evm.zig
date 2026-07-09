const std = @import("std");

const max_command_output = 128 * 1024 * 1024;

const default_fixtures = [_][]const u8{
    "fixtures/vm-loop/arithmetic-loop",
    "fixtures/vm-loop/memory-mstore-loop",
    "fixtures/vm-loop/keccak-loop",
    "fixtures/vm-loop/ten-thousand-hashes",
    "fixtures/vm-loop/storage-sload-loop",
    "fixtures/vm-loop/storage-sstore-loop",
    "fixtures/vm-loop/log0-loop",
    "fixtures/vm-loop/erc20-mint",
    "fixtures/vm-loop/erc20-transfer",
    "fixtures/vm-loop/erc20-approval-transfer",
    "fixtures/vm-loop/snailtracer",
};

const engine_order = [_]Engine{
    .evmz,
    .evmone_baseline,
    .evmone_advanced,
    .revm_interpreter,
};

const Engine = enum {
    evmz,
    evmone_baseline,
    evmone_advanced,
    revm_interpreter,
};

const Options = struct {
    zig_exe: []const u8 = "zig",
    optimize: []const u8 = "ReleaseFast",
    profile: []const u8 = "native",
    support_min: ?[]const u8 = null,
    support_max: ?[]const u8 = null,
    engines: std.ArrayList(Engine) = .empty,
    fixtures: std.ArrayList([]const u8) = .empty,
    num_runs: ?usize = null,
    spec: ?[]const u8 = "osaka",
    out_dir: ?[]const u8 = null,
    json: bool = false,
};

const Row = struct {
    fixture: []const u8,
    fixture_path: []const u8,
    engine: []const u8,
    runner: []const u8,
    scope: []const u8,
    runs: usize,
    median_ms: f64,
    mean_ms: f64,
    min_ms: f64,
    max_ms: f64,
    host_profile: []const u8,
    spec: []const u8,
    runtime_bytes: ?u64,
    deploy_host_calls: ?u64,
    timed_host_calls: ?u64,
    timed_host_calls_per_run: ?f64,
    logs: ?u64,
    samples_ms: []const f64,
};

const RawCommand = struct {
    stdout: []const u8,
    stderr: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var stdout_buffer: [16 * 1024]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    const options = try parseOptions(init, arena);
    const fixtures = if (options.fixtures.items.len == 0) default_fixtures[0..] else options.fixtures.items;
    const engines: []const Engine = if (options.engines.items.len == 0) engine_order[0..] else options.engines.items;
    const timestamp = std.Io.Clock.real.now(init.io).nanoseconds;
    const out_dir = options.out_dir orelse try std.fmt.allocPrint(arena, "zig-out/compare/{d}", .{timestamp});

    try std.Io.Dir.cwd().createDirPath(init.io, out_dir);

    var rows: std.ArrayList(Row) = .empty;
    for (fixtures) |fixture| {
        const fixture_name = baseName(fixture);
        for (engines) |engine| {
            const argv = try engineCommand(arena, options, fixture, engine);
            const label = try std.fmt.allocPrint(arena, "{s}-{s}", .{ fixture_name, engineName(engine) });
            const raw = try runCommand(init.io, arena, label, argv, out_dir);
            const row = try parseMeasurement(arena, fixture, engine, raw);
            try rows.append(arena, row);
        }
    }

    try writeArtifacts(init.io, allocator, rows.items, out_dir);

    const output = if (options.json)
        try std.json.Stringify.valueAlloc(allocator, .{ .out_dir = out_dir, .rows = rows.items }, .{ .whitespace = .indent_2 })
    else
        try renderMarkdown(allocator, rows.items, out_dir);
    defer allocator.free(output);

    try stdout.writeAll(output);
    try stdout.writeByte('\n');
    try stdout.flush();
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
        } else if (std.mem.eql(u8, arg, "--zig-exe")) {
            const value = args.next() orelse return error.MissingZigExe;
            options.zig_exe = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--zig-exe=")) |value| {
            options.zig_exe = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--optimize")) {
            const value = args.next() orelse return error.MissingOptimize;
            options.optimize = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--optimize=")) |value| {
            options.optimize = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--profile")) {
            const value = args.next() orelse return error.MissingProfile;
            options.profile = try parseProfile(allocator, value);
        } else if (stripPrefix(arg, "--profile=")) |value| {
            options.profile = try parseProfile(allocator, value);
        } else if (std.mem.eql(u8, arg, "--support-min")) {
            const value = args.next() orelse return error.MissingSupportMin;
            options.support_min = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--support-min=")) |value| {
            options.support_min = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--support-max")) {
            const value = args.next() orelse return error.MissingSupportMax;
            options.support_max = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--support-max=")) |value| {
            options.support_max = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            try appendEngineFilter(allocator, &options.engines, value);
        } else if (stripPrefix(arg, "--engine=")) |value| {
            try appendEngineFilter(allocator, &options.engines, value);
        } else if (std.mem.eql(u8, arg, "--fixture")) {
            const value = args.next() orelse return error.MissingFixture;
            try options.fixtures.append(allocator, try allocator.dupe(u8, value));
        } else if (stripPrefix(arg, "--fixture=")) |value| {
            try options.fixtures.append(allocator, try allocator.dupe(u8, value));
        } else if (std.mem.eql(u8, arg, "--num-runs") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingNumRuns;
            options.num_runs = try parseNonZeroUsize(value);
        } else if (stripPrefix(arg, "--num-runs=")) |value| {
            options.num_runs = try parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--spec=")) |value| {
            options.spec = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--out-dir")) {
            const value = args.next() orelse return error.MissingOutDir;
            options.out_dir = try allocator.dupe(u8, value);
        } else if (stripPrefix(arg, "--out-dir=")) |value| {
            options.out_dir = try allocator.dupe(u8, value);
        } else if (std.mem.eql(u8, arg, "--json")) {
            options.json = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    return options;
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build compare -- --num-runs 100
        \\  zig build compare -- --fixture fixtures/vm-loop/erc20-transfer --json
        \\
        \\Options:
        \\  --zig-exe <path>       Zig executable used for child bench steps
        \\  --optimize <mode>      Zig/C++ runner optimization mode, default ReleaseFast
        \\  --profile <profile>    evmz build profile forwarded to child Zig builds
        \\  --support-min <name>   minimum evmz fork compiled into the VM-loop runner
        \\  --support-max <name>   maximum evmz fork compiled into the VM-loop runner
        \\  --engine <name>        engine filter, repeatable; all, evmz, evmone, revm, evmone-baseline, evmone-advanced, revm-interpreter
        \\  --fixture <dir>        VM-loop fixture directory, repeatable
        \\  --num-runs, -n <n>     override fixture num-runs.txt for every engine
        \\  --spec <name>          fork spec forwarded to each engine, default osaka
        \\  --out-dir <dir>        raw output directory, default zig-out/compare/<timestamp>
        \\  --json                 print JSON summary instead of markdown table
        \\
    , .{});
}

fn appendEngineFilter(allocator: std.mem.Allocator, engines: *std.ArrayList(Engine), value: []const u8) !void {
    var parts = std.mem.splitScalar(u8, value, ',');
    var appended = false;
    while (parts.next()) |raw_part| {
        const part = std.mem.trim(u8, raw_part, " \t\r\n");
        if (part.len == 0) continue;

        if (std.mem.eql(u8, part, "all")) {
            for (engine_order) |engine| try appendEngineUnique(allocator, engines, engine);
            appended = true;
        } else if (std.mem.eql(u8, part, "evmone")) {
            try appendEngineUnique(allocator, engines, .evmone_baseline);
            try appendEngineUnique(allocator, engines, .evmone_advanced);
            appended = true;
        } else if (std.mem.eql(u8, part, "revm")) {
            try appendEngineUnique(allocator, engines, .revm_interpreter);
            appended = true;
        } else if (parseEngine(part)) |engine| {
            try appendEngineUnique(allocator, engines, engine);
            appended = true;
        } else {
            std.debug.print("unknown engine: {s}\n", .{part});
            printUsage();
            return error.UnknownEngine;
        }
    }
    if (!appended) return error.EmptyEngineFilter;
}

fn appendEngineUnique(allocator: std.mem.Allocator, engines: *std.ArrayList(Engine), engine: Engine) !void {
    for (engines.items) |existing| {
        if (existing == engine) return;
    }
    try engines.append(allocator, engine);
}

fn parseEngine(value: []const u8) ?Engine {
    if (std.mem.eql(u8, value, "evmz")) return .evmz;
    if (std.mem.eql(u8, value, "evmone-baseline") or std.mem.eql(u8, value, "evmone-base")) return .evmone_baseline;
    if (std.mem.eql(u8, value, "evmone-advanced") or std.mem.eql(u8, value, "evmone-adv")) return .evmone_advanced;
    if (std.mem.eql(u8, value, "revm-interpreter")) return .revm_interpreter;
    return null;
}

fn engineCommand(
    allocator: std.mem.Allocator,
    options: Options,
    fixture: []const u8,
    engine: Engine,
) ![]const []const u8 {
    var argv: std.ArrayList([]const u8) = .empty;
    try argv.append(allocator, options.zig_exe);
    try argv.append(allocator, "build");

    switch (engine) {
        .evmz, .evmone_baseline, .evmone_advanced => {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Doptimize={s}", .{options.optimize}));
        },
        .revm_interpreter => {},
    }
    if (engine == .evmz) {
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dprofile={s}", .{options.profile}));
        if (options.support_min) |support_min| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbench-support-min={s}", .{support_min}));
        }
        if (options.support_max) |support_max| {
            try argv.append(allocator, try std.fmt.allocPrint(allocator, "-Dbench-support-max={s}", .{support_max}));
        }
    }

    try argv.append(allocator, switch (engine) {
        .evmz => "vm-loop",
        .evmone_baseline, .evmone_advanced => "evmone-vm-loop",
        .revm_interpreter => "revm-vm-loop",
    });
    try argv.append(allocator, "--");

    if (engine == .evmz) {
        try argv.append(allocator, "--engine");
        try argv.append(allocator, "evmz");
    }

    try appendFixtureArgs(allocator, &argv, fixture, options.num_runs, options.spec);

    if (engine == .evmone_baseline) {
        try argv.append(allocator, "--mode");
        try argv.append(allocator, "baseline");
    }

    return argv.toOwnedSlice(allocator);
}

fn appendFixtureArgs(
    allocator: std.mem.Allocator,
    argv: *std.ArrayList([]const u8),
    fixture: []const u8,
    num_runs: ?usize,
    spec: ?[]const u8,
) !void {
    try argv.append(allocator, "--fixture");
    try argv.append(allocator, fixture);
    try argv.append(allocator, "--summary");
    if (spec) |name| {
        try argv.append(allocator, "--spec");
        try argv.append(allocator, name);
    }
    if (num_runs) |runs| {
        try argv.append(allocator, "--num-runs");
        try argv.append(allocator, try std.fmt.allocPrint(allocator, "{d}", .{runs}));
    }
}

fn runCommand(
    io: std.Io,
    allocator: std.mem.Allocator,
    label: []const u8,
    argv: []const []const u8,
    out_dir: []const u8,
) !RawCommand {
    const command_line = try joinArgv(allocator, argv);
    try writeText(io, allocator, out_dir, label, "cmd.txt", command_line);

    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    });

    try writeText(io, allocator, out_dir, label, "stdout.txt", result.stdout);
    try writeText(io, allocator, out_dir, label, "stderr.txt", result.stderr);

    switch (result.term) {
        .exited => |code| if (code != 0) {
            printCommandFailure(label, argv, result.stdout, result.stderr);
            return error.CommandFailed;
        },
        else => {
            printCommandFailure(label, argv, result.stdout, result.stderr);
            std.debug.print("command terminated: {}\n", .{result.term});
            return error.CommandFailed;
        },
    }

    return .{
        .stdout = result.stdout,
        .stderr = result.stderr,
    };
}

fn writeText(
    io: std.Io,
    allocator: std.mem.Allocator,
    out_dir: []const u8,
    label: []const u8,
    suffix: []const u8,
    data: []const u8,
) !void {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.{s}", .{ out_dir, label, suffix });
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = data });
}

fn joinArgv(allocator: std.mem.Allocator, argv: []const []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();

    for (argv, 0..) |arg, index| {
        if (index != 0) try out.writer.writeByte(' ');
        try out.writer.writeAll(arg);
    }
    try out.writer.writeByte('\n');
    return out.toOwnedSlice();
}

fn printCommandFailure(label: []const u8, argv: []const []const u8, stdout: []const u8, stderr: []const u8) void {
    std.debug.print("command failed: {s}\nargv:", .{label});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\n", .{});
    if (stdout.len != 0) std.debug.print("stdout:\n{s}\n", .{stdout});
    if (stderr.len != 0) std.debug.print("stderr:\n{s}\n", .{stderr});
}

fn parseMeasurement(
    allocator: std.mem.Allocator,
    fixture: []const u8,
    engine: Engine,
    raw: RawCommand,
) !Row {
    const times_ms = try parseTimesMs(allocator, raw.stdout);
    if (times_ms.len == 0) return error.NoTimingRows;

    const summary = firstSummaryLine(raw.stderr);
    const median = try medianMs(allocator, times_ms);
    const mean = meanMs(times_ms);
    const min = minMs(times_ms);
    const max = maxMs(times_ms);
    const timed_host_calls = try optionalU64(keyValue(summary, "timed_host_calls"));

    return .{
        .fixture = baseName(fixture),
        .fixture_path = fixture,
        .engine = keyValue(summary, "engine") orelse engineName(engine),
        .runner = runnerName(engine),
        .scope = keyValue(summary, "scope") orelse defaultScope(engine),
        .runs = times_ms.len,
        .median_ms = median,
        .mean_ms = mean,
        .min_ms = min,
        .max_ms = max,
        .host_profile = keyValue(summary, "host_profile") orelse "",
        .spec = keyValue(summary, "spec") orelse "",
        .runtime_bytes = try optionalU64(keyValue(summary, "runtime_bytes")),
        .deploy_host_calls = try optionalU64(keyValue(summary, "deploy_host_calls")),
        .timed_host_calls = timed_host_calls,
        .timed_host_calls_per_run = hostCallsPerRun(timed_host_calls, times_ms.len),
        .logs = try optionalU64(keyValue(summary, "logs")),
        .samples_ms = times_ms,
    };
}

fn parseTimesMs(allocator: std.mem.Allocator, stdout: []const u8) ![]f64 {
    var times: std.ArrayList(f64) = .empty;
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        const trimmed = std.mem.trim(u8, line, " \t\r\n");
        if (trimmed.len == 0) continue;
        const value = std.fmt.parseFloat(f64, trimmed) catch continue;
        if (!std.math.isFinite(value)) continue;
        try times.append(allocator, value);
    }
    return times.toOwnedSlice(allocator);
}

fn firstSummaryLine(stderr: []const u8) []const u8 {
    var lines = std.mem.splitScalar(u8, stderr, '\n');
    while (lines.next()) |line| {
        if (std.mem.indexOf(u8, line, "fixture=") != null and
            std.mem.indexOf(u8, line, "engine=") != null)
        {
            return std.mem.trim(u8, line, " \t\r\n");
        }
    }
    return "";
}

fn keyValue(line: []const u8, key: []const u8) ?[]const u8 {
    var tokens = std.mem.tokenizeScalar(u8, line, ' ');
    while (tokens.next()) |token| {
        const split = std.mem.indexOfScalar(u8, token, '=') orelse continue;
        if (std.mem.eql(u8, token[0..split], key)) return token[split + 1 ..];
    }
    return null;
}

fn optionalU64(value: ?[]const u8) !?u64 {
    const text = value orelse return null;
    if (text.len == 0) return null;
    return try std.fmt.parseInt(u64, text, 10);
}

fn medianMs(allocator: std.mem.Allocator, values: []const f64) !f64 {
    const sorted = try allocator.dupe(f64, values);
    defer allocator.free(sorted);
    std.mem.sort(f64, sorted, {}, lessThanF64);
    const mid = sorted.len / 2;
    if (sorted.len % 2 == 1) return sorted[mid];
    return (sorted[mid - 1] + sorted[mid]) / 2.0;
}

fn lessThanF64(_: void, lhs: f64, rhs: f64) bool {
    return lhs < rhs;
}

fn meanMs(values: []const f64) f64 {
    var total: f64 = 0;
    for (values) |value| total += value;
    return total / @as(f64, @floatFromInt(values.len));
}

fn minMs(values: []const f64) f64 {
    var result = values[0];
    for (values[1..]) |value| result = @min(result, value);
    return result;
}

fn maxMs(values: []const f64) f64 {
    var result = values[0];
    for (values[1..]) |value| result = @max(result, value);
    return result;
}

fn writeArtifacts(io: std.Io, allocator: std.mem.Allocator, rows: []const Row, out_dir: []const u8) !void {
    const csv = try renderCsv(allocator, rows);
    defer allocator.free(csv);
    const csv_path = try std.fmt.allocPrint(allocator, "{s}/summary.csv", .{out_dir});
    defer allocator.free(csv_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = csv_path, .data = csv });

    const json = try std.json.Stringify.valueAlloc(allocator, rows, .{ .whitespace = .indent_2 });
    defer allocator.free(json);
    const json_path = try std.fmt.allocPrint(allocator, "{s}/summary.json", .{out_dir});
    defer allocator.free(json_path);
    try std.Io.Dir.cwd().writeFile(io, .{ .sub_path = json_path, .data = json });
}

fn renderCsv(allocator: std.mem.Allocator, rows: []const Row) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll("fixture,engine,runner,scope,runs,median_ms,mean_ms,min_ms,max_ms,host_profile,spec,runtime_bytes,deploy_host_calls,timed_host_calls,timed_host_calls_per_run,logs\n");
    for (rows) |row| {
        try writer.print(
            "{s},{s},{s},{s},{d},{d:.6},{d:.6},{d:.6},{d:.6},{s},{s},",
            .{
                row.fixture,
                row.engine,
                row.runner,
                row.scope,
                row.runs,
                row.median_ms,
                row.mean_ms,
                row.min_ms,
                row.max_ms,
                row.host_profile,
                row.spec,
            },
        );
        try writeOptionalU64(writer, row.runtime_bytes);
        try writer.writeByte(',');
        try writeOptionalU64(writer, row.deploy_host_calls);
        try writer.writeByte(',');
        try writeOptionalU64(writer, row.timed_host_calls);
        try writer.writeByte(',');
        try writeOptionalF64(writer, row.timed_host_calls_per_run);
        try writer.writeByte(',');
        try writeOptionalU64(writer, row.logs);
        try writer.writeByte('\n');
    }

    return out.toOwnedSlice();
}

fn writeOptionalU64(writer: *std.Io.Writer, value: ?u64) !void {
    if (value) |actual| try writer.print("{d}", .{actual});
}

fn writeOptionalF64(writer: *std.Io.Writer, value: ?f64) !void {
    if (value) |actual| try writer.print("{d:.3}", .{actual});
}

fn hostCallsPerRun(calls: ?u64, runs: usize) ?f64 {
    if (calls) |actual| {
        if (runs == 0) return null;
        return @as(f64, @floatFromInt(actual)) / @as(f64, @floatFromInt(runs));
    }
    return null;
}

fn renderMarkdown(allocator: std.mem.Allocator, rows: []const Row, out_dir: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(allocator);
    defer out.deinit();
    const writer = &out.writer;

    try writer.writeAll(
        \\# VM-core comparison
        \\
        \\Scope: deployed runtime call through each engine's interpreter-level path. Fixture loading, init-code deployment, bytecode/cache preparation, frame/interpreter setup, and per-run transaction setup live outside the timed window where the runner has that shape. Rows use evmz direct `Interpreter.execute`, standalone evmone baseline/advanced analyzed-code execution, and revm analyzed `Bytecode` raw interpreter path.
        \\
    );
    try writer.print("\nArtifacts: `{s}`\n\n", .{out_dir});
    try writer.writeAll("| fixture | engine | runner | scope | host | spec | runs | host calls/run | median ms | vs fastest |\n");
    try writer.writeAll("| --- | --- | --- | --- | --- | --- | ---: | ---: | ---: | ---: |\n");

    for (rows) |row| {
        const fastest = fastestMedian(rows, row.fixture);
        try writer.print(
            "| {s} | {s} | {s} | {s} | {s} | {s} | {d} | ",
            .{
                row.fixture,
                row.engine,
                row.runner,
                row.scope,
                row.host_profile,
                row.spec,
                row.runs,
            },
        );
        try writeOptionalF64(writer, row.timed_host_calls_per_run);
        try writer.print(
            " | {d:.3} | {d:.2}x |\n",
            .{
                row.median_ms,
                row.median_ms / fastest,
            },
        );
    }

    return out.toOwnedSlice();
}

fn fastestMedian(rows: []const Row, fixture: []const u8) f64 {
    var fastest: f64 = std.math.inf(f64);
    for (rows) |row| {
        if (std.mem.eql(u8, row.fixture, fixture)) fastest = @min(fastest, row.median_ms);
    }
    return fastest;
}

fn engineName(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "evmz",
        .evmone_baseline => "evmone-baseline",
        .evmone_advanced => "evmone-advanced",
        .revm_interpreter => "revm-interpreter",
    };
}

fn runnerName(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "zig",
        .evmone_baseline, .evmone_advanced => "c++",
        .revm_interpreter => "rust-native",
    };
}

fn defaultScope(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "interpreter-prepared-execute",
        .evmone_baseline => "baseline-analyzed-execute",
        .evmone_advanced => "advanced-analyzed-execute",
        .revm_interpreter => "raw-interpreter",
    };
}

fn baseName(path: []const u8) []const u8 {
    return std.fs.path.basename(path);
}

fn stripPrefix(value: []const u8, prefix: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, value, prefix)) return null;
    return value[prefix.len..];
}

fn parseProfile(allocator: std.mem.Allocator, value: []const u8) ![]const u8 {
    if (!std.mem.eql(u8, value, "native") and !std.mem.eql(u8, value, "zkvm")) {
        return error.UnsupportedProfile;
    }
    return allocator.dupe(u8, value);
}

fn parseNonZeroUsize(value: []const u8) !usize {
    const parsed = try std.fmt.parseInt(usize, value, 10);
    if (parsed == 0) return error.ValueMustBeNonZero;
    return parsed;
}

test "parse timing rows ignores non-floats" {
    const times = try parseTimesMs(std.testing.allocator, "1.0\nnoise\n2.5\n");
    defer std.testing.allocator.free(times);
    try std.testing.expectEqualSlices(f64, &.{ 1.0, 2.5 }, times);
}

test "summary key values are parsed from first summary line" {
    const line = firstSummaryLine("debug\nfixture=x engine=evmz scope=interpreter-prepared-execute runtime_bytes=3\n");
    try std.testing.expectEqualStrings("evmz", keyValue(line, "engine").?);
    try std.testing.expectEqualStrings("3", keyValue(line, "runtime_bytes").?);
    try std.testing.expect(keyValue(line, "missing") == null);
}

test "median handles odd and even sample counts" {
    try std.testing.expectEqual(@as(f64, 2.0), try medianMs(std.testing.allocator, &.{ 3.0, 1.0, 2.0 }));
    try std.testing.expectEqual(@as(f64, 2.5), try medianMs(std.testing.allocator, &.{ 4.0, 1.0, 3.0, 2.0 }));
}

test "host calls per run normalizes total counters" {
    try std.testing.expectEqual(@as(?f64, 2.5), hostCallsPerRun(10, 4));
    try std.testing.expect(hostCallsPerRun(null, 4) == null);
    try std.testing.expect(hostCallsPerRun(10, 0) == null);
}
