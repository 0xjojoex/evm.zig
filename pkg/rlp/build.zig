const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("rlp", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = b.args orelse &.{},
    });
    b.step("test", "Run RLP package tests").dependOn(&b.addRunArtifact(tests).step);

    const fuzz_tests = b.addTest(.{
        .name = "rlp-fuzz",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/fuzz.zig"),
            .target = target,
            .optimize = optimize,
            .error_tracing = false,
        }),
    });

    const fuzz_step = b.step("fuzz", "Run RLP fuzz tests");
    fuzz_step.dependOn(&b.addRunArtifact(fuzz_tests).step);
}
