const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = buildProfileOption(b);
    const is_native_profile = std.mem.eql(u8, profile, "native");
    const build_options = buildOptions(b, profile);
    const bench_optimize = b.option(
        std.builtin.OptimizeMode,
        "bench-optimize",
        "Optimization mode forwarded to benchmark runners",
    ) orelse .ReleaseFast;
    const bench_support_min = b.option(
        []const u8,
        "bench-support-min",
        "Minimum Ethereum revision compiled into the VM-loop benchmark",
    );
    const bench_support_max = b.option(
        []const u8,
        "bench-support-max",
        "Maximum Ethereum revision compiled into the VM-loop benchmark",
    );
    const bench_micro_filter = b.option(
        []const u8,
        "micro-filter",
        "Only run benchmark micro tests whose names contain this filter",
    );
    const evmone_dep = b.dependency("evmone", .{ .target = target, .optimize = optimize });
    const native_precompile_deps = if (is_native_profile)
        nativePrecompileDeps(b, target, optimize)
    else
        null;

    const evmz_mod = b.addModule("evmz", .{
        .root_source_file = b.path("src/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    evmz_mod.addOptions("build_options", build_options);
    evmz_mod.addIncludePath(b.path("include"));
    evmz_mod.addIncludePath(evmone_dep.path("evmc/include"));
    if (native_precompile_deps) |deps| {
        addPrecompileNative(b, evmz_mod, deps, evmone_dep);
    }

    const ssz_mod = b.addModule("ssz", .{
        .root_source_file = b.path("pkg/ssz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    evmz_mod.addImport("ssz", ssz_mod);

    const static_c_lib = if (is_native_profile) static_c_lib: {
        const c_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/evmc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        c_lib_mod.addOptions("build_options", build_options);
        c_lib_mod.addImport("ssz", ssz_mod);
        c_lib_mod.addIncludePath(b.path("include"));
        c_lib_mod.addIncludePath(evmone_dep.path("evmc/include"));
        addPrecompileNative(b, c_lib_mod, native_precompile_deps.?, evmone_dep);

        const static_c_lib = b.addLibrary(.{
            .name = "evmz",
            .root_module = c_lib_mod,
            .linkage = .static,
        });
        b.installArtifact(static_c_lib);
        b.default_step.dependOn(&static_c_lib.step);

        const shared_c_lib = b.addLibrary(.{
            .name = "evmz",
            .root_module = c_lib_mod,
            .linkage = .dynamic,
        });
        b.installArtifact(shared_c_lib);
        b.default_step.dependOn(&shared_c_lib.step);

        // C headers.
        const evmz_compat_header = b.addInstallHeaderFile(b.path("include/evmz.h"), "evmz.h");
        const evmz_evmc_header = b.addInstallHeaderFile(b.path("include/evmz/evmc.h"), "evmz/evmc.h");
        const evmz_native_header = b.addInstallHeaderFile(b.path("include/evmz/evmz.h"), "evmz/evmz.h");
        const evmc_header = b.addInstallHeaderFile(evmone_dep.path("evmc/include/evmc/evmc.h"), "evmc/evmc.h");
        b.getInstallStep().dependOn(&evmz_compat_header.step);
        b.getInstallStep().dependOn(&evmz_evmc_header.step);
        b.getInstallStep().dependOn(&evmz_native_header.step);
        b.getInstallStep().dependOn(&evmc_header.step);

        break :static_c_lib static_c_lib;
    } else null;

    // test
    {
        const lib_unit_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/evm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = is_native_profile,
        });
        lib_unit_tests_mod.addOptions("build_options", build_options);
        lib_unit_tests_mod.addImport("ssz", ssz_mod);
        lib_unit_tests_mod.addIncludePath(b.path("include"));
        lib_unit_tests_mod.addIncludePath(evmone_dep.path("evmc/include"));
        if (native_precompile_deps) |deps| {
            addPrecompileNative(b, lib_unit_tests_mod, deps, evmone_dep);
        }
        const lib_unit_tests = b.addTest(.{
            .root_module = lib_unit_tests_mod,
            .filters = b.args orelse &.{},
        });
        // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
        // Keep the test build in Debug while using LLVM for tail dispatch.
        lib_unit_tests.use_llvm = true;

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const ssz_unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("pkg/ssz/src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = b.args orelse &.{},
        });

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&b.addRunArtifact(ssz_unit_tests).step);
        if (is_native_profile) {
            const c_api_tests_mod = b.createModule(.{
                .root_source_file = b.path("src/evmc.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            });
            c_api_tests_mod.addOptions("build_options", build_options);
            c_api_tests_mod.addImport("ssz", ssz_mod);
            c_api_tests_mod.addIncludePath(b.path("include"));
            c_api_tests_mod.addIncludePath(evmone_dep.path("evmc/include"));
            addPrecompileNative(b, c_api_tests_mod, native_precompile_deps.?, evmone_dep);
            const c_api_tests = b.addTest(.{
                .root_module = c_api_tests_mod,
                .filters = b.args orelse &.{},
            });
            c_api_tests.use_llvm = true;
            test_step.dependOn(&b.addRunArtifact(c_api_tests).step);
        }
    }

    {
        // Keep builtin-fuzzer targets pure Zig: Zig 0.16's fuzzer currently trips
        // on native precompile coverage, and default-runner fuzz needs no traces.
        const uint256_fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/uint256.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = false,
        });
        const uint256_fuzz_tests = b.addTest(.{
            .name = "uint256-fuzz",
            .root_module = uint256_fuzz_mod,
        });
        const run_uint256_fuzz_tests = b.addRunArtifact(uint256_fuzz_tests);

        const fuzz_step = b.step("fuzz", "Run fuzzable pure-Zig unit tests");
        fuzz_step.dependOn(&run_uint256_fuzz_tests.step);

        const uint256_fuzz_step = b.step("fuzz-uint256", "Run uint256 fuzz tests");
        uint256_fuzz_step.dependOn(&run_uint256_fuzz_tests.step);
    }

    const optimize_name = @tagName(optimize);
    const bench_optimize_name = @tagName(bench_optimize);
    if (pathExists(b, "eest/build.zig")) {
        addEestDelegate(b, "eest-test", "Run sidecar EEST runner tests", "test", optimize_name, null, profile);
        addEestDelegate(b, "eest", "Run EEST state-test fixtures", "eest", optimize_name, null, profile);
        addEestDelegate(b, "eest-classify", "Classify EEST state-test fixtures", "eest-classify", optimize_name, null, profile);
        addEestDelegate(b, "eest-scope", "Report downloaded EEST fixture scope and support status", "eest-scope", optimize_name, null, profile);
        addEestDelegate(b, "eest-tx", "Run EEST raw transaction-test fixtures", "eest-tx", optimize_name, null, profile);
        addEestDelegate(b, "zkevm", "Run EEST zkEVM stateless SSZ fixtures", "zkevm", optimize_name, null, profile);
        addEestDelegate(b, "zkevm-input", "Extract one EEST zkEVM stateless input as ZisK stdin", "zkevm-input", optimize_name, null, profile);
        addEestDelegate(b, "zkevm-ere", "Run raw ERE stateless input through native adapter", "zkevm-ere", optimize_name, null, profile);
        addEestDelegate(b, "zkevm-ere-bench", "Emit ERE BenchmarkRun rows for zkEVM stateless fixtures", "zkevm-ere-bench", null, bench_optimize_name, profile);
        addEestDelegate(b, "eest-block-stf", "Run regular EEST blockchain_tests through BlockSTF", "eest-block-stf", optimize_name, null, profile);
        addEestDelegate(b, "eest-stateless-block-stf", "Run witness-backed zkEVM blockchain_tests through stateless BlockSTF", "eest-stateless-block-stf", optimize_name, null, profile);
        addEestDelegate(b, "ssz-conformance", "Run consensus-spec generic SSZ fixtures", "ssz-conformance", optimize_name, null, profile);
    }
    if (pathExists(b, "bench/build.zig")) {
        addBenchDelegate(b, "bench-test", "Run benchmark sidecar tests", "test", null, profile);
        addBenchVmLoopDelegate(b, bench_optimize_name, bench_support_min, bench_support_max, profile);
        addBenchDelegate(b, "bench-evmone-vm-loop", "Run standalone evmone VM-loop fixture runner", "evmone-vm-loop", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-revm-vm-loop", "Run revm VM-loop fixture runner", "revm-vm-loop", null, profile);
        addBenchCompareDelegate(b, bench_optimize_name, bench_support_min, bench_support_max, profile);
        addBenchDelegate(b, "bench-block-lifecycle", "Run VM block lifecycle benchmark", "block-lifecycle", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-host-boundary", "Run host-boundary benchmark runner", "host-boundary", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-host-matrix", "Run host-boundary CSV matrix", "host-matrix", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-kernel", "Run pure opcode kernel benchmark", "kernel", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-code-analysis", "Run code-analysis morphology and timing report", "code-analysis", bench_optimize_name, profile);
        addBenchDelegate(b, "bench-revm-kernel", "Run revm opcode kernel benchmark", "revm-kernel", null, profile);
        addBenchDelegate(b, "bench-report", "Run all benchmark layers and write a comparison report", "report", bench_optimize_name, profile);
        addBenchMicroDelegate(b, bench_optimize_name, bench_micro_filter, profile);
    }
    if (pathExists(b, "pkg/ssz/build.zig")) {
        addSszBenchDelegate(b, bench_optimize_name);
    }

    if (is_native_profile) {
        addGuestPayloadTest(b, target, optimize, evmz_mod);
    } else {
        const fail = b.addFail("guest-payload-test is native-only; use guest-zisk-run with -Dziskos-staticlib for zkvm proof");
        const guest_payload_test_step = b.step("guest-payload-test", "Run native tests for guest payload fixtures");
        guest_payload_test_step.dependOn(&fail.step);
    }
    const ziskos_staticlib_path = b.option(
        []const u8,
        "ziskos-staticlib",
        "Path to a ZisK libziskos_staticlib.a provider for guest-zisk",
    );
    const guest_input_path = b.option([]const u8, "guest-input", "Path to ZisK stdin input file for guest-zisk-run");
    const guest_output_path = b.option([]const u8, "guest-output", "Path to write ZisK public output from guest-zisk-run");
    const guest_payload = guestPayloadOption(b);
    addGuestZisk(b, optimize, evmone_dep, ziskos_staticlib_path, guest_payload, guest_input_path, guest_output_path);

    // example
    {
        const example_name = b.option(
            []const u8,
            "example-name",
            "Name of the example",
        ) orelse "basic.zig";

        const is_zig = std.mem.endsWith(u8, example_name, ".zig");
        const path = b.fmt("examples/{s}", .{example_name});
        const root_source_file = b.path(path);
        const example_exe_name = std.fs.path.stem(std.fs.path.basename(example_name));

        if (is_zig) {
            const example_mod = b.createModule(.{
                .root_source_file = b.path("src/evm.zig"),
                .target = target,
                .optimize = optimize,
                .link_libcpp = is_native_profile,
            });
            example_mod.addOptions("build_options", build_options);
            example_mod.addIncludePath(evmone_dep.path("evmc/include"));
            if (native_precompile_deps) |deps| {
                addPrecompileNative(b, example_mod, deps, evmone_dep);
            }
            const example = b.addExecutable(.{
                .name = example_exe_name,
                .root_module = b.createModule(.{
                    .root_source_file = root_source_file,
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "evmz", .module = example_mod },
                    },
                }),
            });
            const run_example = b.addRunArtifact(example);
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);

            const example_tests = b.addTest(.{
                .root_module = b.createModule(.{
                    .root_source_file = root_source_file,
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "evmz", .module = example_mod },
                    },
                }),
            });
            example_tests.use_llvm = true;
            const example_test_step = b.step("example-test", "Run tests in the selected Zig example");
            example_test_step.dependOn(&b.addRunArtifact(example_tests).step);
        } else {
            if (!is_native_profile) {
                std.debug.panic("C examples require -Dprofile=native", .{});
            }
            const example_c = b.addExecutable(.{
                .name = example_exe_name,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });

            example_c.root_module.addIncludePath(b.path("include"));
            example_c.root_module.addIncludePath(evmone_dep.path("evmc/include"));
            example_c.root_module.addCSourceFile(.{
                .file = b.path(path),
                .flags = &[_][]const u8{
                    "-Wall",
                    "-Wextra",
                    "-pedantic",
                    "-std=c99",
                },
            });
            example_c.root_module.linkLibrary(static_c_lib.?);
            var run_example = b.addRunArtifact(example_c);
            run_example.has_side_effects = true;
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);
        }
    }
}

