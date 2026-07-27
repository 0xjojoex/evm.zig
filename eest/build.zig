const std = @import("std");

// `b.option` validates these and lists them in `zig build --help`. The values
// are forwarded verbatim to the evmz dependency, which resolves the accelerated
// backends against the profile and target.
const Profile = enum { native, zkvm };
const KeccakBackend = enum { std, xkcp };
const Secp256k1Backend = enum { std, libsecp256k1 };

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for EEST benchmark-style runners",
    ) orelse .ReleaseFast;
    const profile = b.option(Profile, "profile", "Build profile") orelse .native;
    const native_keccak = b.option(KeccakBackend, "native-keccak", "Native Keccak backend") orelse .std;
    const native_secp256k1 = b.option(Secp256k1Backend, "native-secp256k1", "Native secp256k1 backend") orelse .std;

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
        .@"native-secp256k1" = native_secp256k1,
    });
    const evmz_mod = evmz_dep.module("evmz");
    const ssz_mod = evmz_dep.module("ssz");
    const snappy_mod = b.dependency("snappy", .{
        .target = target,
        .optimize = optimize,
    }).module("snappyz");

    const bench_evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = bench_optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
        .@"native-secp256k1" = native_secp256k1,
    });
    const bench_evmz_mod = bench_evmz_dep.module("evmz");

    {
        const eest_tests = b.addTest(.{
            .root_module = eestModule(b, "src/test.zig", target, optimize, evmz_mod),
            .filters = b.args orelse &.{},
        });
        // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
        // Match the root test lane and compile the evmz-backed test root with LLVM.
        eest_tests.use_llvm = true;
        const ssz_tests = b.addTest(.{
            .root_module = sszConformanceModule(b, "src/ssz_test.zig", target, optimize, ssz_mod, snappy_mod),
            .filters = b.args orelse &.{},
        });

        const test_step = b.step("test", "Run EEST runner tests");
        test_step.dependOn(&b.addRunArtifact(eest_tests).step);
        test_step.dependOn(&b.addRunArtifact(ssz_tests).step);
    }

    {
        const ssz_conformance_exe = b.addExecutable(.{
            .name = "evmz-ssz-conformance",
            .root_module = sszConformanceModule(b, "src/ssz_main.zig", target, optimize, ssz_mod, snappy_mod),
        });
        b.installArtifact(ssz_conformance_exe);
        addStep(b, ssz_conformance_exe, "ssz-conformance", "Run consensus-spec General, Mainnet, and Minimal SSZ fixtures", &.{});
    }

    {
        // The ERE benchmark runner is its own executable so it can build at
        // `bench_optimize` against a matching evmz; everything else shares one.
        const ere_bench_exe = b.addExecutable(.{
            .name = "evmz-zkevm-ere-bench",
            .root_module = eestModule(b, "src/ere_bench_main.zig", target, bench_optimize, bench_evmz_mod),
        });
        b.installArtifact(ere_bench_exe);
        addStep(b, ere_bench_exe, "zkevm-ere-bench", "Emit ERE BenchmarkRun rows for zkEVM stateless fixtures", &.{});
    }

    {
        const eest_exe = b.addExecutable(.{
            .name = "evmz-eest",
            .root_module = eestModule(b, "src/main.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(eest_exe);

        addStep(b, eest_exe, "eest", "Run EEST state-test fixtures", &.{"state"});
        addStep(b, eest_exe, "eest-classify", "Classify EEST state-test fixtures in one runner process", &.{ "state", "--classify" });
        addStep(b, eest_exe, "eest-scope", "Report downloaded EEST fixture scope and support status", &.{ "state", "--scope" });
        addStep(b, eest_exe, "eest-tx", "Run EEST raw transaction-test fixtures", &.{"tx"});
        addStep(b, eest_exe, "zkevm", "Run EEST zkEVM stateless SSZ fixtures", &.{"zkevm"});
        addStep(b, eest_exe, "zkevm-mutations", "Run typed stateless mutation rejection fixtures", &.{"zkevm-mutations"});
        addStep(b, eest_exe, "zkevm-input", "Extract one EEST zkEVM stateless input as ZisK stdin", &.{"zkevm-input"});
        addStep(b, eest_exe, "zkevm-ere", "Run raw ERE stateless input through native adapter", &.{"zkevm-ere"});
        addStep(b, eest_exe, "eest-block-stf", "Run regular EEST blockchain_tests through BlockSTF", &.{"block-stf"});
        addStep(
            b,
            eest_exe,
            "eest-stateless-block-stf",
            "Run witness-backed zkEVM blockchain fixtures through stateless BlockSTF",
            &.{"stateless-block-stf"},
        );
    }
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
    if (b.args) |args| run.addArgs(args);
    b.step(step_name, description).dependOn(&run.step);
}

fn sszConformanceModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    ssz_mod: *std.Build.Module,
    snappy_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "ssz", .module = ssz_mod },
            .{ .name = "snappyz", .module = snappy_mod },
        },
    });
}

fn eestModule(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmz_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
        },
    });
}
