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

test "postgres live: owned diagnostics survive connection teardown" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();

    var owned_error = owned: {
        const url_str = try requireUrl(allocator);
        defer allocator.free(url_str);
        var config = try pg.parseUrl(allocator, url_str);
        defer config.deinit();
        var conn = try pg.Conn.open(allocator, std.testing.io, config);
        defer conn.deinit();

        try std.testing.expectError(error.InvalidSql, conn.exec("select from"));
        break :owned (try conn.lastErrorOwned(allocator)) orelse return error.TestExpectedEqual;
    };
    defer owned_error.deinit(allocator);

    const db_error = owned_error.view();
    try std.testing.expectEqualStrings("42601", db_error.code.?);
    try std.testing.expectEqualStrings("select from", db_error.sql.?);
    try std.testing.expect(db_error.category == .invalid_sql);
    try std.testing.expect(db_error.driver == .postgres);
}

fn requireUrl(allocator: std.mem.Allocator) ![]u8 {
    return std.process.Environ.getAlloc(std.testing.environ, allocator, "ZSQL_PG_URL") catch return error.SkipZigTest;
}

fn runCancelableQuery(conn: *pg.Conn) anyerror!zsql.ExecResult {
    return conn.exec("do $$ begin perform pg_sleep(10); end $$");
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

    _ = try conn.execNamed(
        "insert into zsql_live_users (email, active) values (:email, :active)",
        &.{
            .{ .name = "email", .value = .{ .text = "named@example.com" } },
            .{ .name = "active", .value = .{ .boolean = false } },
        },
    );
    var named_rows = try conn.queryNamed(
        "select email from zsql_live_users where email = :email or email = :email",
        &.{.{ .name = "email", .value = .{ .text = "named@example.com" } }},
    );
    defer named_rows.deinit();
    try std.testing.expectEqualStrings("named@example.com", try (try named_rows.next().?.value("email")).asText());

    // Unique violation should map + populate lastError, and leave conn usable.
    const dup_sql = "insert into zsql_live_users (email) values ($1)";
    const dup = conn.execParams(
        dup_sql,
        &.{.{ .text = "ada@example.com" }},
    );
    try std.testing.expectError(error.UniqueViolation, dup);
    const db_err = conn.lastError() orelse return error.TestExpectedEqual;
    try std.testing.expectEqualStrings("23505", db_err.code.?);
    try std.testing.expect(db_err.constraint != null);
    try std.testing.expectEqualStrings(dup_sql, db_err.sql.?);
    try std.testing.expect(std.mem.indexOf(u8, db_err.sql.?, "ada@example.com") == null);

    // Connection recovered after ErrorResponse drain.
    var count_rows = try conn.query("select count(*)::bigint as n from zsql_live_users");
    defer count_rows.deinit();
    const count_row = count_rows.next().?;
    try std.testing.expectEqual(@as(i64, 2), try (try count_row.value("n")).asInt());
    try std.testing.expectEqual(@as(?zsql.DbError, null), conn.lastError());

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
    try std.testing.expectEqual(zsql.inspect.Dialect.postgres, schema.dialect);
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

test "postgres live: ping succeeds" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();
    try conn.ping();
}

