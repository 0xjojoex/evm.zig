const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const evmz_mod = b.addModule("evmz", .{
        .root_source_file = b.path("src/evm.zig"),
        .target = target,
    });

    const c_lib_mod = b.createModule(.{
        .root_source_file = b.path("src/c_api.zig"),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
    });
    c_lib_mod.addIncludePath(b.path("include"));

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
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/evm.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const run_lib_unit_tests = b.addRunArtifact(lib_unit_tests);

        const c_api_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/c_api.zig"),
                .target = target,
                .optimize = optimize,
                .link_libc = true,
            }),
        });
        c_api_tests.root_module.addIncludePath(b.path("include"));
        const run_c_api_tests = b.addRunArtifact(c_api_tests);

        const eest_tests = b.addTest(.{
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/eest.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });
        const run_eest_tests = b.addRunArtifact(eest_tests);

        const test_step = b.step("test", "Run unit tests");
        test_step.dependOn(&run_lib_unit_tests.step);
        test_step.dependOn(&run_c_api_tests.step);
        test_step.dependOn(&run_eest_tests.step);
    }

    // EEST state-test fixture subset runner
    {
        const eest_exe = b.addExecutable(.{
            .name = "evmz-eest",
            .root_module = b.createModule(.{
                .root_source_file = b.path("src/eest_cli.zig"),
                .target = target,
                .optimize = optimize,
            }),
        });

        const run_eest = b.addRunArtifact(eest_exe);
        if (b.args) |args| {
            run_eest.addArgs(args);
        }

        const eest_step = b.step("eest", "Run EEST state-test fixtures");
        eest_step.dependOn(&run_eest.step);
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

        if (is_zig) {
            const example = b.addExecutable(.{
                .name = example_name,
                .root_module = b.createModule(.{
                    .root_source_file = root_source_file,
                    .target = target,
                    .optimize = optimize,
                    .imports = &.{
                        .{ .name = "evmz", .module = evmz_mod },
                    },
                }),
            });
            const run_example = b.addRunArtifact(example);
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);
        } else {
            const example_c = b.addExecutable(.{
                .name = example_name,
                .root_module = b.createModule(.{
                    .target = target,
                    .optimize = optimize,
                    .link_libc = true,
                }),
            });

            example_c.root_module.addIncludePath(b.path("include"));
            example_c.root_module.addCSourceFile(.{
                .file = b.path(path),
                .flags = &[_][]const u8{
                    "-Wall",
                    "-Wextra",
                    "-pedantic",
                    "-std=c99",
                },
            });
            example_c.root_module.linkLibrary(static_c_lib);
            var run_example = b.addRunArtifact(example_c);
            run_example.has_side_effects = true;
            const run_step = b.step("example", "Run the example");
            run_step.dependOn(&run_example.step);
        }
    }
}
