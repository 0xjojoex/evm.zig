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

    const static_c_lib = if (is_native_profile) static_c_lib: {
        const c_lib_mod = b.createModule(.{
            .root_source_file = b.path("src/evmc.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
        });
        c_lib_mod.addOptions("build_options", build_options);
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
        lib_unit_tests_mod.addIncludePath(b.path("include"));
        lib_unit_tests_mod.addIncludePath(evmone_dep.path("evmc/include"));
        if (native_precompile_deps) |deps| {
            addPrecompileNative(b, lib_unit_tests_mod, deps, evmone_dep);
        }
        const lib_unit_tests = b.addTest(.{
            .root_module = lib_unit_tests_mod,
            .filters = b.args orelse &.{},
        });

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        if (is_native_profile) {
            const c_api_tests_mod = b.createModule(.{
                .root_source_file = b.path("src/evmc.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
                .link_libcpp = true,
            });
            c_api_tests_mod.addOptions("build_options", build_options);
            c_api_tests_mod.addIncludePath(b.path("include"));
            c_api_tests_mod.addIncludePath(evmone_dep.path("evmc/include"));
            addPrecompileNative(b, c_api_tests_mod, native_precompile_deps.?, evmone_dep);
            const c_api_tests = b.addTest(.{
                .root_module = c_api_tests_mod,
                .filters = b.args orelse &.{},
            });
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
        addEestDelegate(b, "bench", "Run EEST benchmark blockchain-test fixtures", "bench", null, bench_optimize_name, profile);
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
