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
- optional offline query checks (JOIN scope, SELECT projections, optional WHERE / JOIN ON / ORDER BY column refs)

It does not give you:
- an ORM
- hidden global state
- runtime reflection
- magic model objects
- fake cross-dialect SQL

## Status

Zig **0.16** package. Core surface is usable for SQLite end-to-end and PostgreSQL protocol/query work (live server recommended for integration).

### Public names

- `zsql.Database(D)`, `zsql.Pool(D)`, `zsql.Lease(D)`, `zsql.Tx(D)`, `zsql.Savepoint(D)`, `zsql.Migrator(D)`
- `zsql.Conn`, `zsql.Stmt`, `zsql.Rows`, `zsql.Row` (driver-agnostic parsing/decoding primitives; use concrete driver types for database I/O)
- `zsql.OwnedRow`, `zsql.Value`, `zsql.OwnedValue`, `zsql.decode`
- `zsql.ExecResult`, `zsql.Error`, `zsql.DbError`, `zsql.OwnedDbError`
- `zsql.QueryBuilder`, `zsql.params`, `zsql.migrate`
- `zsql.Hooks`, `zsql.QueryStart`, `zsql.QueryEnd` (connection-local observability)
- `zsql.StmtCache` (connection-local prepared-statement name LRU)
- `zsql.inspect`, `zsql.check`
- `zsql.drivers.sqlite` (`-Denable-sqlite=true`): full open/exec/query/bind/tx/savepoint/pool/migrator/schema inspect, borrowed `InterruptHandle`, and `Conn.lastError()`
- `zsql.drivers.postgres`: native (no libpq) URL parse, SCRAM-SHA-256 / SCRAM-SHA-256-PLUS / MD5 / cleartext, simple + extended query, tx/savepoints, pool, schema inspect, owned `CancelHandle`, `Conn.lastError()`, optional `enableStmtCache`

Use a driver’s explicit marker for the generic façade, e.g.
`zsql.Database(zsql.drivers.sqlite.Driver)` or
`zsql.Pool(zsql.drivers.postgres.Driver)`. The façade selects concrete driver
types and compile-time validates their lifecycle capabilities; driver authors
can call `zsql.validateDriver(MyDriver)` directly. It does not normalize SQL
dialects or erase useful ownership differences: SQLite `Database` owns the
database handle and creates lightweight `Conn` wrappers, while PostgreSQL
`Database` is the network `Conn` itself, so their `open` signatures remain
driver-specific.

### SQLite

```sh
# Default: compile the bundled SQLite amalgamation (no system libsqlite3)
zig build test -Denable-sqlite=true
zig build run-sqlite-example -Denable-sqlite=true
zig build run-migration-example -Denable-sqlite=true

# Optional: link the OS package instead
zig build test -Denable-sqlite=true -Dsqlite-system=true
```

Uses explicit C ABI bindings in `src/drivers/sqlite/c.zig` (no `@cImport`).
With `-Denable-sqlite=true`, the build fetches and compiles the SQLite amalgamation
by default. Pass `-Dsqlite-system=true` to link system `libsqlite3` via pkg-config.

Long-running work can be interrupted from another task with a borrowed handle:

```zig
const interrupt = try conn.interruptHandle();
// While a query is active on conn from another task:
interrupt.request();
```

The interrupted operation returns `error.QueryTimeout`. The handle does not own
the database and must not outlive or race `Database.deinit`.

```zig
// Optional lock wait (sqlite3_busy_timeout) for multi-writer apps:
var db = try zsql.drivers.sqlite.Database.open(allocator, .{
    .mode = .file,
    .path = "app.db",
    .busy_timeout_ms = 5_000,
    .foreign_keys = true, // default; set false only for legacy schemas
});
```

SQLite extended result codes map unique/primary-key, foreign-key, not-null, and
check failures to the corresponding public `zsql.Error` categories.

### PostgreSQL

Native wire protocol. Prefer parameterized APIs:

```zig
// $1-style placeholders; values never concatenated into SQL
_ = try conn.execParams("insert into users (email) values ($1)", &.{.{ .text = "ada@example.com" }});
var rows = try conn.queryParams("select id, email from users where id = $1", &.{.{ .integer = 1 }});
defer rows.deinit();

// Named binds are rewritten to `$n` safely; repeated names share one bind.
var named_rows = try conn.queryNamed("select email from users where id = :id", &.{
    .{ .name = "id", .value = .{ .integer = 1 } },
});
defer named_rows.deinit();

// Exactly one row (OwnedRow); NoRows / TooManyRows otherwise:
var one = try conn.queryOneParams("select id, email from users where id = $1", &.{.{ .integer = 1 }});
defer one.deinit();

// All rows as []OwnedRow (free with zsql.freeOwnedRows):
const all = try conn.queryAllParams("select id, email from users", &.{});
defer zsql.freeOwnedRows(allocator, all);
```

