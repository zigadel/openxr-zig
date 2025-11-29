const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // Optional override: -Dregistry=/abs/path/to/xr.xml
    const registry_opt = b.option([]const u8, "registry", "Override path to OpenXR XML registry");

    // Default to the xr.xml shipped in this repo (examples/xr.xml),
    // which is known to be compatible with this generator.
    const spec_path: []const u8 = registry_opt orelse b.pathFromRoot("examples/xr.xml");

    // ─────────────────────────────────────────────────────────────────────
    // Generator CLI: openxr-zig-generator
    // ─────────────────────────────────────────────────────────────────────
    const gen_mod = b.createModule(.{
        .root_source_file = b.path("generator/main.zig"),
        .target = target,
        .optimize = optimize,
    });

    const generator_exe = b.addExecutable(.{
        .name = "openxr-zig-generator",
        .root_module = gen_mod,
    });
    b.installArtifact(generator_exe);

    // Run generator at build time: openxr-zig-generator <xr.xml> <out.zig>
    const gen_cmd = b.addRunArtifact(generator_exe);
    gen_cmd.addArg(spec_path);
    const xr_zig = gen_cmd.addOutputFileArg("xr.zig");

    // Expose the generated bindings as a module named "openxr".
    const xr_mod = b.addModule("openxr", .{
        .root_source_file = xr_zig,
    });
    _ = xr_mod; // currently only used by dependents (via b.dependency(...).module("openxr"))

    // ─────────────────────────────────────────────────────────────────────
    // Tests for the generator itself
    // ─────────────────────────────────────────────────────────────────────
    const test_step = b.step("test", "Run generator tests");

    const test_mod = b.createModule(.{
        .root_source_file = b.path("generator/index.zig"),
        .target = target,
        .optimize = optimize,
    });

    const test_art = b.addTest(.{
        .root_module = test_mod,
    });

    const run_tests = b.addRunArtifact(test_art);
    test_step.dependOn(&run_tests.step);
}
