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
    const profile = buildProfileOption(b);
    const native_keccak = nativeKeccakOption(b, profile);

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
    });
    const evmone_dep = b.dependency("evmone", .{ .target = target, .optimize = optimize });
    const intx_dep = b.dependency("intx", .{ .target = target, .optimize = optimize });
    const zbench_dep = b.dependency("zbench", .{ .target = target, .optimize = micro_optimize });
    const evmone_libgcc = nativeEvmoneLibgcc(b, target);
    const evmz_mod = evmz_dep.module("evmz");
    evmz_mod.omit_frame_pointer = true;
    const vm_loop_support_min = b.option(
        []const u8,
        "bench-support-min",
        "Minimum Ethereum revision compiled into the VM-loop benchmark",
    ) orelse "frontier";
    const vm_loop_support_max = b.option(
        []const u8,
        "bench-support-max",
        "Maximum Ethereum revision compiled into the VM-loop benchmark",
    ) orelse "latest";
    const vm_loop_options = b.addOptions();
    vm_loop_options.addOption([]const u8, "support_min", vm_loop_support_min);
    vm_loop_options.addOption([]const u8, "support_max", vm_loop_support_max);
    const vm_loop_options_mod = vm_loop_options.createModule();

    {
        const vm_loop_mod = benchModule(b, "src/vm_loop.zig", target, optimize, evmz_mod);
        vm_loop_mod.addImport("build_options", vm_loop_options_mod);
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
        const block_lifecycle_mod = benchModule(b, "src/block_lifecycle.zig", target, optimize, evmz_mod);
        const block_lifecycle = b.addExecutable(.{
            .name = "evmz-block-lifecycle",
            .root_module = block_lifecycle_mod,
        });
        b.installArtifact(block_lifecycle);

        const run_block_lifecycle = b.addRunArtifact(block_lifecycle);
        if (b.args) |args| run_block_lifecycle.addArgs(args);
        b.step("block-lifecycle", "Run VM block lifecycle benchmark").dependOn(&run_block_lifecycle.step);
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
        addEvmoneVm(kernel_mod, evmone_dep, intx_dep, evmone_libgcc);
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
        addRevmNativeRustFlags(run_revm_kernel);
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
        addRevmNativeRustFlags(run_revm_vm_loop);
        if (b.args) |args| run_revm_vm_loop.addArgs(args);
        b.step("revm-vm-loop", "Run revm VM-loop fixture runner").dependOn(&run_revm_vm_loop.step);
    }

    {
        const evmone_vm_loop_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = true,
            .link_libc = true,
            .link_libcpp = true,
        });
        addEvmoneVm(evmone_vm_loop_mod, evmone_dep, intx_dep, evmone_libgcc);
        evmone_vm_loop_mod.addCSourceFile(.{
            .file = b.path("evmone/vm_loop.cpp"),
            .flags = &[_][]const u8{
                "-std=c++20",
                "-Wall",
                "-Wextra",
                "-Wno-missing-field-initializers",
                "-fomit-frame-pointer",
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
            "--profile",
            profile,
            "--native-keccak",
            native_keccak,
            "--support-min",
            vm_loop_support_min,
            "--support-max",
            vm_loop_support_max,
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
            "--profile",
            profile,
            "--native-keccak",
            native_keccak,
        });
        run_report.setCwd(b.path("."));
        if (b.args) |args| run_report.addArgs(args);
        b.step("report", "Run all benchmark layers and write a comparison report").dependOn(&run_report.step);
    }

    {
        const micro_evmz_dep = b.dependency("evmz", .{
            .target = target,
            .optimize = micro_optimize,
            .profile = profile,
            .@"native-keccak" = native_keccak,
        });
        const micro_evmz_mod = micro_evmz_dep.module("evmz");
        micro_evmz_mod.omit_frame_pointer = true;
        const zbench_mod = b.createModule(.{
            .root_source_file = zbench_dep.path("src/zbench.zig"),
            .target = target,
            .optimize = micro_optimize,
            .omit_frame_pointer = true,
        });
        const micro_mod = benchModule(b, "src/micro.zig", target, micro_optimize, micro_evmz_mod);
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
        const vm_loop_test_mod = benchModule(b, "src/vm_loop.zig", target, optimize, evmz_mod);
        vm_loop_test_mod.addImport("build_options", vm_loop_options_mod);
        const vm_loop_tests = b.addTest(.{
            .root_module = vm_loop_test_mod,
        });
        const block_lifecycle_tests = b.addTest(.{
            .root_module = benchModule(b, "src/block_lifecycle.zig", target, optimize, evmz_mod),
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
                addEvmoneVm(kernel_test_mod, evmone_dep, intx_dep, evmone_libgcc);
                break :blk kernel_test_mod;
            },
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
        test_step.dependOn(&b.addRunArtifact(block_lifecycle_tests).step);
        test_step.dependOn(&b.addRunArtifact(host_boundary_tests).step);
        test_step.dependOn(&b.addRunArtifact(host_matrix_tests).step);
        test_step.dependOn(&b.addRunArtifact(kernel_tests).step);
        test_step.dependOn(&b.addRunArtifact(compare_tests).step);
    }
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

fn addRevmNativeRustFlags(run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("RUSTFLAGS", "-C target-cpu=native -C force-frame-pointers=no");
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_LTO", "fat");
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "1");
}

fn addEvmoneVm(
    module: *std.Build.Module,
    evmone_dep: *std.Build.Dependency,
    intx_dep: *std.Build.Dependency,
    libgcc: ?std.Build.LazyPath,
) void {
    module.omit_frame_pointer = true;
    module.link_libc = true;
    module.link_libcpp = true;
    if (libgcc) |archive| module.addObjectFile(archive);
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
        "-fomit-frame-pointer",
        "-fno-exceptions",
        "-fno-rtti",
        "-DPROJECT_VERSION=\"0.22.0\"",
    };
    const c_flags = &[_][]const u8{
        "-Wall",
        "-Wextra",
        "-fomit-frame-pointer",
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

/// Evmone's x86 Keccak selector uses GCC CPU-detection symbols absent from Zig's compiler runtime.
fn nativeEvmoneLibgcc(b: *std.Build, target: std.Build.ResolvedTarget) ?std.Build.LazyPath {
    if (!target.query.isNative() or target.result.os.tag != .linux or target.result.cpu.arch != .x86_64) return null;

    const copy = b.addSystemCommand(&.{
        "sh",
        "-c",
        \\set -eu
        \\cp "$(gcc -print-libgcc-file-name)" "$1"
        ,
        "evmone-libgcc",
    });
    return copy.addOutputFileArg("libgcc.a");
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
        .omit_frame_pointer = true,
        .link_libcpp = true,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
        },
    });
}
