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
    try std.testing.expectEqual(@as(i64, 2), try (try count_row.value("n")).asInt());

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
    defer conn.deinit();
    var cancel = try conn.createCancelHandle(allocator);
    defer cancel.deinit();

    var query = io.async(runCancelableQuery, .{&conn});
    defer _ = query.cancel(io) catch {};
    try io.sleep(.{ .nanoseconds = 50 * std.time.ns_per_ms }, .awake);
    try cancel.request();
    try std.testing.expectError(error.QueryTimeout, query.await(io));

    // Canceling a statement must leave the original session synchronized.
    var rows = try conn.query("select 1::int as n");
    defer rows.deinit();
    try std.testing.expectEqual(@as(i64, 1), try rows.next().?.as(i64, 0));
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
