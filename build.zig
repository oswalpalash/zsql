const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const enable_sqlite = b.option(bool, "enable-sqlite", "Compile the experimental SQLite driver skeleton") orelse false;

    const options = b.addOptions();
    options.addOption(bool, "enable_sqlite", enable_sqlite);

    const zsql_mod = b.addModule("zsql", .{
        .root_source_file = b.path("src/zsql.zig"),
        .target = target,
        .optimize = optimize,
    });
    zsql_mod.addOptions("zsql_options", options);
    if (enable_sqlite) {
        // Explicit libc + sqlite3 linkage is required for reliable Linux CI.
        // `@cImport` is avoided in the driver; symbols come from c.zig externs.
        zsql_mod.link_libc = true;
        zsql_mod.linkSystemLibrary("sqlite3", .{
            .needed = true,
            .use_pkg_config = .yes,
        });
    }

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

    // CLI
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("zsql", zsql_mod);
    if (enable_sqlite) {
        cli_mod.link_libc = true;
        cli_mod.linkSystemLibrary("sqlite3", .{
            .needed = true,
            .use_pkg_config = .yes,
        });
    }
    const cli_exe = b.addExecutable(.{
        .name = "zsql",
        .root_module = cli_mod,
    });
    b.installArtifact(cli_exe);
    const run_cli = b.addRunArtifact(cli_exe);
    if (b.args) |args| run_cli.addArgs(args);
    const run_step = b.step("run", "Run the zsql CLI");
    run_step.dependOn(&run_cli.step);

    // Offline checked-query example (no DB / no SQLite required).
    const checked_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/checked_queries.zig"),
        .target = target,
        .optimize = optimize,
    });
    checked_example_mod.addImport("zsql", zsql_mod);
    const checked_example = b.addExecutable(.{
        .name = "checked-queries",
        .root_module = checked_example_mod,
    });
    const run_checked_example = b.addRunArtifact(checked_example);
    const checked_example_step = b.step("checked-queries-example", "Run offline checked-query example");
    checked_example_step.dependOn(&run_checked_example.step);

    const sqlite_example_step = b.step("sqlite-example", "Run the SQLite GPA leak-checked example");
    const sqlite_migrate_example_step = b.step("sqlite-migrate-example", "Run the SQLite migration GPA leak-checked example");
    if (enable_sqlite) {
        const sqlite_example_mod = b.createModule(.{
            .root_source_file = b.path("examples/sqlite_basic.zig"),
            .target = target,
            .optimize = optimize,
        });
        sqlite_example_mod.addImport("zsql", zsql_mod);
        sqlite_example_mod.link_libc = true;
        sqlite_example_mod.linkSystemLibrary("sqlite3", .{
            .needed = true,
            .use_pkg_config = .yes,
        });

        const sqlite_example = b.addExecutable(.{
            .name = "sqlite-basic",
            .root_module = sqlite_example_mod,
        });

        const run_sqlite_example = b.addRunArtifact(sqlite_example);
        sqlite_example_step.dependOn(&run_sqlite_example.step);

        const sqlite_migrate_example_mod = b.createModule(.{
            .root_source_file = b.path("examples/sqlite_migrate.zig"),
            .target = target,
            .optimize = optimize,
        });
        sqlite_migrate_example_mod.addImport("zsql", zsql_mod);
        sqlite_migrate_example_mod.link_libc = true;
        sqlite_migrate_example_mod.linkSystemLibrary("sqlite3", .{
            .needed = true,
            .use_pkg_config = .yes,
        });

        const sqlite_migrate_example = b.addExecutable(.{
            .name = "sqlite-migrate",
            .root_module = sqlite_migrate_example_mod,
        });

        const run_sqlite_migrate_example = b.addRunArtifact(sqlite_migrate_example);
        sqlite_migrate_example_step.dependOn(&run_sqlite_migrate_example.step);
    } else {
        sqlite_example_step.dependOn(&run_tests.step);
        sqlite_migrate_example_step.dependOn(&run_tests.step);
    }
}