SQLite mirrors this with `Conn.queryOne` / `Conn.queryAll`. Pools expose
`Pool.queryOne` / `Pool.queryOneParams` and `Pool.queryAll` / `Pool.queryAllParams`
(lease held only for the fetch; free multi-row results with `zsql.freeOwnedRows`).

Scoped transactions via `withTx` (commit on success, rollback on error):

```zig
// SQLite: body receives *Tx
try conn.withTx({}, struct {
    fn run(_: void, tx: *zsql.drivers.sqlite.Tx) !void {
        _ = try tx.exec("insert into t (id) values (?)", &.{.{ .integer = 1 }});
    }
}.run);

// Postgres: body receives *Conn (tx state lives on the connection)
try pg_conn.withTx({}, struct {
    fn run(_: void, c: *zsql.drivers.postgres.Conn) !void {
        _ = try c.execParams("insert into t (n) values ($1)", &.{.{ .integer = 1 }});
    }
}.run);

// Pools: `Pool.withTx` (and SQLite `Pool.withTxImmediate`) hold a lease for the body.
try pg_pool.withTx({}, struct {
    fn run(_: void, c: *zsql.drivers.postgres.Conn) !void {
        _ = try c.execParams("insert into t (n) values ($1)", &.{.{ .integer = 1 }});
    }
}.run);
```

Transaction state is explicit: starting a nested transaction returns
`error.ConnectionBusy`; committing or rolling back while idle returns
`error.TransactionClosed`. PostgreSQL commands rejected inside a transaction
put it into failed state, where `begin`/`commit` return
`error.TransactionAborted` until `rollback` restores the session.
`Savepoint.rollback` is also valid in PostgreSQL's failed state and performs
`ROLLBACK TO` followed by `RELEASE`, restoring the outer transaction for use.

Pool acquire timeout: `0` = non-blocking, `std.math.maxInt(u64)` = wait forever
(condition), any other value = deadline-based wait with ≤1 ms polling.

Pools retain synchronized connections after recoverable SQL errors and discard
closed, protocol-broken, or transaction-busy leases. A lease released with an
open transaction is never returned to another borrower.

`Pool.deinit()` closes idle connections and wakes blocked acquirers with
`error.PoolClosed`. Already-issued leases and pooled rows remain usable; they
close their connection instead of returning it when released. The `Pool` value
must remain alive until those outstanding owners are deinitialized.

TLS uses Zig's `std.crypto.tls.Client` (no OpenSSL). Behavior by `sslmode`:

- `disable` / `allow`: plain connection
- `prefer`: SSLRequest; plain if rejected; TLS if accepted (no cert verification)
- `require`: TLS encryption without certificate verification
- `verify-ca`: TLS + system CA verification
- `verify-full`: TLS + system CA + hostname verification

Use `sslmode=verify-full` when you need full certificate checks against OS trust stores.

Auth: trust, cleartext, MD5, **SCRAM-SHA-256**, and **SCRAM-SHA-256-PLUS**
(`tls-server-end-point` channel binding).

SCRAM-PLUS is used when the server offers it, TLS is active, and a leaf
certificate DER is available for channel binding. Because `std.crypto.tls.Client`
does not expose the peer certificate after handshake (TLS 1.3 encrypts it),
pin the server leaf cert when you need PLUS:

```zig
var config = try zsql.drivers.postgres.parseUrl(allocator, url);
defer config.deinit();
config.channel_binding = .require; // or prefer (default) / disable
config.peer_cert_der = server_leaf_cert_der; // borrowed; not freed by deinit
var conn = try zsql.drivers.postgres.Conn.open(allocator, io, config);
```

URL query: `channel_binding=disable|prefer|require` (libpq-compatible).

Optional `statement_timeout=<ms>` sets PostgreSQL `statement_timeout` after
startup (integer milliseconds; `0` disables). Server cancellations map to
`error.QueryTimeout`. You can also call `conn.setStatementTimeoutMs(ms)` at
runtime.

`connect_timeout=<seconds>` bounds the complete connection setup, including
DNS, TCP, TLS, startup, authentication, and session settings. Expiry returns
`error.ConnectionTimeout`; `0` or omission means no connection deadline.

Explicit cancellation uses an allocator-owned handle so it can safely run on a
separate task and TCP connection without borrowing mutable query state:

