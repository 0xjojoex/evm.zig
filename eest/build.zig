const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode for the EEST benchmark runner",
    ) orelse .ReleaseFast;
    const profile = buildProfileOption(b);

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
    });
    const evmz_mod = evmz_dep.module("evmz");

    const bench_evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = bench_optimize,
        .profile = profile,
    });
    const bench_evmz_mod = bench_evmz_dep.module("evmz");

    const evmone_dep = b.dependency("evmone", .{ .target = target, .optimize = bench_optimize });
    const intx_dep = b.dependency("intx", .{ .target = target, .optimize = bench_optimize });

    {
        const state_tests = b.addTest(.{
            .root_module = eestModule(b, "src/state.zig", target, optimize, evmz_mod),
        });
        const tx_tests = b.addTest(.{
            .root_module = eestModule(b, "src/tx.zig", target, optimize, evmz_mod),
        });

        const bench_tests_mod = eestModule(b, "src/bench.zig", target, optimize, evmz_mod);
        addEvmoneVm(bench_tests_mod, evmz_dep, evmone_dep, intx_dep);
        const bench_tests = b.addTest(.{ .root_module = bench_tests_mod });

        const test_step = b.step("test", "Run EEST runner tests");
        test_step.dependOn(&b.addRunArtifact(state_tests).step);
        test_step.dependOn(&b.addRunArtifact(tx_tests).step);
        test_step.dependOn(&b.addRunArtifact(bench_tests).step);
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
        const bench_mod = eestModule(b, "src/bench_cli.zig", target, bench_optimize, bench_evmz_mod);
        addEvmoneVm(bench_mod, bench_evmz_dep, evmone_dep, intx_dep);
        const bench_exe = b.addExecutable(.{
            .name = "evmz-eest-bench",
            .root_module = bench_mod,
        });
        b.installArtifact(bench_exe);

        const run_bench = b.addRunArtifact(bench_exe);
        if (b.args) |args| run_bench.addArgs(args);
        b.step("bench", "Run EEST benchmark blockchain-test fixtures").dependOn(&run_bench.step);
    }
}

fn buildProfileOption(b: *std.Build) []const u8 {
    const profile = b.option([]const u8, "profile", "Build profile: native or zkvm") orelse "native";
    if (!std.mem.eql(u8, profile, "native") and !std.mem.eql(u8, profile, "zkvm")) {
        std.debug.panic("unsupported profile '{s}' (expected native or zkvm)", .{profile});
    }
    return profile;
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

fn addEvmoneVm(
    module: *std.Build.Module,
    evmz_dep: *std.Build.Dependency,
    evmone_dep: *std.Build.Dependency,
    intx_dep: *std.Build.Dependency,
) void {
    const cxx_flags = &[_][]const u8{
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Wno-missing-field-initializers",
        "-fno-exceptions",
        "-fno-rtti",
        "-DPROJECT_VERSION=\"0.22.0\"",
    };
    const c_flags = &[_][]const u8{
        "-Wall",
        "-Wextra",
    };

    module.addIncludePath(evmz_dep.path("include"));
    module.addIncludePath(evmone_dep.path("evmc/include"));
    module.addIncludePath(evmone_dep.path("include"));
    module.addIncludePath(evmone_dep.path("lib"));
    module.addIncludePath(intx_dep.path("include"));

    const sources = &[_][]const u8{
        "lib/evmone/advanced_analysis.cpp",
        "lib/evmone/advanced_execution.cpp",
        "lib/evmone/advanced_instructions.cpp",
        "lib/evmone/baseline_analysis.cpp",
        "lib/evmone/baseline_execution.cpp",
        "lib/evmone/baseline_instruction_table.cpp",
        "lib/evmone/delegation.cpp",
        "lib/evmone/instructions_calls.cpp",
        "lib/evmone/instructions_storage.cpp",
        "lib/evmone/tracing.cpp",
        "lib/evmone/vm.cpp",
    };
    for (sources) |source| {
        module.addCSourceFile(.{ .file = evmone_dep.path(source), .flags = cxx_flags });
    }
    module.addCSourceFile(.{ .file = evmone_dep.path("lib/evmone_precompiles/keccak.c"), .flags = c_flags });
}
