const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for EEST benchmark-style runners",
    ) orelse .ReleaseFast;
    const profile = buildProfileOption(b);
    const native_keccak = nativeKeccakOption(b, profile);

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
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
    });
    const bench_evmz_mod = bench_evmz_dep.module("evmz");

    {
        const state_tests = b.addTest(.{
            .root_module = eestModule(b, "src/state.zig", target, optimize, evmz_mod),
        });
        const state_cli_tests = b.addTest(.{
            .root_module = eestModule(b, "src/state_cli.zig", target, optimize, evmz_mod),
        });
        const tx_tests = b.addTest(.{
            .root_module = eestModule(b, "src/tx.zig", target, optimize, evmz_mod),
        });

        const stateless_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless.zig", target, optimize, evmz_mod),
        });
        const stateless_cli_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless_cli.zig", target, optimize, evmz_mod),
        });
        const stateless_input_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless_input_cli.zig", target, optimize, evmz_mod),
        });
        const stateless_ere_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless_ere_cli.zig", target, optimize, evmz_mod),
        });
        const stateless_ere_bench_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless_ere_bench.zig", target, optimize, evmz_mod),
        });
        const block_stf_tests = b.addTest(.{
            .root_module = eestModule(b, "src/block_stf.zig", target, optimize, evmz_mod),
        });
        const block_stf_cli_tests = b.addTest(.{
            .root_module = eestModule(b, "src/block_stf_cli.zig", target, optimize, evmz_mod),
        });
        const stateless_block_stf_tests = b.addTest(.{
            .root_module = eestModule(b, "src/stateless_block_stf.zig", target, optimize, evmz_mod),
        });
        // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
        // Match the root test lane and compile evmz-backed tests with LLVM.
        for ([_]*std.Build.Step.Compile{
            state_tests,
            state_cli_tests,
            tx_tests,
            stateless_tests,
            stateless_cli_tests,
            stateless_input_tests,
            stateless_ere_tests,
            stateless_ere_bench_tests,
            block_stf_tests,
            block_stf_cli_tests,
            stateless_block_stf_tests,
        }) |test_artifact| {
            test_artifact.use_llvm = true;
        }
        const ssz_conformance_tests = b.addTest(.{
            .root_module = sszConformanceModule(b, "src/ssz_conformance.zig", target, optimize, ssz_mod, snappy_mod),
        });
        const ssz_conformance_cli_tests = b.addTest(.{
            .root_module = sszConformanceModule(b, "src/ssz_conformance_cli.zig", target, optimize, ssz_mod, snappy_mod),
        });

        const test_step = b.step("test", "Run EEST runner tests");
        test_step.dependOn(&b.addRunArtifact(state_tests).step);
        test_step.dependOn(&b.addRunArtifact(state_cli_tests).step);
        test_step.dependOn(&b.addRunArtifact(tx_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_cli_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_input_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_ere_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_ere_bench_tests).step);
        test_step.dependOn(&b.addRunArtifact(block_stf_tests).step);
        test_step.dependOn(&b.addRunArtifact(block_stf_cli_tests).step);
        test_step.dependOn(&b.addRunArtifact(stateless_block_stf_tests).step);
        test_step.dependOn(&b.addRunArtifact(ssz_conformance_tests).step);
        test_step.dependOn(&b.addRunArtifact(ssz_conformance_cli_tests).step);
    }

    {
        const ssz_conformance_exe = b.addExecutable(.{
            .name = "evmz-ssz-conformance",
            .root_module = sszConformanceModule(
                b,
                "src/ssz_conformance_cli.zig",
                target,
                optimize,
                ssz_mod,
                snappy_mod,
            ),
        });
        b.installArtifact(ssz_conformance_exe);

        const run_ssz_conformance = b.addRunArtifact(ssz_conformance_exe);
        if (b.args) |args| run_ssz_conformance.addArgs(args);
        b.step("ssz-conformance", "Run consensus-spec General, Mainnet, and Minimal SSZ fixtures").dependOn(&run_ssz_conformance.step);
    }

    {
        const state_exe = b.addExecutable(.{
            .name = "evmz-eest",
            .root_module = eestModule(b, "src/state_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(state_exe);

        const run_eest = b.addRunArtifact(state_exe);
        if (b.args) |args| run_eest.addArgs(args);
        b.step("eest", "Run EEST state-test fixtures").dependOn(&run_eest.step);

        const run_classify = b.addRunArtifact(state_exe);
        run_classify.addArg("--classify");
        if (b.args) |args| run_classify.addArgs(args);
        b.step("eest-classify", "Classify EEST state-test fixtures in one runner process").dependOn(&run_classify.step);

        const run_scope = b.addRunArtifact(state_exe);
        run_scope.addArg("--scope");
        if (b.args) |args| run_scope.addArgs(args);
        b.step("eest-scope", "Report downloaded EEST fixture scope and support status").dependOn(&run_scope.step);
    }

    {
        const tx_exe = b.addExecutable(.{
            .name = "evmz-eest-tx",
            .root_module = eestModule(b, "src/tx_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(tx_exe);

        const run_tx = b.addRunArtifact(tx_exe);
        if (b.args) |args| run_tx.addArgs(args);
        b.step("eest-tx", "Run EEST raw transaction-test fixtures").dependOn(&run_tx.step);
    }

    {
        const stateless_exe = b.addExecutable(.{
            .name = "evmz-zkevm",
            .root_module = eestModule(b, "src/stateless_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(stateless_exe);

        const run_stateless = b.addRunArtifact(stateless_exe);
        if (b.args) |args| run_stateless.addArgs(args);
        b.step("zkevm", "Run EEST zkEVM stateless SSZ fixtures").dependOn(&run_stateless.step);
    }

    {
        const stateless_input_exe = b.addExecutable(.{
            .name = "evmz-zkevm-input",
            .root_module = eestModule(b, "src/stateless_input_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(stateless_input_exe);

        const run_stateless_input = b.addRunArtifact(stateless_input_exe);
        if (b.args) |args| run_stateless_input.addArgs(args);
        b.step("zkevm-input", "Extract one EEST zkEVM stateless input as ZisK stdin").dependOn(&run_stateless_input.step);
    }

    {
        const stateless_ere_exe = b.addExecutable(.{
            .name = "evmz-zkevm-ere",
            .root_module = eestModule(b, "src/stateless_ere_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(stateless_ere_exe);

        const run_stateless_ere = b.addRunArtifact(stateless_ere_exe);
        if (b.args) |args| run_stateless_ere.addArgs(args);
        b.step("zkevm-ere", "Run raw ERE stateless input through native adapter").dependOn(&run_stateless_ere.step);
    }

    {
        const stateless_ere_bench_exe = b.addExecutable(.{
            .name = "evmz-zkevm-ere-bench",
            .root_module = eestModule(b, "src/stateless_ere_bench_cli.zig", target, bench_optimize, bench_evmz_mod),
        });
        b.installArtifact(stateless_ere_bench_exe);

        const run_stateless_ere_bench = b.addRunArtifact(stateless_ere_bench_exe);
        if (b.args) |args| run_stateless_ere_bench.addArgs(args);
        b.step("zkevm-ere-bench", "Emit ERE BenchmarkRun rows for zkEVM stateless fixtures").dependOn(&run_stateless_ere_bench.step);
    }

    {
        const block_stf_exe = b.addExecutable(.{
            .name = "evmz-eest-block-stf",
            .root_module = eestModule(b, "src/block_stf_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(block_stf_exe);

        const run_block_stf = b.addRunArtifact(block_stf_exe);
        if (b.args) |args| run_block_stf.addArgs(args);
        b.step("eest-block-stf", "Run regular EEST blockchain_tests through BlockSTF").dependOn(&run_block_stf.step);
    }

    {
        const stateless_block_stf_exe = b.addExecutable(.{
            .name = "evmz-eest-stateless-block-stf",
            .root_module = eestModule(b, "src/stateless_block_stf_cli.zig", target, optimize, evmz_mod),
        });
        b.installArtifact(stateless_block_stf_exe);

        const run_stateless_block_stf = b.addRunArtifact(stateless_block_stf_exe);
        if (b.args) |args| run_stateless_block_stf.addArgs(args);
        b.step("eest-stateless-block-stf", "Run witness-backed zkEVM blockchain fixtures through stateless BlockSTF").dependOn(&run_stateless_block_stf.step);
    }
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

fn buildProfileOption(b: *std.Build) []const u8 {
    const profile = b.option([]const u8, "profile", "Build profile: native or zkvm") orelse "native";
    if (!std.mem.eql(u8, profile, "native") and !std.mem.eql(u8, profile, "zkvm")) {
        std.debug.panic("unsupported profile '{s}' (expected native or zkvm)", .{profile});
    }
    return profile;
}

fn nativeKeccakOption(b: *std.Build, profile: []const u8) []const u8 {
    const backend = b.option([]const u8, "native-keccak", "Native Keccak backend: std or xkcp") orelse "std";
    if (!std.mem.eql(u8, backend, "std") and !std.mem.eql(u8, backend, "xkcp")) {
        std.debug.panic("unsupported native Keccak backend '{s}' (expected std or xkcp)", .{backend});
    }
    return if (std.mem.eql(u8, profile, "native")) backend else "std";
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