```zig
var cancel = try conn.createCancelHandle(allocator);
defer cancel.deinit();
// While a query is active on conn from another task:
try cancel.request(); // five-second request deadline
```

The interrupted query returns `error.QueryTimeout`, and the original connection
drains through `ReadyForQuery` before it is reused. Use
`requestWithTimeout(duration)` to choose a different cancellation deadline.

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
PostgreSQL `lastError()` is borrowed until the next SQL operation or `deinit`;
starting a later operation clears stale metadata, including when it succeeds.

SQLite exposes the same borrowed `Conn.lastError()` shape with its numeric
extended result code, diagnostic message, and statement text. It duplicates
connection-owned metadata immediately and never stores bind parameter values;
deferred `Rows.next()` failures update the same move-safe diagnostic state, so
pooled rows remain inspectable through their lease. A subsequent operation,
lease release, or `Conn.close()` clears the previous diagnostic.

Optional prepared-statement cache (connection-local, no global state):

```zig
try conn.enableStmtCache(32);
// execParams/queryParams reuse named server prepares for identical SQL
try conn.disableStmtCache();
```

Failed PostgreSQL Parse attempts and server-side cached-plan invalidations remove
their client mapping. The next call receives a fresh statement name and Parse,
preventing permanent `prepared statement does not exist` or `0A000` loops.

SQLite (`-Denable-sqlite=true`) has the same `enableStmtCache` API, caching `sqlite3_stmt` handles.
Schema-changing SQLite statements and scripts clear cached handles while keeping
the configured cache enabled, preventing stale result-column metadata after DDL.

Schema inspection (for offline checks):

```zig
const schema = try conn.inspectSchema(allocator);
defer zsql.drivers.postgres.freeInspectedSchema(allocator, schema);
```

### PostgreSQL extensions

LISTEN/NOTIFY keeps a dedicated pool lease until the listener is deinitialized:

```zig
var listener = try pool.listen();
defer listener.deinit();
try listener.listen("events");
var notification = try listener.next();
defer notification.deinit(allocator);
```

COPY uses trusted COPY SQL plus explicit bytes; values are encoded by the caller
for the selected COPY format:

```zig
_ = try conn.copyIn("copy users (id, email) from stdin with (format csv)", csv_bytes);
const exported = try conn.copyOut("copy users to stdout with (format csv)");
defer allocator.free(exported);
```

### QueryBuilder

```zig
var qb = zsql.QueryBuilder.init(allocator, .postgres);
// bind accepts Value or common Zig scalars (bool/int/float/[]const u8/?T/null)
defer qb.deinit();
try qb.appendTrustedSql("select * from ");
try qb.ident("users");
// or: try qb.identPath("public.users");
// or: try qb.identSegments(&.{ "public", "users" });
try qb.appendTrustedSql(" where id = ");
try qb.bind(@as(i64, 1)); // Zig scalars OK
// qb.sqlSlice() + qb.bindsSlice() for driver execParams/queryParams
```

Unsafe raw append is named `rawUnsafe` on purpose.

### Query hooks

Connection-local observability (no global registry). Hooks receive statement text
and duration — never bind parameter values.

```zig
var state: Counter = .{};
conn.setHooks(.{
    .ctx = &state,
    .before_query = struct {
        fn f(ctx: ?*anyopaque, start: zsql.QueryStart) void {
            _ = ctx;
            _ = start.sql; // statement only; binds are never included
        }
    }.f,
    .after_query = struct {
        fn f(ctx: ?*anyopaque, end: zsql.QueryEnd) void {
            _ = ctx;
            _ = end.duration_ns;
            _ = end.rows_affected;
            _ = end.err; // optional ErrorCategory on failure
        }
    }.f,
});
// clear: conn.setHooks(.{});
```

Pools accept the same hooks on `PoolConfig.hooks` and apply them to every
acquired connection.

### Typed row decoding

```zig
// Borrowed until next row / rows deinit:
const id = try row.as(i64, 0);
const email = try row.asName([]const u8, "email");

// Allocator-owned text/blob copy (caller frees):
const owned_email = try row.asNameOwned(allocator, "email");
defer allocator.free(owned_email);

// Struct mapping (name first, ordinal fallback):
const user = try row.to(struct { id: i64, email: []const u8 });

// Single-value helper (same rules as Row.as / Row.to):
const flag = try zsql.decode(bool, try row.get(2));
```

Postgres `SimpleRow` exposes the same `get` / `getName` / `as` / `asName` / `to` / `getOwned` surface.

`zsql.types.Text`, `Blob`, `Numeric`, and canonical-text `Uuid` decode through
the same borrowed row path. PostgreSQL `date`, `time`, `timestamp`, and
`timestamptz` are intentionally exposed as raw text in this release: parsing
them implicitly would require timezone and precision policy that zsql does not
hide. The explicit `Date`, `Time`, and `Timestamp` wrappers are available for
application-owned conversions.

