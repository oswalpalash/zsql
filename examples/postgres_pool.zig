//! Leak-checked PostgreSQL pool example.
//!
//! Requires `ZSQL_PG_URL`, e.g.:
//!
//! ```sh
//! export ZSQL_PG_URL='postgres://zsql:zsql@127.0.0.1:5432/zsql?sslmode=disable'
//! zig build postgres-pool-example
//! ```
//!
//! Exits successfully with a notice when the URL is unset so local builds without
//! Postgres stay green.

const std = @import("std");
const zsql = @import("zsql");
const pg = zsql.drivers.postgres;

pub fn main(init: std.process.Init) !void {
    const allocator = init.gpa;
    const io = init.io;

    const url_str = std.process.Environ.getAlloc(init.minimal.environ, allocator, "ZSQL_PG_URL") catch {
        try std.Io.File.stdout().writeStreamingAll(io, "ZSQL_PG_URL unset; skipping postgres pool example\n");
        return;
    };
    defer allocator.free(url_str);

    var config = try pg.parseUrl(allocator, url_str);
    defer config.deinit();

    var pool = try pg.Pool.init(allocator, io, .{
        .database = config,
        .max_open = 4,
        .max_idle = 2,
        .acquire_timeout_ns = 2 * std.time.ns_per_s,
    });
    defer pool.deinit();

    _ = try pool.exec(
        \\create temporary table if not exists zsql_pool_demo (
        \\  id serial primary key,
        \\  email text not null
        \\)
    );

    _ = try pool.execParams(
        "insert into zsql_pool_demo (email) values ($1)",
        &.{.{ .text = "ada@example.com" }},
    );

    var rows = try pool.queryParams(
        "select id, email from zsql_pool_demo where email = $1",
        &.{.{ .text = "ada@example.com" }},
    );
    defer rows.deinit();

    const row = rows.next() orelse return error.NoRows;
    const email = try (try row.value("email")).asText();
    if (!std.mem.eql(u8, email, "ada@example.com")) return error.UnexpectedEmail;

    const stats = pool.stats();
    if (stats.open == 0) return error.PoolEmpty;

    try std.Io.File.stdout().writeStreamingAll(io, "postgres pool example ok\n");
}
