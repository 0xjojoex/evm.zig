const std = @import("std");
const evmz = @import("evmz");
const common = @import("common.zig");
const kernel_evmone = @import("kernel_evmone.zig");

const Host = common.Host;
const Interpreter = evmz.interpreter;

const default_iterations = 100_000;
const default_repeats = 5;
const default_warmups = 1;
const default_fixtures_dir = "fixtures/kernel";

const KernelCase = enum {
    push_pop,
    add,
    mul,
    div,
    sdiv,
    mod,
    smod,
    addmod,
    mulmod,
    exp,
    comparison,
    bitwise,
    shift,
    add_wide,
    mul_wide,
    div_wide,
    sdiv_wide,
    mod_wide,
    smod_wide,
    addmod_wide,
    mulmod_wide,
    exp_wide,
    pushdata_large,
    jumpdest_dense,
    jump,
    jumpi_taken,
    jumpi_fallthrough,
    jumpi_alternating,
};

const KernelTier = enum {
    small,
    edge,
    large,
    branch,
    all,
};

const Engine = enum {
    evmz,
    evmz_call_total,
    evmone_baseline,
    evmone_advanced,
};

const EvmzMeasureScope = enum {
    execute_only,
    call_total,
};

const Options = struct {
    iterations: usize = default_iterations,
    repeats: usize = default_repeats,
    warmups: usize = default_warmups,
    revision: evmz.eth.Revision = .latest,
    fixtures_dir: []const u8 = default_fixtures_dir,
    no_header: bool = false,
};

const Measurement = struct {
    elapsed_ns: u64,
    bytecode_bytes: usize,
    gas_used: u64,
    host_calls: u64,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;

    var stdout_buffer: [8192]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(init.io, &stdout_buffer);
    const stdout = &stdout_writer.interface;

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    var selected_cases: std.ArrayList(KernelCase) = .empty;
    defer selected_cases.deinit(allocator);
    var selected_tiers: std.ArrayList(KernelTier) = .empty;
    defer selected_tiers.deinit(allocator);
    var selected_engines: std.ArrayList(Engine) = .empty;
    defer selected_engines.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--case")) {
            const value = args.next() orelse return error.MissingCase;
            try selected_cases.append(allocator, parseCase(value) orelse return error.InvalidCase);
        } else if (common.stripPrefix(arg, "--case=")) |value| {
            try selected_cases.append(allocator, parseCase(value) orelse return error.InvalidCase);
        } else if (std.mem.eql(u8, arg, "--tier")) {
            const value = args.next() orelse return error.MissingTier;
            try selected_tiers.append(allocator, parseTier(value) orelse return error.InvalidTier);
        } else if (common.stripPrefix(arg, "--tier=")) |value| {
            try selected_tiers.append(allocator, parseTier(value) orelse return error.InvalidTier);
        } else if (std.mem.eql(u8, arg, "--engine")) {
            const value = args.next() orelse return error.MissingEngine;
            try selected_engines.append(allocator, parseEngine(value) orelse return error.InvalidEngine);
        } else if (common.stripPrefix(arg, "--engine=")) |value| {
            try selected_engines.append(allocator, parseEngine(value) orelse return error.InvalidEngine);
        } else if (std.mem.eql(u8, arg, "--iterations") or std.mem.eql(u8, arg, "-n")) {
            const value = args.next() orelse return error.MissingIterations;
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--iterations=")) |value| {
            options.iterations = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--repeats")) {
            const value = args.next() orelse return error.MissingRepeats;
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--repeats=")) |value| {
            options.repeats = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmups=")) |value| {
            options.warmups = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.revision = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--fixtures-dir")) {
            options.fixtures_dir = args.next() orelse return error.MissingFixturesDir;
        } else if (common.stripPrefix(arg, "--fixtures-dir=")) |value| {
            options.fixtures_dir = value;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.no_header = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (selected_cases.items.len == 0 and selected_tiers.items.len == 0) {
        try appendTierCases(allocator, &selected_cases, .small);
    } else {
        for (selected_tiers.items) |tier| {
            try appendTierCases(allocator, &selected_cases, tier);
        }
    }
    if (selected_engines.items.len == 0) {
        try selected_engines.append(allocator, .evmz);
    }

    if (!options.no_header) {
        try stdout.print("suite,engine,case,repeat,iterations,bytecode_bytes,elapsed_ns,ns_per_iter,gas_used,host_calls\n", .{});
    }

    for (selected_engines.items) |engine| {
        for (selected_cases.items) |case| {
            var warmup_index: usize = 0;
            while (warmup_index < options.warmups) : (warmup_index += 1) {
                _ = try measure(init.io, allocator, engine, case, options.iterations, options.revision, options.fixtures_dir);
            }

            var repeat_index: usize = 0;
            while (repeat_index < options.repeats) : (repeat_index += 1) {
                const measurement = try measure(init.io, allocator, engine, case, options.iterations, options.revision, options.fixtures_dir);
                const ns_per_iter = @as(f64, @floatFromInt(measurement.elapsed_ns)) /
                    @as(f64, @floatFromInt(options.iterations));
                try stdout.print(
                    "kernel,{s},{s},{d},{d},{d},{d},{d:.3},{d},{d}\n",
                    .{
                        engineName(engine),
                        @tagName(case),
                        repeat_index + 1,
                        options.iterations,
                        measurement.bytecode_bytes,
                        measurement.elapsed_ns,
                        ns_per_iter,
                        measurement.gas_used,
                        measurement.host_calls,
                    },
                );
            }
        }
    }

    try stdout.flush();
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build kernel -- [options]
        \\
        \\Options:
        \\  --case <name>           case filter; repeatable, default all cases
        \\  --tier <name>           small, edge, large, branch, all; repeatable
        \\  --engine <name>         evmz, evmz-call-total, evmone, evmone-baseline, evmone-advanced
        \\  --iterations, -n <n>    repeated opcode pattern count, default 100000
        \\  --repeats <n>           printed samples per case, default 5
        \\  --warmups <n>           unprinted samples before repeats, default 1
        \\  --spec <name>           fork spec, default latest
        \\  --fixtures-dir <path>   kernel fixture directory, default fixtures/kernel
        \\  --no-header             omit CSV header
        \\
        \\Cases:
        \\  push-pop, add, mul, div, sdiv, mod, smod, addmod, mulmod,
        \\  exp, comparison, bitwise, shift, add-wide, mul-wide, div-wide,
        \\  sdiv-wide, mod-wide, smod-wide, addmod-wide, mulmod-wide,
        \\  exp-wide, pushdata-large, jumpdest-dense, jump, jumpi-taken,
        \\  jumpi-fallthrough, jumpi-alternating
        \\
    , .{});
}

