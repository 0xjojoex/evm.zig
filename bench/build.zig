const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const micro_optimize = b.option(
        std.builtin.OptimizeMode,
        "micro-optimize",
        "Optimization mode for micro benchmark tests",
    ) orelse if (optimize == .Debug) .ReleaseFast else optimize;
    const compare_optimize = if (optimize == .Debug) .ReleaseFast else optimize;
    const micro_filter = b.option(
        []const u8,
        "micro-filter",
        "Only run micro benchmark tests whose names contain this filter",
    );

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
    });
    const evmone_dep = b.dependency("evmone", .{ .target = target, .optimize = optimize });
    const intx_dep = b.dependency("intx", .{ .target = target, .optimize = optimize });
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = micro_optimize });
    const evmz_mod = evmz_dep.module("evmz");

    {
        const vm_loop_mod = benchModule(b, "src/vm_loop.zig", target, optimize, evmz_mod);
        const vm_loop = b.addExecutable(.{
            .name = "evmz-vm-loop",
            .root_module = vm_loop_mod,
        });
        b.installArtifact(vm_loop);

        const run_vm_loop = b.addRunArtifact(vm_loop);
        if (b.args) |args| run_vm_loop.addArgs(args);
        b.step("vm-loop", "Run evmz VM-loop fixture runner").dependOn(&run_vm_loop.step);
    }

    {
        const host_boundary_mod = benchModule(b, "src/host_boundary.zig", target, optimize, evmz_mod);
        const host_boundary = b.addExecutable(.{
            .name = "evmz-host-boundary",
            .root_module = host_boundary_mod,
        });
        b.installArtifact(host_boundary);

        const run_host_boundary = b.addRunArtifact(host_boundary);
        if (b.args) |args| run_host_boundary.addArgs(args);
        b.step("host-boundary", "Run host-boundary benchmark runner").dependOn(&run_host_boundary.step);
    }

    {
        const host_matrix_mod = benchModule(b, "src/host_matrix.zig", target, optimize, evmz_mod);
        const host_matrix = b.addExecutable(.{
            .name = "evmz-host-matrix",
            .root_module = host_matrix_mod,
        });
        b.installArtifact(host_matrix);

        const run_host_matrix = b.addRunArtifact(host_matrix);
        if (b.args) |args| run_host_matrix.addArgs(args);
        b.step("host-matrix", "Run host-boundary CSV matrix").dependOn(&run_host_matrix.step);
    }

    {
        const kernel_mod = benchModule(b, "src/kernel.zig", target, optimize, evmz_mod);
        addEvmoneVm(kernel_mod, evmone_dep, intx_dep);
        const kernel = b.addExecutable(.{
            .name = "evmz-kernel",
            .root_module = kernel_mod,
        });
        b.installArtifact(kernel);

        const run_kernel = b.addRunArtifact(kernel);
        if (b.args) |args| run_kernel.addArgs(args);
        b.step("kernel", "Run pure opcode kernel benchmark").dependOn(&run_kernel.step);
    }

    {
        const code_analysis_mod = benchModule(b, "src/code_analysis.zig", target, optimize, evmz_mod);
        const code_analysis = b.addExecutable(.{
            .name = "evmz-code-analysis",
            .root_module = code_analysis_mod,
        });
        b.installArtifact(code_analysis);

        const run_code_analysis = b.addRunArtifact(code_analysis);
        if (b.args) |args| run_code_analysis.addArgs(args);
        b.step("code-analysis", "Run code-analysis morphology and timing report").dependOn(&run_code_analysis.step);
    }

    {
        const run_revm_kernel = b.addSystemCommand(&.{
            "cargo",
            "run",
            "--quiet",
            "--release",
            "--manifest-path",
            "revm/Cargo.toml",
            "--",
        });
        run_revm_kernel.setCwd(b.path("."));
        if (b.args) |args| run_revm_kernel.addArgs(args);
        b.step("revm-kernel", "Run revm opcode kernel benchmark").dependOn(&run_revm_kernel.step);
    }

    {
        const run_revm_vm_loop = b.addSystemCommand(&.{
            "cargo",
            "run",
            "--quiet",
            "--release",
            "--manifest-path",
            "revm/Cargo.toml",
            "--",
            "vm-loop",
        });
        run_revm_vm_loop.setCwd(b.path("."));
        if (b.args) |args| run_revm_vm_loop.addArgs(args);
        b.step("revm-vm-loop", "Run revm VM-loop fixture runner").dependOn(&run_revm_vm_loop.step);
    }

    {
        const evmone_vm_loop_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        addEvmoneVm(evmone_vm_loop_mod, evmone_dep, intx_dep);
        evmone_vm_loop_mod.addCSourceFile(.{
            .file = b.path("evmone/vm_loop.cpp"),
            .flags = &[_][]const u8{
                "-std=c++20",
                "-Wall",
                "-Wextra",
                "-Wno-missing-field-initializers",
                "-fno-rtti",
            },
        });
        const evmone_vm_loop = b.addExecutable(.{
            .name = "evmone-vm-loop",
            .root_module = evmone_vm_loop_mod,
        });
        b.installArtifact(evmone_vm_loop);

        const run_evmone_vm_loop = b.addRunArtifact(evmone_vm_loop);
        if (b.args) |args| run_evmone_vm_loop.addArgs(args);
        b.step("evmone-vm-loop", "Run standalone evmone VM-loop fixture runner").dependOn(&run_evmone_vm_loop.step);
    }

    {
        const compare_mod = b.createModule(.{
            .root_source_file = b.path("src/compare.zig"),
            .target = target,
            .optimize = compare_optimize,
        });
        const compare = b.addExecutable(.{
            .name = "evmz-compare",
            .root_module = compare_mod,
        });
        b.installArtifact(compare);

        const run_compare = b.addRunArtifact(compare);
        run_compare.setCwd(b.path("."));
        run_compare.addArgs(&.{
            "--zig-exe",
            b.graph.zig_exe,
            "--optimize",
            @tagName(compare_optimize),
        });
        if (b.args) |args| run_compare.addArgs(args);
        b.step("compare", "Run VM-core comparison").dependOn(&run_compare.step);
    }

    {
        const run_report = b.addSystemCommand(&.{
            "python3",
            "scripts/report.py",
            "--zig-exe",
            b.graph.zig_exe,
        });
        run_report.setCwd(b.path("."));
        if (b.args) |args| run_report.addArgs(args);
        b.step("report", "Run all benchmark layers and write a comparison report").dependOn(&run_report.step);
    }

    {
        const zbench_mod = b.createModule(.{
            .root_source_file = zbench_dep.path("src/zbench.zig"),
            .target = target,
            .optimize = micro_optimize,
        });
        const micro_mod = benchModule(b, "src/micro.zig", target, micro_optimize, evmz_mod);
        micro_mod.addImport("zbench", zbench_mod);
        const micro_filters: []const []const u8 = if (micro_filter) |filter| &.{filter} else &.{};
        const micro_tests = b.addTest(.{
            .root_module = micro_mod,
            .filters = micro_filters,
            .test_runner = .{
                .path = b.path("src/micro_test_runner.zig"),
                .mode = .simple,
            },
        });
        const run_micro = b.addRunArtifact(micro_tests);
        run_micro.stdio = .inherit;
        run_micro.has_side_effects = true;
        b.step("micro", "Run focused zBench micro benchmarks").dependOn(&run_micro.step);
    }

    {
        const common_tests = b.addTest(.{
            .root_module = benchModule(b, "src/common.zig", target, optimize, evmz_mod),
        });
        const vm_loop_tests = b.addTest(.{
            .root_module = benchModule(b, "src/vm_loop.zig", target, optimize, evmz_mod),
        });
        const host_boundary_tests = b.addTest(.{
            .root_module = benchModule(b, "src/host_boundary.zig", target, optimize, evmz_mod),
        });
        const host_matrix_tests = b.addTest(.{
            .root_module = benchModule(b, "src/host_matrix.zig", target, optimize, evmz_mod),
        });
        const kernel_tests = b.addTest(.{
            .root_module = blk: {
                const kernel_test_mod = benchModule(b, "src/kernel.zig", target, optimize, evmz_mod);
                addEvmoneVm(kernel_test_mod, evmone_dep, intx_dep);
                break :blk kernel_test_mod;
            },
        });
        const code_analysis_tests = b.addTest(.{
            .root_module = benchModule(b, "src/code_analysis.zig", target, optimize, evmz_mod),
        });
        const compare_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compare.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const test_step = b.step("test", "Run benchmark sidecar tests");
        test_step.dependOn(&b.addRunArtifact(common_tests).step);
        test_step.dependOn(&b.addRunArtifact(vm_loop_tests).step);
        test_step.dependOn(&b.addRunArtifact(host_boundary_tests).step);
        test_step.dependOn(&b.addRunArtifact(host_matrix_tests).step);
        test_step.dependOn(&b.addRunArtifact(kernel_tests).step);
        test_step.dependOn(&b.addRunArtifact(code_analysis_tests).step);
        test_step.dependOn(&b.addRunArtifact(compare_tests).step);
    }
}

fn addEvmoneVm(module: *std.Build.Module, evmone_dep: *std.Build.Dependency, intx_dep: *std.Build.Dependency) void {
    module.link_libc = true;
    module.link_libcpp = true;
    module.addIncludePath(evmone_dep.path("evmc/include"));
    module.addIncludePath(evmone_dep.path("include"));
    module.addIncludePath(evmone_dep.path("lib"));
    module.addIncludePath(intx_dep.path("include"));

    const cxx_flags = &[_][]const u8{
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Wno-missing-field-initializers",
        "-Wno-unknown-attributes",
        "-fno-exceptions",
        "-fno-rtti",
        "-DPROJECT_VERSION=\"0.21.0\"",
    };
    const c_flags = &[_][]const u8{
        "-Wall",
        "-Wextra",
    };
    const evmone_sources = &[_][]const u8{
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
    for (evmone_sources) |source| {
        module.addCSourceFile(.{ .file = evmone_dep.path(source), .flags = cxx_flags });
    }
    module.addCSourceFile(.{ .file = evmone_dep.path("lib/evmone_precompiles/keccak.c"), .flags = c_flags });
}

fn benchModule(
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