test "postgres live: reusable prepared statement exec query and close" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();

    _ = try conn.exec("create temporary table zsql_prepared (id bigint primary key, name text not null)");
    var insert = try conn.prepare("insert into zsql_prepared (id, name) values ($1, $2)");
    defer insert.deinit();
    try std.testing.expectEqual(@as(usize, 2), insert.parameterCount());
    try std.testing.expectEqualSlices(u32, &.{ 20, 25 }, insert.parameterOids());
    try std.testing.expectError(error.BindCountMismatch, insert.exec(&.{.{ .integer = 1 }}));
    try std.testing.expectEqual(@as(u64, 1), (try insert.exec(&.{ .{ .integer = 1 }, .{ .text = "ada" } })).rows_affected);
    try std.testing.expectEqual(@as(u64, 1), (try insert.exec(&.{ .{ .integer = 2 }, .{ .text = "grace" } })).rows_affected);

    var select = try conn.prepare("select name from zsql_prepared where id = $1");
    defer select.deinit();
    try std.testing.expectEqualSlices(u32, &.{20}, select.parameterOids());
    var first = try select.query(&.{.{ .integer = 1 }});
    defer first.deinit();
    try std.testing.expectEqualStrings("ada", try (try first.next().?.getName("name")).asText());
    var second = try select.query(&.{.{ .integer = 2 }});
    defer second.deinit();
    try std.testing.expectEqualStrings("grace", try (try second.next().?.getName("name")).asText());

    // Server statements are session-scoped: they remain usable across commit
    // and rollback. An aborted transaction reports a typed error and does not
    // trigger automatic reprepare inside the failed transaction.
    try conn.begin();
    try std.testing.expectError(
        error.UniqueViolation,
        insert.exec(&.{ .{ .integer = 1 }, .{ .text = "duplicate" } }),
    );
    try std.testing.expectError(error.TransactionAborted, select.query(&.{.{ .integer = 1 }}));
    try std.testing.expectEqualStrings("25P02", conn.lastError().?.code.?);
    try conn.rollback();

    try conn.begin();
    _ = try insert.exec(&.{ .{ .integer = 3 }, .{ .text = "linus" } });
    try conn.commit();
    var committed = try select.query(&.{.{ .integer = 3 }});
    defer committed.deinit();
    try std.testing.expectEqualStrings("linus", try (try committed.next().?.getName("name")).asText());

    try conn.begin();
    _ = try insert.exec(&.{ .{ .integer = 4 }, .{ .text = "rolled-back" } });
    try conn.rollback();
    var rolled_back = try select.query(&.{.{ .integer = 4 }});
    defer rolled_back.deinit();
    try std.testing.expect(rolled_back.next() == null);

    var named = try conn.prepareNamed("select name from zsql_prepared where id = :id or id = :id");
    defer named.deinit();
    const parameter_names = named.parameterNames().?;
    try std.testing.expectEqual(@as(usize, 1), parameter_names.len);
    try std.testing.expectEqualStrings("id", parameter_names[0]);
    var named_rows = try named.queryNamed(&.{.{ .name = "id", .value = .{ .integer = 2 } }});
    defer named_rows.deinit();
    try std.testing.expectEqualStrings("grace", try (try named_rows.next().?.getName("name")).asText());
    try std.testing.expectError(error.InvalidBindValue, named.queryNamed(&.{
        .{ .name = "id", .value = .{ .integer = 1 } },
        .{ .name = "extra", .value = .{ .integer = 2 } },
    }));

    var shape = try conn.prepare("select * from zsql_prepared order by id");
    defer shape.deinit();
    var before_shape = try shape.query(&.{});
    defer before_shape.deinit();
    try std.testing.expectEqual(@as(usize, 2), before_shape.next().?.values.len);
    _ = try conn.exec("alter table zsql_prepared add column active boolean not null default true");
    var after_shape = try shape.query(&.{});
    defer after_shape.deinit();
    try std.testing.expectEqual(@as(usize, 3), after_shape.next().?.values.len);

    try insert.close();
    try named.close();
    try shape.close();
    // Successful Close collectors consumed ReadyForQuery before reuse.
    _ = try conn.exec("deallocate all");
    var recovered_missing = try select.query(&.{.{ .integer = 1 }});
    defer recovered_missing.deinit();
    try std.testing.expectEqualStrings("ada", try (try recovered_missing.next().?.getName("name")).asText());

    try select.close();
    try std.testing.expectError(error.StatementClosed, select.query(&.{.{ .integer = 1 }}));
    try std.testing.expectError(error.InvalidSql, conn.prepare("select from"));
    try std.testing.expectEqualStrings("select from", conn.lastError().?.sql.?);
    // Failed prepare drained its ErrorResponse sequence before reuse.
    try conn.ping();
}

