const std = @import("std");
const common = @import("common.zig");
const evmz = @import("evmz");

const Analysis = evmz.code.Analysis;
const Config = evmz.Config;
const Host = evmz.Host;
const Interpreter = evmz.Interpreter;
const JumpDestMap = evmz.code.JumpDestMap;
const Opcode = evmz.Opcode;

const max_code_hex_bytes = 128 * 1024 * 1024;
const default_fixtures_dir = "fixtures/kernel";
const default_batch_target_bytes = 2 * 1024 * 1024;
const max_default_batch = 5000;
const min_default_batch = 8;

const Options = struct {
    samples: usize = 7,
    warmups: usize = 1,
    batch: ?usize = null,
    kernel_iterations: usize = 1000,
    fixtures_dir: []const u8 = default_fixtures_dir,
    spec: evmz.Spec = .latest,
    no_header: bool = false,
};

const InputKind = enum {
    hex_file,
    kernel,
    vm_init,
    vm_runtime,
};

const Input = struct {
    kind: InputKind,
    name: []const u8,
    path: []const u8,
};

const Morphology = struct {
    bytes: usize,
    instructions: usize,
    raw_push: usize,
    real_push: usize,
    raw_jumpdest: usize,
    real_jumpdest: usize,
    blocks: usize,
    static_safe_blocks: usize,
    static_safe_instructions: usize,
    max_static_safe_block_len: usize,
    metered_flat_blocks: usize,
    metered_flat_instructions: usize,
    max_metered_flat_block_len: usize,
};

const Timing = struct {
    legacy_jumpdest_ns: u64,
    simd_jumpdest_ns: u64,
    base_analysis_ns: u64,
    advanced_analysis_ns: u64,
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
    var inputs: std.ArrayList(Input) = .empty;
    defer deinitInputs(allocator, &inputs);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--hex-file")) {
            const path = args.next() orelse return error.MissingHexFile;
            try appendPathInput(allocator, &inputs, .hex_file, "hex", path);
        } else if (common.stripPrefix(arg, "--hex-file=")) |path| {
            try appendPathInput(allocator, &inputs, .hex_file, "hex", path);
        } else if (std.mem.eql(u8, arg, "--kernel")) {
            const name = args.next() orelse return error.MissingKernel;
            try appendKernelInput(allocator, &inputs, name);
        } else if (common.stripPrefix(arg, "--kernel=")) |name| {
            try appendKernelInput(allocator, &inputs, name);
        } else if (std.mem.eql(u8, arg, "--vm-fixture")) {
            const path = args.next() orelse return error.MissingFixture;
            try appendPathInput(allocator, &inputs, .vm_runtime, "runtime", path);
        } else if (common.stripPrefix(arg, "--vm-fixture=")) |path| {
            try appendPathInput(allocator, &inputs, .vm_runtime, "runtime", path);
        } else if (std.mem.eql(u8, arg, "--vm-init")) {
            const path = args.next() orelse return error.MissingFixture;
            try appendPathInput(allocator, &inputs, .vm_init, "init", path);
        } else if (common.stripPrefix(arg, "--vm-init=")) |path| {
            try appendPathInput(allocator, &inputs, .vm_init, "init", path);
        } else if (std.mem.eql(u8, arg, "--kernel-iterations")) {
            const value = args.next() orelse return error.MissingIterations;
            options.kernel_iterations = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--kernel-iterations=")) |value| {
            options.kernel_iterations = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--samples")) {
            const value = args.next() orelse return error.MissingSamples;
            options.samples = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--samples=")) |value| {
            options.samples = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--warmups")) {
            const value = args.next() orelse return error.MissingWarmups;
            options.warmups = try parseUsize(value);
        } else if (common.stripPrefix(arg, "--warmups=")) |value| {
            options.warmups = try parseUsize(value);
        } else if (std.mem.eql(u8, arg, "--batch")) {
            const value = args.next() orelse return error.MissingBatch;
            options.batch = try common.parseNonZeroUsize(value);
        } else if (common.stripPrefix(arg, "--batch=")) |value| {
            options.batch = try common.parseNonZeroUsize(value);
        } else if (std.mem.eql(u8, arg, "--fixtures-dir")) {
            options.fixtures_dir = args.next() orelse return error.MissingFixturesDir;
        } else if (common.stripPrefix(arg, "--fixtures-dir=")) |value| {
            options.fixtures_dir = value;
        } else if (std.mem.eql(u8, arg, "--spec")) {
            const value = args.next() orelse return error.MissingSpec;
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (common.stripPrefix(arg, "--spec=")) |value| {
            options.spec = common.parseSpec(value) orelse return error.InvalidSpec;
        } else if (std.mem.eql(u8, arg, "--no-header")) {
            options.no_header = true;
        } else {
            return error.UnknownArgument;
        }
    }

    if (inputs.items.len == 0) {
        try appendDefaultInputs(allocator, &inputs);
    }

    if (!options.no_header) {
        try stdout.print(
            "source,name,bytes,instructions,raw_push,real_push,raw_jumpdest,real_jumpdest,blocks,static_safe_blocks,static_safe_instructions,static_safe_instruction_pct,max_static_safe_block_len,metered_flat_blocks,metered_flat_instructions,metered_flat_instruction_pct,max_metered_flat_block_len,batch,legacy_jumpdest_ns_per_byte,simd_jumpdest_ns_per_byte,simd_jumpdest_delta_pct,base_analysis_ns_per_instr,advanced_analysis_ns_per_instr,advanced_analysis_delta_pct\n",
            .{},
        );
    }

    for (inputs.items) |input| {
        const code = try loadInput(init.io, allocator, input, options);
        defer allocator.free(code);

        const morphology = try analyzeMorphology(allocator, code);
        const batch = options.batch orelse defaultBatch(code.len);
        const timing = try measureTimings(allocator, code, batch, options.samples, options.warmups);
        try printRow(stdout, input, morphology, timing, batch);
    }

    try stdout.flush();
}

