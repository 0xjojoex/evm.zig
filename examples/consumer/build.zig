//! A downstream package that depends on evmz the way the README's Install
//! section shows, running the README's quick start.
//!
//! It leaves `use_llvm` unset on purpose, so CI builds it on the compiler's
//! default backend: on x86_64 Linux, Debug uses the self-hosted backend and
//! linker, while `fast` and `small` use LLVM. Zig 0.17.1's self-hosted ELF
//! linker crashes (SEGV) on evmz's native precompile object (Zig issue 36588),
//! so the Debug build fails until that is fixed; see the README's Install
//! section.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const evmz = b.dependency("evmz", .{ .target = target, .optimize = optimize });
    const exe = b.addExecutable(.{
        .name = "consumer",
        .root_module = b.createModule(.{
            .root_source_file = b.path("main.zig"),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "evmz", .module = evmz.module("evmz") },
            },
        }),
    });
    b.installArtifact(exe);

    const run = b.addRunArtifact(exe);
    b.step("run", "Run the quick start").dependOn(&run.step);
}
