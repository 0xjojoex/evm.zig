const std = @import("std");

const EvmzBuildConfig = struct {
    profile: []const u8,
    native_keccak: []const u8,
    native_secp256k1: []const u8,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = buildProfileOption(b);
    const is_native_profile = std.mem.eql(u8, profile, "native");
    const requested_native_keccak = nativeKeccakOption(b);
    const native_keccak = resolveNativeKeccak(profile, target, requested_native_keccak);
    const requested_native_secp256k1 = nativeSecp256k1Option(b);
    const native_secp256k1 = resolveNativeSecp256k1(profile, target, requested_native_secp256k1);
    const pic = b.option(bool, "pic", "Build the public evmz module as position-independent code") orelse false;
    const evmz_build = EvmzBuildConfig{
        .profile = profile,
        .native_keccak = native_keccak,
        .native_secp256k1 = native_secp256k1,
    };
    const use_xkcp = std.mem.eql(u8, native_keccak, "xkcp");
    const xkcp_dep = if (use_xkcp) b.lazyDependency("xkcp", .{}) else null;
    if (use_xkcp and xkcp_dep == null) return;
    const xkcp_object = if (xkcp_dep) |dep|
        buildXkcpObject(b, target, optimize, dep, if (pic) "xkcp-pic" else "xkcp", if (pic) true else null)
    else
        null;
    if (xkcp_dep) |dep| {
        const install_license = b.addInstallFile(dep.path("LICENSE"), "share/licenses/evmz/XKCP.txt");
        b.getInstallStep().dependOn(&install_license.step);
    }
    const use_libsecp256k1 = std.mem.eql(u8, native_secp256k1, "libsecp256k1");
    const libsecp256k1_dep = if (use_libsecp256k1)
        b.lazyDependency("libsecp256k1", .{})
    else
        null;
    if (use_libsecp256k1 and libsecp256k1_dep == null) return;
    const libsecp256k1_object = if (libsecp256k1_dep) |dep|
        buildLibsecp256k1Object(b, target, optimize, dep, if (pic) "libsecp256k1-pic" else "libsecp256k1", if (pic) true else null)
    else
        null;
    if (libsecp256k1_dep) |dep| {
        const install_license = b.addInstallFile(dep.path("COPYING"), "share/licenses/evmz/libsecp256k1.txt");
        b.getInstallStep().dependOn(&install_license.step);
    }
    const build_options = buildOptions(b, profile, native_keccak, native_secp256k1);
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
    const native_precompile_deps = if (is_native_profile)
        nativePrecompileDeps(b, target, optimize)
    else
        null;

    // Frame pointers cost ~3 instructions per tail-dispatch handler; bench
    // builds already omit them, so keep shipped release artifacts identical.
    const omit_frame_pointer = optimize != .Debug;

    const evmz_mod = b.addModule("evmz", .{
        .root_source_file = b.path("src/evm.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
        .pic = if (pic) true else null,
    });
    evmz_mod.addOptions("build_options", build_options);
    evmz_mod.addIncludePath(b.path("include"));
    if (native_precompile_deps) |deps| {
        addPrecompileNative(b, evmz_mod, deps);
    }
    addNativeKeccak(evmz_mod, xkcp_object);
    addNativeSecp256k1(evmz_mod, libsecp256k1_object);

    const ssz_mod = b.addModule("ssz", .{
        .root_source_file = b.path("pkg/ssz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rlp_mod = b.addModule("rlp", .{
        .root_source_file = b.path("pkg/rlp/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    evmz_mod.addImport("ssz", ssz_mod);
    evmz_mod.addImport("rlp", rlp_mod);
    const mpt_mod = b.addModule("mpt", .{
        .root_source_file = b.path("pkg/mpt/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_mod.addImport("rlp", rlp_mod);
    evmz_mod.addImport("mpt", mpt_mod);

    const core_check = b.addObject(.{
        .name = "evmz",
        .root_module = evmz_mod,
    });
    b.default_step.dependOn(&core_check.step);
    b.step("check", "Compile the public evmz module").dependOn(&core_check.step);

    // test
    {
        const unit_tests_mod = b.createModule(.{
            .root_source_file = b.path("src/evm.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = is_native_profile,
        });
        unit_tests_mod.addOptions("build_options", build_options);
        unit_tests_mod.addImport("ssz", ssz_mod);
        unit_tests_mod.addImport("rlp", rlp_mod);
        unit_tests_mod.addImport("mpt", mpt_mod);
        unit_tests_mod.addIncludePath(b.path("include"));
        if (native_precompile_deps) |deps| {
            addPrecompileNative(b, unit_tests_mod, deps);
        }
        addNativeKeccak(unit_tests_mod, xkcp_object);
        addNativeSecp256k1(unit_tests_mod, libsecp256k1_object);
        const unit_tests = b.addTest(.{
            .root_module = unit_tests_mod,
            .filters = b.args orelse &.{},
        });
        // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
        // Keep the test build in Debug while using LLVM for tail dispatch.
        unit_tests.use_llvm = true;

        const run_unit_tests = b.addRunArtifact(unit_tests);

        const ssz_unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("pkg/ssz/src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = b.args orelse &.{},
        });
        const rlp_unit_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("pkg/rlp/src/test.zig"),
                .target = target,
                .optimize = optimize,
            }),
            .filters = b.args orelse &.{},
        });
        const mpt_unit_tests_mod = b.createModule(.{
            .root_source_file = b.path("pkg/mpt/test.zig"),
            .target = target,
            .optimize = optimize,
        });
        mpt_unit_tests_mod.addImport("mpt", mpt_mod);
        const mpt_unit_tests = b.addTest(.{
            .root_module = mpt_unit_tests_mod,
            .filters = b.args orelse &.{},
        });
        const guest_zisk_ab_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("guest/zisk_ab.zig"),
                .target = b.graph.host,
                .optimize = optimize,
            }),
        });

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_unit_tests.step);
        test_step.dependOn(&b.addRunArtifact(ssz_unit_tests).step);
        test_step.dependOn(&b.addRunArtifact(rlp_unit_tests).step);
        test_step.dependOn(&b.addRunArtifact(mpt_unit_tests).step);
        test_step.dependOn(&b.addRunArtifact(guest_zisk_ab_tests).step);
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
        uint256_fuzz_tests.use_llvm = true;
        const run_uint256_fuzz_tests = b.addRunArtifact(uint256_fuzz_tests);

        const modexp_fuzz_mod = b.createModule(.{
            .root_source_file = b.path("src/precompile/modexp.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = false,
        });
        const modexp_fuzz_tests = b.addTest(.{
            .name = "modexp-fuzz",
            .root_module = modexp_fuzz_mod,
        });
        modexp_fuzz_tests.use_llvm = true;
        const run_modexp_fuzz_tests = b.addRunArtifact(modexp_fuzz_tests);

        const rlp_fuzz_mod = b.createModule(.{
            .root_source_file = b.path("pkg/rlp/src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = false,
        });
        const rlp_fuzz_tests = b.addTest(.{
            .name = "rlp-fuzz",
            .root_module = rlp_fuzz_mod,
        });
        const run_rlp_fuzz_tests = b.addRunArtifact(rlp_fuzz_tests);

        const mpt_fuzz_mod = b.createModule(.{
            .root_source_file = b.path("pkg/mpt/src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = false,
        });
        mpt_fuzz_mod.addImport("mpt", mpt_mod);
        const mpt_fuzz_tests = b.addTest(.{
            .name = "mpt-fuzz",
            .root_module = mpt_fuzz_mod,
        });
        const run_mpt_fuzz_tests = b.addRunArtifact(mpt_fuzz_tests);

        const fuzz_step = b.step("fuzz", "Run fuzzable pure-Zig unit tests");
        fuzz_step.dependOn(&run_uint256_fuzz_tests.step);
        fuzz_step.dependOn(&run_modexp_fuzz_tests.step);
        fuzz_step.dependOn(&run_rlp_fuzz_tests.step);
        fuzz_step.dependOn(&run_mpt_fuzz_tests.step);

        const uint256_fuzz_step = b.step("fuzz-uint256", "Run uint256 fuzz tests");
        uint256_fuzz_step.dependOn(&run_uint256_fuzz_tests.step);

        const modexp_fuzz_step = b.step("fuzz-modexp", "Run modexp fuzz tests");
        modexp_fuzz_step.dependOn(&run_modexp_fuzz_tests.step);
    }

    const optimize_name = @tagName(optimize);
    const bench_optimize_name = @tagName(bench_optimize);
    if (pathExists(b, "eest/build.zig")) {
        addEestDelegate(b, "eest-test", "Run sidecar EEST runner tests", "test", optimize_name, null, evmz_build);
        addEestDelegate(b, "eest", "Run EEST state-test fixtures", "eest", optimize_name, null, evmz_build);
        addEestDelegate(b, "eest-classify", "Classify EEST state-test fixtures", "eest-classify", optimize_name, null, evmz_build);
        addEestDelegate(b, "eest-scope", "Report downloaded EEST fixture scope and support status", "eest-scope", optimize_name, null, evmz_build);
        addEestDelegate(b, "eest-tx", "Run EEST raw transaction-test fixtures", "eest-tx", optimize_name, null, evmz_build);
        addEestDelegate(b, "zkevm", "Run EEST zkEVM stateless SSZ fixtures", "zkevm", optimize_name, null, evmz_build);
        addEestDelegate(b, "zkevm-input", "Extract one EEST zkEVM stateless input as ZisK stdin", "zkevm-input", optimize_name, null, evmz_build);
        addEestDelegate(b, "zkevm-ere", "Run raw ERE stateless input through native adapter", "zkevm-ere", optimize_name, null, evmz_build);
        addEestDelegate(b, "zkevm-ere-bench", "Emit ERE BenchmarkRun rows for zkEVM stateless fixtures", "zkevm-ere-bench", null, bench_optimize_name, evmz_build);
        addEestDelegate(b, "eest-block-stf", "Run regular EEST blockchain_tests through BlockSTF", "eest-block-stf", optimize_name, null, evmz_build);
        addEestDelegate(b, "eest-stateless-block-stf", "Run witness-backed zkEVM blockchain_tests through stateless BlockSTF", "eest-stateless-block-stf", optimize_name, null, evmz_build);
        addEestDelegate(b, "ssz-conformance", "Run consensus-spec generic SSZ fixtures", "ssz-conformance", optimize_name, null, evmz_build);
    }
    if (pathExists(b, "bench/build.zig")) {
        addBenchDelegate(b, "bench-test", "Run benchmark sidecar tests", "test", null, evmz_build);
        addBenchVmLoopDelegate(b, bench_optimize_name, bench_support_min, bench_support_max, evmz_build);
        addBenchDelegate(b, "bench-evmone-vm-loop", "Run standalone evmone VM-loop fixture runner", "evmone-vm-loop", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-revm-vm-loop", "Run revm VM-loop fixture runner", "revm-vm-loop", null, evmz_build);
        addBenchCompareDelegate(b, bench_optimize_name, bench_support_min, bench_support_max, evmz_build);
        addBenchDelegate(b, "bench-block-lifecycle", "Run VM block lifecycle benchmark", "block-lifecycle", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-host-boundary", "Run host-boundary benchmark runner", "host-boundary", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-host-matrix", "Run host-boundary CSV matrix", "host-matrix", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-kernel", "Run pure opcode kernel benchmark", "kernel", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-code-analysis", "Run code-analysis morphology and timing report", "code-analysis", bench_optimize_name, evmz_build);
        addBenchDelegate(b, "bench-revm-kernel", "Run revm opcode kernel benchmark", "revm-kernel", null, evmz_build);
        addBenchDelegate(b, "bench-report", "Run all benchmark layers and write a comparison report", "report", bench_optimize_name, evmz_build);
        addBenchMicroDelegate(b, bench_optimize_name, bench_micro_filter, evmz_build);
    }
    if (pathExists(b, "pkg/ssz/build.zig")) {
        addSszBenchDelegate(b, bench_optimize_name);
    }
    if (is_native_profile and pathExists(b, "pkg/evmc/build.zig")) {
        addEvmcDelegate(b, "evmc", "Build the EVMC compatibility package", null, target, optimize_name, evmz_build);
        addEvmcDelegate(b, "evmc-test", "Run EVMC compatibility package tests", "test", target, optimize_name, evmz_build);
        addEvmcDelegate(b, "evmc-example", "Run the EVMC C example", "example", target, optimize_name, evmz_build);
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
    addGuestZiskAb(b, optimize);
    addGuestZisk(b, optimize, ziskos_staticlib_path, guest_payload, guest_input_path, guest_output_path);

    // examples
    {
        const example_name = b.option(
            []const u8,
            "example-name",
            "Name of the example",
        ) orelse "basic.zig";

        const is_zig = std.mem.endsWith(u8, example_name, ".zig");
        if (is_zig) {
            addExamplesDelegate(b, "example", "Run the selected Zig example", "example", example_name, target, optimize_name, evmz_build);
            addExamplesDelegate(b, "example-test", "Run tests in the selected Zig example", "example-test", example_name, target, optimize_name, evmz_build);
        } else {
            if (!is_native_profile) {
                std.debug.panic("C examples require -Dprofile=native", .{});
            }
            if (!std.mem.eql(u8, example_name, "basic.c")) {
                std.debug.panic("unknown C example '{s}'", .{example_name});
            }
            addEvmcDelegate(b, "example", "Run the EVMC C example", "example", target, optimize_name, evmz_build);
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

fn nativeKeccakOption(b: *std.Build) []const u8 {
    const backend = b.option(
        []const u8,
        "native-keccak",
        "Native Keccak backend: std or xkcp (ignored by profile=zkvm)",
    ) orelse "std";
    if (!std.mem.eql(u8, backend, "std") and !std.mem.eql(u8, backend, "xkcp")) {
        std.debug.panic("unsupported native Keccak backend '{s}' (expected std or xkcp)", .{backend});
    }
    return backend;
}

fn nativeSecp256k1Option(b: *std.Build) []const u8 {
    const backend = b.option(
        []const u8,
        "native-secp256k1",
        "Native secp256k1 backend: std or libsecp256k1 (ignored by profile=zkvm)",
    ) orelse "std";
    if (!std.mem.eql(u8, backend, "std") and !std.mem.eql(u8, backend, "libsecp256k1")) {
        std.debug.panic("unsupported native secp256k1 backend '{s}' (expected std or libsecp256k1)", .{backend});
    }
    return backend;
}

fn resolveNativeKeccak(
    profile: []const u8,
    target: std.Build.ResolvedTarget,
    requested: []const u8,
) []const u8 {
    if (!std.mem.eql(u8, profile, "native") or !std.mem.eql(u8, requested, "xkcp")) return "std";
    return switch (target.result.cpu.arch) {
        .x86_64, .aarch64, .riscv64 => "xkcp",
        else => "std",
    };
}

fn resolveNativeSecp256k1(
    profile: []const u8,
    target: std.Build.ResolvedTarget,
    requested: []const u8,
) []const u8 {
    if (!std.mem.eql(u8, profile, "native") or !std.mem.eql(u8, requested, "libsecp256k1")) return "std";
    return switch (target.result.cpu.arch) {
        .x86_64, .aarch64, .riscv64 => "libsecp256k1",
        else => "std",
    };
}

fn buildOptions(
    b: *std.Build,
    profile: []const u8,
    native_keccak: []const u8,
    native_secp256k1: []const u8,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption([]const u8, "profile", profile);
    options.addOption([]const u8, "native_keccak", native_keccak);
    options.addOption([]const u8, "native_secp256k1", native_secp256k1);
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
    const build_options = buildOptions(b, "zkvm", "std", "std");
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
    const ssz_mod = b.createModule(.{
        .root_source_file = b.path("pkg/ssz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    const rlp_mod = b.createModule(.{
        .root_source_file = b.path("pkg/rlp/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    evmz_mod.addImport("ssz", ssz_mod);
    evmz_mod.addImport("rlp", rlp_mod);
    const mpt_mod = b.createModule(.{
        .root_source_file = b.path("pkg/mpt/src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_mod.addImport("rlp", rlp_mod);
    evmz_mod.addImport("mpt", mpt_mod);

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

fn addGuestZiskAb(b: *std.Build, optimize: std.builtin.OptimizeMode) void {
    const runner = b.addExecutable(.{
        .name = "evmz-guest-zisk-ab",
        .root_module = b.createModule(.{
            .root_source_file = b.path("guest/zisk_ab.zig"),
            .target = b.graph.host,
            .optimize = optimize,
        }),
    });
    const run = b.addRunArtifact(runner);
    run.addArgs(&.{ "--zig", b.graph.zig_exe });
    if (b.args) |args| run.addArgs(args);
    const step = b.step("guest-zisk-ab", "Compare verified ZisK guest steps across two source trees");
    step.dependOn(&run.step);
}

fn pathExists(b: *std.Build, sub_path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, sub_path, .{}) catch return false;
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
    config: EvmzBuildConfig,
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
    addEvmzBuildArgs(run, b, config);
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
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    if (optimize_name) |name| {
        run.addArg(b.fmt("-Doptimize={s}", .{name}));
    }
    addEvmzBuildArgs(run, b, config);
    run.addArg(child_step);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("bench"));

    const step = b.step(step_name, description);
    step.dependOn(&run.step);
}

fn addExamplesDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    example_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize_name: []const u8,
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}),
        b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}),
        b.fmt("-Doptimize={s}", .{optimize_name}),
        b.fmt("-Dexample-name={s}", .{example_name}),
    });
    addEvmzBuildArgs(run, b, config);
    run.addArg(child_step);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("examples"));

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

fn addEvmcDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: ?[]const u8,
    target: std.Build.ResolvedTarget,
    optimize_name: []const u8,
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}),
        b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}),
        b.fmt("-Doptimize={s}", .{optimize_name}),
        b.fmt("-Dnative-keccak={s}", .{config.native_keccak}),
        b.fmt("-Dnative-secp256k1={s}", .{config.native_secp256k1}),
    });
    if (child_step) |name| run.addArg(name);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("pkg/evmc"));

    b.step(step_name, description).dependOn(&run.step);
}