fn printUsage() void {
    std.debug.print(
        \\Usage:
        \\  zig build code-analysis -- [options]
        \\
        \\Inputs:
        \\  --hex-file <path>            analyze raw hex bytecode file
        \\  --kernel <name>              analyze repeated kernel fixture, e.g. jumpdest_dense
        \\  --vm-fixture <dir>           deploy init.hex and analyze runtime bytecode
        \\  --vm-init <dir>              analyze fixture init.hex directly
        \\
        \\Options:
        \\  --kernel-iterations <n>      repeated kernel patterns, default 1000
        \\  --samples <n>                timed samples per input, default 7
        \\  --warmups <n>                unprinted warmup samples, default 1
        \\  --batch <n>                  analysis/map builds per sample, default size-based
        \\  --fixtures-dir <path>        kernel fixture directory, default fixtures/kernel
        \\  --spec <name>                fork spec for VM fixture deployment, default latest
        \\  --no-header                  omit CSV header
        \\
    , .{});
}

fn appendDefaultInputs(allocator: std.mem.Allocator, inputs: *std.ArrayList(Input)) !void {
    const kernels = &[_][]const u8{
        "jumpdest_dense",
        "jump",
        "jumpi_taken",
        "push_pop",
        "pushdata_large",
    };
    for (kernels) |name| try appendKernelInput(allocator, inputs, name);

    const vm_fixtures = &[_][]const u8{
        "fixtures/vm-loop/erc20-transfer",
        "fixtures/vm-loop/erc20-mint",
        "fixtures/vm-loop/ten-thousand-hashes",
        "fixtures/vm-loop/arithmetic-loop",
        "fixtures/vm-loop/memory-mstore-loop",
        "fixtures/vm-loop/storage-sload-loop",
        "fixtures/vm-loop/storage-sstore-loop",
    };
    for (vm_fixtures) |path| try appendPathInput(allocator, inputs, .vm_runtime, "runtime", path);
}

fn appendKernelInput(allocator: std.mem.Allocator, inputs: *std.ArrayList(Input), name: []const u8) !void {
    try inputs.append(allocator, .{
        .kind = .kernel,
        .name = try std.fmt.allocPrint(allocator, "kernel/{s}", .{name}),
        .path = name,
    });
}

fn appendPathInput(
    allocator: std.mem.Allocator,
    inputs: *std.ArrayList(Input),
    kind: InputKind,
    prefix: []const u8,
    path: []const u8,
) !void {
    const basename = std.fs.path.basename(path);
    try inputs.append(allocator, .{
        .kind = kind,
        .name = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ prefix, basename }),
        .path = path,
    });
}