fn measure(
    io: std.Io,
    allocator: std.mem.Allocator,
    engine: Engine,
    case: KernelCase,
    iterations: usize,
    revision: evmz.eth.Revision,
    fixtures_dir: []const u8,
) !Measurement {
    const code = try kernelBytecode(io, allocator, case, iterations, fixtures_dir);
    defer allocator.free(code);

    return switch (engine) {
        .evmz => try measureEvmz(allocator, code, revision, .execute_only),
        .evmz_call_total => try measureEvmz(allocator, code, revision, .call_total),
        .evmone_baseline => blk: {
            const measurement = try kernel_evmone.measure(code, revision, .baseline);
            break :blk .{
                .elapsed_ns = measurement.elapsed_ns,
                .bytecode_bytes = code.len,
                .gas_used = measurement.gas_used,
                .host_calls = measurement.host_calls,
            };
        },
        .evmone_advanced => blk: {
            const measurement = try kernel_evmone.measure(code, revision, .advanced);
            break :blk .{
                .elapsed_ns = measurement.elapsed_ns,
                .bytecode_bytes = code.len,
                .gas_used = measurement.gas_used,
                .host_calls = measurement.host_calls,
            };
        },
    };
}

fn measureEvmz(
    allocator: std.mem.Allocator,
    code: []const u8,
    revision: evmz.eth.Revision,
    scope: EvmzMeasureScope,
) !Measurement {
    var counting_host = common.CountingHost.init(allocator, .null);
    defer counting_host.deinit();
    var host = counting_host.host();
    const msg = Host.Message{
        .depth = 0,
        .kind = .call,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = &.{},
        .value = 0,
        .code_address = common.contract_address,
    };

    counting_host.resetCounters();
    const total_start_ns = if (scope == .call_total) try common.monotonicNowNs() else 0;
    var frame = try Interpreter.OwnedCallFrame(evmz.Evm.Protocol).init(allocator, .{
        .host = &host,
        .msg = &msg,
        .code = code,
        .revision = revision,
    });
    errdefer frame.deinit();
    var interpreter = frame.interpreter();

    const start_ns = if (scope == .execute_only) try common.monotonicNowNs() else total_start_ns;
    const result = try interpreter.execute();
    const end_ns = try common.monotonicNowNs();
    const host_calls = counting_host.counters.total();
    frame.deinit();

    try common.rejectNullHostTouches(.null, counting_host.counters);
    if (result.status != .success) return error.KernelFailed;

    return .{
        .elapsed_ns = end_ns - start_ns,
        .bytecode_bytes = code.len,
        .gas_used = @intCast(common.max_gas - result.gas_left),
        .host_calls = host_calls,
    };
}

