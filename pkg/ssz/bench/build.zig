const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const ssz_dep = b.dependency("ssz", .{
        .target = target,
        .optimize = optimize,
    });
    const zbench_dep = b.dependency("zbench", .{
        .target = target,
        .optimize = optimize,
    });

    const module = b.createModule(.{
        .root_source_file = b.path("src/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    module.addImport("ssz", ssz_dep.module("ssz"));
    module.addImport("zbench", b.createModule(.{
        .root_source_file = zbench_dep.path("src/zbench.zig"),
        .target = target,
        .optimize = optimize,
        .omit_frame_pointer = true,
    }));

    const executable = b.addExecutable(.{
        .name = "ssz-bench",
        .root_module = module,
    });
    const run = b.addRunArtifact(executable);
    if (b.args) |args| run.addArgs(args);
    b.step("bench", "Run the zbench-backed SSZ benchmark matrix").dependOn(&run.step);

    const tests = b.addTest(.{ .root_module = module });
    b.step("test", "Compile and run SSZ benchmark tests").dependOn(&b.addRunArtifact(tests).step);
}
