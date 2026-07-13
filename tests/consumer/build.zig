const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_sqlite = b.option(bool, "enable-sqlite", "Exercise SQLite") orelse false;
    const sqlite_system = b.option(bool, "sqlite-system", "Use system SQLite") orelse false;

    const zsql_dep = b.dependency("zsql", .{
        .target = target,
        .optimize = optimize,
        .@"enable-sqlite" = enable_sqlite,
        .@"sqlite-system" = sqlite_system,
    });
    const root = b.createModule(.{
        .root_source_file = b.path(if (enable_sqlite) "src/sqlite.zig" else "src/core.zig"),
        .target = target,
        .optimize = optimize,
    });
    root.addImport("zsql", zsql_dep.module("zsql"));
    const exe = b.addExecutable(.{ .name = "zsql-consumer-smoke", .root_module = root });
    const run = b.addRunArtifact(exe);
    b.step("run", "Compile and run the external-consumer smoke test").dependOn(&run.step);
}
