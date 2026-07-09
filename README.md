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
- `zsql.ExecResult`, `zsql.Error`, `zsql.DbError`
- `zsql.QueryBuilder`, `zsql.params`, `zsql.migrate`
- `zsql.inspect`, `zsql.check`
- `zsql.drivers.sqlite` (`-Denable-sqlite=true`): full open/exec/query/bind/tx/savepoint/pool/migrator/schema inspect
- `zsql.drivers.postgres`: native (no libpq) URL parse, SCRAM-SHA-256 / MD5 / cleartext, simple + extended query, tx/savepoints, pool

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

TLS is not implemented: `sslmode=require|verify-*` returns `error.TlsFailed`. Use `sslmode=disable` on trusted networks for now.

Auth: trust, cleartext, MD5, **SCRAM-SHA-256**.

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

SQLite can build a schema graph with `Conn.inspectSchema` and render ZON via `zsql.inspect.writeSchemaZon`.

### CLI

```sh
zig build run -- --help
zig build run -- doctor
zig build run -- migrate new create_users
```

## Development

```sh
zig fmt --check .
zig build
zig build test
zig build test -Denable-sqlite=true
```

CI runs the same gates on Ubuntu with system SQLite.
