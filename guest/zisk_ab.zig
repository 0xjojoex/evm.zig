const std = @import("std");

const max_command_output = 4 * 1024 * 1024;
const max_public_output = 1024 * 1024;

const Options = struct {
    baseline_tree: ?[]const u8 = null,
    candidate_tree: []const u8 = ".",
    ziskemu: ?[]const u8 = null,
    ziskos_staticlib: ?[]const u8 = null,
    zig_exe: []const u8 = "zig",
    work_dir: []const u8 = "zig-out/guest/zisk-ab",
    max_steps: []const u8 = "5000000",
    global_cache_dir: ?[]const u8 = null,
    system_package_dir: ?[]const u8 = null,
    report_only: bool = false,
};

const Measurement = struct {
    steps: u64,
    public_output: []u8,
};

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const arena = init.arena.allocator();

    var args = try std.process.Args.Iterator.initAllocator(init.minimal.args, allocator);
    defer args.deinit();
    _ = args.next();

    var options = Options{};
    var payloads: std.ArrayList([]const u8) = .empty;
    defer payloads.deinit(allocator);

    while (args.next()) |arg_z| {
        const arg = arg_z[0..arg_z.len];
        if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
            printUsage();
            return;
        } else if (std.mem.eql(u8, arg, "--baseline-tree")) {
            options.baseline_tree = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--candidate-tree")) {
            options.candidate_tree = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--ziskemu")) {
            options.ziskemu = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--ziskos-staticlib")) {
            options.ziskos_staticlib = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--zig")) {
            options.zig_exe = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--work-dir")) {
            options.work_dir = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--max-steps")) {
            options.max_steps = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--global-cache-dir")) {
            options.global_cache_dir = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--system-package-dir")) {
            options.system_package_dir = try nextArg(arena, &args, arg);
        } else if (std.mem.eql(u8, arg, "--payload")) {
            const payload = try nextArg(arena, &args, arg);
            if (!isSelfContainedPayload(payload)) return error.UnsupportedGuestPayload;
            try payloads.append(allocator, payload);
        } else if (std.mem.eql(u8, arg, "--report-only")) {
            options.report_only = true;
        } else {
            std.debug.print("unknown argument: {s}\n", .{arg});
            printUsage();
            return error.UnknownArgument;
        }
    }

    if (options.baseline_tree == null or options.ziskemu == null or options.ziskos_staticlib == null) {
        printUsage();
        return error.MissingRequiredArgument;
    }
    if (payloads.items.len == 0) {
        try payloads.append(allocator, "basic");
        try payloads.append(allocator, "stateless-smoke");
    }

    const baseline_tree = try std.fs.path.resolve(arena, &.{options.baseline_tree.?});
    const candidate_tree = try std.fs.path.resolve(arena, &.{options.candidate_tree});
    const ziskemu = try std.fs.path.resolve(arena, &.{options.ziskemu.?});
    const provider = try std.fs.path.resolve(arena, &.{options.ziskos_staticlib.?});
    const work_dir = try std.fs.path.resolve(arena, &.{options.work_dir});
    const global_cache_dir = if (options.global_cache_dir) |path|
        try std.fs.path.resolve(arena, &.{path})
    else
        null;
    const system_package_dir = if (options.system_package_dir) |path|
        try std.fs.path.resolve(arena, &.{path})
    else
        null;

    try std.Io.Dir.cwd().createDirPath(init.io, work_dir);

    var regressed = false;
    for (payloads.items) |payload| {
        const failed = try comparePayload(init.io, allocator, arena, .{
            .baseline_tree = baseline_tree,
            .candidate_tree = candidate_tree,
            .ziskemu = ziskemu,
            .provider = provider,
            .zig_exe = options.zig_exe,
            .work_dir = work_dir,
            .max_steps = options.max_steps,
            .global_cache_dir = global_cache_dir,
            .system_package_dir = system_package_dir,
            .payload = payload,
        });
        regressed = regressed or failed;
    }

    if (regressed and !options.report_only) std.process.exit(1);
}

const CompareOptions = struct {
    baseline_tree: []const u8,
    candidate_tree: []const u8,
    ziskemu: []const u8,
    provider: []const u8,
    zig_exe: []const u8,
    work_dir: []const u8,
    max_steps: []const u8,
    global_cache_dir: ?[]const u8,
    system_package_dir: ?[]const u8,
    payload: []const u8,
};

