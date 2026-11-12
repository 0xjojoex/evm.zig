const std = @import("std");
const Translator = @import("translate_c").Translator;

// `b.option` validates these and lists them in `zig build --help`. The values
// are forwarded verbatim to the evmz dependency, which resolves the accelerated
// backends against the profile and target.
const Profile = enum { native, zkvm };
const KeccakBackend = enum { std, xkcp };

pub fn build(b: *std.Build) void {
    const test_filters = b.option([]const []const u8, "test-filter", "Compile only matching tests (repeatable)") orelse &.{};
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const micro_optimize = b.option(
        std.lang.Optimize,
        "micro-optimize",
        "Optimization mode for micro benchmark tests",
    ) orelse if (optimize == .debug) .fast else optimize;
    const compare_optimize = if (optimize == .debug) .fast else optimize;
    const micro_filter = b.option(
        []const u8,
        "micro-filter",
        "Only run micro benchmark tests whose names contain this filter",
    );
    const profile = b.option(Profile, "profile", "Build profile") orelse .native;
    const native_keccak = b.option(KeccakBackend, "native-keccak", "Native Keccak backend") orelse .xkcp;

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
    const evmc_bindings_mod = b.createModule(.{
        .root_source_file = b.path("src/evmc_bindings.zig"),
        .target = target,
        .optimize = optimize,
    });
    const translator = Translator.init(b.dependency("translate_c", .{}), .{
        .name = "evmc",
        .c_source_file = b.path("src/evmc_bindings.h"),
        .target = target,
        .optimize = optimize,
    });
    translator.addIncludePath(evmcCHeaders(b, evmone_dep));
    translator.addIncludePath(evmone_dep.path("evmc/include"));
    evmc_bindings_mod.addImport("evmc_c", translator.mod);
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
        run_vm_loop.addPassthruArgs();
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
        run_block_lifecycle.addPassthruArgs();
        b.step("block-lifecycle", "Run VM block lifecycle benchmark").dependOn(&run_block_lifecycle.step);
    }

    {
        const tx_loop_mod = benchModule(b, "src/tx_loop.zig", target, optimize, evmz_mod);
        const tx_loop = b.addExecutable(.{
            .name = "evmz-tx-loop",
            .root_module = tx_loop_mod,
        });
        b.installArtifact(tx_loop);

        const run_tx_loop = b.addRunArtifact(tx_loop);
        run_tx_loop.addPassthruArgs();
        b.step("tx-loop", "Run evmz transaction-level benchmark").dependOn(&run_tx_loop.step);
    }

    {
        const run = b.addSystemCommand(&.{
            "cargo",           "+1.96.0",         "run", "--quiet", "--release", "--locked",
            "--manifest-path", "evm2/Cargo.toml", "--",  "tx-loop",
        });
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("EVM2_DISPATCH_BACKEND", "packed");
        run.setEnvironmentVariable("CARGO_TARGET_DIR", "evm2/target");
        addNativeRustFlags(run);
        run.addPassthruArgs();
        b.step("evm2-tx-loop", "Run EVM2 transaction-level benchmark").dependOn(&run.step);
    }

    {
        const kernel_mod = benchModule(b, "src/kernel.zig", target, optimize, evmz_mod);
        kernel_mod.addImport("evmc_bindings", evmc_bindings_mod);
        addEvmoneVm(kernel_mod, evmone_dep, intx_dep, evmone_libgcc);
        const kernel = b.addExecutable(.{
            .name = "evmz-kernel",
            .root_module = kernel_mod,
        });
        b.installArtifact(kernel);

        const run_kernel = b.addRunArtifact(kernel);
        run_kernel.addPassthruArgs();
        b.step("kernel", "Run pure opcode kernel benchmark").dependOn(&run_kernel.step);
    }

    {
        const run = b.addSystemCommand(&.{
            "cargo",           "+1.96.0",         "run", "--quiet", "--release", "--locked",
            "--manifest-path", "evm2/Cargo.toml", "--",  "kernel",
        });
        run.setCwd(b.path("."));
        run.setEnvironmentVariable("EVM2_DISPATCH_BACKEND", "packed");
        run.setEnvironmentVariable("CARGO_TARGET_DIR", "evm2/target");
        addNativeRustFlags(run);
        run.addPassthruArgs();
        b.step("evm2-kernel", "Run EVM2 opcode kernel benchmark").dependOn(&run.step);
    }

    for ([_]struct { step: []const u8, toolchain: []const u8, dispatch: []const u8, target_dir: []const u8 }{
        .{ .step = "evm2-vm-loop", .toolchain = "+1.96.0", .dispatch = "packed", .target_dir = "evm2/target" },
        .{ .step = "evm2-packed-nightly-vm-loop", .toolchain = "+nightly-2026-06-01", .dispatch = "packed", .target_dir = "evm2/target/packed-nightly" },
        .{ .step = "evm2-tail-vm-loop", .toolchain = "+nightly-2026-06-01", .dispatch = "tco", .target_dir = "evm2/target/tail" },
    }) |variant| {
        const run = b.addSystemCommand(&.{
            "cargo",           variant.toolchain, "run", "--quiet", "--release", "--locked",
            "--manifest-path", "evm2/Cargo.toml", "--",
        });
        run.setCwd(b.path("."));
        addNativeRustFlags(run);
        run.setEnvironmentVariable("EVM2_DISPATCH_BACKEND", variant.dispatch);
        run.setEnvironmentVariable("CARGO_TARGET_DIR", variant.target_dir);
        run.addPassthruArgs();
        b.step(variant.step, "Run EVM2 VM-loop fixtures with the selected compiler and dispatch").dependOn(&run.step);
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
        run_evmone_vm_loop.addPassthruArgs();
        b.step("evmone-vm-loop", "Run standalone evmone VM-loop fixture runner").dependOn(&run_evmone_vm_loop.step);
    }

    {
        const evmone_tx_loop_mod = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .omit_frame_pointer = true,
            .link_libc = true,
            .link_libcpp = true,
        });
        addEvmoneVm(evmone_tx_loop_mod, evmone_dep, intx_dep, evmone_libgcc);
        addEvmoneState(evmone_tx_loop_mod, evmone_dep);
        evmone_tx_loop_mod.addCSourceFiles(.{
            .root = b.path("evmone"),
            .files = &.{ "tx_loop.cpp", "unlinked_precompiles.cpp" },
            .flags = evmone_state_cxx_flags,
        });
        const evmone_tx_loop = b.addExecutable(.{
            .name = "evmone-tx-loop",
            .root_module = evmone_tx_loop_mod,
        });
        b.installArtifact(evmone_tx_loop);

        const run_evmone_tx_loop = b.addRunArtifact(evmone_tx_loop);
        run_evmone_tx_loop.addPassthruArgs();
        b.step("evmone-tx-loop", "Run evmone transaction-level benchmark").dependOn(&run_evmone_tx_loop.step);
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
            @tagName(profile),
            "--native-keccak",
            @tagName(native_keccak),
            "--support-min",
            vm_loop_support_min,
            "--support-max",
            vm_loop_support_max,
        });
        run_compare.addPassthruArgs();
        b.step("compare", "Run VM-core comparison").dependOn(&run_compare.step);
    }

    {
        const run_report = b.addSystemCommand(&.{
            "python3",
            "scripts/report.py",
            "--zig-exe",
            b.graph.zig_exe,
            "--profile",
            @tagName(profile),
            "--native-keccak",
            @tagName(native_keccak),
        });
        run_report.setCwd(b.path("."));
        run_report.addPassthruArgs();
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
        const bench_tests_mod = benchModule(b, "src/test.zig", target, optimize, evmz_mod);
        bench_tests_mod.addImport("build_options", vm_loop_options_mod);
        const bench_tests = b.addTest(.{
            .name = "evmz-bench-tests",
            .root_module = bench_tests_mod,
            .filters = test_filters,
            .test_runner = .{ .path = evmz_dep.path("tools/test_runner.zig"), .mode = .simple },
        });
        const kernel_tests = b.addTest(.{
            .name = "evmone-kernel-tests",
            .root_module = blk: {
                const kernel_test_mod = benchModule(b, "src/kernel.zig", target, optimize, evmz_mod);
                kernel_test_mod.addImport("evmc_bindings", evmc_bindings_mod);
                addEvmoneVm(kernel_test_mod, evmone_dep, intx_dep, evmone_libgcc);
                break :blk kernel_test_mod;
            },
            .filters = test_filters,
            .test_runner = .{ .path = evmz_dep.path("tools/test_runner.zig"), .mode = .simple },
        });
        const compare_tests = b.addTest(.{
            .name = "compare-tests",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/compare.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = test_filters,
            .test_runner = .{ .path = evmz_dep.path("tools/test_runner.zig"), .mode = .simple },
        });
        const test_step = b.step("test", "Run benchmark sidecar tests");
        const run_bench_tests = b.addRunArtifact(bench_tests);
        run_bench_tests.addPassthruArgs();
        test_step.dependOn(&run_bench_tests.step);
        const run_kernel_tests = b.addRunArtifact(kernel_tests);
        run_kernel_tests.addPassthruArgs();
        test_step.dependOn(&run_kernel_tests.step);
        const run_compare_tests = b.addRunArtifact(compare_tests);
        run_compare_tests.addPassthruArgs();
        test_step.dependOn(&run_compare_tests.step);
    }
}

