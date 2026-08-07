const std = @import("std");

const EvmzBuildConfig = struct {
    profile: Profile,
    native_keccak: KeccakBackend,
    native_secp256k1: Secp256k1Backend,
};

const PackageModules = struct {
    ssz: *std.Build.Module,
    rlp: *std.Build.Module,
    mpt: *std.Build.Module,
};

const EvmzModuleConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    build_options: *std.Build.Step.Options,
    stateless_profile: *std.Build.Module,
    packages: PackageModules,
    native_precompiles: ?NativePrecompileDeps = null,
    xkcp: ?*std.Build.Step.Compile = null,
    libsecp256k1: ?*std.Build.Step.Compile = null,
    omit_frame_pointer: ?bool = null,
    pic: ?bool = null,
    guest: bool = false,
    strip: ?bool = null,
    exported: bool = false,
};

const TestConfig = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    packages: PackageModules,
    stateless_profile: *std.Build.Module,
    native_build_options: *std.Build.Step.Options,
    native_test_options: *std.Build.Step.Options,
    native_test_options_all: *std.Build.Step.Options,
    zkvm_test_options: *std.Build.Step.Options,
    zkvm_test_options_all: *std.Build.Step.Options,
    native_precompiles: NativePrecompileDeps,
    xkcp: ?*std.Build.Step.Compile,
    libsecp256k1: ?*std.Build.Step.Compile,
    selected_profile: Profile,
};

const TestSteps = struct {
    native: *std.Build.Step,
    native_all: *std.Build.Step,
    zkvm: *std.Build.Step,
    zkvm_all: *std.Build.Step,
    packages: *std.Build.Step,
    selected: *std.Build.Step,
};

