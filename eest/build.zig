const std = @import("std");

// `b.option` validates these and lists them in `zig build --help`. The values
// are forwarded verbatim to the evmz dependency, which resolves the accelerated
// backends against the profile and target.
const Profile = enum { native, zkvm };
const KeccakBackend = enum { std, xkcp };

pub fn build(b: *std.Build) void {
    const test_filters = b.option([]const []const u8, "test-filter", "Compile only matching tests (repeatable)") orelse &.{};
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const pinned_consensus_fixtures = b.option(
        bool,
        "pinned-consensus-fixtures",
        "Use consensus fixtures pinned in consensus.zon when no path is given",
    ) orelse false;
    const profile = b.option(Profile, "profile", "Build profile") orelse .native;
    const native_keccak = b.option(KeccakBackend, "native-keccak", "Native Keccak backend") orelse .xkcp;
    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
    });
    const evmz_mod = evmz_dep.module("evmz");
    const ssz_mod = evmz_dep.module("ssz");
    const snappy_mod = b.createModule(.{
        .root_source_file = b.path("vendor/snappy/snappy.zig"),
        .target = target,
        .optimize = optimize,
    });

    {
        const eest_tests = b.addTest(.{
            .root_module = eestModule(b, "src/test.zig", target, optimize, evmz_mod, evmz_dep.module("fixtures"), evmz_dep.module("statetest"), evmz_dep.module("blocktest")),
            .filters = test_filters,
            .test_runner = .{ .path = evmz_dep.path("tools/test_runner.zig"), .mode = .simple },
        });
        // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
        // Match the root test lane and compile the evmz-backed test root with LLVM.
        eest_tests.use_llvm = true;
        const ssz_tests = b.addTest(.{
            .root_module = sszConformanceModule(b, "src/ssz_test.zig", target, optimize, ssz_mod, snappy_mod),
            .filters = test_filters,
            .test_runner = .{ .path = evmz_dep.path("tools/test_runner.zig"), .mode = .simple },
        });

        const test_step = b.step("test", "Run EEST runner tests");
        const run_eest_tests = b.addRunArtifact(eest_tests);
        run_eest_tests.addPassthruArgs();
        test_step.dependOn(&run_eest_tests.step);
        const run_ssz_tests = b.addRunArtifact(ssz_tests);
        run_ssz_tests.addPassthruArgs();
        test_step.dependOn(&run_ssz_tests.step);
    }

    {
        const ssz_conformance_exe = b.addExecutable(.{
            .name = "evmz-ssz-conformance",
            .root_module = sszConformanceModule(b, "src/ssz_main.zig", target, optimize, ssz_mod, snappy_mod),
        });
        b.installArtifact(ssz_conformance_exe);
        const run = b.addRunArtifact(ssz_conformance_exe);
        if (pinned_consensus_fixtures) {
            run.addArgs(&.{ "--pinned-consensus-fixtures", "--zig-exe" });
            run.addFileArg2(.zig_exe, .{ .make_absolute = true });
            run.addArg("--zig-global-cache");
            run.addDirectoryArg2(.{ .relative = .{ .base = .global_cache } }, .{ .make_absolute = true });
        }
        run.setCwd(b.path(".."));
        run.addPassthruArgs();
        b.step(
            "ssz-conformance",
            "Run consensus-spec General, Mainnet, and Minimal SSZ fixtures",
        ).dependOn(&run.step);
    }

    {
        const eest_exe = b.addExecutable(.{
            .name = "evmz-eest",
            .root_module = eestModule(b, "src/main.zig", target, optimize, evmz_mod, evmz_dep.module("fixtures"), evmz_dep.module("statetest"), evmz_dep.module("blocktest")),
        });
        b.installArtifact(eest_exe);

        addStep(b, eest_exe, "zkevm", "Run EEST zkEVM stateless SSZ fixtures", &.{"zkevm"});
        addStep(b, eest_exe, "zkevm-mutations", "Run typed stateless mutation rejection fixtures", &.{
            "zkevm-mutations",
            "--manifest",
            "fixtures/stateless-mutations-tests-zkevm.txt",
        });
        addStep(b, eest_exe, "zkevm-input", "Extract one EEST zkEVM stateless input for a zkVM guest", &.{"zkevm-input"});
        addStep(b, eest_exe, "zkevm-ere", "Run raw ERE stateless input through native adapter", &.{"zkevm-ere"});

        addConsumeStep(
            b,
            eest_exe,
            "consume",
            "Run execution-spec fixtures through consume direct",
            default_execution_input,
            "evmz_consumer",
            direct_selection,
            ".zig-cache/eest-consume/logs",
        );
        addConsumeStep(
            b,
            eest_exe,
            "consume-zkevm",
            "Run tests-zkevm fixtures through consume direct",
            default_zkevm_input,
            "evmz_zkevm_consumer",
            "blockchain_test",
            ".zig-cache/eest-consume/zkevm-logs",
        );
        addResolveZkevmStep(b);
    }
}

