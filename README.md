# zsql
`zsql` is a Zig-first SQL toolkit providing a stable raw-SQL API, typed bind/scan, pooling, transactions, migrations, and optional offline query verification across SQLite and PostgreSQL.

## Status

This repository is in the SQLite driver foundation phase. The package currently exposes the public core names that driver work will build on:

- `zsql.Database`
- `zsql.Conn`
- `zsql.Stmt`
- `zsql.Tx`
- `zsql.Savepoint`
- `zsql.drivers.sqlite.Migrator`
- `zsql.drivers.sqlite.Pool`
- `zsql.drivers.sqlite.Lease`
- `zsql.Rows`
- `zsql.Row`
- `zsql.OwnedRow`
- `zsql.ExecResult`
- `zsql.Value`
- `zsql.OwnedValue`
- `zsql.params`
- `zsql.migrate`
- `zsql.drivers.sqlite` with `-Denable-sqlite=true`

The `zsql.params` module can classify SQL placeholders while ignoring quoted SQL and comments. It recognizes `?`, `?NNN`, `:name`, `@name`, and `$name` forms for future driver binding. Prepared statements record that metadata and reject bind-count mismatches before driver execution.

The `zsql.migrate` module can parse and scan versioned migration files such as `V0001__create_users.sql`, return sorted unique migration entries, reject duplicate versions, and compute deterministic SHA-256 SQL checksums.

The SQLite surface is currently opt-in and links against system SQLite for open/close, prepare/finalize, positional and named typed binds, non-row `exec` metadata, borrowed row decoding, `Row.to` struct mapping, transactions, savepoints, a single-threaded connection pool with max-open, max-idle, and stats support, and a `Migrator` wrapper over migration metadata/status/validation/apply helpers:

```sh
zig build test -Denable-sqlite=true
```

## Development

Run the test gate with Zig 0.16:

```sh
zig build test
```

Run the SQLite example with leak checking:

```sh
zig build sqlite-example -Denable-sqlite=true
```

Run the SQLite migration example with leak checking:

```sh
zig build sqlite-migrate-example -Denable-sqlite=true
```