fn loadInput(
    io: std.Io,
    allocator: std.mem.Allocator,
    input: Input,
    options: Options,
) ![]u8 {
    return switch (input.kind) {
        .hex_file => readHexFile(io, allocator, input.path),
        .kernel => kernelBytecode(io, allocator, input.path, options.kernel_iterations, options.fixtures_dir),
        .vm_init => blk: {
            const init_path = try fixturePath(allocator, input.path, "init.hex");
            defer allocator.free(init_path);
            break :blk try readHexFile(io, allocator, init_path);
        },
        .vm_runtime => blk: {
            const init_path = try fixturePath(allocator, input.path, "init.hex");
            defer allocator.free(init_path);
            const init_code = try readHexFile(io, allocator, init_path);
            defer allocator.free(init_code);
            break :blk try deployRuntime(allocator, init_code, options.spec);
        },
    };
}

fn deinitInputs(allocator: std.mem.Allocator, inputs: *std.ArrayList(Input)) void {
    for (inputs.items) |input| allocator.free(input.name);
    inputs.deinit(allocator);
}

fn readHexFile(io: std.Io, allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(max_code_hex_bytes));
    defer allocator.free(text);
    return common.decodeHexAlloc(allocator, text);
}

fn fixturePath(allocator: std.mem.Allocator, fixture_dir: []const u8, name: []const u8) ![]const u8 {
    return std.fmt.allocPrint(allocator, "{s}/{s}", .{ fixture_dir, name });
}

fn deployRuntime(allocator: std.mem.Allocator, init_code: []const u8, spec: evmz.Spec) ![]u8 {
    var counting_host = common.CountingHost.init(allocator, .mock);
    defer counting_host.deinit();
    var host = counting_host.host();
    const msg = Host.Message{
        .depth = 0,
        .kind = .create,
        .gas = common.max_gas,
        .recipient = common.contract_address,
        .sender = common.caller_address,
        .input_data = &.{},
        .value = 0,
        .code_address = common.contract_address,
    };

    var frame = try Interpreter.OwnedCallFrame.init(allocator, .{
        .host = &host,
        .msg = &msg,
        .code = init_code,
        .spec = spec,
    });
    defer frame.deinit();
    var interpreter = frame.interpreter();

    const result = try interpreter.execute();
    if (result.status != .success) return error.DeployFailed;
    return allocator.dupe(u8, result.output_data);
}

fn kernelBytecode(
    io: std.Io,
    allocator: std.mem.Allocator,
    case_name: []const u8,
    iterations: usize,
    fixtures_dir: []const u8,
) ![]u8 {
    const path = try std.fmt.allocPrint(allocator, "{s}/{s}.hex", .{ fixtures_dir, case_name });
    defer allocator.free(path);

    const text = try std.Io.Dir.cwd().readFileAlloc(io, path, allocator, .limited(1024 * 1024));
    defer allocator.free(text);

    var patterns: std.ArrayList([]u8) = .empty;
    defer {
        for (patterns.items) |pattern| allocator.free(pattern);
        patterns.deinit(allocator);
    }

    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw_line| {
        const line = std.mem.trim(u8, raw_line, " \t\r");
        if (line.len == 0 or line[0] == '#') continue;
        try patterns.append(allocator, try common.decodeHexAlloc(allocator, line));
    }
    if (patterns.items.len == 0) return error.EmptyKernelFixture;

    var code: std.ArrayList(u8) = .empty;
    errdefer code.deinit(allocator);
    var i: usize = 0;
    while (i < iterations) : (i += 1) {
        try code.appendSlice(allocator, patterns.items[i % patterns.items.len]);
    }
    try code.append(allocator, @intFromEnum(Opcode.STOP));
    return code.toOwnedSlice(allocator);
}

