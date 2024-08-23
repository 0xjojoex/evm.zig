const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // const evmz_module = b.addModule("evmz", .{
    //     .root_source_file = b.path("src/evm.zig"),
    // });

    // const lib = b.addStaticLibrary(.{
    //     .name = "evmz",
    //     .root_source_file = b.path("src/evm.zig"),
    //     .target = target,
    //     .optimize = optimize,
    // });
    // .b.installArtifact(lib);

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

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const exe_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .test_runner = b.path("test_runner.zig"),
        });

        const run_exe_unit_tests = b.addRunArtifact(exe_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_exe_unit_tests.step);
    }
}