const default_execution_input = "tests@v21.0.2";
const default_zkevm_input = "tests-zkevm@v21.0.6";

const direct_selection =
    "state_test or transaction_test or (blockchain_test and " ++
    "(Paris or Shanghai or Cancun or Prague or Osaka or Amsterdam or " ++
    "BPO1 or BPO2 or AmsterdamBPOIncrease or AmsterdamBPODecrease) and not " ++
    "(ParisToShanghaiAtTime15k or ShanghaiToCancunAtTime15k or " ++
    "CancunToPragueAtTime15k or PragueToOsakaAtTime15k or " ++
    "OsakaToBPO1AtTime15k or BPO1ToBPO2AtTime15k or " ++
    "AmsterdamToBPOIncreaseAtTime15k or AmsterdamToBPODecreaseAtTime15k or " ++
    "BPO2ToAmsterdamAtTime15k))";

fn addConsumeStep(
    b: *std.Build,
    eest_exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    input: []const u8,
    plugin: []const u8,
    selection: []const u8,
    log_dir: []const u8,
) void {
    const consume = consumeCommand(b);
    consume.addArgs(&.{
        "consume",
        "direct",
        "--input",
        input,
        "--log-to",
        log_dir,
        "--bin",
    });
    consume.addFileArg(eest_exe.getEmittedBin());
    consume.addArgs(&.{ "-p", plugin, "-m", selection, "--dist=loadgroup" });
    consume.addPassthruArgs();
    b.step(step_name, description).dependOn(&consume.step);
}

fn addResolveZkevmStep(b: *std.Build) void {
    const resolve = consumeCommand(b);
    resolve.addArgs(&.{
        "python",
        "-m",
        "evmz_fixture_source",
        "--input",
        default_zkevm_input,
        "--manifest",
        ".zig-cache/eest-consume/zkevm-corpus.json",
    });
    resolve.addPassthruArgs();
    b.step("resolve-zkevm", "Resolve tests-zkevm through execution-specs").dependOn(&resolve.step);
}

fn consumeCommand(b: *std.Build) *std.Build.Step.Run {
    const consume = b.addSystemCommand(&.{ "uv", "run", "--frozen", "--project" });
    consume.addDirectoryArg(b.path("consume"));
    // uv may reuse a git checkout through a local file URL.
    consume.setEnvironmentVariable("GIT_ALLOW_PROTOCOL", "file:https");
    consume.setCwd(b.path(".."));
    return consume;
}

/// Names a `zig build` step that runs `exe` with a fixed argument prefix,
/// then whatever the caller passed after `--`.
fn addStep(
    b: *std.Build,
    exe: *std.Build.Step.Compile,
    step_name: []const u8,
    description: []const u8,
    prefix: []const []const u8,
) void {
    const run = b.addRunArtifact(exe);
    run.addArgs(prefix);
    run.addPassthruArgs();
    b.step(step_name, description).dependOn(&run.step);
}

fn sszConformanceModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    ssz_mod: *std.Build.Module,
    snappy_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "consensus_pins", .module = b.createModule(.{ .root_source_file = b.path("consensus.zon") }) },
            .{ .name = "ssz", .module = ssz_mod },
            .{ .name = "snappyz", .module = snappy_mod },
        },
    });
}

fn eestModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.lang.Optimize,
    evmz_mod: *std.Build.Module,
    fixtures_mod: *std.Build.Module,
    statetest_mod: *std.Build.Module,
    blocktest_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "fixtures", .module = fixtures_mod },
            .{ .name = "statetest", .module = statetest_mod },
            .{ .name = "blocktest", .module = blocktest_mod },
        },
    });
}