fn buildProfileOption(b: *std.Build) []const u8 {
    const profile = b.option([]const u8, "profile", "Build profile: native or zkvm") orelse "native";
    if (!std.mem.eql(u8, profile, "native") and !std.mem.eql(u8, profile, "zkvm")) {
        std.debug.panic("unsupported profile '{s}' (expected native or zkvm)", .{profile});
    }
    return profile;
}

fn buildOptions(b: *std.Build, profile: []const u8) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "profile", profile);
    return options;
}

fn guestOptions(b: *std.Build, use_ziskos_staticlib: bool) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(bool, "use_ziskos_staticlib", use_ziskos_staticlib);
    return options;
}

fn guestZiskTarget(b: *std.Build) std.Build.ResolvedTarget {
    const query = std.Target.Query.parse(.{
        .arch_os_abi = "riscv64-freestanding",
        .cpu_features = "generic_rv64+m+a",
    }) catch @panic("invalid ZisK guest target");
    return b.resolveTargetQuery(query);
}

fn guestPayloadOption(b: *std.Build) []const u8 {
    const payload = b.option([]const u8, "guest-payload", "Guest payload: basic, stateless-smoke, stateless-ssz-smoke, stateless-ere-smoke, or stateless-ere") orelse "basic";
    _ = guestPayloadSource(payload) catch |err| switch (err) {
        error.UnknownGuestPayload => std.debug.panic("unsupported guest payload '{s}' (expected basic, stateless-smoke, stateless-ssz-smoke, stateless-ere-smoke, or stateless-ere)", .{payload}),
    };
    return payload;
}