test "postgres live: bytea round trips hex and escape output" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();

    const expected = [_]u8{ 0, 0xff, '\\', 'A' };
    var stmt = try conn.prepare("select $1::bytea as payload");
    defer stmt.deinit();

    var hex_rows = try stmt.query(&.{.{ .blob = &expected }});
    defer hex_rows.deinit();
    try std.testing.expectEqualSlices(u8, &expected, try (try hex_rows.next().?.value("payload")).asBlob());

    _ = try conn.exec("set bytea_output = 'escape'");
    var escape_rows = try stmt.query(&.{.{ .blob = &expected }});
    defer escape_rows.deinit();
    try std.testing.expectEqualSlices(u8, &expected, try (try escape_rows.next().?.value("payload")).asBlob());

    var simple_rows = try conn.query("select decode('00ff5c41', 'hex') as payload");
    defer simple_rows.deinit();
    try std.testing.expectEqualSlices(u8, &expected, try (try simple_rows.next().?.value("payload")).asBlob());
}

test "postgres live: query rejects multiple result schemas and recovers" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();

    try std.testing.expectError(
        error.Unsupported,
        conn.query("select 1::int as first; select 2::int as second"),
    );
    var rows = try conn.query("select 3::int as value");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 3), try (try rows.next().?.value("value")).asInt());
}

test "postgres live: exec rejects rows and recovers" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();

    try std.testing.expectError(error.UnexpectedRow, conn.exec("select 1"));
    try conn.ping();

    try std.testing.expectError(
        error.UnexpectedRow,
        conn.execParams("select $1::int", &.{.{ .integer = 2 }}),
    );
    var rows = try conn.query("select 3::int as value");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 3), try (try rows.next().?.value("value")).asInt());
}

test "postgres live: queryOneParams enforces cardinality" {
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

    _ = try conn.exec("drop table if exists zsql_one_row");
    _ = try conn.exec("create temporary table zsql_one_row (id int primary key, name text)");
    try std.testing.expectError(error.NoRows, conn.queryOneParams("select id from zsql_one_row", &.{}));

    _ = try conn.exec("insert into zsql_one_row (id, name) values (1, 'a'), (2, 'b')");
    try std.testing.expectError(error.TooManyRows, conn.queryOneParams("select id from zsql_one_row", &.{}));

    var owned = try conn.queryOneParams("select id, name from zsql_one_row where id = $1", &.{.{ .integer = 1 }});
    defer owned.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try owned.getName("id")).asInt());
    try std.testing.expectEqualStrings("a", try (try owned.getName("name")).asText());
}

test "postgres live: pool queryAllParams collects owned rows" {
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

    // Use a real table (not TEMP): pool may hand out different connections.
    _ = try pool.exec("drop table if exists zsql_pool_all");
    _ = try pool.exec(
        \\create table zsql_pool_all (
        \\  id int primary key,
        \\  name text not null
        \\)
    );
    defer _ = pool.exec("drop table if exists zsql_pool_all") catch {};

    _ = try pool.execParams(
        "insert into zsql_pool_all (id, name) values ($1, $2), ($3, $4)",
        &.{ .{ .integer = 1 }, .{ .text = "a" }, .{ .integer = 2 }, .{ .text = "b" } },
    );

    _ = try pool.execNamed(
        "insert into zsql_pool_all (id, name) values (:id, :name)",
        &.{
            .{ .name = "id", .value = .{ .integer = 3 } },
            .{ .name = "name", .value = .{ .text = "named" } },
        },
    );
    var named_rows = try pool.queryNamed(
        "select name from zsql_pool_all where id = :id or id = :id",
        &.{.{ .name = "id", .value = .{ .integer = 3 } }},
    );
    try std.testing.expectEqualStrings("named", try (try named_rows.next().?.value("name")).asText());
    named_rows.deinit();

    const owned = try pool.queryAllParams("select id, name from zsql_pool_all order by id", &.{});
    defer zsql.freeOwnedRows(allocator, owned);
    try std.testing.expectEqual(@as(usize, 3), owned.len);
    try std.testing.expectEqual(@as(i64, 1), try (try owned[0].getName("id")).asInt());
    try std.testing.expectEqualStrings("b", try (try owned[1].getName("name")).asText());
    try std.testing.expectEqual(@as(usize, 0), pool.stats().leased);
    try pool.ping();
}

