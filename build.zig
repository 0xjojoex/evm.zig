const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    _ = b.addModule("ssz", .{
        .root_source_file = b.path("src/lib.zig"),
        .target = target,
        .optimize = optimize,
    });

    const run_bench = b.addSystemCommand(&.{
        b.graph.zig_exe,
        "build",
        b.fmt("-Doptimize={s}", .{@tagName(optimize)}),
        "bench",
    });
    if (b.args) |args| {
        run_bench.addArg("--");
        run_bench.addArgs(args);
    }
    run_bench.setCwd(b.path("bench"));
    b.step("bench", "Run SSZ encode, decode, and Merkleization benchmarks").dependOn(&run_bench.step);

    const tests = b.addTest(.{
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/test.zig"),
            .target = target,
            .optimize = optimize,
        }),
        .filters = b.args orelse &.{},
    });
    b.step("test", "Run SSZ package tests").dependOn(&b.addRunArtifact(tests).step);
}