const GuestPayloadSteps = struct {
    tests: *std.Build.Step,
    abi: *std.Build.Step,
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "Build profile") orelse .native;
    const is_native_profile = profile == .native;
    const requested_native_keccak = b.option(
        KeccakBackend,
        "native-keccak",
        "Native Keccak backend (ignored by profile=zkvm)",
    ) orelse .std;
    const native_keccak = resolveNativeKeccak(profile, target, requested_native_keccak);
    const requested_native_secp256k1 = b.option(
        Secp256k1Backend,
        "native-secp256k1",
        "Native secp256k1 backend (ignored by profile=zkvm)",
    ) orelse .std;
    const native_secp256k1 = resolveNativeSecp256k1(profile, target, requested_native_secp256k1);
    const pic = b.option(bool, "pic", "Build the public evmz module as position-independent code") orelse false;
    const evmz_build = EvmzBuildConfig{
        .profile = profile,
        .native_keccak = native_keccak,
        .native_secp256k1 = native_secp256k1,
    };
    const use_xkcp = native_keccak == .xkcp;
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
    const use_libsecp256k1 = native_secp256k1 == .libsecp256k1;
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
    const stateless_schemas = b.option(
        []const []const u8,
        "stateless-schema",
        "Stateless wire schema id compiled into the router, e.g. 0x1501 (repeatable; default all known)",
    ) orelse &.{};
    const native_build_options = buildOptions(
        b,
        .native,
        native_keccak,
        native_secp256k1,
        stateless_schemas,
        null,
    );
    const zkvm_build_options = buildOptions(
        b,
        .zkvm,
        .std,
        .std,
        stateless_schemas,
        null,
    );
    const test_forks = b.option(
        TestForks,
        "test-forks",
        "Fork revisions compiled into unit tests (ci always builds all)",
    ) orelse .dev;
    const native_test_options = buildOptions(b, .native, native_keccak, native_secp256k1, stateless_schemas, test_forks);
    const native_test_options_all = buildOptions(b, .native, native_keccak, native_secp256k1, stateless_schemas, .all);
    const zkvm_test_options = buildOptions(b, .zkvm, .std, .std, stateless_schemas, test_forks);
    const zkvm_test_options_all = buildOptions(b, .zkvm, .std, .std, stateless_schemas, .all);
    const build_options = if (is_native_profile) native_build_options else zkvm_build_options;
    const stateless_profile_none_mod = b.createModule(.{
        .root_source_file = b.path("guest/profile_none.zig"),
        .target = target,
        .optimize = optimize,
    });
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
    const native_precompile_deps = nativePrecompileDeps(
        b,
        target,
        optimize,
        if (pic) true else null,
    );

    // Frame pointers cost ~3 instructions per tail-dispatch handler; bench
    // builds already omit them, so keep shipped release artifacts identical.
    const omit_frame_pointer = optimize != .Debug;

    const packages = createPackageModules(b, target, optimize, null, true);
    const native_evmz_mod = createEvmzModule(b, .{
        .target = target,
        .optimize = optimize,
        .build_options = native_build_options,
        .stateless_profile = stateless_profile_none_mod,
        .packages = packages,
        .native_precompiles = native_precompile_deps,
        .xkcp = xkcp_object,
        .libsecp256k1 = libsecp256k1_object,
        .omit_frame_pointer = omit_frame_pointer,
        .pic = if (pic) true else null,
        .exported = is_native_profile,
    });
    const zkvm_evmz_mod = createEvmzModule(b, .{
        .target = target,
        .optimize = optimize,
        .build_options = zkvm_build_options,
        .stateless_profile = stateless_profile_none_mod,
        .packages = packages,
        .omit_frame_pointer = omit_frame_pointer,
        .pic = if (pic) true else null,
        .exported = !is_native_profile,
    });
    const evmz_mod = if (is_native_profile) native_evmz_mod else zkvm_evmz_mod;
    const ssz_mod = packages.ssz;
    const rlp_mod = packages.rlp;
    const mpt_mod = packages.mpt;

    const core_check = b.addObject(.{
        .name = "evmz",
        .root_module = evmz_mod,
    });
    core_check.use_llvm = true;
    b.default_step.dependOn(&core_check.step);
    b.step("check", "Compile the public evmz module").dependOn(&core_check.step);

    const tidy_step = addTidy(b);
    const fmt_step = addFmtCheck(b);
    const check_guest_elf_tests = addCheckGuestElf(b);
    const check_zisk_failure_status_tests = addCheckZiskFailureStatus(b);

    const debug_description = "Run the interactive controlled-execution debugger";
    if (is_native_profile) {
        const debug_cli_mod = b.createModule(.{
            .root_source_file = b.path("src/debug_cli.zig"),
            .target = target,
            .optimize = optimize,
            .link_libcpp = true,
        });
        debug_cli_mod.addOptions("build_options", build_options);
        debug_cli_mod.addImport("ssz", ssz_mod);
        debug_cli_mod.addImport("rlp", rlp_mod);
        debug_cli_mod.addImport("mpt", mpt_mod);
        debug_cli_mod.addIncludePath(b.path("include"));
        addPrecompileNative(b, debug_cli_mod, native_precompile_deps);
        addNativeKeccak(debug_cli_mod, xkcp_object);
        addNativeSecp256k1(debug_cli_mod, libsecp256k1_object);

        const debug_cli = b.addExecutable(.{
            .name = "evmz-debug",
            .root_module = debug_cli_mod,
        });
        const run_debug_cli = b.addRunArtifact(debug_cli);
        // The debugger reads commands from stdin, so it needs the real one.
        run_debug_cli.stdio = .inherit;
        if (b.args) |args| run_debug_cli.addArgs(args);
        b.step("debug", debug_description).dependOn(&run_debug_cli.step);
    } else {
        b.step("debug", debug_description).dependOn(&b.addFail("debug is native-only").step);
    }

    const call_fixture_oracle_mod = b.createModule(.{
        .root_source_file = b.path("src/cli.zig"),
        .target = target,
        .optimize = optimize,
        .link_libcpp = is_native_profile,
    });
    call_fixture_oracle_mod.addOptions("build_options", build_options);
    call_fixture_oracle_mod.addImport("stateless_profile", stateless_profile_none_mod);
    call_fixture_oracle_mod.addImport("ssz", ssz_mod);
    call_fixture_oracle_mod.addImport("rlp", rlp_mod);
    call_fixture_oracle_mod.addImport("mpt", mpt_mod);
    call_fixture_oracle_mod.addIncludePath(b.path("include"));
    if (is_native_profile) addPrecompileNative(b, call_fixture_oracle_mod, native_precompile_deps);
    addNativeKeccak(call_fixture_oracle_mod, xkcp_object);
    addNativeSecp256k1(call_fixture_oracle_mod, libsecp256k1_object);
    const call_fixture_oracle = b.addExecutable(.{
        .name = "call-fixture-oracle",
        .root_module = call_fixture_oracle_mod,
    });
    // The VM's tail-dispatch path requires LLVM on x86_64 with Zig 0.16.
    call_fixture_oracle.use_llvm = true;
    const run_call_fixture_oracle = b.addRunArtifact(call_fixture_oracle);
    if (b.args) |args| run_call_fixture_oracle.addArgs(args);
    const call_fixture_oracle_step = b.step(
        "call-fixture-oracle",
        "Diff curated call fixtures against a local Geth evm binary",
    );
    call_fixture_oracle_step.dependOn(&run_call_fixture_oracle.step);

    const tests = addTests(b, .{
        .target = target,
        .optimize = optimize,
        .packages = packages,
        .stateless_profile = stateless_profile_none_mod,
        .native_build_options = native_build_options,
        .native_test_options = native_test_options,
        .native_test_options_all = native_test_options_all,
        .zkvm_test_options = zkvm_test_options,
        .zkvm_test_options_all = zkvm_test_options_all,
        .native_precompiles = native_precompile_deps,
        .xkcp = xkcp_object,
        .libsecp256k1 = libsecp256k1_object,
        .selected_profile = profile,
    });
    const ci_step = b.step("ci", "Run deterministic pull-request verification");
    ci_step.dependOn(&core_check.step);
    // ci always verifies the full fork matrix; -Dtest-forks cannot weaken it.
    ci_step.dependOn(tests.native_all);
    ci_step.dependOn(tests.zkvm_all);
    ci_step.dependOn(tests.packages);
    ci_step.dependOn(check_guest_elf_tests);
    ci_step.dependOn(check_zisk_failure_status_tests);
    ci_step.dependOn(tidy_step);
    ci_step.dependOn(fmt_step);

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
        rlp_fuzz_tests.use_llvm = true;
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
        mpt_fuzz_tests.use_llvm = true;
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

        const rlp_fuzz_step = b.step("fuzz-rlp", "Run RLP fuzz tests");
        rlp_fuzz_step.dependOn(&run_rlp_fuzz_tests.step);

        const mpt_fuzz_step = b.step("fuzz-mpt", "Run MPT fuzz tests");
        mpt_fuzz_step.dependOn(&run_mpt_fuzz_tests.step);
    }

    const optimize_name = @tagName(optimize);
    const bench_optimize_name = @tagName(bench_optimize);
    if (pathExists(b, "eest/build.zig")) {
        addEestDelegate(b, "eest-test", "Run sidecar EEST runner tests", "test", optimize_name, null, evmz_build, ci_step);
        addEestDelegate(b, "eest", "Run EEST state-test fixtures", "eest", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "eest-classify", "Classify EEST state-test fixtures", "eest-classify", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "eest-scope", "Report downloaded EEST fixture scope and support status", "eest-scope", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "eest-tx", "Run EEST raw transaction-test fixtures", "eest-tx", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "zkevm", "Run EEST zkEVM stateless SSZ fixtures", "zkevm", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "zkevm-mutations", "Run typed stateless mutation rejection fixtures", "zkevm-mutations", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "zkevm-input", "Extract one EEST zkEVM stateless input for a zkVM guest", "zkevm-input", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "zkevm-ere", "Run raw ERE stateless input through native adapter", "zkevm-ere", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "eest-block-stf", "Run regular EEST blockchain_tests through BlockSTF", "eest-block-stf", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "eest-stateless-block-stf", "Run witness-backed zkEVM blockchain_tests through stateless BlockSTF", "eest-stateless-block-stf", optimize_name, null, evmz_build, null);
        addEestDelegate(b, "ssz-conformance", "Run consensus-spec generic SSZ fixtures", "ssz-conformance", optimize_name, null, evmz_build, null);
    }
    if (pathExists(b, "bench/build.zig")) {
        addBenchDelegate(b, "bench-test", "Run benchmark sidecar tests", "test", null, evmz_build, null);
        addBenchRevisionDelegate(b, "bench-vm-loop", "Run evmz VM-loop fixture runner", "vm-loop", bench_optimize_name, bench_support_min, bench_support_max, evmz_build);
        addBenchDelegate(b, "bench-evmone-vm-loop", "Run standalone evmone VM-loop fixture runner", "evmone-vm-loop", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-revm-vm-loop", "Run revm VM-loop fixture runner", "revm-vm-loop", null, evmz_build, null);
        addBenchRevisionDelegate(b, "bench-compare", "Run VM-core comparison", "compare", bench_optimize_name, bench_support_min, bench_support_max, evmz_build);
        addBenchDelegate(b, "bench-block-lifecycle", "Run VM block lifecycle benchmark", "block-lifecycle", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-host-boundary", "Run host-boundary benchmark runner", "host-boundary", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-host-matrix", "Run host-boundary CSV matrix", "host-matrix", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-kernel", "Run pure opcode kernel benchmark", "kernel", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-code-analysis", "Run code-analysis morphology and timing report", "code-analysis", bench_optimize_name, evmz_build, null);
        addBenchDelegate(b, "bench-revm-kernel", "Run revm opcode kernel benchmark", "revm-kernel", null, evmz_build, null);
        addBenchDelegate(b, "bench-report", "Run all benchmark layers and write a comparison report", "report", bench_optimize_name, evmz_build, null);
        addBenchMicroDelegate(b, bench_optimize_name, bench_micro_filter, evmz_build);
    }
    if (pathExists(b, "pkg/ssz/build.zig")) {
        addSszBenchDelegate(b, bench_optimize_name);
    }
    if (is_native_profile and pathExists(b, "pkg/evmc/build.zig")) {
        addEvmcDelegate(b, "evmc", "Build the EVMC compatibility package", null, target, optimize_name, evmz_build);
        addEvmcDelegate(b, "evmc-ci", "Build and test the EVMC compatibility package", "ci", target, optimize_name, evmz_build);
        addEvmcDelegate(b, "evmc-test", "Run EVMC compatibility package tests", "test", target, optimize_name, evmz_build);
        addEvmcDelegate(b, "evmc-example", "Run the EVMC C example", "example", target, optimize_name, evmz_build);
    }

    // Capacity is free in guest execution steps: the linker reserves the heap
    // after `_bss_end` as bare address space, nothing zeroes it, and the bump
    // allocator only writes what it hands out. Default to filling ZisK's RAM,
    // matching what ERE guests get, rather than to a number sized for one
    // corpus. Shrink it deliberately once a real workload's peak is known.
    const guest_heap_bytes = b.option(
        u64,
        "guest-heap-bytes",
        "Fixed guest payload heap capacity in bytes",
    ) orelse 480 * 1024 * 1024;
    // 0xA0030000 + 536674304 = 0xC0000000, ZisK's RAM top.
    const guest_zisk_ram_bytes = b.option(
        u64,
        "guest-zisk-ram-bytes",
        "ZisK guest RAM envelope in bytes",
    ) orelse 536674304;

    const guest_payload_steps = addGuestPayloadTests(b, target, optimize, native_evmz_mod, guest_heap_bytes);
    ci_step.dependOn(guest_payload_steps.tests);
    ci_step.dependOn(guest_payload_steps.abi);
    const ziskos_staticlib_path = b.option(
        []const u8,
        "ziskos-staticlib",
        "Path to a ZisK libziskos_staticlib.a provider for guest-zisk",
    );
    const sp1_staticlib_path = b.option(
        []const u8,
        "sp1-staticlib",
        "Path to an SP1 libzkevm.a provider for guest-sp1",
    );
    const guest_input_path = b.option([]const u8, "guest-input", "Path to zkVM guest input");
    const guest_output_path = b.option([]const u8, "guest-output", "Path to write zkVM public output");
    const guest_payload = b.option(GuestPayload, "guest-payload", "Guest payload") orelse .@"stateless-ere";
    const guest_zisk_strip = b.option(bool, "guest-zisk-strip", "Strip symbols from the ZisK guest ELF") orelse false;
    const guest_sp1_strip = b.option(bool, "guest-sp1-strip", "Strip symbols from the SP1 guest ELF") orelse true;
    const guest_zisk_profile_tags = b.option(bool, "guest-zisk-profile-tags", "Instrument ZisK stateless validation phases") orelse false;
    const guest_heap_metrics = b.option(bool, "guest-heap-metrics", "Meter guest fixed-heap usage") orelse false;
    addGuest(
        b,
        .zisk,
        optimize,
        ziskos_staticlib_path,
        guest_payload,
        guest_input_path,
        guest_output_path,
        guest_zisk_strip,
        omit_frame_pointer,
        guest_zisk_profile_tags,
        guest_heap_metrics,
        guest_heap_bytes,
        guest_zisk_ram_bytes,
        zkvm_build_options,
    );
    addGuest(
        b,
        .sp1,
        optimize,
        sp1_staticlib_path,
        guest_payload,
        guest_input_path,
        guest_output_path,
        guest_sp1_strip,
        omit_frame_pointer,
        false,
        guest_heap_metrics,
        guest_heap_bytes,
        null,
        zkvm_build_options,
    );

    // examples
    {
        const example_name = b.option(
            []const u8,
            "example-name",
            "Name of the example",
        ) orelse "basic.zig";

        const is_zig = std.mem.endsWith(u8, example_name, ".zig");
        if (is_zig) {
            addExamplesDelegate(b, "example", "Run the selected Zig example", "example", example_name, target, optimize_name, evmz_build, null);
            addExamplesDelegate(b, "example-test", "Run tests in the selected Zig example", "example-test", example_name, target, optimize_name, evmz_build, null);
            addExamplesDelegate(b, "examples-test-all", "Run tests in all Zig examples", "test", example_name, target, optimize_name, evmz_build, null);
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

// `b.option` validates and lists these in `zig build --help`
const Profile = enum { native, zkvm };
const KeccakBackend = enum { std, xkcp };
const Secp256k1Backend = enum { std, libsecp256k1 };
// Membership is resolved in `src/t.zig`.
const TestForks = enum { head, dev, all };

/// Accelerated backends only exist for the architectures we build assembly for,
/// and never under the zkVM profile.
fn resolveNativeKeccak(
    profile: Profile,
    target: std.Build.ResolvedTarget,
    requested: KeccakBackend,
) KeccakBackend {
    if (profile != .native or requested != .xkcp) return .std;
    return switch (target.result.cpu.arch) {
        .x86_64, .aarch64, .riscv64 => .xkcp,
        else => .std,
    };
}

fn resolveNativeSecp256k1(
    profile: Profile,
    target: std.Build.ResolvedTarget,
    requested: Secp256k1Backend,
) Secp256k1Backend {
    if (profile != .native or requested != .libsecp256k1) return .std;
    return switch (target.result.cpu.arch) {
        .x86_64, .aarch64, .riscv64 => .libsecp256k1,
        else => .std,
    };
}

fn buildOptions(
    b: *std.Build,
    profile: Profile,
    native_keccak: KeccakBackend,
    native_secp256k1: Secp256k1Backend,
    stateless_schemas: []const []const u8,
    test_forks: ?TestForks,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(Profile, "profile", profile);
    options.addOption(KeccakBackend, "native_keccak", native_keccak);
    options.addOption(Secp256k1Backend, "native_secp256k1", native_secp256k1);
    options.addOption([]const []const u8, "stateless_schemas", stateless_schemas);
    // Test-only: absent from production and guest options so the knob can
    // never dirty shipped artifacts. `t.zig` treats a missing field as `all`.
    if (test_forks) |preset| options.addOption([]const u8, "test_forks", @tagName(preset));
    return options;
}

fn createPackageModules(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    omit_frame_pointer: ?bool,
    exported: bool,
) PackageModules {
    const ssz_options = std.Build.Module.CreateOptions{
        .root_source_file = b.path("pkg/ssz/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
    };
    const rlp_options = std.Build.Module.CreateOptions{
        .root_source_file = b.path("pkg/rlp/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
    };
    const mpt_options = std.Build.Module.CreateOptions{
        .root_source_file = b.path("pkg/mpt/src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
    };
    const ssz = if (exported) b.addModule("ssz", ssz_options) else b.createModule(ssz_options);
    const rlp = if (exported) b.addModule("rlp", rlp_options) else b.createModule(rlp_options);
    const mpt = if (exported) b.addModule("mpt", mpt_options) else b.createModule(mpt_options);
    mpt.addImport("rlp", rlp);
    return .{ .ssz = ssz, .rlp = rlp, .mpt = mpt };
}

fn createEvmzModule(b: *std.Build, config: EvmzModuleConfig) *std.Build.Module {
    const options = std.Build.Module.CreateOptions{
        .root_source_file = b.path("src/evm.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .single_threaded = if (config.guest) true else null,
        .strip = config.strip,
        .unwind_tables = if (config.guest) .none else null,
        .code_model = if (config.guest) .medium else .default,
        .pic = if (config.guest) false else config.pic,
        .omit_frame_pointer = config.omit_frame_pointer,
        .error_tracing = if (config.guest) false else null,
    };
    const module = if (config.exported)
        b.addModule("evmz", options)
    else
        b.createModule(options);
    module.addOptions("build_options", config.build_options);
    module.addImport("stateless_profile", config.stateless_profile);
    module.addImport("ssz", config.packages.ssz);
    module.addImport("rlp", config.packages.rlp);
    module.addImport("mpt", config.packages.mpt);
    module.addIncludePath(b.path("include"));
    if (config.native_precompiles) |deps| addPrecompileNative(b, module, deps);
    addNativeKeccak(module, config.xkcp);
    addNativeSecp256k1(module, config.libsecp256k1);
    return module;
}

/// Forward `zig build test -- <substring>` to the custom runner as runtime
/// filters; argv changes re-run the cached binary without recompiling.
fn runTests(b: *std.Build, tests: *std.Build.Step.Compile) *std.Build.Step {
    const run = b.addRunArtifact(tests);
    if (b.args) |args| run.addArgs(args);
    return &run.step;
}

fn addTests(b: *std.Build, config: TestConfig) TestSteps {
    // Compile-time pruning stays a deliberate build option; ad-hoc filtering
    // belongs to the runner's TEST_FILTER env var, which needs no recompile.
    const test_filters = b.option(
        []const []const u8,
        "test-filter",
        "Compile only tests whose names contain this filter (repeatable)",
    ) orelse &.{};
    const test_runner = std.Build.Step.Compile.TestRunner{
        .path = b.path("tools/test_runner.zig"),
        .mode = .simple,
    };
    const native_test_mod = createEvmzModule(b, .{
        .target = config.target,
        .optimize = config.optimize,
        .build_options = config.native_test_options,
        .stateless_profile = config.stateless_profile,
        .packages = config.packages,
        .native_precompiles = config.native_precompiles,
        .xkcp = config.xkcp,
        .libsecp256k1 = config.libsecp256k1,
    });
    const native_tests = b.addTest(.{
        .name = "evmz-native-tests",
        .root_module = native_test_mod,
        .filters = test_filters,
        .test_runner = test_runner,
    });

    // Zig 0.16's self-hosted x86_64 backend cannot lower `.always_tail`.
    native_tests.use_llvm = true;
    const native_step = b.step("test-evmz-native", "Run native-profile evmz tests");
    native_step.dependOn(runTests(b, native_tests));

    const native_all_test_mod = createEvmzModule(b, .{
        .target = config.target,
        .optimize = config.optimize,
        .build_options = config.native_test_options_all,
        .stateless_profile = config.stateless_profile,
        .packages = config.packages,
        .native_precompiles = config.native_precompiles,
        .xkcp = config.xkcp,
        .libsecp256k1 = config.libsecp256k1,
    });
    const native_all_tests = b.addTest(.{
        .name = "evmz-native-all-tests",
        .root_module = native_all_test_mod,
        .filters = test_filters,
        .test_runner = test_runner,
    });
    native_all_tests.use_llvm = true;
    const native_all_step = b.step(
        "test-evmz-native-all",
        "Run native-profile evmz tests with the full fork matrix",
    );
    native_all_step.dependOn(runTests(b, native_all_tests));

    const zkvm_test_mod = createEvmzModule(b, .{
        .target = config.target,
        .optimize = config.optimize,
        .build_options = config.zkvm_test_options,
        .stateless_profile = config.stateless_profile,
        .packages = config.packages,
    });
    const provider_mod = b.createModule(.{
        .root_source_file = b.path("src/zkvm_accelerators_native_test.zig"),
        .target = config.target,
        .optimize = config.optimize,
        .link_libcpp = true,
    });
    provider_mod.addOptions("build_options", config.native_build_options);
    addPrecompileNative(b, provider_mod, config.native_precompiles);
    const provider = b.addObject(.{
        .name = "zkvm-test-accelerators",
        .root_module = provider_mod,
    });
    provider.use_llvm = true;
    zkvm_test_mod.addObject(provider);
    zkvm_test_mod.link_libcpp = true;

    const zkvm_tests = b.addTest(.{
        .name = "evmz-zkvm-tests",
        .root_module = zkvm_test_mod,
        .filters = test_filters,
        .test_runner = test_runner,
    });
    zkvm_tests.use_llvm = true;
    const provider_tests = b.addTest(.{
        .name = "zkvm-test-accelerators",
        .root_module = provider_mod,
    });
    provider_tests.use_llvm = true;
    const zkvm_step = b.step("test-evmz-zkvm", "Run zkVM-profile evmz semantic tests");
    zkvm_step.dependOn(runTests(b, zkvm_tests));
    zkvm_step.dependOn(&b.addRunArtifact(provider_tests).step);

    const zkvm_all_test_mod = createEvmzModule(b, .{
        .target = config.target,
        .optimize = config.optimize,
        .build_options = config.zkvm_test_options_all,
        .stateless_profile = config.stateless_profile,
        .packages = config.packages,
    });
    zkvm_all_test_mod.addObject(provider);
    zkvm_all_test_mod.link_libcpp = true;
    const zkvm_all_tests = b.addTest(.{
        .name = "evmz-zkvm-all-tests",
        .root_module = zkvm_all_test_mod,
        .filters = test_filters,
        .test_runner = test_runner,
    });
    zkvm_all_tests.use_llvm = true;
    const zkvm_all_step = b.step(
        "test-evmz-zkvm-all",
        "Run zkVM-profile evmz semantic tests with the full fork matrix",
    );
    zkvm_all_step.dependOn(runTests(b, zkvm_all_tests));
    zkvm_all_step.dependOn(&b.addRunArtifact(provider_tests).step);

    const ssz_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("pkg/ssz/src/test.zig"),
            .target = config.target,
            .optimize = config.optimize,
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const rlp_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("pkg/rlp/src/test.zig"),
            .target = config.target,
            .optimize = config.optimize,
        }),
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const mpt_tests_mod = b.createModule(.{
        .root_source_file = b.path("pkg/mpt/test.zig"),
        .target = config.target,
        .optimize = config.optimize,
    });
    mpt_tests_mod.addImport("mpt", config.packages.mpt);
    const mpt_tests = b.addTest(.{
        .root_module = mpt_tests_mod,
        .filters = test_filters,
        .test_runner = test_runner,
    });
    const packages_step = b.step("test-packages", "Run SSZ, RLP, and MPT tests");
    packages_step.dependOn(runTests(b, ssz_tests));
    packages_step.dependOn(runTests(b, rlp_tests));
    packages_step.dependOn(runTests(b, mpt_tests));

    const selected_step = b.step("test", "Run unit tests for the selected profile");
    selected_step.dependOn(if (config.selected_profile == .native) native_step else zkvm_step);
    selected_step.dependOn(packages_step);

    return .{
        .native = native_step,
        .native_all = native_all_step,
        .zkvm = zkvm_step,
        .zkvm_all = zkvm_all_step,
        .packages = packages_step,
        .selected = selected_step,
    };
}

fn guestOptions(
    b: *std.Build,
    backend: GuestBackend,
    heap_metrics: bool,
    heap_bytes: u64,
) *std.Build.Step.Options {
    const options = b.addOptions();
    options.addOption(GuestBackend, "backend", backend);
    options.addOption(bool, "heap_metrics", heap_metrics);
    options.addOption(u64, "heap_bytes", heap_bytes);
    return options;
}

const GuestBackend = enum {
    native,
    zisk,
    sp1,

    fn config(self: GuestBackend) GuestBackendConfig {
        return switch (self) {
            .native => unreachable,
            .zisk => .{
                .target_features = "generic_rv64+m+zicclsm+relax",
                .runtime_root = "guest/runtime/zisk/root.zig",
                .linker_script = "guest/runtime/zisk/zisk-rv64.ld",
                .artifact_name = "evmz-guest-zisk",
                .install_dir = "guest/zisk",
                .build_step = "guest-zisk",
                .build_description = "Build the ZisK rv64 guest ELF",
                .run_step = "guest-zisk-run",
                .run_description = "Run the ZisK guest ELF with ziskemu",
                .missing_provider = "guest-zisk requires -Dziskos-staticlib=<path>/libziskos_staticlib.a",
            },
            .sp1 => .{
                .target_features = "generic_rv64+m+relax",
                .runtime_root = "guest/runtime/sp1/root.zig",
                .linker_script = "guest/runtime/sp1/sp1-rv64.ld",
                .artifact_name = "evmz-guest-sp1",
                .install_dir = "guest/sp1",
                .build_step = "guest-sp1",
                .build_description = "Build the SP1 rv64 guest ELF",
                .run_step = "guest-sp1-run",
                .run_description = "Run the SP1 guest ELF",
                .missing_provider = "guest-sp1 requires -Dsp1-staticlib=<path>/libzkevm.a",
            },
        };
    }
};

const GuestBackendConfig = struct {
    target_features: []const u8,
    runtime_root: []const u8,
    linker_script: []const u8,
    artifact_name: []const u8,
    install_dir: []const u8,
    build_step: []const u8,
    build_description: []const u8,
    run_step: []const u8,
    run_description: []const u8,
    missing_provider: []const u8,
};

const GuestCompilePolicy = struct {
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    omit_frame_pointer: bool,
    strip: bool,

    fn module(
        self: GuestCompilePolicy,
        b: *std.Build,
        source: []const u8,
        imports: []const std.Build.Module.Import,
    ) *std.Build.Module {
        return b.createModule(.{
            .root_source_file = b.path(source),
            .target = self.target,
            .optimize = self.optimize,
            .code_model = .medium,
            .error_tracing = false,
            .omit_frame_pointer = self.omit_frame_pointer,
            .imports = imports,
            .pic = false,
            .single_threaded = true,
            .strip = self.strip,
            .unwind_tables = .none,
        });
    }
};

const GuestPayload = enum {
    basic,
    @"exit-failure-probe",
    @"stateless-ere",

    fn source(self: GuestPayload) []const u8 {
        return switch (self) {
            .basic => "guest/payload/basic.zig",
            .@"exit-failure-probe" => "guest/payload/exit_failure_probe.zig",
            .@"stateless-ere" => "guest/payload/stateless_ere.zig",
        };
    }
};

fn addGuestPayloadTests(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmz_mod: *std.Build.Module,
    heap_bytes: u64,
) GuestPayloadSteps {
    const guest_options = guestOptions(b, .native, false, heap_bytes);
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
    const payload_tests_mod = b.createModule(.{
        .root_source_file = b.path("guest/payload/test.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_payload_basic", .module = basic_payload_mod },
            .{ .name = "guest_payload_stateless_ere", .module = stateless_ere_payload_mod },
        },
    });
    const payload_tests = b.addTest(.{
        .name = "guest-payload-tests",
        .root_module = payload_tests_mod,
    });
    payload_tests.use_llvm = true;

    const test_step = b.step("guest-payload-test", "Run native tests for guest payload fixtures");
    test_step.dependOn(&b.addRunArtifact(payload_tests).step);

    const basic_abi = b.addObject(.{
        .name = "guest-payload-basic-abi",
        .root_module = basic_payload_mod,
    });
    basic_abi.use_llvm = true;
    const stateless_ere_abi = b.addObject(.{
        .name = "guest-payload-stateless-ere-abi",
        .root_module = stateless_ere_payload_mod,
    });
    stateless_ere_abi.use_llvm = true;
    const abi_step = b.step(
        "guest-payload-abi-check",
        "Compile guest payloads with production C exports enabled",
    );
    abi_step.dependOn(&basic_abi.step);
    abi_step.dependOn(&stateless_ere_abi.step);

    return .{ .tests = test_step, .abi = abi_step };
}

fn addGuest(
    b: *std.Build,
    backend: GuestBackend,
    optimize: std.builtin.OptimizeMode,
    provider_path_option: ?[]const u8,
    guest_payload: GuestPayload,
    guest_input_path: ?[]const u8,
    guest_output_path: ?[]const u8,
    strip: bool,
    omit_frame_pointer: bool,
    profile_tags: bool,
    heap_metrics: bool,
    heap_bytes: u64,
    ram_bytes: ?u64,
    build_options: *std.Build.Step.Options,
) void {
    const config = backend.config();
    // A zero heap_bytes collapses _heap_start onto _heap_end, which the guest
    // allocator reads as unreachable. Every other memory bound is left to the linker
    // script, which unlike this function knows the guest's own data and bss sizes.
    const unbuildable: ?[]const u8 = if (provider_path_option == null)
        config.missing_provider
    else if (heap_bytes == 0)
        "guest-heap-bytes must be greater than zero"
    else
        null;
    if (unbuildable) |message| {
        const fail = b.addFail(message);
        const guest_step = b.step(config.build_step, config.build_description);
        guest_step.dependOn(&fail.step);
        const run_step = b.step(config.run_step, config.run_description);
        run_step.dependOn(&fail.step);
        return;
    }
    const provider_path = provider_path_option.?;

    const target = b.resolveTargetQuery(std.Target.Query.parse(.{
        .arch_os_abi = "riscv64-freestanding",
        .cpu_features = config.target_features,
    }) catch @panic("invalid guest target"));
    const policy = GuestCompilePolicy{
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = omit_frame_pointer,
        .strip = strip,
    };
    const guest_options = guestOptions(b, backend, heap_metrics, heap_bytes);
    const guest_options_mod = guest_options.createModule();
    const guest_payload_source = guest_payload.source();
    const stateless_profile_mod = policy.module(
        b,
        if (profile_tags) "guest/profile_zisk.zig" else "guest/profile_none.zig",
        &.{},
    );

    const packages = createPackageModules(b, target, optimize, omit_frame_pointer, false);
    const evmz_mod = createEvmzModule(b, .{
        .target = target,
        .optimize = optimize,
        .build_options = build_options,
        .stateless_profile = stateless_profile_mod,
        .packages = packages,
        .omit_frame_pointer = omit_frame_pointer,
        .guest = true,
        .strip = strip,
    });

    const guest_allocator_mod = policy.module(
        b,
        "guest/allocator.zig",
        &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
    );
    const payload_mod = policy.module(
        b,
        guest_payload_source,
        &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
            .{ .name = "guest_allocator", .module = guest_allocator_mod },
        },
    );
    const guest_io_mod = policy.module(
        b,
        "guest/io.zig",
        &.{
            .{ .name = "evmz", .module = evmz_mod },
            .{ .name = "guest_options", .module = guest_options_mod },
        },
    );
    payload_mod.addImport("guest_io", guest_io_mod);
    const root_mod = policy.module(
        b,
        config.runtime_root,
        &.{.{ .name = "guest_payload", .module = payload_mod }},
    );
    const memory_symbols_source = if (ram_bytes) |bytes|
        b.fmt(
            \\.global _evmz_payload_heap_size
            \\.set _evmz_payload_heap_size, {d}
            \\.global _evmz_ram_size
            \\.set _evmz_ram_size, {d}
            \\
        , .{ heap_bytes, bytes })
    else
        b.fmt(
            \\.global _evmz_payload_heap_size
            \\.set _evmz_payload_heap_size, {d}
            \\
        , .{heap_bytes});
    const memory_symbols = b.addWriteFiles().add(
        b.fmt("evmz-guest-memory-{s}.S", .{@tagName(backend)}),
        memory_symbols_source,
    );
    root_mod.addAssemblyFile(memory_symbols);
    root_mod.addObjectFile(.{ .cwd_relative = provider_path });
    if (backend == .sp1) {
        const atomics_mod = policy.module(b, "guest/runtime/sp1/atomics.zig", &.{});
        root_mod.addObject(b.addObject(.{
            .name = "evmz-sp1-atomics",
            .root_module = atomics_mod,
        }));
    }

    const guest = b.addExecutable(.{
        .name = config.artifact_name,
        .root_module = root_mod,
    });
    guest.entry = .{ .symbol_name = "_start" };
    guest.link_gc_sections = true;
    guest.setLinkerScript(b.path(config.linker_script));

    const install_guest = b.addInstallArtifact(guest, .{
        .dest_dir = .{ .override = .{ .custom = config.install_dir } },
        .dest_sub_path = b.fmt("{s}.elf", .{config.artifact_name}),
    });

    const guest_step = b.step(config.build_step, config.build_description);
    guest_step.dependOn(&install_guest.step);

    addGuestRunner(b, backend, guest, guest_input_path, guest_output_path);
}

fn addGuestRunner(
    b: *std.Build,
    backend: GuestBackend,
    guest: *std.Build.Step.Compile,
    guest_input_path: ?[]const u8,
    guest_output_path: ?[]const u8,
) void {
    switch (backend) {
        .native => unreachable,
        .zisk => {
            const ziskemu = b.option([]const u8, "ziskemu", "Path to ziskemu for guest-zisk-run") orelse "ziskemu";
            const ziskemu_steps = b.option([]const u8, "ziskemu-steps", "Maximum ziskemu steps for guest-zisk-run") orelse "5000000";
            const run = b.addSystemCommand(&.{ ziskemu, "-e" });
            run.addFileArg(guest.getEmittedBin());
            if (guest_input_path) |path| run.addArgs(&.{ "-i", path });
            if (guest_output_path) |path| run.addArgs(&.{ "-o", path });
            run.addArgs(&.{ "-n", ziskemu_steps, "-m", "--steps", "-c" });
            run.has_side_effects = true;

            const config = backend.config();
            const run_step = b.step(config.run_step, config.run_description);
            run_step.dependOn(&run.step);
        },
        .sp1 => {
            const config = backend.config();
            const host_manifest = b.pathFromRoot("guest/runtime/sp1/host/Cargo.toml");
            const host_target = b.cache_root.join(b.allocator, &.{"sp1-host"}) catch @panic("OOM");
            const build_host = b.addSystemCommand(&.{
                "cargo",
                "build",
                "--quiet",
                "--release",
                "--locked",
                "--manifest-path",
                host_manifest,
                "--target-dir",
                host_target,
            });
            build_host.has_side_effects = true;

            const host_exe = b.pathJoin(&.{ host_target, "release", "evmz-sp1-host" });
            const run = b.addSystemCommand(&.{ host_exe, "--elf" });
            run.step.dependOn(&build_host.step);
            run.addFileArg(guest.getEmittedBin());
            if (guest_input_path) |path| run.addArgs(&.{ "--input", path });
            if (guest_output_path) |path| run.addArgs(&.{ "--output", path });
            run.has_side_effects = true;

            const run_step = b.step(config.run_step, config.run_description);
            run_step.dependOn(&run.step);
        },
    }
}

/// Whole-tree hygiene check. It reads the working tree rather than a declared
/// input set, so the run can never be cached.
fn addTidy(b: *std.Build) *std.Build.Step {
    const tidy = b.addExecutable(.{
        .name = "tidy",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/tidy.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    const run = b.addRunArtifact(tidy);
    run.has_side_effects = true;
    run.addDirectoryArg(b.path("."));
    if (b.args) |args| run.addArgs(args);

    const step = b.step("tidy", "Report unused private declarations and orphan files");
    step.dependOn(&run.step);
    return step;
}

fn addCheckGuestElf(b: *std.Build) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path("tools/check_guest_elf.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const executable = b.addExecutable(.{
        .name = "check-guest-elf",
        .root_module = module,
    });
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("check-guest-elf", "Validate a zkEVM guest ELF").dependOn(&run.step);

    const tests = b.addTest(.{
        .name = "check-guest-elf-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_guest_elf.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    return &b.addRunArtifact(tests).step;
}

fn addCheckZiskFailureStatus(b: *std.Build) *std.Build.Step {
    const module = b.createModule(.{
        .root_source_file = b.path("tools/check_zisk_failure_status.zig"),
        .target = b.graph.host,
        .optimize = .ReleaseSafe,
    });
    const executable = b.addExecutable(.{
        .name = "check-zisk-failure-status",
        .root_module = module,
    });
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step(
        "check-zisk-failure-status",
        "Require ZisK to propagate a failure-probe guest return",
    ).dependOn(&run.step);

    const tests = b.addTest(.{
        .name = "check-zisk-failure-status-test",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/check_zisk_failure_status.zig"),
            .target = b.graph.host,
            .optimize = .ReleaseSafe,
        }),
    });
    return &b.addRunArtifact(tests).step;
}

fn addFmtCheck(b: *std.Build) *std.Build.Step {
    const fmt = b.addFmt(.{
        .paths = &.{
            "build.zig",
            "src",
            "pkg",
            "guest",
            "tools",
            "examples",
            "eest",
            "bench",
        },
        .check = true,
    });
    const step = b.step("fmt-check", "Check Zig source formatting");
    step.dependOn(&fmt.step);
    return step;
}

fn pathExists(b: *std.Build, sub_path: []const u8) bool {
    b.build_root.handle.access(b.graph.io, sub_path, .{}) catch return false;
    return true;
}

const NativePrecompileDeps = struct {
    ckzg_dep: *std.Build.Dependency,
    trusted_setup_mod: *std.Build.Module,
    object: *std.Build.Step.Compile,
};

fn nativePrecompileDeps(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    pic: ?bool,
) NativePrecompileDeps {
    const ckzg_dep = b.dependency("ckzg", .{ .target = target, .optimize = optimize });
    const blst_dep = b.dependency("blst", .{ .target = target, .optimize = optimize });
    const mcl_dep = b.dependency("mcl", .{});
    return .{
        .ckzg_dep = ckzg_dep,
        .trusted_setup_mod = buildTrustedSetupModule(b, ckzg_dep.path("src/trusted_setup.txt")),
        .object = buildNativePrecompileObject(b, target, optimize, blst_dep, mcl_dep, pic),
    };
}

const ChildBuildConfig = struct {
    directory: []const u8,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize: ?[]const u8 = null,
    bench_optimize: ?[]const u8 = null,
    target: ?std.Build.ResolvedTarget = null,
    example_name: ?[]const u8 = null,
    support_min: ?[]const u8 = null,
    support_max: ?[]const u8 = null,
    micro_filter: ?[]const u8 = null,
    evmz: EvmzBuildConfig,
    aggregate: ?*std.Build.Step = null,
    forward_args: bool = true,
};

fn addChildBuild(b: *std.Build, config: ChildBuildConfig) void {
    const run = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
    });
    if (config.target) |target| {
        run.addArg(b.fmt("-Dtarget={s}", .{target.query.zigTriple(b.allocator) catch @panic("OOM")}));
        run.addArg(b.fmt("-Dcpu={s}", .{target.query.serializeCpuAlloc(b.allocator) catch @panic("OOM")}));
    }
    if (config.optimize) |name| run.addArg(b.fmt("-Doptimize={s}", .{name}));
    if (config.bench_optimize) |name| run.addArg(b.fmt("-Dbench-optimize={s}", .{name}));
    if (config.example_name) |name| run.addArg(b.fmt("-Dexample-name={s}", .{name}));
    if (config.support_min) |revision| run.addArg(b.fmt("-Dbench-support-min={s}", .{revision}));
    if (config.support_max) |revision| run.addArg(b.fmt("-Dbench-support-max={s}", .{revision}));
    if (config.micro_filter) |filter| run.addArg(b.fmt("-Dmicro-filter={s}", .{filter}));
    addEvmzBuildArgs(run, b, config.evmz);
    run.addArg(config.child_step);
    if (config.forward_args) if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    };
    run.setCwd(b.path(config.directory));

    const step = b.step(config.step_name, config.description);
    step.dependOn(&run.step);
    if (config.aggregate) |parent| parent.dependOn(step);
}

