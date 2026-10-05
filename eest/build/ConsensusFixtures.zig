//! Pinned consensus-spec fixtures, prepared once per user in a shared cache.
//! Zig 0.17 build scripts cannot run custom make steps, so a host tool
//! (`prepare_consensus_fixtures.zig`) does the work inside a run step.

const std = @import("std");
const pins = @import("../consensus.zon");
const presets = .{ "general", "mainnet", "minimal" };

pub fn create(b: *std.Build) [presets.len]std.Build.LazyPath {
    const tool = b.addExecutable(.{
        .name = "prepare-consensus-fixtures",
        .root_module = b.createModule(.{
            .root_source_file = b.path("build/prepare_consensus_fixtures.zig"),
            .target = b.graph.host,
        }),
    });
    const run = b.addRunArtifact(tool);
    run.setName("prepare shared consensus fixtures");
    // The shared cache lives outside the build graph; re-check it every run.
    run.has_side_effects = true;
    run.addFileArg(.zig_exe);
    const roots = run.addOutputDirectoryArg("consensus-fixtures");
    inline for (presets) |preset| {
        const pin = @field(pins, preset);
        const subdir = if (std.mem.eql(u8, preset, "general")) "general/phase0/ssz_generic" else preset;
        run.addArgs(&.{ preset, pin.url, pin.hash, subdir });
    }

    var paths: [presets.len]std.Build.LazyPath = undefined;
    inline for (presets, &paths) |preset, *path| path.* = roots.path(b, preset);
    return paths;
}