fn analyzeMorphology(allocator: std.mem.Allocator, code: []const u8) !Morphology {
    var analysis = try Analysis.initWithConfig(allocator, code, .advanced);
    defer analysis.deinit(allocator);

    var morphology = Morphology{
        .bytes = code.len,
        .instructions = analysis.instructions.len,
        .raw_push = 0,
        .real_push = 0,
        .raw_jumpdest = 0,
        .real_jumpdest = 0,
        .blocks = analysis.blocks.len,
        .static_safe_blocks = 0,
        .static_safe_instructions = 0,
        .max_static_safe_block_len = 0,
        .metered_flat_blocks = 0,
        .metered_flat_instructions = 0,
        .max_metered_flat_block_len = 0,
    };

    for (code) |byte| {
        morphology.raw_push += @intFromBool(isPush(byte));
        morphology.raw_jumpdest += @intFromBool(byte == @intFromEnum(Opcode.JUMPDEST));
    }
    for (analysis.instructions) |meta| {
        morphology.real_push += @intFromBool(meta.isPush());
    }
    morphology.real_jumpdest = analysis.metadata.jumpdest.count();
    analyzeBlocks(analysis, &morphology);
    return morphology;
}

fn analyzeBlocks(analysis: Analysis, morphology: *Morphology) void {
    for (analysis.blocks) |block| {
        const block_len = @as(usize, @intCast(block.last_instruction - block.first_instruction));

        if (block.isStaticSafe()) {
            morphology.static_safe_blocks += 1;
            morphology.static_safe_instructions += block_len;
            morphology.max_static_safe_block_len = @max(morphology.max_static_safe_block_len, block_len);
        }

        if (block.isMeteredFlatSafe()) {
            morphology.metered_flat_blocks += 1;
            morphology.metered_flat_instructions += block_len;
            morphology.max_metered_flat_block_len = @max(morphology.max_metered_flat_block_len, block_len);
        }
    }
}

fn measureTimings(
    allocator: std.mem.Allocator,
    code: []const u8,
    batch: usize,
    samples: usize,
    warmups: usize,
) !Timing {
    var legacy_samples = try allocator.alloc(u64, samples);
    defer allocator.free(legacy_samples);
    var simd_samples = try allocator.alloc(u64, samples);
    defer allocator.free(simd_samples);
    var base_samples = try allocator.alloc(u64, samples);
    defer allocator.free(base_samples);
    var advanced_samples = try allocator.alloc(u64, samples);
    defer allocator.free(advanced_samples);

    var warmup_index: usize = 0;
    while (warmup_index < warmups) : (warmup_index += 1) {
        _ = try measureJumpdest(allocator, code, .legacy, batch);
        _ = try measureJumpdest(allocator, code, .simd_bitmask, batch);
        _ = try measureAnalysis(allocator, code, .base, batch);
        _ = try measureAnalysis(allocator, code, .advanced, batch);
    }

    for (0..samples) |index| {
        legacy_samples[index] = try measureJumpdest(allocator, code, .legacy, batch);
        simd_samples[index] = try measureJumpdest(allocator, code, .simd_bitmask, batch);
        base_samples[index] = try measureAnalysis(allocator, code, .base, batch);
        advanced_samples[index] = try measureAnalysis(allocator, code, .advanced, batch);
    }

    return .{
        .legacy_jumpdest_ns = median(legacy_samples),
        .simd_jumpdest_ns = median(simd_samples),
        .base_analysis_ns = median(base_samples),
        .advanced_analysis_ns = median(advanced_samples),
    };
}

fn measureJumpdest(
    allocator: std.mem.Allocator,
    code: []const u8,
    strategy: JumpDestMap.Strategy,
    batch: usize,
) !u64 {
    const start_ns = try common.monotonicNowNs();
    var index: usize = 0;
    while (index < batch) : (index += 1) {
        var map = JumpDestMap.init(strategy);
        try map.analyze(allocator, code);
        std.mem.doNotOptimizeAway(map.bits.bit_length);
        if (map.bits.bit_length != 0) std.mem.doNotOptimizeAway(map.bits.masks[0]);
        map.deinit(allocator);
    }
    return try elapsedSince(start_ns);
}

fn measureAnalysis(
    allocator: std.mem.Allocator,
    code: []const u8,
    config: Config,
    batch: usize,
) !u64 {
    const start_ns = try common.monotonicNowNs();
    var index: usize = 0;
    while (index < batch) : (index += 1) {
        var analysis = try Analysis.initWithConfig(allocator, code, config);
        std.mem.doNotOptimizeAway(analysis.instructions.len);
        analysis.deinit(allocator);
    }
    return try elapsedSince(start_ns);
}