fn addEestDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize: ?[]const u8,
    bench_optimize: ?[]const u8,
    evmz: EvmzBuildConfig,
    aggregate: ?*std.Build.Step,
) void {
    addChildBuild(b, .{
        .directory = "eest",
        .step_name = step_name,
        .description = description,
        .child_step = child_step,
        .optimize = optimize,
        .bench_optimize = bench_optimize,
        .evmz = evmz,
        .aggregate = aggregate,
    });
}

fn addBenchDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize: ?[]const u8,
    evmz: EvmzBuildConfig,
    aggregate: ?*std.Build.Step,
) void {
    addChildBuild(b, .{
        .directory = "bench",
        .step_name = step_name,
        .description = description,
        .child_step = child_step,
        .optimize = optimize,
        .evmz = evmz,
        .aggregate = aggregate,
    });
}

fn addExamplesDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    example_name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: []const u8,
    evmz: EvmzBuildConfig,
    aggregate: ?*std.Build.Step,
) void {
    addChildBuild(b, .{
        .directory = "examples",
        .step_name = step_name,
        .description = description,
        .child_step = child_step,
        .optimize = optimize,
        .target = target,
        .example_name = example_name,
        .evmz = evmz,
        .aggregate = aggregate,
    });
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
        b.fmt("-Dnative-keccak={t}", .{config.native_keccak}),
        b.fmt("-Dnative-secp256k1={t}", .{config.native_secp256k1}),
    });
    if (child_step) |name| run.addArg(name);
    if (b.args) |args| {
        run.addArg("--");
        run.addArgs(args);
    }
    run.setCwd(b.path("pkg/evmc"));

    b.step(step_name, description).dependOn(&run.step);
}

