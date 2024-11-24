const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const lib = b.addStaticLibrary(.{
        .name = "evmz",
        .root_source_file = b.path("src/evm.zig"),
        .target = target,
        .optimize = optimize,
    });
    b.installArtifact(lib);

    const static_c_lib = b.addStaticLibrary(.{
        .name = "evmcz",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    static_c_lib.addIncludePath(b.path("include"));
    static_c_lib.linkLibC();
    b.installArtifact(static_c_lib);
    b.default_step.dependOn(&static_c_lib.step);

    // test
    {
        // Creates a step for unit testing. This only builds the test executable
        // but does not run it.
        const lib_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/evm.zig"),
            .target = target,
            .optimize = optimize,
            .test_runner = b.path("test_runner.zig"),
        });

        lib_unit_tests.addIncludePath(b.path("include"));

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        // const exe_unit_tests = b.addTest(.{
        //     .root_source_file = b.path("src/main.zig"),
        //     .target = target,
        //     .optimize = optimize,
        //     .test_runner = b.path("test_runner.zig"),
        // });

        // const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        // test_step.dependOn(&run_exe_unit_tests.step);
    }
}