fn guestPayloadSource(payload: []const u8) error{UnknownGuestPayload}![]const u8 {
    if (std.mem.eql(u8, payload, "basic")) return "guest/payload/basic.zig";
    if (std.mem.eql(u8, payload, "stateless-smoke")) return "guest/payload/stateless_smoke.zig";
    if (std.mem.eql(u8, payload, "stateless-ssz-smoke")) return "guest/payload/stateless_ssz_smoke.zig";
    if (std.mem.eql(u8, payload, "stateless-ere-smoke")) return "guest/payload/stateless_ere_smoke.zig";
    if (std.mem.eql(u8, payload, "stateless-ere")) return "guest/payload/stateless_ere.zig";
    return error.UnknownGuestPayload;
}

fn addGuestPayloadTest(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmz_mod: *std.Build.Module,
) void {
    const guest_options = guestOptions(b, false);
    const guest_options_mod = guest_options.createModule();
    const guest_allocator_mod = b.createModule(.{
        .root_source_file = b.path("guest/allocator.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
    });
    const basic_payload_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/basic.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    });
    const guest_payload_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/basic_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "guest_payload_basic", .module = basic_payload_mod },
        },
    });
    const guest_payload_tests = b.addTest(.{
        .name = "guest-payload-basic",
        .root_module = guest_payload_tests_mod,
    });

    const stateless_smoke_payload_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    });
    const stateless_smoke_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "guest_payload_stateless_smoke", .module = stateless_smoke_payload_mod },
        },
    });
    const stateless_smoke_tests = b.addTest(.{
        .name = "guest-payload-stateless-smoke",
        .root_module = stateless_smoke_tests_mod,
    });
    const stateless_ssz_smoke_payload_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ssz_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    });
    const stateless_ssz_smoke_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ssz_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "guest_payload_stateless_ssz_smoke", .module = stateless_ssz_smoke_payload_mod },
        },
    });
    const stateless_ssz_smoke_tests = b.addTest(.{
        .name = "guest-payload-stateless-ssz-smoke",
        .root_module = stateless_ssz_smoke_tests_mod,
    });
    const stateless_ere_smoke_payload_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ere_smoke.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    });
    const stateless_ere_smoke_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ere_smoke_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "guest_payload_stateless_ere_smoke", .module = stateless_ere_smoke_payload_mod },
        },
    });
    const stateless_ere_smoke_tests = b.addTest(.{
        .name = "guest-payload-stateless-ere-smoke",
        .root_module = stateless_ere_smoke_tests_mod,
    });
    const guest_io_mod = b.createModule(.{
        .root_source_file = b.path("guest/io.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
    });
    const stateless_ere_payload_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ere.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_io", .module = guest_io_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    });
    const stateless_ere_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/stateless_ere_test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_payload_stateless_ere", .module = stateless_ere_payload_mod },
        },
    });
    const stateless_ere_tests = b.addTest(.{
        .name = "guest-payload-stateless-ere",
        .root_module = stateless_ere_tests_mod,
    });

    const guest_payload_test_step = b.step("guest-payload-test", "Run native tests for guest payload fixtures");
    guest_payload_test_step.dependOn(&b.addRunArtifact(guest_payload_tests).step);
    guest_payload_test_step.dependOn(&b.addRunArtifact(stateless_smoke_tests).step);
    guest_payload_test_step.dependOn(&b.addRunArtifact(stateless_ssz_smoke_tests).step);
    guest_payload_test_step.dependOn(&b.addRunArtifact(stateless_ere_smoke_tests).step);
    guest_payload_test_step.dependOn(&b.addRunArtifact(stateless_ere_tests).step);
}