test "postgres live: pool withTx commits and rolls back" {
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
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();

    _ = try pool.exec("drop table if exists zsql_pool_tx");
    _ = try pool.exec(
        \\create table zsql_pool_tx (
        \\  id int primary key,
        \\  name text not null
        \\)
    );
    defer _ = pool.exec("drop table if exists zsql_pool_tx") catch {};

    try pool.withTx({}, struct {
        fn run(_: void, c: *pg.Conn) !void {
            _ = try c.execParams(
                "insert into zsql_pool_tx (id, name) values ($1, $2)",
                &.{ .{ .integer = 1 }, .{ .text = "ok" } },
            );
        }
    }.run);

    const failed = pool.withTx({}, struct {
        fn run(_: void, c: *pg.Conn) !void {
            _ = try c.execParams(
                "insert into zsql_pool_tx (id, name) values ($1, $2)",
                &.{ .{ .integer = 2 }, .{ .text = "nope" } },
            );
            return error.ForceRollback;
        }
    }.run);
    try std.testing.expectError(error.ForceRollback, failed);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().open);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    const rows = try pool.queryAllParams("select id from zsql_pool_tx order by id", &.{});
    defer zsql.freeOwnedRows(allocator, rows);
    try std.testing.expectEqual(@as(usize, 1), rows.len);
    try std.testing.expectEqual(@as(i64, 1), try (try rows[0].getName("id")).asInt());
    try std.testing.expectEqual(@as(usize, 0), pool.stats().leased);
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
    _ = try conn.exec("drop schema if exists zsql_inspect_audit cascade");
    defer {
        _ = conn.exec("drop table if exists zsql_inspect_demo") catch {};
        _ = conn.exec("drop schema if exists zsql_inspect_audit cascade") catch {};
    }
    _ = try conn.exec(
        \\create table zsql_inspect_demo (
        \\  id bigserial primary key,
        \\  email text not null
        \\)
    );
    _ = try conn.exec("create schema zsql_inspect_audit");
    _ = try conn.exec("create table zsql_inspect_audit.events (id bigint primary key)");

    const schema = try conn.inspectSchema(allocator);
    defer pg.freeInspectedSchema(allocator, schema);
    try std.testing.expectEqual(zsql.inspect.Dialect.postgres, schema.dialect);

    var found_public = false;
    var found_audit = false;
    for (schema.tables) |table| {
        if (std.mem.eql(u8, table.schema orelse "", "public") and
            std.mem.eql(u8, table.name, "zsql_inspect_demo"))
        {
            found_public = true;
            try std.testing.expect(table.columns.len >= 2);
        }
        if (std.mem.eql(u8, table.schema orelse "", "zsql_inspect_audit") and
            std.mem.eql(u8, table.name, "events")) found_audit = true;
    }
    try std.testing.expect(found_public);
    try std.testing.expect(found_audit);

    var growing: std.Io.Writer.Allocating = .init(allocator);
    defer growing.deinit();
    try zsql.inspect.writeSchemaZon(&growing.writer, schema);
    try std.testing.expect(std.mem.indexOf(u8, growing.written(), "zsql_inspect_demo") != null);
    try std.testing.expect(std.mem.indexOf(u8, growing.written(), ".schema = \"zsql_inspect_audit\"") != null);
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

