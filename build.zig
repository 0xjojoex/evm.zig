const std = @import("std");

pub fn build(b: *std.Build) !void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("evmz", .{
        .root_source_file = b.path("src/evm.zig")
    });

    const static_c_lib = b.addStaticLibrary(.{
        .name = "evmz",
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
    });
    static_c_lib.addIncludePath(b.path("include"));
    _ = static_c_lib.getEmittedH();
    static_c_lib.linkLibC();
    b.installArtifact(static_c_lib);
    b.default_step.dependOn(&static_c_lib.step);

    // C Headers
    const c_header = b.addInstallFileWithDir(
        b.path("include/evmz.h"),
        .header,
        "evmz.h",
    );
    b.getInstallStep().dependOn(&c_header.step);

    // test
    {
        const lib_unit_tests = b.addTest(.{
            .root_source_file = b.path("src/evm.zig"),
            .target = target,
            .optimize = optimize,
            .test_runner = b.path("test_runner.zig"),
        });

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
    }

    // example
    {
        const example_name = b.option(
            []const u8,
            "example-name",
            "Name of the example",
        ) orelse "basic.zig";

        const is_zig = std.mem.endsWith(u8, example_name, ".zig");
        const path = try std.fmt.allocPrint(b.allocator, "examples/{s}", .{example_name});
        defer b.allocator.free(path);
        const root_source_file = b.path(path);

        if (is_zig) {
            const example = b.addExecutable(.{
                .name = example_name,
                .root_source_file = root_source_file,
                .target = target,
                .optimize = optimize,
            });
            example.root_module.addImport("evmz", b.modules.get(
                "evmz"
            ).?);
            const run_example = b.addRunArtifact(example);
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);
        } else {
            const example_c = b.addExecutable(.{
                .name = example_name,
                .target = target,
                .optimize = optimize,
            });

            example_c.addIncludePath(b.path("include"));
            example_c.addCSourceFile(.{
                .file = b.path(path),
                .flags = &[_][]const u8{
                    "-Wall",
                    "-Wextra",
                    "-pedantic",
                    "-std=c99",
                },
            });
            example_c.linkLibrary(static_c_lib);
            const install_step = b.addInstallArtifact(example_c, .{
                           .dest_dir = .{ .override = .{ .custom = "example" } },
                       });
            b.getInstallStep().dependOn(&install_step.step);
            const run_example = b.addRunArtifact(example_c);
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);
        }
    }
}