fn addGuestZisk(
    b: *std.Build,
    optimize: std.builtin.OptimizeMode,
    evmone_dep: *std.Build.Dependency,
    ziskos_staticlib_path: ?[]const u8,
    guest_payload: []const u8,
    guest_input_path: ?[]const u8,
    guest_output_path: ?[]const u8,
) void {
    const provider_path = ziskos_staticlib_path orelse {
        const fail = b.addFail("guest-zisk requires -Dziskos-staticlib=<path>/libziskos_staticlib.a");
        const guest_step = b.step("guest-zisk", "Build the ZisK rv64 guest ELF");
        guest_step.dependOn(&fail.step);
        const run_step = b.step("guest-zisk-run", "Run the ZisK guest ELF with ziskemu");
        run_step.dependOn(&fail.step);
        return;
    };

    const target = guestZiskTarget(b);
    const build_options = buildOptions(b, "zkvm");
    const guest_options = guestOptions(b, true);
    const guest_options_mod = guest_options.createModule();
    const guest_payload_source = guestPayloadSource(guest_payload) catch unreachable;

    const evmz_mod = b.createModule(.{
        .root_source_file = b.path("src/evm.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
        .error_tracing = false,
        .pic = false,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    evmz_mod.addOptions("build_options", build_options);
    evmz_mod.addIncludePath(b.path("include"));
    evmz_mod.addIncludePath(evmone_dep.path("evmc/include"));
    const ssz_mod = b.createModule(.{
        .root_source_file = b.path("pkg/ssz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    evmz_mod.addImport("ssz", ssz_mod);

    const guest_allocator_mod = b.createModule(.{
        .root_source_file = b.path("guest/allocator.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
        .error_tracing = false,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
        .pic = false,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    const payload_mod = b.createModule(.{
        .root_source_file = b.path(guest_payload_source),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
        .error_tracing = false,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
        .pic = false,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    const guest_io_mod = b.createModule(.{
        .root_source_file = b.path("guest/io.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
        .error_tracing = false,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
        .pic = false,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    payload_mod.addImport("guest_io", guest_io_mod);
    const root_imports: []const std.Build.Module.Import = &.{
        .{ .name = "guest_payload", .module = payload_mod },
    };

    const root_mod = b.createModule(.{
        .root_source_file = b.path("guest/runtime/zisk/root.zig"),
        .target = target,
        .optimize = optimize,
        .code_model = .medium,
        .error_tracing = false,
        .imports = root_imports,
        .pic = false,
        .single_threaded = true,
        .strip = true,
        .unwind_tables = .none,
    });
    root_mod.addObjectFile(.{ .cwd_relative = provider_path });

    const guest = b.addExecutable(.{
        .name = "evmz-guest-zisk",
        .root_module = root_mod,
    });
    guest.entry = .{ .symbol_name = "_start" };
    guest.link_gc_sections = true;
    guest.setLinkerScript(b.path("guest/runtime/zisk/zisk-rv64.ld"));

    const install_guest = b.addInstallArtifact(guest, .{
        .dest_dir = .{ .override = .{ .custom = "guest/zisk" } },
        .dest_sub_path = "evmz-guest-zisk.elf",
    });

    const guest_step = b.step("guest-zisk", "Build the ZisK rv64 guest ELF");
    guest_step.dependOn(&install_guest.step);

    const ziskemu = b.option([]const u8, "ziskemu", "Path to ziskemu for guest-zisk-run") orelse "ziskemu";
    const ziskemu_steps = b.option([]const u8, "ziskemu-steps", "Maximum ziskemu steps for guest-zisk-run") orelse "5000000";
    const run = b.addSystemCommand(&.{ ziskemu, "-e" });
    run.addFileArg(guest.getEmittedBin());
    if (guest_input_path) |path| run.addArgs(&.{ "-i", path });
    if (guest_output_path) |path| run.addArgs(&.{ "-o", path });
    run.addArgs(&.{ "-n", ziskemu_steps, "-m", "--steps", "-c" });
    run.has_side_effects = true;

    const run_step = b.step("guest-zisk-run", "Run the ZisK guest ELF with ziskemu");
    run_step.dependOn(&run.step);
}

fn pathExists(b: *std.Build, sub_path: []const u8) bool {
    std.Io.Dir.accessAbsolute(b.graph.io, b.pathFromRoot(sub_path), .{}) catch return false;
    return true;
}

const NativePrecompileDeps = struct {
    ckzg_dep: *std.Build.Dependency,
    blst_dep: *std.Build.Dependency,
    mcl_dep: *std.Build.Dependency,
    trusted_setup_mod: *std.Build.Module,
};

fn nativePrecompileDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) NativePrecompileDeps {
    const ckzg_dep = b.dependency("ckzg", .{ .target = target, .optimize = optimize });
    const blst_dep = b.dependency("blst", .{ .target = target, .optimize = optimize });
    const mcl_dep = b.dependency("mcl", .{});
    return .{
        .ckzg_dep = ckzg_dep,
        .blst_dep = blst_dep,
        .mcl_dep = mcl_dep,
        .trusted_setup_mod = buildTrustedSetupModule(b, ckzg_dep.path("src/trusted_setup.txt")),
    };
}

fn addEestDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize_name: ?[]const u8,
    bench_optimize_name: ?[]const u8,
    profile: []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    if (optimize_name) |name| {
        run.addArg(b.fmt("-Doptimize={s}", .{name}));
    }
    if (bench_optimize_name) |name| {
        run.addArg(b.fmt("-Dbench-optimize={s}", .{name}));
    }
    run.addArg(b.fmt("-Dprofile={s}", .{profile}));
    run.addArg(child_step);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("eest"));

    const step = b.step(step_name, description);
    step.dependOn(&run.step);
}

fn addBenchDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize_name: ?[]const u8,
    profile: []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    if (optimize_name) |name| {
        run.addArg(b.fmt("-Doptimize={s}", .{name}));
    }
    run.addArg(b.fmt("-Dprofile={s}", .{profile}));
    run.addArg(child_step);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("bench"));

    const step = b.step(step_name, description);
    step.dependOn(&run.step);
}

fn addSszBenchDelegate(b: *std.Build, optimize_name: []const u8) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        b.fmt("-Doptimize={s}", .{optimize_name}),
        "bench",
    });
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("pkg/ssz"));

    const step = b.step("ssz-bench", "Run standalone SSZ codec benchmarks");
    step.dependOn(&run.step);
}

fn addBenchCompareDelegate(
    b: *std.Build,
    optimize_name: []const u8,
    support_min: ?[]const u8,
    support_max: ?[]const u8,
    profile: []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    run.addArg(b.fmt("-Dprofile={s}", .{profile}));
    if (support_min) |revision| {
        run.addArg(b.fmt("-Dbench-support-min={s}", .{revision}));
    }
    if (support_max) |revision| {
        run.addArg(b.fmt("-Dbench-support-max={s}", .{revision}));
    }
    run.addArg("compare");
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("bench"));

    const step = b.step("bench-compare", "Run VM-core comparison");
    step.dependOn(&run.step);
}

fn addBenchVmLoopDelegate(
    b: *std.Build,
    optimize_name: []const u8,
    support_min: ?[]const u8,
    support_max: ?[]const u8,
    profile: []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    run.addArg(b.fmt("-Dprofile={s}", .{profile}));
    if (support_min) |revision| {
        run.addArg(b.fmt("-Dbench-support-min={s}", .{revision}));
    }
    if (support_max) |revision| {
        run.addArg(b.fmt("-Dbench-support-max={s}", .{revision}));
    }
    run.addArg("vm-loop");
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("bench"));

    const step = b.step("bench-vm-loop", "Run evmz VM-loop fixture runner");
    step.dependOn(&run.step);
}

fn addBenchMicroDelegate(
    b: *std.Build,
    optimize_name: []const u8,
    micro_filter: ?[]const u8,
    profile: []const u8,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    run.addArg(b.fmt("-Dprofile={s}", .{profile}));
    if (micro_filter) |filter| {
        run.addArg(b.fmt("-Dmicro-filter={s}", .{filter}));
    }
    run.addArg("micro");
    run.setCwd(b.path("bench"));

    const step = b.step("bench-micro", "Run focused zBench micro benchmarks");
    step.dependOn(&run.step);
}

fn addPrecompileNative(
    b: *std.Build,
    module: *std.Build.Module,
    deps: NativePrecompileDeps,
    evmone_dep: *std.Build.Dependency,
) void {
    const mcl_flags = &[_][]const u8{
        "-std=c++20",
        "-Wall",
        "-Wextra",
        "-Wno-missing-field-initializers",
        "-DNDEBUG",
        "-DMCL_FP_BIT=256",
        "-DMCL_FR_BIT=256",
        "-DMCL_USE_LLVM=1",
        "-DMCL_BINT_ASM=1",
        "-DMCL_BINT_ASM_X64=0",
        "-DMCL_MSM=0",
        "-DMCL_DONT_USE_XBYAK",
    };
    const c_flags = &[_][]const u8{
        "-Wall",
        "-Wextra",
    };
    module.link_libc = true;
    module.link_libcpp = true;
    module.addImport("ckzg", deps.ckzg_dep.module("ckzg"));
    module.addImport("kzg_trusted_setup", deps.trusted_setup_mod);
    module.addIncludePath(b.path("src/precompile"));
    module.addIncludePath(evmone_dep.path("evmc/include"));
    module.addIncludePath(deps.ckzg_dep.path("src"));
    module.addIncludePath(deps.blst_dep.path("bindings"));
    module.addIncludePath(deps.mcl_dep.path("include"));
    module.addIncludePath(deps.mcl_dep.path("src"));
    module.addCSourceFile(.{ .file = b.path("src/precompile/bn254.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = deps.mcl_dep.path("src/fp.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = deps.mcl_dep.path("src/bn_c256.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = deps.mcl_dep.path("src/base64.ll"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = deps.mcl_dep.path("src/bint64.ll"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = b.path("src/precompile/bls12.c"), .flags = c_flags });
}

fn buildTrustedSetupModule(b: *std.Build, txt: std.Build.LazyPath) *std.Build.Module {
    const path = txt.getPath(b);
    const text = std.Io.Dir.cwd().readFileAlloc(b.graph.io, path, b.allocator, .unlimited) catch |err| {
        std.debug.panic("cannot read trusted setup '{s}': {s}", .{ path, @errorName(err) });
    };
    var it = std.mem.tokenizeAny(u8, text, " \t\r\n");
    const n_g1 = parseUsize(&it) orelse std.debug.panic("trusted setup missing g1 count", .{});
    const n_g2 = parseUsize(&it) orelse std.debug.panic("trusted setup missing g2 count", .{});

    const wf = b.addWriteFiles();
    _ = wf.add("g1_lagrange.bin", decodeHexPoints(b.allocator, &it, n_g1, 48));
    _ = wf.add("g2_monomial.bin", decodeHexPoints(b.allocator, &it, n_g2, 96));
    _ = wf.add("g1_monomial.bin", decodeHexPoints(b.allocator, &it, n_g1, 48));
    const src = wf.add("kzg_trusted_setup.zig", b.fmt(
        \\pub const num_g1_points: usize = {d};
        \\pub const num_g2_points: usize = {d};
        \\pub const g1_lagrange_bytes = @embedFile("g1_lagrange.bin")[0 .. num_g1_points * 48];
        \\pub const g2_monomial_bytes = @embedFile("g2_monomial.bin")[0 .. num_g2_points * 96];
        \\pub const g1_monomial_bytes = @embedFile("g1_monomial.bin")[0 .. num_g1_points * 48];
        \\
    , .{ n_g1, n_g2 }));

    return b.addModule("kzg_trusted_setup", .{ .root_source_file = src });
}

fn parseUsize(it: anytype) ?usize {
    const token = it.next() orelse return null;
    return std.fmt.parseUnsigned(usize, token, 10) catch null;
}

fn decodeHexPoints(allocator: std.mem.Allocator, it: anytype, count: usize, comptime point_size: usize) []const u8 {
    const out = allocator.alloc(u8, count * point_size) catch @panic("OOM");
    for (0..count) |i| {
        const hex = it.next() orelse std.debug.panic("trusted setup truncated at point {d}", .{i});
        if (hex.len != point_size * 2) {
            std.debug.panic("point {d} has wrong hex length: {d}", .{ i, hex.len });
        }
        _ = std.fmt.hexToBytes(out[i * point_size ..][0..point_size], hex) catch {
            std.debug.panic("invalid hex at point {d}", .{i});
        };
    }
    return out;
}
