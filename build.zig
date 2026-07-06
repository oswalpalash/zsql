const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    const zsql_mod = b.addModule("zsql", .{
        .root_source_file = b.path("src/zsql.zig"),
        .target = target,
        .optimize = optimize,
    });

    const lib = b.addLibrary(.{
        .linkage = .static,
        .name = "zsql",
        .root_module = zsql_mod,
    });
    b.installArtifact(lib);

    const tests = b.addTest(.{
        .root_module = zsql_mod,
    });

    const run_tests = b.addRunArtifact(tests);
    const test_step = b.step("test", "Run zsql tests");
    test_step.dependOn(&run_tests.step);
}