fn addBenchCompareDelegate(
    b: *std.Build,
    optimize_name: []const u8,
    support_min: ?[]const u8,
    support_max: ?[]const u8,
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    addEvmzBuildArgs(run, b, config);
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
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    addEvmzBuildArgs(run, b, config);
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
    config: EvmzBuildConfig,
) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    run.addArg(b.fmt("-Doptimize={s}", .{optimize_name}));
    addEvmzBuildArgs(run, b, config);
    if (micro_filter) |filter| {
        run.addArg(b.fmt("-Dmicro-filter={s}", .{filter}));
    }
    run.addArg("micro");
    run.setCwd(b.path("bench"));

    const step = b.step("bench-micro", "Run focused zBench micro benchmarks");
    step.dependOn(&run.step);
}

fn addEvmzBuildArgs(run: *std.Build.Step.Run, b: *std.Build, config: EvmzBuildConfig) void {
    run.addArg(b.fmt("-Dprofile={s}", .{config.profile}));
    run.addArg(b.fmt("-Dnative-keccak={s}", .{config.native_keccak}));
    run.addArg(b.fmt("-Dnative-secp256k1={s}", .{config.native_secp256k1}));
}

const XkcpLane = enum {
    x86_64_dispatch,
    aarch64_dispatch,
    generic64,
};