fn addNativeRustFlags(run: *std.Build.Step.Run) void {
    run.setEnvironmentVariable("RUSTFLAGS", "-C target-cpu=native -C force-frame-pointers=no");
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_LTO", "fat");
    run.setEnvironmentVariable("CARGO_PROFILE_RELEASE_CODEGEN_UNITS", "1");
}

fn evmcCHeaders(b: *std.Build, evmone_dep: *std.Build.Dependency) std.Build.LazyPath {
    b.graph.poisonCache();
    const path = evmone_dep.builder.root.joinString(b.allocator, "evmc/include/evmc/evmc.h") catch
        @panic("OOM");
    var header = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .limited(128 * 1024)) catch
        @panic("cannot read evmone EVMC header");
    // EVMC 19's C header has C++ member initializers. Drop them for the C translator;
    // the field types and ABI remain unchanged.
    for ([_][]const u8{ "left", "spilled" }) |field| {
        const before = b.fmt("int64_t {s} = 0;", .{field});
        std.debug.assert(std.mem.count(u8, header, before) == 1);
        header = std.mem.replaceOwned(u8, b.allocator, header, before, b.fmt("int64_t {s};", .{field})) catch
            @panic("OOM");
    }
    const files = b.addWriteFiles();
    _ = files.add("evmc/evmc.h", header);
    return files.getDirectory();
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
        "-DPROJECT_VERSION=\"0.25.0\"",
    };
    const evmone_sources = &[_][]const u8{
        "lib/evmone/advanced_analysis.cpp",
        "lib/evmone/advanced_execution.cpp",
        "lib/evmone/advanced_instructions.cpp",
        "lib/evmone/baseline_analysis.cpp",
        "lib/evmone/baseline_execution.cpp",
        "lib/evmone/baseline_instruction_table.cpp",
        "lib/evmone/create_address.cpp",
        "lib/evmone/delegation.cpp",
        "lib/evmone/instructions_calls.cpp",
        "lib/evmone/instructions_storage.cpp",
        "lib/evmone/tracing.cpp",
        "lib/evmone/vm.cpp",
    };
    for (evmone_sources) |source| {
        module.addCSourceFile(.{ .file = evmone_dep.path(source), .flags = cxx_flags });
    }
    module.addCSourceFile(.{
        .file = evmone_dep.path("lib/evmone_precompiles/keccak.cpp"),
        .flags = cxx_flags,
    });
}

