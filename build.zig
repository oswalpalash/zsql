const std = @import("std");

/// Compile flags for the bundled SQLite amalgamation.
/// Keep conservative: threadsafe, URI filenames, no loadable extensions.
const sqlite_amalgamation_c_flags = [_][]const u8{
    "-std=c99",
    "-DSQLITE_DQS=0",
    "-DSQLITE_DEFAULT_MEMSTATUS=0",
    "-DSQLITE_OMIT_DEPRECATED=1",
    "-DSQLITE_OMIT_LOAD_EXTENSION=1",
    "-DSQLITE_THREADSAFE=1",
    "-DSQLITE_USE_URI=1",
};

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    // Default builds (enable-sqlite=false) must remain free of libc so the
    // CLI and library install cleanly without system SQLite. Do not call
    // std.c.* from code paths compiled into the default package.
    const enable_sqlite = b.option(bool, "enable-sqlite", "Compile the SQLite driver") orelse false;
    // When SQLite is enabled, the amalgamation is the default (reproducible,
    // no system libsqlite3). Pass -Dsqlite-system=true to link the OS package.
    const sqlite_system = b.option(bool, "sqlite-system", "Link system libsqlite3 instead of the bundled amalgamation") orelse false;
    const use_amalgamation = enable_sqlite and !sqlite_system;

    const options = b.addOptions();
    options.addOption(bool, "enable_sqlite", enable_sqlite);
    options.addOption(bool, "sqlite_amalgamation", use_amalgamation);
    // Keep in sync with build.zig.zon version for `zsql doctor`.
    options.addOption([]const u8, "package_version", "0.0.2");

    // Build the amalgamation static library once when requested. Lazy so
    // default (non-sqlite) builds never fetch the SQLite tarball.
    const sqlite_amalg_lib: ?*std.Build.Step.Compile = if (use_amalgamation)
        buildSqliteAmalgamation(b, target, optimize)
    else
        null;

    const zsql_mod = b.addModule("zsql", .{
        .root_source_file = b.path("src/zsql.zig"),
        .target = target,
        .optimize = optimize,
    });
    zsql_mod.addOptions("zsql_options", options);
    if (enable_sqlite) {
        linkSqlite(zsql_mod, sqlite_system, sqlite_amalg_lib);
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

    // Convenience aliases used in docs / local workflows.
    const test_core_step = b.step("test-core", "Alias for zig build test (driver-agnostic + postgres unit tests)");
    test_core_step.dependOn(test_step);

    // CLI
    const cli_mod = b.createModule(.{
        .root_source_file = b.path("cli/main.zig"),
        .target = target,
        .optimize = optimize,
    });
    cli_mod.addImport("zsql", zsql_mod);
    if (enable_sqlite) {
        // Amalgamation symbols come via the zsql module; system builds still
        // need an explicit link on the executable module for some linkers.
        if (sqlite_system) {
            linkSqlite(cli_mod, true, null);
        } else {
            cli_mod.link_libc = true;
        }
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
    const check_sql_step = b.step("check-sql", "Validate the checked-query schema example without a database");
    check_sql_step.dependOn(&run_checked_example.step);

    // Aggregate examples step: always-safe examples (no external DB required).
    const examples_step = b.step("examples", "Run examples that need no external services");
    examples_step.dependOn(checked_example_step);

    // Optional live PostgreSQL tests (skipped unless ZSQL_PG_URL is set at runtime).
    const pg_live_mod = b.createModule(.{
        .root_source_file = b.path("tests/postgres_live.zig"),
        .target = target,
        .optimize = optimize,
    });
    pg_live_mod.addImport("zsql", zsql_mod);
    const pg_live_tests = b.addTest(.{
        .root_module = pg_live_mod,
    });
    const run_pg_live = b.addRunArtifact(pg_live_tests);
    // Inherits process env (including ZSQL_PG_URL when set by CI or the shell).
    const test_postgres_step = b.step("test-postgres", "Run live PostgreSQL integration tests (requires ZSQL_PG_URL)");
    test_postgres_step.dependOn(&run_pg_live.step);

    // Postgres pool example: skips cleanly when ZSQL_PG_URL is unset.
    const pg_pool_example_mod = b.createModule(.{
        .root_source_file = b.path("examples/postgres_pool.zig"),
        .target = target,
        .optimize = optimize,
    });
    pg_pool_example_mod.addImport("zsql", zsql_mod);
    const pg_pool_example = b.addExecutable(.{
        .name = "postgres-pool",
        .root_module = pg_pool_example_mod,
    });
    const run_pg_pool_example = b.addRunArtifact(pg_pool_example);
    const pg_pool_example_step = b.step("postgres-pool-example", "Run postgres pool example (skips if ZSQL_PG_URL unset)");
    pg_pool_example_step.dependOn(&run_pg_pool_example.step);
    const run_pg_pool_example_step = b.step("run-postgres-pool-example", "Acceptance alias for postgres-pool-example");
    run_pg_pool_example_step.dependOn(pg_pool_example_step);

    const sqlite_example_step = b.step("sqlite-example", "Run the SQLite GPA leak-checked example");
    const sqlite_migrate_example_step = b.step("sqlite-migrate-example", "Run the SQLite migration GPA leak-checked example");
    const run_sqlite_example_step = b.step("run-sqlite-example", "Acceptance alias for sqlite-example");
    run_sqlite_example_step.dependOn(sqlite_example_step);
    const run_migration_example_step = b.step("run-migration-example", "Acceptance alias for sqlite-migrate-example");
    run_migration_example_step.dependOn(sqlite_migrate_example_step);
    if (enable_sqlite) {
        const sqlite_example_mod = b.createModule(.{
            .root_source_file = b.path("examples/sqlite_basic.zig"),
            .target = target,
            .optimize = optimize,
        });
        sqlite_example_mod.addImport("zsql", zsql_mod);
        if (sqlite_system) {
            linkSqlite(sqlite_example_mod, true, null);
        } else {
            sqlite_example_mod.link_libc = true;
        }

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
        if (sqlite_system) {
            linkSqlite(sqlite_migrate_example_mod, true, null);
        } else {
            sqlite_migrate_example_mod.link_libc = true;
        }

        const sqlite_migrate_example = b.addExecutable(.{
            .name = "sqlite-migrate",
            .root_module = sqlite_migrate_example_mod,
        });

        const run_sqlite_migrate_example = b.addRunArtifact(sqlite_migrate_example);
        sqlite_migrate_example_step.dependOn(&run_sqlite_migrate_example.step);

        const test_sqlite_step = b.step("test-sqlite", "Run tests with -Denable-sqlite=true (same as current test run when flag set)");
        test_sqlite_step.dependOn(test_step);

        // When SQLite is enabled, fold leak-checked examples into `zig build examples`.
        examples_step.dependOn(sqlite_example_step);
        examples_step.dependOn(sqlite_migrate_example_step);
    } else {
        sqlite_example_step.dependOn(&run_tests.step);
        sqlite_migrate_example_step.dependOn(&run_tests.step);

        // Without the flag, document the intended invocation rather than faking coverage.
        const test_sqlite_step = b.step("test-sqlite", "Requires: zig build test-sqlite -Denable-sqlite=true");
        test_sqlite_step.dependOn(test_step);
    }

    // Postgres pool example is optional (skips without ZSQL_PG_URL); always buildable.
    examples_step.dependOn(pg_pool_example_step);
}

fn buildSqliteAmalgamation(
    b: *std.Build,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
) ?*std.Build.Step.Compile {
    // lazyDependency returns null on the first configure pass while the package
    // is fetched, then rebuilds. Callers treat null as "not ready yet".
    const dep = b.lazyDependency("sqlite_amalgamation", .{}) orelse return null;

    const lib = b.addLibrary(.{
        .name = "sqlite3_amalgamation",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = target,
            .optimize = optimize,
            .link_libc = true,
        }),
    });
    lib.root_module.addCSourceFile(.{
        .file = dep.path("sqlite3.c"),
        .flags = &sqlite_amalgamation_c_flags,
    });
    lib.root_module.addIncludePath(dep.path("."));
    return lib;
}

fn linkSqlite(
    mod: *std.Build.Module,
    sqlite_system: bool,
    amalg_lib: ?*std.Build.Step.Compile,
) void {
    mod.link_libc = true;
    if (sqlite_system) {
        // Explicit libc + sqlite3 linkage for hosts that ship a package.
        // `@cImport` is avoided in the driver; symbols come from c.zig externs.
        mod.linkSystemLibrary("sqlite3", .{
            .needed = true,
            .use_pkg_config = .yes,
        });
    } else if (amalg_lib) |lib| {
        mod.linkLibrary(lib);
    }
}