fn elapsedSince(start_ns: u64) !u64 {
    const end_ns = try common.monotonicNowNs();
    return end_ns - start_ns;
}

fn printRow(
    stdout: *std.Io.Writer,
    input: Input,
    morphology: Morphology,
    timing: Timing,
    batch: usize,
) !void {
    const static_safe_instruction_pct = pct(morphology.static_safe_instructions, morphology.instructions);
    const metered_flat_instruction_pct = pct(morphology.metered_flat_instructions, morphology.instructions);
    const legacy_jumpdest_ns_per_byte = nsPer(timing.legacy_jumpdest_ns, batch, morphology.bytes);
    const simd_jumpdest_ns_per_byte = nsPer(timing.simd_jumpdest_ns, batch, morphology.bytes);
    const base_analysis_ns_per_instr = nsPer(timing.base_analysis_ns, batch, morphology.instructions);
    const advanced_analysis_ns_per_instr = nsPer(timing.advanced_analysis_ns, batch, morphology.instructions);

    try stdout.print(
        "{s},{s},{d},{d},{d},{d},{d},{d},{d},{d},{d},{d:.3},{d},{d},{d},{d:.3},{d},{d},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3},{d:.3}\n",
        .{
            @tagName(input.kind),
            input.name,
            morphology.bytes,
            morphology.instructions,
            morphology.raw_push,
            morphology.real_push,
            morphology.raw_jumpdest,
            morphology.real_jumpdest,
            morphology.blocks,
            morphology.static_safe_blocks,
            morphology.static_safe_instructions,
            static_safe_instruction_pct,
            morphology.max_static_safe_block_len,
            morphology.metered_flat_blocks,
            morphology.metered_flat_instructions,
            metered_flat_instruction_pct,
            morphology.max_metered_flat_block_len,
            batch,
            legacy_jumpdest_ns_per_byte,
            simd_jumpdest_ns_per_byte,
            deltaPct(simd_jumpdest_ns_per_byte, legacy_jumpdest_ns_per_byte),
            base_analysis_ns_per_instr,
            advanced_analysis_ns_per_instr,
            deltaPct(advanced_analysis_ns_per_instr, base_analysis_ns_per_instr),
        },
    );
}

fn nsPer(total_ns: u64, batch: usize, count: usize) f64 {
    if (count == 0) return 0;
    return @as(f64, @floatFromInt(total_ns)) /
        @as(f64, @floatFromInt(batch)) /
        @as(f64, @floatFromInt(count));
}

fn pct(numerator: usize, denominator: usize) f64 {
    if (denominator == 0) return 0;
    return @as(f64, @floatFromInt(numerator)) * 100.0 /
        @as(f64, @floatFromInt(denominator));
}

fn deltaPct(current: f64, baseline: f64) f64 {
    if (baseline == 0) return 0;
    return (current - baseline) * 100.0 / baseline;
}

fn defaultBatch(bytes_len: usize) usize {
    if (bytes_len == 0) return max_default_batch;
    const raw = default_batch_target_bytes / bytes_len;
    return std.math.clamp(raw, min_default_batch, max_default_batch);
}

fn isPush(opcode: u8) bool {
    return opcode >= @intFromEnum(Opcode.PUSH0) and opcode <= @intFromEnum(Opcode.PUSH32);
}

fn parseUsize(value: []const u8) !usize {
    return std.fmt.parseUnsigned(usize, value, 10);
}

fn median(values: []u64) u64 {
    insertionSort(values);
    return values[values.len / 2];
}

fn insertionSort(values: []u64) void {
    var index: usize = 1;
    while (index < values.len) : (index += 1) {
        const value = values[index];
        var cursor = index;
        while (cursor > 0 and values[cursor - 1] > value) : (cursor -= 1) {
            values[cursor] = values[cursor - 1];
        }
        values[cursor] = value;
    }
}

test "default batch is bounded" {
    try std.testing.expectEqual(@as(usize, max_default_batch), defaultBatch(1));
    try std.testing.expectEqual(@as(usize, min_default_batch), defaultBatch(1024 * 1024 * 1024));
}

test "median sorts and returns middle sample" {
    var values = [_]u64{ 9, 3, 7, 1, 5 };
    try std.testing.expectEqual(@as(u64, 5), median(&values));
}