/// Unlike the interpreter library, evmone's state harness is built with exceptions and RTTI.
const evmone_state_cxx_flags = &[_][]const u8{
    "-std=c++20",
    "-Wall",
    "-Wextra",
    "-Wno-missing-field-initializers",
    "-Wno-unknown-attributes",
    "-fomit-frame-pointer",
};

/// Adds evmone's state-test transaction harness (`state::transition` and `test::TestState`) and
/// the precompiles it links, except the blst-backed BLS12-381 and KZG ones.
fn addEvmoneState(module: *std.Build.Module, evmone_dep: *std.Build.Dependency) void {
    // The harness includes its own headers as `<test/state/...>`.
    module.addIncludePath(evmone_dep.path("."));
    module.addCSourceFiles(.{
        .root = evmone_dep.path("."),
        .files = &.{
            "test/state/authorization.cpp",
            "test/state/block.cpp",
            "test/state/bloom_filter.cpp",
            "test/state/host.cpp",
            "test/state/precompiles.cpp",
            "test/state/requests.cpp",
            "test/state/rlp_decode.cpp",
            "test/state/state.cpp",
            "test/state/system_contracts.cpp",
            "test/state/transaction.cpp",
            "test/utils/test_state.cpp",
            "lib/evmone_precompiles/blake2b.cpp",
            "lib/evmone_precompiles/bn254.cpp",
            "lib/evmone_precompiles/modexp.cpp",
            "lib/evmone_precompiles/mulmod.cpp",
            "lib/evmone_precompiles/pairing/bn254/pairing.cpp",
            "lib/evmone_precompiles/ripemd160.cpp",
            "lib/evmone_precompiles/secp256k1.cpp",
            "lib/evmone_precompiles/secp256r1.cpp",
            "lib/evmone_precompiles/sha256.cpp",
        },
        .flags = evmone_state_cxx_flags,
    });
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
    optimize: std.lang.Optimize,
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