fn comparePayload(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: CompareOptions,
) !bool {
    const payload_dir = try std.fs.path.join(arena, &.{ options.work_dir, options.payload });
    try std.Io.Dir.cwd().createDirPath(io, payload_dir);

    const baseline_elf = try buildGuest(io, allocator, arena, options, .baseline, payload_dir);
    const candidate_elf = try buildGuest(io, allocator, arena, options, .candidate, payload_dir);

    const baseline = try measureGuest(io, allocator, arena, options, .baseline, payload_dir, baseline_elf);
    defer allocator.free(baseline.public_output);
    const candidate = try measureGuest(io, allocator, arena, options, .candidate, payload_dir, candidate_elf);
    defer allocator.free(candidate.public_output);

    const output_matches = std.mem.eql(u8, baseline.public_output, candidate.public_output);
    const delta: i128 = @as(i128, candidate.steps) - @as(i128, baseline.steps);
    const delta_pct = if (baseline.steps == 0)
        std.math.inf(f64)
    else
        @as(f64, @floatFromInt(delta)) * 100.0 / @as(f64, @floatFromInt(baseline.steps));
    const steps_pass = stepGatePasses(baseline.steps, candidate.steps);

    std.debug.print(
        "guest-zisk-ab payload={s} baseline_steps={d} candidate_steps={d} delta={d} delta_pct={d:.2}% output={s} status={s}\n",
        .{
            options.payload,
            baseline.steps,
            candidate.steps,
            delta,
            delta_pct,
            if (output_matches) "match" else "mismatch",
            if (output_matches and steps_pass) "pass" else "fail",
        },
    );
    if (!output_matches) return error.PublicOutputMismatch;
    return !steps_pass;
}

const Side = enum { baseline, candidate };

fn buildGuest(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: CompareOptions,
    side: Side,
    payload_dir: []const u8,
) ![]const u8 {
    const label = @tagName(side);
    const tree = switch (side) {
        .baseline => options.baseline_tree,
        .candidate => options.candidate_tree,
    };
    const prefix = try std.fs.path.join(arena, &.{ payload_dir, label });
    const cache_dir_name = try std.fmt.allocPrint(arena, "{s}-cache", .{label});
    const cache_dir = try std.fs.path.join(arena, &.{ payload_dir, cache_dir_name });
    const payload_arg = try std.fmt.allocPrint(arena, "-Dguest-payload={s}", .{options.payload});
    const provider_arg = try std.fmt.allocPrint(arena, "-Dziskos-staticlib={s}", .{options.provider});

    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(allocator);
    try argv.appendSlice(allocator, &.{
        options.zig_exe,
        "build",
        "guest-zisk",
        "-Doptimize=ReleaseFast",
        payload_arg,
        provider_arg,
        "--prefix",
        prefix,
        "--cache-dir",
        cache_dir,
    });
    if (options.global_cache_dir) |path| try argv.appendSlice(allocator, &.{ "--global-cache-dir", path });
    if (options.system_package_dir) |path| try argv.appendSlice(allocator, &.{ "--system", path });

    try runChecked(io, allocator, label, argv.items, .{ .path = tree });
    return std.fs.path.join(arena, &.{ prefix, "guest/zisk/evmz-guest-zisk.elf" });
}