fn kernelBytecode(
    io: std.Io,
    allocator: std.mem.Allocator,
    case: KernelCase,
    iterations: usize,
    fixtures_dir: []const u8,
) ![]u8 {
    var fixture = try FixtureSet.load(io, allocator, fixtures_dir, case);
    defer fixture.deinit(allocator);

    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    try code.ensureTotalCapacity(allocator, try fixture.bytecodeSize(iterations));

    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try code.appendSlice(allocator, fixture.patterns.items[i % fixture.patterns.items.len]);
    }
    try code.append(allocator, 0x00);
    return code.toOwnedSlice(allocator);
}

const FixtureSet = struct {
    patterns: std.ArrayList([]u8) = .empty,

    fn load(io: std.Io, allocator: std.mem.Allocator, fixtures_dir: []const u8, case: KernelCase) !FixtureSet {
        const path = try std.fmt.allocPrint(allocator, "{s}/{s}.hex", .{ fixtures_dir, @tagName(case) });
        defer allocator.free(path);

        const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
        defer allocator.free(text);

        var fixture = FixtureSet{};
        errdefer fixture.deinit(allocator);

        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |raw_line| {
            const line = std.mem.trim(u8, raw_line, " \t\r");
            if (line.len == 0 or line[0] == '#') continue;
            const bytes = try common.decodeHexAlloc(allocator, line);
            try fixture.patterns.append(allocator, bytes);
        }
        if (fixture.patterns.items.len == 0) return error.EmptyKernelFixture;
        return fixture;
    }

    fn deinit(self: *FixtureSet, allocator: std.mem.Allocator) void {
        for (self.patterns.items) |pattern| allocator.free(pattern);
        self.patterns.deinit(allocator);
    }

    fn bytecodeSize(self: FixtureSet, iterations: usize) !usize {
        var size: usize = 1;
        var i: usize = 0;
        while (i < iterations) : (i += 1) {
            size = try std.math.add(usize, size, self.patterns.items[i % self.patterns.items.len].len);
        }
        return size;
    }
};

fn appendTierCases(allocator: std.mem.Allocator, cases: *std.ArrayList(KernelCase), tier: KernelTier) !void {
    const small = [_]KernelCase{
        .push_pop,
        .add,
        .mul,
        .div,
        .sdiv,
        .mod,
        .smod,
        .addmod,
        .mulmod,
        .exp,
        .comparison,
        .bitwise,
        .shift,
    };
    const edge = [_]KernelCase{
        .add_wide,
        .mul_wide,
        .div_wide,
        .sdiv_wide,
        .mod_wide,
        .smod_wide,
        .addmod_wide,
        .mulmod_wide,
        .exp_wide,
    };
    const large = [_]KernelCase{
        .pushdata_large,
        .jumpdest_dense,
    };
    const branch = [_]KernelCase{
        .jump,
        .jumpi_taken,
        .jumpi_fallthrough,
        .jumpi_alternating,
    };
    switch (tier) {
        .small => try appendUniqueCases(allocator, cases, &small),
        .edge => try appendUniqueCases(allocator, cases, &edge),
        .large => try appendUniqueCases(allocator, cases, &large),
        .branch => try appendUniqueCases(allocator, cases, &branch),
        .all => {
            try appendUniqueCases(allocator, cases, &small);
            try appendUniqueCases(allocator, cases, &edge);
            try appendUniqueCases(allocator, cases, &large);
            try appendUniqueCases(allocator, cases, &branch);
        },
    }
}