test "postgres live: failed migration persists dirty state after rollback" {
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
    _ = try conn.exec("drop table if exists zsql_repaired");
    defer _ = conn.exec("drop table if exists zsql_repaired") catch {};
    _ = try conn.exec("drop table if exists zsql_migrations");
    defer _ = conn.exec("drop table if exists zsql_migrations") catch {};

    const bad_sql = "create table zsql_broken (";
    const migrations = [_]zsql.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "broken",
            .filename = "V0001__broken.sql",
        },
        .sql = bad_sql,
        .checksum = zsql.migrate.checksumSql(bad_sql),
    }};
    const migrator = pg.Migrator.init(&conn);
    try std.testing.expectError(error.InvalidSql, migrator.apply(&migrations));

    var status = try migrator.status(allocator);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 1), status.records.len);
    try std.testing.expect(status.records[0].dirty);
    try std.testing.expectError(error.MigrationDirty, migrator.apply(&migrations));

    const fixed_sql = "create table zsql_repaired (id bigint primary key)";
    const fixed_checksum = zsql.migrate.checksumSql(fixed_sql);
    try std.testing.expectError(error.MigrationChecksumMismatch, migrator.repairDirty(1, fixed_checksum));
    try migrator.repairDirty(1, migrations[0].checksum);
    try std.testing.expectError(error.MigrationNotFound, migrator.repairDirty(99, migrations[0].checksum));

    const fixed = [_]zsql.migrate.MigrationFile{.{
        .id = migrations[0].id,
        .sql = fixed_sql,
        .checksum = fixed_checksum,
    }};
    try std.testing.expectEqual(@as(usize, 1), (try migrator.apply(&fixed)).applied);
    try std.testing.expectError(error.MigrationNotDirty, migrator.repairDirty(1, fixed_checksum));
    try conn.ping();
}

test "postgres live: copy in and out bytes" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, std.testing.io, config);
    defer conn.deinit();

    _ = try conn.exec("create temporary table zsql_copy_demo (id int, name text)");
    const result = try conn.copyIn("copy zsql_copy_demo (id, name) from stdin with (format csv)", "1,ada\n2,grace\n");
    try std.testing.expectEqual(@as(u64, 2), result.rows_affected);
    const out = try conn.copyOut("copy zsql_copy_demo (id, name) to stdout with (format csv)");
    defer allocator.free(out);
    try std.testing.expectEqualStrings("1,ada\n2,grace\n", out);

    // Wrong-direction calls must terminate or drain the active COPY exchange
    // before returning so the same connection remains usable.
    try std.testing.expectError(
        error.ProtocolError,
        conn.copyOut("copy zsql_copy_demo (id, name) from stdin with (format csv)"),
    );
    try conn.ping();
    try std.testing.expectError(
        error.ProtocolError,
        conn.copyIn("copy zsql_copy_demo (id, name) to stdout with (format csv)", ""),
    );
    try conn.ping();
}

test "postgres live: pooled COPY output survives pool teardown" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var pool = try pg.Pool.init(allocator, std.testing.io, .{
        .database = config,
        .max_open = 1,
        .max_idle = 1,
    });
    errdefer pool.deinit();

    _ = try pool.exec("create temporary table zsql_pool_copy (id int, name text)");
    const inserted = try pool.copyIn(
        "copy zsql_pool_copy (id, name) from stdin with (format csv)",
        "1,ada\n2,grace\n",
    );
    try std.testing.expectEqual(@as(u64, 2), inserted.rows_affected);
    const output = try pool.copyOut(
        "copy zsql_pool_copy (id, name) to stdout with (format csv)",
    );
    defer allocator.free(output);

    // Wrong-direction recovery is synchronized, but the pool conservatively
    // discards ProtocolError sessions before opening a clean replacement.
    try std.testing.expectError(
        error.ProtocolError,
        pool.copyOut("copy zsql_pool_copy (id, name) from stdin with (format csv)"),
    );
    try pool.ping();
    pool.deinit();

    try std.testing.expectEqualStrings("1,ada\n2,grace\n", output);
}

