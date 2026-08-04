const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const native_keccak = b.option(
        []const u8,
        "native-keccak",
        "Native Keccak backend forwarded to evmz: std or xkcp",
    ) orelse "std";
    const native_secp256k1 = b.option(
        []const u8,
        "native-secp256k1",
        "Native secp256k1 backend forwarded to evmz: std or libsecp256k1",
    ) orelse "std";

    const evmz_dep = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = "native",
        .pic = true,
        .@"native-keccak" = native_keccak,
        .@"native-secp256k1" = native_secp256k1,
    });
    const evmone_dep = b.dependency("evmone", .{
        .target = target,
        .optimize = optimize,
    });
    const evmz_mod = evmz_dep.module("evmz");

    const package_mod = b.addModule("evmz_evmc", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
        },
    });
    addEvmcIncludes(b, package_mod, evmone_dep);

    const adapter_mod = adapterModule(b, target, optimize, evmz_mod, evmone_dep);
    const static_lib = b.addLibrary(.{
        .name = "evmz-evmc",
        .root_module = adapter_mod,
        .linkage = .static,
    });
    const shared_lib = b.addLibrary(.{
        .name = "evmz-evmc",
        .root_module = adapter_mod,
        .linkage = .dynamic,
    });
    b.installArtifact(static_lib);
    b.installArtifact(shared_lib);

    const compatibility_header = b.addInstallHeaderFile(b.path("include/evmz.h"), "evmz.h");
    const adapter_header = b.addInstallHeaderFile(b.path("include/evmz/evmc.h"), "evmz/evmc.h");
    const evmc_header = b.addInstallHeaderFile(evmone_dep.path("evmc/include/evmc/evmc.h"), "evmc/evmc.h");
    const mit_license = b.addInstallFile(b.path("LICENSE-MIT"), "share/licenses/evmz-evmc/LICENSE-MIT");
    const apache_license = b.addInstallFile(b.path("LICENSE-APACHE"), "share/licenses/evmz-evmc/LICENSE-APACHE");
    b.getInstallStep().dependOn(&compatibility_header.step);
    b.getInstallStep().dependOn(&adapter_header.step);
    b.getInstallStep().dependOn(&evmc_header.step);
    b.getInstallStep().dependOn(&mit_license.step);
    b.getInstallStep().dependOn(&apache_license.step);

    const tests_mod = adapterModule(b, target, optimize, evmz_mod, evmone_dep);
    tests_mod.addCSourceFile(.{
        .file = b.path("src/c_api/evmc_abi18_smoke.c"),
        .flags = &.{ "-Wall", "-Wextra", "-pedantic", "-std=c23" },
    });
    const tests = b.addTest(.{
        .root_module = tests_mod,
        .filters = b.args orelse &.{},
    });
    tests.use_llvm = true;
    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run EVMC compatibility package tests");
    test_step.dependOn(&run_tests.step);

    const static_example = cExample(b, "evmz-evmc-example", target, optimize, evmone_dep);
    static_example.root_module.linkLibrary(static_lib);
    const run_static_example = b.addRunArtifact(static_example);
    run_static_example.has_side_effects = true;
    b.step("example", "Run the EVMC C example against the static library").dependOn(&run_static_example.step);

    const shared_example = cExample(b, "evmz-evmc-shared-example", target, optimize, evmone_dep);
    shared_example.root_module.linkLibrary(shared_lib);
    const run_shared_example = b.addRunArtifact(shared_example);
    run_shared_example.has_side_effects = true;
    b.step("shared-example", "Run the EVMC C example against the shared library").dependOn(&run_shared_example.step);

    const ci_step = b.step("ci", "Build and test the EVMC compatibility package");
    ci_step.dependOn(b.getInstallStep());
    ci_step.dependOn(&run_tests.step);
    ci_step.dependOn(&run_static_example.step);
    ci_step.dependOn(&run_shared_example.step);
}

fn cExample(
    b: *std.Build,
    name: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmone_dep: *std.Build.Dependency,
) *std.Build.Step.Compile {
    const example = b.addExecutable(.{
        .name = name,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    example.root_module.addIncludePath(b.path("include"));
    example.root_module.addIncludePath(evmone_dep.path("evmc/include"));
    example.root_module.addCSourceFile(.{
        .file = b.path("examples/basic.c"),
        .flags = &.{ "-Wall", "-Wextra", "-pedantic", "-std=c23" },
    });
    return example;
}

fn adapterModule(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmz_mod: *std.Build.Module,
    evmone_dep: *std.Build.Dependency,
) *std.Build.Module {
    const module = b.createModule(.{
        .root_source_file = b.path("src/evmc.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .link_libcpp = true,
        .pic = true,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
        },
    });
    addEvmcIncludes(b, module, evmone_dep);
    return module;
}

fn addEvmcIncludes(
    b: *std.Build,
    module: *std.Build.Module,
    evmone_dep: *std.Build.Dependency,
) void {
    module.addIncludePath(b.path("include"));
    module.addIncludePath(evmone_dep.path("evmc/include"));
}
