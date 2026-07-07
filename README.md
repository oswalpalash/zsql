# zsql
`zsql` is a Zig-first SQL toolkit providing a stable raw-SQL API, typed bind/scan, pooling, transactions, migrations, and optional offline query verification across SQLite and PostgreSQL.

## Status

This repository is in the buildable-core phase. The package currently exposes the public core names that driver work will build on:

- `zsql.Database`
- `zsql.Conn`
- `zsql.Stmt`
- `zsql.Rows`
- `zsql.Row`
- `zsql.Value`
- `zsql.params`

Execution methods currently return `error.DriverUnavailable` until SQLite and PostgreSQL drivers are implemented.

The `zsql.params` module can classify SQL placeholders while ignoring quoted SQL and comments. It recognizes `?`, `?NNN`, `:name`, `@name`, and `$name` forms for future driver binding.

## Development

Run the test gate with Zig 0.16:

```sh
zig build test
```