test "postgres live: asynchronous notifications preserve session reuse" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var listener = try pg.Conn.open(allocator, std.testing.io, config);
    errdefer listener.deinit();
    var sender = try pg.Conn.open(allocator, std.testing.io, config);
    defer sender.deinit();

    try listener.listen("zsql_live_events");
    _ = try sender.exec("notify zsql_live_events, 'ready'");
    var notification = try listener.nextNotification();
    defer notification.deinit(allocator);

    try listener.unlisten("zsql_live_events");
    try listener.ping();
    listener.deinit();

    try std.testing.expectEqualStrings("zsql_live_events", notification.channel);
    try std.testing.expectEqualStrings("ready", notification.payload);
}

test "postgres live: pooled listener clears subscriptions before reuse" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var pool = try pg.Pool.init(allocator, std.testing.io, .{
        .database = config,
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();
    var sender = try pg.Conn.open(allocator, std.testing.io, config);
    defer sender.deinit();

    var listener = try pool.listen();
    errdefer listener.deinit();
    try listener.listen("zsql_pool_events");
    _ = try sender.exec("notify zsql_pool_events, 'owned'");
    var notification = try listener.next();
    defer notification.deinit(allocator);
    listener.deinit();

    try std.testing.expectEqualStrings("zsql_pool_events", notification.channel);
    try std.testing.expectEqualStrings("owned", notification.payload);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().leased);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    var lease = try pool.acquire();
    defer if (lease.open) lease.discard() catch {};
    var rows = try (try lease.conn()).query(
        "select count(*)::bigint as n from pg_listening_channels()",
    );
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 0), try rows.next().?.as(i64, 0));
    try lease.release();
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

    // Explicit and cached statements share one session-wide name namespace.
    // Enabling the cache must not reset the counter and collide with this live
    // explicit statement.
    var explicit = try conn.prepare("select $1::int as explicit_n");
    defer explicit.deinit();
    try conn.enableStmtCache(4);
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheLen());

    const sql = "select $1::int as n";
    var rows1 = try conn.queryParams(sql, &.{.{ .integer = 1 }});
    defer rows1.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try rows1.next().?.value("n")).asInt());
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    var explicit_rows = try explicit.query(&.{.{ .integer = 3 }});
    defer explicit_rows.deinit();
    try std.testing.expectEqual(@as(i64, 3), try explicit_rows.next().?.as(i64, 0));

    var rows2 = try conn.queryParams(sql, &.{.{ .integer = 2 }});
    defer rows2.deinit();
    try std.testing.expectEqual(@as(i64, 2), try (try rows2.next().?.value("n")).asInt());
    // Same SQL should still be a single cached prepare.
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    const invalid_sql = "select from where id = $1";
    try std.testing.expectError(error.InvalidSql, conn.queryParams(invalid_sql, &.{.{ .integer = 1 }}));
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());
    // A failed Parse must not leave a nonexistent prepared-name mapping.
    try std.testing.expectError(error.InvalidSql, conn.queryParams(invalid_sql, &.{.{ .integer = 1 }}));
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    _ = try conn.exec("create temporary table zsql_cache_shape (id int primary key)");
    _ = try conn.exec("insert into zsql_cache_shape (id) values (1)");
    const shape_sql = "select * from zsql_cache_shape where id = $1";
    var before_shape = try conn.queryParams(shape_sql, &.{.{ .integer = 1 }});
    defer before_shape.deinit();
    try std.testing.expectEqual(@as(usize, 1), before_shape.next().?.values.len);
    try std.testing.expectEqual(@as(usize, 2), conn.stmtCacheLen());

    _ = try conn.exec("alter table zsql_cache_shape add column label text");
    _ = try conn.exec("update zsql_cache_shape set label = 'fresh' where id = 1");
    try std.testing.expectError(error.DriverError, conn.queryParams(shape_sql, &.{.{ .integer = 1 }}));
    try std.testing.expectEqualStrings("0A000", conn.lastError().?.code.?);
    try std.testing.expectEqual(@as(usize, 1), conn.stmtCacheLen());

    var after_shape = try conn.queryParams(shape_sql, &.{.{ .integer = 1 }});
    defer after_shape.deinit();
    const shape_row = after_shape.next().?;
    try std.testing.expectEqual(@as(usize, 2), shape_row.values.len);
    try std.testing.expectEqualStrings("fresh", try (try shape_row.value("label")).asText());
    try std.testing.expectEqual(@as(usize, 2), conn.stmtCacheLen());

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

