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

    // `exec` is for non-row statements; probe with SET + a short query via lease.
    _ = try pool.exec("set application_name to 'zsql-live-pool'");
    var rows = try pool.queryParams("select 1::int as n", &.{});
    defer rows.deinit();
    const row = rows.next().?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("n")).asInt());

    const stats = pool.stats();
    try std.testing.expect(stats.open >= 1);
    // Lease still held until rows.deinit above finishes; after defer, open may be idle.
}
