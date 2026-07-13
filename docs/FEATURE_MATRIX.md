# zsql feature matrix

This matrix ties the public promise to concrete implementation and repeatable
evidence. A checked box means the feature has a public API and deterministic
coverage; PostgreSQL rows marked live also run against PostgreSQL 16 in CI.

## Product promise

| Capability | Status | Public evidence | Test or example evidence |
| --- | --- | --- | --- |
| SQLite driver | Complete | `zsql.drivers.sqlite`; borrowed `InterruptHandle` | interruption and driver tests with `-Denable-sqlite=true` |
| Native PostgreSQL driver | Complete | full-open `connect_timeout`; owned `CancelHandle` | timeout/protocol unit tests; live cancellation in CI |
| Prepared statements | Complete | driver-selected `Statement(D)`; explicit direct/pool owners; narrow one-shot PostgreSQL invalidation recovery | SQLite schema-change tests and PostgreSQL direct/pool/cache live tests |
| Safe parameter binding | Complete | positional and named bind APIs on both drivers and prepared statements | driver tests; `tests/postgres_live.zig` |
| Typed row decoding | Complete | `Row.as`, `Row.asName`, `Row.to`, `zsql.decode` | core and driver tests |
| Explicit owned rows | Complete | `OwnedRow`, `Row.getOwned`, `zsql.freeOwnedRows` | allocator-backed core and driver tests |
| Connection pooling | Complete | `Pool(D)`, `Lease(D)`, health-aware release, shutdown draining/wakeup, stats and timeouts | SQLite recovery/lifecycle tests; PostgreSQL live tests |
| Transactions and savepoints | Complete | explicit nested/idle/aborted states; failed-state savepoint recovery; `Tx(D)`, `Savepoint(D)`, `withTx` | SQLite state tests and PostgreSQL direct/pool live tests |
| Migrations | Complete | transactional apply, durable dirty failures, checksum-guarded API/CLI repair; `Migrator(D).up`, `.status` | SQLite repair workflow, PostgreSQL live repair tests, CLI parser tests, migration example |
| Schema inspection | Complete | driver `inspectSchema`; CLI `inspect` | inspector tests and PostgreSQL live tests |
| Optional offline query checks | Complete within documented bounded scope | `zsql.check`, `zsql.checkedQuery` | `zig build check-sql` |
| Query builder | Complete | `QueryBuilder`, `ident`, `identPath`, `bind`, `rawUnsafe` | core unit tests |
| Rich database errors | Complete | fine-grained constraints; owned SQL templates; next-operation-bounded SQLite/PostgreSQL `lastError`; move-safe SQLite row-step diagnostics | SQLite redaction/deferred-row tests; PostgreSQL live lifetime/constraint tests |
| Driver extension contract | Complete | `zsql.validateDriver`, concrete connection/row/ownership selectors, concrete dialect APIs | compile-time SQLite/PostgreSQL façade tests |
| No ORM or hidden global runtime | By design | raw SQL APIs and explicit allocators on owning entry points | API review and leak-checked examples |

## Acceptance commands

The `run-*` names are stable roadmap-facing commands. Shorter historical names
remain as compatibility aliases.

| Scope | Command |
| --- | --- |
| Format | `zig fmt --check .` |
| Default build | `zig build` |
| Deterministic tests | `zig build test` |
| SQLite tests | `zig build test -Denable-sqlite=true` |
| SQLite example | `zig build run-sqlite-example -Denable-sqlite=true` |
| Migration example | `zig build run-migration-example -Denable-sqlite=true` |
| PostgreSQL unit plus optional live tests | `zig build test-postgres` |
| PostgreSQL pool example | `zig build run-postgres-pool-example` |
| Offline checks | `zig build check-sql` |
| All service-free examples | `zig build examples -Denable-sqlite=true` |

## Deliberate boundaries

- PostgreSQL temporal values remain explicit text/domain wrappers until an
  application chooses timezone and precision policy.
- Offline checking is a small schema-aware validator, not a full SQL parser.
- The driver façade selects concrete capability types; it does not normalize
  SQL syntax or erase driver-specific functionality.