test "postgres live: lease release consumes connection when idle growth is OOM" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer std.debug.assert(gpa_state.deinit() == .ok);
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var failing = std.testing.FailingAllocator.init(allocator, .{});
    var pool = try pg.Pool.init(failing.allocator(), std.testing.io, .{
        .database = config,
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();

    var lease = try pool.acquire();
    try (try lease.conn()).ping();
    failing.fail_index = failing.alloc_index;
    try std.testing.expectError(error.OutOfMemory, lease.release());
    try std.testing.expect(failing.has_induced_failure);
    try std.testing.expect(!lease.open);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().leased);

    failing.fail_index = std.math.maxInt(usize);
    try pool.ping();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);
}

test "postgres live: pooled prepared statement owns a stable lease" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var pool = try pg.Pool.init(allocator, std.testing.io, .{
        .database = config,
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();

    var stmt = try pool.prepareNamed("select :n::int as n");
    defer stmt.deinit();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().leased);
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    try std.testing.expectEqualStrings("n", stmt.parameterNames().?[0]);
    var first = try stmt.queryNamed(&.{.{ .name = "n", .value = .{ .integer = 7 } }});
    defer first.deinit();
    try std.testing.expectEqual(@as(i64, 7), try first.next().?.as(i64, 0));
    var second = try stmt.queryNamed(&.{.{ .name = "n", .value = .{ .integer = 9 } }});
    defer second.deinit();
    try std.testing.expectEqual(@as(i64, 9), try second.next().?.as(i64, 0));
    try stmt.close();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    var shutdown_stmt = try pool.prepare("select $1::int as n");
    defer shutdown_stmt.deinit();
    pool.deinit();
    var after_shutdown = try shutdown_stmt.query(&.{.{ .integer = 11 }});
    defer after_shutdown.deinit();
    try std.testing.expectEqual(@as(i64, 11), try after_shutdown.next().?.as(i64, 0));
    shutdown_stmt.deinit();
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);
}

test "postgres live: pool shutdown drains outstanding leases and rows" {
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
        .max_idle = 2,
    });
    defer pool.deinit();

    var lease = try pool.acquire();
    defer if (lease.open) lease.discard() catch {};
    var rows = try pool.queryParams("select 7::int as n", &.{});
    defer rows.deinit();
    pool.deinit();

    try (try lease.conn()).ping();
    const row = rows.next() orelse return error.NoRows;
    try std.testing.expectEqual(@as(i64, 7), try (try row.value("n")).asInt());
    rows.deinit();
    try std.testing.expectError(error.PoolClosed, lease.release());
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);
    try std.testing.expectError(error.PoolClosed, pool.acquire());
    pool.deinit();
}

test "postgres live: pool retains recoverable errors and discards unsafe releases" {
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
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();

    _ = try pool.exec("create temporary table zsql_pool_session (id int primary key)");
    try std.testing.expectError(error.InvalidSql, pool.exec("select from"));
    try std.testing.expectError(error.NoRows, pool.queryOneParams("select id from zsql_pool_session", &.{}));
    _ = try pool.exec("insert into zsql_pool_session (id) values (1)");
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);

    var tx_lease = try pool.acquire();
    try (try tx_lease.conn()).begin();
    try tx_lease.release();
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);

    var closed_lease = try pool.acquire();
    (try closed_lease.conn()).deinit();
    try closed_lease.release();
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);

    var replacement = try pool.acquire();
    try replacement.release();
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);
}

