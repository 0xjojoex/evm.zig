const std = @import("std");

const Example = struct {
    name: []const u8,
    path: []const u8,
};

const examples = [_]Example{
    .{ .name = "basic", .path = "basic.zig" },
    .{ .name = "bal_parallel", .path = "bal_parallel.zig" },
    .{ .name = "op_deposit", .path = "op_deposit.zig" },
    .{ .name = "custom_fork", .path = "custom_fork/main.zig" },
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const profile = buildProfileOption(b);
    const native_keccak = nativeKeccakOption(b, profile);
    const native_secp256k1 = nativeSecp256k1Option(b, profile);
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

fn buildProfileOption(b: *std.Build) []const u8 {
    const profile = b.option([]const u8, "profile", "Build profile: native or zkvm") orelse "native";
    if (!std.mem.eql(u8, profile, "native") and !std.mem.eql(u8, profile, "zkvm")) {
        std.debug.panic("unsupported profile '{s}' (expected native or zkvm)", .{profile});
    }
    return profile;
}

fn nativeKeccakOption(b: *std.Build, profile: []const u8) []const u8 {
    const backend = b.option([]const u8, "native-keccak", "Native Keccak backend: std or xkcp") orelse "std";
    if (!std.mem.eql(u8, backend, "std") and !std.mem.eql(u8, backend, "xkcp")) {
        std.debug.panic("unsupported native Keccak backend '{s}' (expected std or xkcp)", .{backend});
    }
    return if (std.mem.eql(u8, profile, "native")) backend else "std";
}

fn nativeSecp256k1Option(b: *std.Build, profile: []const u8) []const u8 {
    const backend = b.option(
        []const u8,
        "native-secp256k1",
        "Native secp256k1 backend: std or libsecp256k1",
    ) orelse "std";
    if (!std.mem.eql(u8, backend, "std") and !std.mem.eql(u8, backend, "libsecp256k1")) {
        std.debug.panic("unsupported native secp256k1 backend '{s}' (expected std or libsecp256k1)", .{backend});
    }
    return if (std.mem.eql(u8, profile, "native")) backend else "std";
}
