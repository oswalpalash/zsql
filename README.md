# zsql
`zsql` is a Zig-first SQL toolkit providing a stable raw-SQL API, typed bind/scan, pooling, transactions, migrations, and optional offline query verification across SQLite and PostgreSQL.

## Status

This repository is in the SQLite driver foundation phase. The package currently exposes the public core names that driver work will build on:

- `zsql.Database`
- `zsql.Conn`
- `zsql.Stmt`
- `zsql.Rows`
- `zsql.Row`
- `zsql.Value`
- `zsql.params`
- `zsql.drivers.sqlite` with `-Denable-sqlite=true`

Execution methods currently return `error.DriverUnavailable` until SQLite and PostgreSQL drivers are implemented.

The `zsql.params` module can classify SQL placeholders while ignoring quoted SQL and comments. It recognizes `?`, `?NNN`, `:name`, `@name`, and `$name` forms for future driver binding. Prepared statements record that metadata and reject bind-count mismatches before driver execution.

The SQLite surface is currently opt-in and links against system SQLite for open/close, prepare/finalize, typed bind conversion, and non-row `exec` tests:

```sh
zig build test -Denable-sqlite=true
```

## Development

Run the test gate with Zig 0.16:

```sh
zig build test
```