fn measureGuest(
    io: std.Io,
    allocator: std.mem.Allocator,
    arena: std.mem.Allocator,
    options: CompareOptions,
    side: Side,
    payload_dir: []const u8,
    elf_path: []const u8,
) !Measurement {
    const label = @tagName(side);
    const output_name = try std.fmt.allocPrint(arena, "{s}.public.bin", .{label});
    const output_path = try std.fs.path.join(arena, &.{ payload_dir, output_name });
    const argv = [_][]const u8{
        options.ziskemu,
        "-e",
        elf_path,
        "-o",
        output_path,
        "-n",
        options.max_steps,
        "-m",
        "--steps",
        "-c",
    };
    std.Io.Dir.cwd().deleteFile(io, output_path) catch |err| switch (err) {
        error.FileNotFound => {},
        else => return err,
    };
    const result = try std.process.run(allocator, io, .{
        .argv = &argv,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (!termOk(result.term)) {
        printCommandFailure(label, &argv, result.stdout, result.stderr);
        return error.ZiskemuFailed;
    }
    const steps = parseZiskSteps(result.stdout) orelse parseZiskSteps(result.stderr) orelse {
        std.debug.print("{s}: ziskemu did not report steps\nstdout:\n{s}\nstderr:\n{s}\n", .{ label, result.stdout, result.stderr });
        return error.MissingZiskSteps;
    };
    if (steps == 0) return error.ZeroZiskSteps;

    const public_output = try std.Io.Dir.cwd().readFileAlloc(io, output_path, allocator, .limited(max_public_output));
    return .{ .steps = steps, .public_output = public_output };
}

fn runChecked(
    io: std.Io,
    allocator: std.mem.Allocator,
    label: []const u8,
    argv: []const []const u8,
    cwd: std.process.Child.Cwd,
) !void {
    const result = try std.process.run(allocator, io, .{
        .argv = argv,
        .cwd = cwd,
        .stdout_limit = .limited(max_command_output),
        .stderr_limit = .limited(max_command_output),
    });
    defer allocator.free(result.stdout);
    defer allocator.free(result.stderr);
    if (termOk(result.term)) return;
    printCommandFailure(label, argv, result.stdout, result.stderr);
    return error.CommandFailed;
}

fn printCommandFailure(label: []const u8, argv: []const []const u8, stdout: []const u8, stderr: []const u8) void {
    std.debug.print("{s} command failed:", .{label});
    for (argv) |arg| std.debug.print(" {s}", .{arg});
    std.debug.print("\nstdout:\n{s}\nstderr:\n{s}\n", .{ stdout, stderr });
}

fn nextArg(arena: std.mem.Allocator, args: *std.process.Args.Iterator, flag: []const u8) ![]const u8 {
    const value_z = args.next() orelse {
        std.debug.print("missing value for {s}\n", .{flag});
        return error.MissingArgumentValue;
    };
    return arena.dupe(u8, value_z[0..value_z.len]);
}

fn parseZiskSteps(bytes: []const u8) ?u64 {
    const needle = "steps=";
    const start = std.mem.indexOf(u8, bytes, needle) orelse return null;
    var cursor = start + needle.len;
    const digits_start = cursor;
    while (cursor < bytes.len and std.ascii.isDigit(bytes[cursor])) cursor += 1;
    if (cursor == digits_start) return null;
    return std.fmt.parseInt(u64, bytes[digits_start..cursor], 10) catch null;
}

fn stepGatePasses(baseline: u64, candidate: u64) bool {
    return candidate <= baseline;
}

fn isSelfContainedPayload(payload: []const u8) bool {
    return std.mem.eql(u8, payload, "basic") or
        std.mem.eql(u8, payload, "stateless-smoke") or
        std.mem.eql(u8, payload, "stateless-ssz-smoke") or
        std.mem.eql(u8, payload, "stateless-ere-smoke");
}

fn termOk(term: std.process.Child.Term) bool {
    return switch (term) {
        .exited => |code| code == 0,
        else => false,
    };
}

fn printUsage() void {
    std.debug.print(
        \\usage: zig build guest-zisk-ab -- --baseline-tree PATH --ziskemu PATH --ziskos-staticlib PATH [options]
        \\
        \\Builds identical self-contained ZisK payloads from baseline and candidate
        \\source trees, verifies byte-identical public output, and fails when the
        \\candidate executes more ZisK steps. Defaults to `basic` and
        \\`stateless-smoke` in ReleaseFast.
        \\
        \\options:
        \\  --candidate-tree PATH       default: current directory
        \\  --payload NAME              repeatable; overrides default payload set
        \\  --max-steps N               default: 5000000
        \\  --work-dir PATH             default: zig-out/guest/zisk-ab
        \\  --global-cache-dir PATH     shared Zig package cache for both trees
        \\  --system-package-dir PATH   disable fetching and use this package directory
        \\  --report-only               report regressions without failing
        \\
    , .{});
}

test "parses ZisK process step output" {
    try std.testing.expectEqual(@as(?u64, 31_834), parseZiskSteps("process_rom() steps=31834 duration=0.001"));
    try std.testing.expectEqual(@as(?u64, null), parseZiskSteps("STEPS: 31834"));
    try std.testing.expectEqual(@as(?u64, null), parseZiskSteps("process_rom() steps= duration=0.001"));
}

test "guest step gate accepts equal or improved candidates only" {
    try std.testing.expect(stepGatePasses(100, 99));
    try std.testing.expect(stepGatePasses(100, 100));
    try std.testing.expect(!stepGatePasses(100, 101));
}

test "guest A/B accepts only self-contained payloads" {
    try std.testing.expect(isSelfContainedPayload("basic"));
    try std.testing.expect(isSelfContainedPayload("stateless-smoke"));
    try std.testing.expect(!isSelfContainedPayload("stateless-ere"));
    try std.testing.expect(!isSelfContainedPayload("../basic"));
}