test "postgres live: statement_timeout maps to QueryTimeout" {
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

    try conn.setStatementTimeoutMs(50);
    // Use a non-row DO block so exec does not see RowDescription first.
    // pg_sleep is in seconds; 1s exceeds 50ms statement_timeout → SQLSTATE 57014.
    try std.testing.expectError(
        error.QueryTimeout,
        conn.exec("do $$ begin perform pg_sleep(1); end $$"),
    );
    // Connection remains usable after timeout cancel.
    try conn.setStatementTimeoutMs(0);
    var rows = try conn.query("select 1::int as n");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), try rows.next().?.as(i64, 0));
}

test "postgres live: transaction state rejects nested idle and aborted misuse" {
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

    try std.testing.expectError(error.TransactionClosed, conn.commit());
    try std.testing.expectError(error.TransactionClosed, conn.rollback());
    try conn.begin();
    try std.testing.expectError(error.ConnectionBusy, conn.begin());
    try std.testing.expectError(error.InvalidSql, conn.exec("select from"));
    try std.testing.expectError(error.TransactionAborted, conn.commit());
    try std.testing.expectError(error.TransactionAborted, conn.begin());
    try conn.rollback();

    try conn.begin();
    try conn.commit();
    try conn.ping();
}

test "postgres live: savepoint rollback recovers failed transaction state" {
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

    try conn.begin();
    var sp = try conn.savepoint();
    try std.testing.expectError(error.InvalidSql, conn.exec("select from"));
    try std.testing.expectError(error.TransactionAborted, sp.release());
    try sp.rollback();
    try std.testing.expectError(error.SavepointClosed, sp.rollback());
    var rows = try conn.query("select 1::int as n");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), try rows.next().?.as(i64, 0));
    try conn.commit();
}

test "postgres live: pool commits after savepoint recovery" {
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
        .max_open = 1,
        .max_idle = 1,
    });
    defer pool.deinit();

    try pool.withTx({}, struct {
        fn run(_: void, conn: *pg.Conn) !void {
            var sp = try conn.savepoint();
            try std.testing.expectError(error.InvalidSql, conn.exec("select from"));
            try sp.rollback();
            _ = try conn.exec("do $$ begin null; end $$");
        }
    }.run);
    try std.testing.expectEqual(@as(usize, 1), pool.stats().idle);
    try pool.ping();
}

test "postgres live: CancelHandle cancels an active query" {
    var gpa_state: std.heap.DebugAllocator(.{}) = .init;
    defer _ = gpa_state.deinit();
    const allocator = gpa_state.allocator();
    const url_str = try requireUrl(allocator);
    defer allocator.free(url_str);
    const io = std.testing.io;

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();
    var conn = try pg.Conn.open(allocator, io, config);
    errdefer conn.deinit();
    var cancel = try conn.createCancelHandle(allocator);
    defer cancel.deinit();

    var query = io.async(runCancelableQuery, .{&conn});
    defer _ = query.cancel(io) catch {};
    try io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);
    try cancel.request();
    try std.testing.expectError(error.QueryTimeout, query.await(io));

    // Canceling a statement must leave the original session synchronized.
    {
        var rows = try conn.query("select 1::int as n");
        defer rows.deinit();
        try std.testing.expectEqual(@as(i64, 1), try rows.next().?.as(i64, 0));
    }

    // Endpoint and key storage are independent, so handle teardown remains
    // valid after the originating connection has released all of its memory.
    conn.deinit();
}

test "postgres live: SimpleRow as/to decode" {
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

    var rows = try conn.queryParams(
        "select $1::bigint as id, $2::text as name, $3::boolean as active",
        &.{ .{ .integer = 9 }, .{ .text = "grace" }, .{ .boolean = true } },
    );
    defer rows.deinit();
    const row = rows.next() orelse return error.NoRows;
    try std.testing.expectEqual(@as(i64, 9), try row.as(i64, 0));
    try std.testing.expectEqualStrings("grace", try row.asName([]const u8, "name"));
    const User = struct { id: i64, name: []const u8, active: bool };
    const user = try row.to(User);
    try std.testing.expectEqual(@as(i64, 9), user.id);
    try std.testing.expectEqualStrings("grace", user.name);
    try std.testing.expect(user.active);
}