fn buildXkcpObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
    name: []const u8,
    pic: ?bool,
) *std.Build.Step.Compile {
    const lane: XkcpLane = switch (target.result.cpu.arch) {
        .x86_64 => if (target.result.os.tag == .windows) .generic64 else .x86_64_dispatch,
        .aarch64 => switch (target.result.os.tag) {
            .linux, .macos => .aarch64_dispatch,
            else => .generic64,
        },
        .riscv64 => .generic64,
        else => unreachable,
    };

    const config = switch (lane) {
        .x86_64_dispatch =>
        \\#define XKCP_has_KeccakP1600
        \\#define XKCP_has_x86_64_CPU_detection
        \\
        ,
        .aarch64_dispatch =>
        \\#define XKCP_has_KeccakP1600
        \\#define XKCP_has_aarch64_CPU_detection
        \\
        ,
        .generic64 =>
        \\#define XKCP_has_KeccakP1600
        \\
        ,
    };
    const generated = b.addWriteFiles();
    const config_header = generated.add("xkcp/config.h", config);
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = pic,
    });
    const c_flags = &[_][]const u8{
        "-std=c11",
        "-Wall",
        "-Wextra",
    };

    module.addIncludePath(config_header.dirname());
    module.addIncludePath(dep.path("lib/common"));
    module.addIncludePath(dep.path("lib/high/Keccak"));
    module.addIncludePath(dep.path("lib/low/common"));
    module.addIncludePath(dep.path("lib/low/KeccakP-1600/common"));
    module.addIncludePath(dep.path("lib/low/KeccakP-1600/plain-64bits"));
    module.addCSourceFile(.{
        .file = dep.path("lib/high/Keccak/KeccakSponge.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = b.path("src/crypto/xkcp_keccak.c"),
        .flags = c_flags,
    });
    module.addCSourceFile(.{
        .file = dep.path("lib/low/KeccakP-1600/plain-64bits/KeccakP-1600-opt64.c"),
        .flags = c_flags,
    });

    switch (lane) {
        .x86_64_dispatch => {
            module.addIncludePath(dep.path("lib/low/x86-64-dispatch"));
            module.addIncludePath(dep.path("lib/low/KeccakP-1600/AVX2"));
            module.addIncludePath(dep.path("lib/low/KeccakP-1600/AVX512"));
            module.addCSourceFile(.{
                .file = dep.path("lib/low/x86-64-dispatch/x86-64-dispatch.c"),
                .flags = c_flags,
            });
            const asm_flags: []const []const u8 = if (target.result.os.tag == .macos)
                &.{"-Wa,-defsym,old_gas_syntax=1"}
            else
                &.{};
            module.addCSourceFile(.{
                .file = dep.path("lib/low/KeccakP-1600/AVX2/KeccakP-1600-AVX2.s"),
                .flags = asm_flags,
            });
            module.addCSourceFile(.{
                .file = dep.path("lib/low/KeccakP-1600/AVX512/KeccakP-1600-AVX512.s"),
                .flags = asm_flags,
            });
        },
        .aarch64_dispatch => {
            module.addIncludePath(dep.path("lib/low/aarch64-dispatch"));
            module.addIncludePath(dep.path("lib/low/KeccakP-1600/ARMv8A-SHA3"));
            module.addCSourceFile(.{
                .file = dep.path("lib/low/aarch64-dispatch/aarch64-dispatch.c"),
                .flags = c_flags,
            });
            module.addCSourceFile(.{
                .file = dep.path("lib/low/KeccakP-1600/ARMv8A-SHA3/KeccakP-1600-x1-v84a.c"),
                .flags = c_flags,
            });
            module.addCSourceFile(.{
                .file = b.path("src/crypto/xkcp_aarch64.S"),
                .flags = &.{
                    "-D__ARM_FEATURE_SHA3=1",
                    "-Wa,-march=armv8.4-a+sha3",
                },
            });
        },
        .generic64 => module.addIncludePath(dep.path("lib/low/KeccakP-1600/plain-64bits/SnP")),
    }

    return b.addObject(.{ .name = name, .root_module = module });
}