fn addBenchRevisionDelegate(
    b: *std.Build,
    step_name: []const u8,
    description: []const u8,
    child_step: []const u8,
    optimize: []const u8,
    support_min: ?[]const u8,
    support_max: ?[]const u8,
    evmz: EvmzBuildConfig,
) void {
    addChildBuild(b, .{
        .directory = "bench",
        .step_name = step_name,
        .description = description,
        .child_step = child_step,
        .optimize = optimize,
        .support_min = support_min,
        .support_max = support_max,
        .evmz = evmz,
    });
}

fn addBenchMicroDelegate(
    b: *std.Build,
    optimize: []const u8,
    micro_filter: ?[]const u8,
    evmz: EvmzBuildConfig,
) void {
    addChildBuild(b, .{
        .directory = "bench",
        .step_name = "bench-micro",
        .description = "Run focused zBench micro benchmarks",
        .child_step = "micro",
        .optimize = optimize,
        .micro_filter = micro_filter,
        .evmz = evmz,
        .forward_args = false,
    });
}

fn addEvmzBuildArgs(run: *std.Build.Step.Run, b: *std.Build, config: EvmzBuildConfig) void {
    run.addArg(b.fmt("-Dprofile={t}", .{config.profile}));
    run.addArg(b.fmt("-Dnative-keccak={t}", .{config.native_keccak}));
    run.addArg(b.fmt("-Dnative-secp256k1={t}", .{config.native_secp256k1}));
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
    module.link_libc = true;
    module.link_libcpp = true;
    module.addImport("ckzg", deps.ckzg_dep.module("ckzg"));
    module.addImport("kzg_trusted_setup", deps.trusted_setup_mod);
    module.addIncludePath(b.path("src/precompile"));
    module.addObject(deps.object);
}

fn buildNativePrecompileObject(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    blst_dep: *std.Build.Dependency,
    mcl_dep: *std.Build.Dependency,
    pic: ?bool,
) *std.Build.Step.Compile {
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
    const module = b.createModule(.{
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = pic,
    });
    module.addIncludePath(blst_dep.path("bindings"));
    module.addIncludePath(mcl_dep.path("include"));
    module.addIncludePath(mcl_dep.path("src"));
    module.addCSourceFile(.{ .file = b.path("src/precompile/bn254.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = mcl_dep.path("src/fp.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = mcl_dep.path("src/bn_c256.cpp"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = mcl_dep.path("src/base64.ll"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = mcl_dep.path("src/bint64.ll"), .flags = mcl_flags });
    module.addCSourceFile(.{ .file = b.path("src/precompile/bls12.c"), .flags = c_flags });
    return b.addObject(.{
        .name = if (pic == true) "native-precompiles-pic" else "native-precompiles",
        .root_module = module,
    });
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
