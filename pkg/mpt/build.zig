const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rlp_dep = b.dependency("rlp", .{ .target = target, .optimize = optimize });
    const region_mod = b.createModule(.{
        .root_source_file = b.path("src/ResettableRegion.zig"),
        .target = target,
        .optimize = optimize,
    });

    const mpt_mod = b.addModule("mpt", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_mod.addImport("rlp", rlp_dep.module("rlp"));
    mpt_mod.addImport("resettable_region", region_mod);

    const test_mod = b.createModule(.{
        .root_source_file = b.path("test.zig"),
        .target = target,
        .optimize = optimize,
    });
    test_mod.addImport("mpt", mpt_mod);
    const tests = b.addTest(.{
        .root_module = test_mod,
        .filters = b.args orelse &.{},
    });
    const region_tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/ResettableRegion.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = b.args orelse &.{},
    });
    const test_step = b.step("test", "Run standalone MPT package and region tests");
    test_step.dependOn(&b.addRunArtifact(tests).step);
    test_step.dependOn(&b.addRunArtifact(region_tests).step);

    const fuzz_mod = b.createModule(.{
        .root_source_file = b.path("src/fuzz.zig"),
        .target = target,
        .optimize = optimize,
        .error_tracing = false,
    });
    fuzz_mod.addImport("mpt", mpt_mod);
    const fuzz_tests = b.addTest(.{
        .name = "mpt-fuzz",
        .root_module = fuzz_mod,
    });
    b.step("fuzz", "Run MPT fuzz tests").dependOn(&b.addRunArtifact(fuzz_tests).step);
}