fn buildLibsecp256k1Object(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    dep: *std.Build.Dependency,
    name: []const u8,
    pic: ?bool,
) *std.Build.Step.Compile {
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .pic = pic,
    });
    const common_flags = [_][]const u8{
        // Match upstream's language baseline and keep dependency warnings visible.
        "-std=c90",
        "-Wall",
        "-Wextra",

        // Keep upstream's public C API internal to evmz; only our one-shot adapter
        // overrides this visibility and becomes linkable from Zig.
        "-fvisibility=hidden",
        "-DSECP256K1_NO_API_VISIBILITY_ATTRIBUTES=1",

        // Recovery is optional upstream. Keep its desktop verification window, but
        // use the smallest supported signing table because evmz never signs here.
        "-DENABLE_MODULE_RECOVERY=1",
        "-DECMULT_WINDOW_SIZE=15",
        "-DCOMB_BLOCKS=2",
        "-DCOMB_TEETH=5",
    };
    const x86_64_flags = common_flags ++ [_][]const u8{
        // Upstream enables this after an assembler capability check. Zig's Clang
        // supports it on the non-Windows x86-64 targets selected below.
        "-DUSE_ASM_X86_64=1",
    };
    const flags: []const []const u8 = if (target.result.cpu.arch == .x86_64 and target.result.os.tag != .windows)
        &x86_64_flags
    else
        &common_flags;

    module.addIncludePath(dep.path("include"));
    module.addIncludePath(dep.path("src"));
    module.addCSourceFile(.{ .file = dep.path("src/secp256k1.c"), .flags = flags });
    module.addCSourceFile(.{ .file = dep.path("src/precomputed_ecmult.c"), .flags = flags });
    module.addCSourceFile(.{ .file = dep.path("src/precomputed_ecmult_gen.c"), .flags = flags });
    module.addCSourceFile(.{ .file = b.path("src/crypto/libsecp256k1.c"), .flags = flags });

    return b.addObject(.{ .name = name, .root_module = module });
}

fn addNativeKeccak(module: *std.Build.Module, xkcp_object: ?*std.Build.Step.Compile) void {
    const object = xkcp_object orelse return;
    module.link_libc = true;
    module.addObject(object);
}

fn addNativeSecp256k1(module: *std.Build.Module, object: ?*std.Build.Step.Compile) void {
    const libsecp256k1 = object orelse return;
    module.link_libc = true;
    module.addObject(libsecp256k1);
}

fn addPrecompileNative(
    b: *std.Build,
    module: *std.Build.Module,
    deps: NativePrecompileDeps,
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
