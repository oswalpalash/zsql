//! Optional live PostgreSQL integration tests.
//!
//! Skipped unless `ZSQL_PG_URL` is set, e.g.:
//!
//! ```sh
//! export ZSQL_PG_URL='postgres://zsql:zsql@127.0.0.1:5432/zsql?sslmode=disable'
//! zig build test-postgres
//! ```
//!
//! CI runs this step with a Postgres service container when available.

const std = @import("std");
const zsql = @import("zsql");
const pg = zsql.drivers.postgres;

fn requireUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, "ZSQL_PG_URL") catch return error.SkipZigTest;
}

test "postgres live: handshake, params, tx, errors, inspect" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var conn = try pg.Conn.open(allocator, io, config);
    defer conn.deinit();

    _ = try conn.exec(
        \\drop table if exists zsql_live_users;
        \\create table zsql_live_users (
        \\  id bigserial primary key,
        \\  email text not null unique,
        \\  active boolean not null default true
        \\);
    );

    const insert = try conn.execParams(
        "insert into zsql_live_users (email, active) values ($1, $2)",
        &.{ .{ .text = "ada@example.com" }, .{ .boolean = true } },
    );
    try std.testing.expectEqual(@as(u64, 1), insert.rows_affected);

    var rows = try conn.queryParams(
        "select id, email, active from zsql_live_users where email = $1",
        &.{.{ .text = "ada@example.com" }},
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRows;
    try std.testing.expectEqualStrings("ada@example.com", try (try row.value("email")).asText());
    try std.testing.expect(try (try row.value("active")).asBool());
    try std.testing.expect(rows.next() == null);

    // Unique violation should map + populate lastError, and leave conn usable.
    const dup = conn.execParams(
        "insert into zsql_live_users (email) values ($1)",
        &.{.{ .text = "ada@example.com" }},
    );
    try std.testing.expectError(error.UniqueViolation, dup);
    const db_err = conn.lastError() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("23505", db_err.code.?);
    try std.testing.expect(db_err.constraint != null);

    // Connection recovered after ErrorResponse drain.
    var count_rows = try conn.query("select count(*)::bigint as n from zsql_live_users");
    defer count_rows.deinit();
    const count_row = count_rows.next().?;
    try std.testing.expectEqual(@as(i64, 1), try (try count_row.value("n")).asInt());

    try conn.begin();
    _ = try conn.execParams(
        "insert into zsql_live_users (email) values ($1)",
        &.{.{ .text = "grace@example.com" }},
    );
    var sp = try conn.savepoint();
    _ = try conn.execParams(
        "insert into zsql_live_users (email) values ($1)",
        &.{.{ .text = "rollback-me@example.com" }},
    );
    try sp.rollback();
    try conn.commit();

    const schema = try conn.inspectSchema(allocator);
    defer pg.freeInspectedSchema(allocator, schema);
    var found_users = false;
    for (schema.tables) |table| {
        if (std.mem.eql(u8, table.name, "zsql_live_users")) {
            found_users = true;
            var has_email = false;
            for (table.columns) |col| {
                if (std.mem.eql(u8, col.name, "email")) {
                    has_email = true;
                    try std.testing.expect(!col.nullable);
                }
                if (std.mem.eql(u8, col.name, "id")) {
                    try std.testing.expect(col.primary_key);
                }
            }
            try std.testing.expect(has_email);
        }
    }
    try std.testing.expect(found_users);

    _ = try conn.exec("drop table if exists zsql_live_users");
}

test "postgres live: inspectSchema exports user tables" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, io, config);
    defer conn.deinit();

    _ = try conn.exec("drop table if exists zsql_inspect_demo");
    _ = try conn.exec(
        \\create table zsql_inspect_demo (
        \\  id bigserial primary key,
        \\  email text not null
        \\)
    );

    const schema = try conn.inspectSchema(allocator);
    defer pg.freeInspectedSchema(allocator, schema);

    var found = false;
    for (schema.tables) |table| {
        if (std.mem.eql(u8, table.name, "zsql_inspect_demo")) {
            found = true;
            try std.testing.expect(table.columns.len >= 2);
        }
    }
    try std.testing.expect(found);

    var growing: std.Io.Writer.Allocating = .init(allocator);
    defer growing.deinit();
    try zsql.inspect.writeSchemaZon(&growing.writer, schema);
    try std.testing.expect(std.mem.indexOf(u8, growing.written(), "zsql_inspect_demo") != null);

    _ = try conn.exec("drop table if exists zsql_inspect_demo");
}

test "postgres live: migrator applies pending files" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var conn = try pg.Conn.open(allocator, io, config);
    defer conn.deinit();

    _ = try conn.exec("drop table if exists zsql_mig_demo");
    _ = try conn.exec("drop table if exists zsql_migrations");

    const sql =
        \\create table zsql_mig_demo (id bigint primary key, email text not null);
    ;
    const checksum = zsql.migrate.checksumSql(sql);
    const migrations = [_]zsql.migrate.MigrationFile{
        .{
            .id = .{
                .version = 1,
                .name = "create_demo",
                .filename = "V0001__create_demo.sql",
            },
            .sql = sql,
            .checksum = checksum,
        },
    };

    const migrator = pg.Migrator.init(&conn);
    const first = try migrator.apply(&migrations);
    try std.testing.expectEqual(@as(usize, 1), first.applied);
    const second = try migrator.apply(&migrations);
    try std.testing.expectEqual(@as(usize, 0), second.applied);

    var status = try migrator.status(allocator);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 1), status.records.len);
    try std.testing.expect(!status.records[0].dirty);

    _ = try conn.exec("drop table if exists zsql_mig_demo");
    _ = try conn.exec("drop table if exists zsql_migrations");
}

test "postgres live: statement cache reuses named prepares" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var conn = try pg.Conn.open(allocator, io, config);
    defer conn.deinit();

    try conn.enableStmtCache(4);
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheLen());

    const sql = "select $1::int as n";
    var rows1 = try conn.queryParams(sql, &.{.{ .integer = 1 }});
    defer rows1.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try rows1.next().?.value("n")).asInt());
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    var rows2 = try conn.queryParams(sql, &.{.{ .integer = 2 }});
    defer rows2.deinit();
    try std.testing.expectEqual(@as(i64, 2), try (try rows2.next().?.value("n")).asInt());
    // Same SQL should still be a single cached prepare.
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    try conn.disableStmtCache();
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheLen());
}

test "postgres live: pool acquire release" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var pool = try pg.Pool.init(allocator, io, .{
        .database = config,
        .max_open = 2,
        .max_idle = 1,
    });
    defer pool.deinit();

    // Non-row SET may emit ParameterStatus; exec must tolerate it.
    _ = try pool.exec("set application_name to 'zsql-live-pool'");
    var rows = try pool.queryParams("select 1::int as n", &.{});
    const row = rows.next().?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("n")).asInt());
    rows.deinit();

    const stats = pool.stats();
    try std.testing.expect(stats.open >= 1);
    try std.testing.expectEqual(@as(usize, 0), stats.leased);
}
