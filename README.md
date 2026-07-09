# zsql

zsql is a small, explicit SQL toolkit for Zig.

It gives you:
- SQLite and PostgreSQL drivers
- prepared statements
- safe parameter binding
- typed row decoding
- struct mapping
- connection pooling
- transactions and savepoints
- migrations
- optional offline query checks

It does not give you:
- an ORM
- hidden global state
- runtime reflection
- magic model objects
- fake cross-dialect SQL

## Status

Zig **0.16** package. Core surface is usable for SQLite end-to-end and PostgreSQL protocol/query work (live server recommended for integration).

### Public names

- `zsql.Database`, `zsql.Conn`, `zsql.Stmt`, `zsql.Tx`, `zsql.Savepoint`
- `zsql.Rows`, `zsql.Row`, `zsql.OwnedRow`, `zsql.Value`, `zsql.OwnedValue`
- `zsql.ExecResult`, `zsql.Error`, `zsql.DbError`, `zsql.OwnedDbError`
- `zsql.QueryBuilder`, `zsql.params`, `zsql.migrate`
- `zsql.StmtCache` (connection-local prepared-statement name LRU)
- `zsql.inspect`, `zsql.check`
- `zsql.drivers.sqlite` (`-Denable-sqlite=true`): full open/exec/query/bind/tx/savepoint/pool/migrator/schema inspect
- `zsql.drivers.postgres`: native (no libpq) URL parse, SCRAM-SHA-256 / MD5 / cleartext, simple + extended query, tx/savepoints, pool, schema inspect, `Conn.lastError()`, optional `enableStmtCache`

### SQLite

```sh
zig build test -Denable-sqlite=true
zig build sqlite-example -Denable-sqlite=true
zig build sqlite-migrate-example -Denable-sqlite=true
```

Links system `sqlite3` via explicit C ABI bindings (no `@cImport`).

### PostgreSQL

Native wire protocol. Prefer parameterized APIs:

```zig
// $1-style placeholders; values never concatenated into SQL
_ = try conn.execParams("insert into users (email) values ($1)", &.{.{ .text = "ada@example.com" }});
var rows = try conn.queryParams("select id, email from users where id = $1", &.{.{ .integer = 1 }});
defer rows.deinit();
```

TLS uses Zig's `std.crypto.tls.Client` (no OpenSSL). Behavior by `sslmode`:

- `disable` / `allow`: plain connection
- `prefer`: SSLRequest; plain if rejected; TLS if accepted (no cert verification)
- `require`: TLS encryption without certificate verification
- `verify-ca`: TLS + system CA verification
- `verify-full`: TLS + system CA + hostname verification

Use `sslmode=verify-full` when you need full certificate checks against OS trust stores.

Auth: trust, cleartext, MD5, **SCRAM-SHA-256**.

Failed commands map SQLSTATE into fine-grained errors (`UniqueViolation`, `ForeignKeyViolation`, …) and store rich metadata on the connection:

```zig
conn.execParams(...) catch |err| {
    if (conn.lastError()) |db_err| {
        // db_err.code / .table / .constraint — never includes bind params you sent
        _ = db_err;
    }
    return err;
};
```

After `ErrorResponse`, the driver drains to `ReadyForQuery` so the connection stays usable.

Optional prepared-statement cache (connection-local, no global state):

```zig
try conn.enableStmtCache(32);
// execParams/queryParams reuse named server prepares for identical SQL
try conn.disableStmtCache();
```

SQLite (`-Denable-sqlite=true`) has the same `enableStmtCache` API, caching `sqlite3_stmt` handles.

Schema inspection (for offline checks):

```zig
const schema = try conn.inspectSchema(allocator);
defer zsql.drivers.postgres.freeInspectedSchema(allocator, schema);
```

### QueryBuilder

```zig
var qb = zsql.QueryBuilder.init(allocator, .postgres);
defer qb.deinit();
try qb.appendTrustedSql("select * from ");
try qb.ident("users");
try qb.appendTrustedSql(" where id = ");
try qb.bind(.{ .integer = 1 });
// qb.sqlSlice() + qb.bindsSlice() for driver execParams/queryParams
```

Unsafe raw append is named `rawUnsafe` on purpose.

### Offline checks

```zig
try zsql.check.checkQuery(.{
    .sql = "select id, email from users where id = :id",
    .schema = schema,
    .args = &.{.{ .name = "id" }},
    .row = &.{
        .{ .name = "id", .type_name = "INTEGER" },
        .{ .name = "email", .type_name = "TEXT" },
    },
    .from_table = "users",
});
```

SQLite and PostgreSQL can build a schema graph with `Conn.inspectSchema` and render ZON via `zsql.inspect.writeSchemaZon`.

### CLI

```sh
zig build run -- --help
zig build run -- doctor
zig build run -- migrate new create_users

# SQLite apply/status/inspect (build CLI with SQLite enabled):
zig build -Denable-sqlite=true
./zig-out/bin/zsql migrate up --database app.db --dir migrations
./zig-out/bin/zsql migrate status --database app.db --dir migrations
./zig-out/bin/zsql inspect --database app.db --out schema.zon

# Postgres migrate/inspect (native driver; no -Denable-sqlite required):
./zig-out/bin/zsql migrate up --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable'
./zig-out/bin/zsql migrate status --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable'
./zig-out/bin/zsql inspect --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable' --out schema.zon

zig build checked-queries-example
zig build postgres-pool-example   # skips cleanly if ZSQL_PG_URL unset
```

## Development

```sh
zig fmt --check .
zig build
zig build test
zig build test -Denable-sqlite=true

# Optional live PostgreSQL (skipped when ZSQL_PG_URL is unset):
# export ZSQL_PG_URL='postgres://zsql:zsql@127.0.0.1:5432/zsql?sslmode=disable'
# zig build test-postgres
```

CI runs the same gates on Ubuntu with system SQLite and a Postgres service for `zig build test-postgres`.
