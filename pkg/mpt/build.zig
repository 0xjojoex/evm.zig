const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const rlp_dep = b.dependency("rlp", .{ .target = target, .optimize = optimize });

    const mpt_mod = b.addModule("mpt", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });
    mpt_mod.addImport("rlp", rlp_dep.module("rlp"));

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
    b.step("test", "Run standalone MPT package tests").dependOn(&b.addRunArtifact(tests).step);

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