fn appendUniqueCases(
    allocator: std.mem.Allocator,
    cases: *std.ArrayList(KernelCase),
    additions: []const KernelCase,
) !void {
    for (additions) |case| {
        if (std.mem.indexOfScalar(KernelCase, cases.items, case) == null) {
            try cases.append(allocator, case);
        }
    }
}

fn parseEngine(value: []const u8) ?Engine {
    if (std.mem.eql(u8, value, "evmone")) return .evmone_advanced;
    inline for (std.meta.fields(Engine)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn engineName(engine: Engine) []const u8 {
    return switch (engine) {
        .evmz => "evmz",
        .evmz_call_total => "evmz-call-total",
        .evmone_baseline => "evmone-baseline",
        .evmone_advanced => "evmone-advanced",
    };
}

fn parseCase(value: []const u8) ?KernelCase {
    inline for (std.meta.fields(KernelCase)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
}

fn parseTier(value: []const u8) ?KernelTier {
    inline for (std.meta.fields(KernelTier)) |field| {
        if (tagNameMatches(value, field.name)) return @enumFromInt(field.value);
    }
    return null;
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

fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10);
}

test "case parser accepts dashed names" {
    try std.testing.expectEqual(KernelCase.push_pop, parseCase("push-pop").?);
    try std.testing.expectEqual(KernelCase.mulmod, parseCase("mulmod").?);
    try std.testing.expectEqual(KernelCase.add_wide, parseCase("add-wide").?);
    try std.testing.expectEqual(KernelCase.jumpi_fallthrough, parseCase("jumpi-fallthrough").?);
}

test "tier parser accepts names" {
    try std.testing.expectEqual(KernelTier.small, parseTier("small").?);
    try std.testing.expectEqual(KernelTier.branch, parseTier("branch").?);
}

test "engine parser accepts evmone aliases" {
    try std.testing.expectEqual(Engine.evmone_advanced, parseEngine("evmone").?);
    try std.testing.expectEqual(Engine.evmone_baseline, parseEngine("evmone-baseline").?);
    try std.testing.expectEqual(Engine.evmz_call_total, parseEngine("evmz-call-total").?);
    try std.testing.expect(parseEngine("evmz-advanced") == null);
    try std.testing.expect(parseEngine("evmz-advanced-call-total") == null);
}

test "kernel bytecode repeats pattern and stops" {
    const code = try kernelBytecode(std.testing.io, std.testing.allocator, .add, 2, default_fixtures_dir);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualSlices(u8, &.{ 0x60, 0x02, 0x60, 0x03, 0x01, 0x50, 0x60, 0x02, 0x60, 0x03, 0x01, 0x50, 0x00 }, code);
}

test "jump kernel cycles fixture pattern" {
    const code = try kernelBytecode(std.testing.io, std.testing.allocator, .jump, 2, default_fixtures_dir);
    defer std.testing.allocator.free(code);
    try std.testing.expectEqualSlices(u8, &.{
        0x58, 0x60, 0x05, 0x01, 0x56, 0x5b, 0x60, 0x01, 0x50,
        0x58, 0x60, 0x05, 0x01, 0x56, 0x5b, 0x60, 0x01, 0x50,
        0x00,
    }, code);
}

test "push pop kernel touches no host" {
    const measurement = try measure(std.testing.io, std.testing.allocator, .evmz, .push_pop, 2, .latest, default_fixtures_dir);
    try std.testing.expectEqual(@as(u64, 0), measurement.host_calls);
}

test "branch kernels touch no host" {
    const jump = try measure(std.testing.io, std.testing.allocator, .evmz, .jump, 2, .latest, default_fixtures_dir);
    try std.testing.expectEqual(@as(u64, 0), jump.host_calls);
    const jumpi = try measure(std.testing.io, std.testing.allocator, .evmz, .jumpi_alternating, 2, .latest, default_fixtures_dir);
    try std.testing.expectEqual(@as(u64, 0), jumpi.host_calls);
}

test "call total scope touches no host" {
    const measurement = try measure(std.testing.io, std.testing.allocator, .evmz_call_total, .jumpdest_dense, 2, .latest, default_fixtures_dir);
    try std.testing.expectEqual(@as(u64, 0), measurement.host_calls);
}
