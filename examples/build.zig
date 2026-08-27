const std = @import("std");

// `b.option` validates these and lists them in `zig build --help`. The values
// are forwarded verbatim to the evmz dependency, which resolves the accelerated
// backends against the profile and target.
const Profile = enum { native, zkvm };
const KeccakBackend = enum { std, xkcp };
const Secp256k1Backend = enum { std, libsecp256k1 };

const Example = struct {
    name: []const u8,
    path: []const u8,
};

const examples = [_]Example{
    .{ .name = "basic", .path = "basic.zig" },
    .{ .name = "bal_parallel", .path = "bal_parallel.zig" },
    .{ .name = "op", .path = "op/main.zig" },
    .{ .name = "custom_fork", .path = "custom_fork/main.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = b.option(Profile, "profile", "Build profile") orelse .native;
    const native_keccak = b.option(KeccakBackend, "native-keccak", "Native Keccak backend") orelse .std;
    const native_secp256k1 = b.option(Secp256k1Backend, "native-secp256k1", "Native secp256k1 backend") orelse .std;
    const selected_path = b.option(
        []const u8,
        "example-name",
        "Name of the Zig example",
    ) orelse "basic.zig";

    const evmz_mod = b.dependency("evmz", .{
        .target = target,
        .optimize = optimize,
        .profile = profile,
        .@"native-keccak" = native_keccak,
        .@"native-secp256k1" = native_secp256k1,
    }).module("evmz");

    const run_selected_step = b.step("example", "Run the selected Zig example");
    const test_selected_step = b.step("example-test", "Run tests in the selected Zig example");
    const test_all_step = b.step("test", "Run tests in all Zig examples");
    var selected = false;

    for (examples) |example| {
        const executable = b.addExecutable(.{
            .name = example.name,
            .root_module = exampleModule(b, example.path, target, optimize, evmz_mod),
        });
        b.default_step.dependOn(&executable.step);
        const run = b.addRunArtifact(executable);
        if (b.args) |args| run.addArgs(args);

        const tests = b.addTest(.{
            .root_module = exampleModule(b, example.path, target, optimize, evmz_mod),
        });
        tests.use_llvm = true;
        const run_tests = b.addRunArtifact(tests);
        test_all_step.dependOn(&run_tests.step);

        if (std.mem.eql(u8, selected_path, example.path)) {
            selected = true;
            run_selected_step.dependOn(&run.step);
            test_selected_step.dependOn(&run_tests.step);
        }
    }

    if (!selected) {
        std.debug.panic("unknown Zig example '{s}'", .{selected_path});
    }
}

fn exampleModule(
    b: *std.Build,
    path: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    evmz_mod: *std.Build.Module,
) *std.Build.Module {
    return b.createModule(.{
        .root_source_file = b.path(path),
        .target = target,
        .optimize = optimize,
        .imports = &.{
            .{ .name = "evmz", .module = evmz_mod },
        },
    });
}