### Offline checks

```zig
// Generated by `zsql inspect --out db/schema.zon`; parser-owned schema graph.
const schema = try zsql.inspect.parseSchemaZon(allocator, @embedFile("db/schema.zon"));
defer zsql.inspect.freeParsedSchemaZon(allocator, schema);

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

// Multi-table / JOIN scope (qualified columns; AmbiguousColumn for bare `id`):
try zsql.check.checkQuery(.{
    .sql =
    \\select users.email, posts.title
    \\from users join posts on posts.user_id = users.id
    ,
    .schema = schema,
    .from_tables = &.{ "users", "posts" },
    .row = &.{
        .{ .name = "users.email", .type_name = "TEXT" },
        .{ .name = "posts.title", .type_name = "TEXT" },
    },
    .check_projections = true, // also parse SELECT list against the scope
    .check_where = true, // resolve bare/qualified column refs in WHERE/HAVING
    .check_join_on = true, // resolve column refs in JOIN ON clauses
    .check_order_by = true, // resolve column refs in ORDER BY
});

// Or a reusable checked-query type:
const get_user = zsql.checkedQuery(.{
    .sql = "select id, email from users where id = :id",
    .args = .{ .id = i64 },
    .row = struct { id: i64, email: []const u8 },
    .from_table = "users",
    .check_where = true,
});
try get_user.validate(schema);
// get_user.sql is the trusted SQL string for runtime prepare/bind
```

Use `.level = .result_shape` or `.result_types` when a single progressive
validation policy is preferable to individual clause flags. `result_shape`
checks projections; `result_types` additionally enables WHERE/HAVING, JOIN ON,
and ORDER BY reference validation.

When `from_table` / `from_tables` are omitted, `checkQuery` best-effort extracts
`FROM` / `JOIN` table names and aliases from the SQL. `check_where`,
`check_join_on`, and `check_order_by` are opt-in: they resolve simple column refs
(including those inside function arguments like `lower(email)`), while skipping
keywords, binds, casts, and function *names*. SQLite and PostgreSQL can build a
schema graph with `Conn.inspectSchema` and render ZON via
`zsql.inspect.writeSchemaZon`. Applications load an embedded artifact with
`parseSchemaZon` and release its allocator-owned graph with
`freeParsedSchemaZon`.

### CLI

Migration applies are transactional and serialized per driver. If migration SQL
fails, schema changes roll back and zsql persists that version/checksum as
`dirty` after rollback. Later applies return `error.MigrationDirty` until an
operator inspects and repairs or removes the failed record; zsql does not hide
or automatically retry an uncertain migration.

`Migrator(D).repairDirty(version, expected_checksum)` is the guarded repair
primitive. It locks migration history, requires an existing dirty row and exact
checksum match, then deletes only that row so corrected migration SQL can rerun.
It never marks schema state clean.

The CLI derives that checksum from the matching file in `--dir`: run repair
while the failed file is unchanged, then edit it if needed and run `migrate up`.
If the file was already changed, repair stops with `MigrationChecksumMismatch`.

```sh
zig build run -- --help
zig build run -- doctor
zig build run -- migrate new create_users

# SQLite apply/status/inspect (build CLI with SQLite enabled):
zig build -Denable-sqlite=true
./zig-out/bin/zsql migrate up --database app.db --dir migrations
./zig-out/bin/zsql migrate status --database app.db --dir migrations
./zig-out/bin/zsql migrate repair --database app.db --version 1 --dir migrations
./zig-out/bin/zsql inspect --database app.db --out schema.zon

# Postgres migrate/inspect (native driver; no -Denable-sqlite required):
./zig-out/bin/zsql migrate up --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable'
./zig-out/bin/zsql migrate status --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable'
./zig-out/bin/zsql migrate repair --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable' --version 1 --dir migrations
./zig-out/bin/zsql inspect --url 'postgres://user:pass@127.0.0.1:5432/db?sslmode=disable' --out schema.zon

# Optional schema-to-Zig struct generation:
./zig-out/bin/zsql gen structs --schema schema.zon --out src/db/schema.zig

zig build checked-queries-example
# CI-friendly alias for validating the checked-query schema artifact/example:
zig build check-sql
zig build run-postgres-pool-example # skips cleanly if ZSQL_PG_URL unset
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

The implementation evidence behind the public promise and roadmap acceptance
commands is tracked in [`docs/FEATURE_MATRIX.md`](docs/FEATURE_MATRIX.md).
