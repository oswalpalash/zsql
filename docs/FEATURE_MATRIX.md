# zsql feature matrix

This matrix ties the public promise to concrete implementation and repeatable
evidence. A checked box means the feature has a public API and deterministic
coverage; PostgreSQL rows marked live also run against PostgreSQL 16 in CI.

## Product promise

| Capability | Status | Public evidence | Test or example evidence |
| --- | --- | --- | --- |
| Package consumption | Complete | Zig package module `zsql`; propagated core/bundled/system SQLite dependency options; documented `zig fetch --save=zsql` setup | separate-package public-name compile contract plus core and leak-checked SQLite executables via `consumer-smoke` / `consumer-smoke-system` in CI |
| Installed distribution | Complete | installed static library, `zsql` CLI, and machine-readable `share/zsql/build.zon`; optional validated `-Dsource-revision`; byte-identical `zsql doctor --zon`; no repository-relative runtime resources | clean-prefix `install-smoke` validates file/CLI parity, strict arguments, null/default provenance, and `unrecorded`; reproducibility gate validates matching explicit metadata/doctor revision; configure-only validation rejects malformed revisions |
| Target portability | Complete for release gate | core library and CLI cross-build for `x86_64-windows` and static `aarch64-linux-musl`, both libc-free by default and with bundled SQLite | isolated-prefix four-cell `portability-smoke` is part of `release-verify` in CI |
| Native artifact reproducibility | Complete for stripped `ReleaseSafe` gate | public `-Dstrip=true` install mode removes debug paths; installed archives canonicalize Zig 0.16's cache-derived member name | `reproducibility-smoke` compares CLI, static-library, and provenance bytes across separate local caches and prefixes |
| Version integrity | Complete | `build.zig.zon` release version projected into `zsql.version` and CLI doctor | `version-sync` source gate plus installed-doctor manifest comparison |
| Release payload | Complete | manifest `.paths` includes all library, CLI, consumer, and gate inputs | isolated-index Git archive is fetched, extracted, tested, consumed, installed, and cross-built for static ARM Linux with bundled SQLite by `package-smoke` |
| Pre-tag release contract | Complete | documented `release-verify`; live PostgreSQL remains explicit and separate | aggregate runs every deterministic format/build/test/example/package/install/consumer gate and has failure-propagation regression |
| Release governance | Blocked on owner license choice | `RELEASE_CHECKLIST.md` defines metadata, live PostgreSQL, immutable tag, fetch hash, and post-release evidence | deterministic and live gates exist; no public tag until a recognized `LICENSE` is added |
| SQLite driver | Complete | `zsql.drivers.sqlite`; borrowed `InterruptHandle` | interruption and driver tests with `-Denable-sqlite=true` |
| Native PostgreSQL driver | Complete | full-open `connect_timeout`; ordered grammar-validated SCRAM attributes/nonces, allocator-bounded salt handling, constant-time raw verifier comparison, and secure secret erasure; endpoint-owning `CancelHandle`; owned notifications; clean pooled listeners; direct and short-lease pooled COPY with owned output; lifecycle-aware command recovery | SCRAM ordering/grammar/extension/ambiguity/error/base64/password-erasure and exhaustive allocation-failure tests; cancellation/notification/COPY ownership and OOM tests; live post-teardown ownership, clean pool reuse, cancellation/COPY/notification recovery in CI |
| Prepared statements | Complete | driver-selected `Statement(D)`; reusable ownership-safe SQLite query borrows with busy/deferred-close state and leak-free cache-copy bind scratch; explicit PostgreSQL direct/pool owners; owned prepared-query rows survive statement/pool teardown; reusable named-bind scratch; session-monotonic PostgreSQL names; allocation-free cache teardown; unsigned OID metadata; narrow invalidation recovery | external façade contract; SQLite reuse/OOM/teardown/text-bind-cache/schema-change tests and PostgreSQL protocol/direct/pool/cache/OOM/lifetime tests |
| Safe parameter binding | Complete | positional/named APIs; two-allocation SQLite named-index resolution with one unbounded shared marker probe and exact OOM errors; single-allocation PostgreSQL Bind packets; full unsigned 16-bit parameter count; strict protocol C-strings | long-name/allocation-boundary/failure-atomicity, byte-parity, NUL, driver, and PostgreSQL live tests |
| Typed row decoding | Complete | `Row.as`, `Row.asName`, `Row.to`, `zsql.decode`; allocation-free struct mapping without arbitrary result-width caps; owned PostgreSQL bytea hex/escape decode; single-schema query contract | malformed/OOM unit tests; wide-result mapping, multi-result recovery, and core/live driver tests |
| Explicit owned rows | Complete | `OwnedRow`, `Row.getOwned`, `zsql.freeOwnedRows`; direct PostgreSQL deep copies without staging arrays; documented invalidation boundary for borrowed values | exhaustive partial-OOM core/driver tests plus external SQLite survival after rows, connection, and database teardown |
| Connection pooling | Complete | `Pool(D)`, `Lease(D)`, health-aware consuming release, OOM-safe idle return and owned-result unwind, shutdown draining/wakeup, stats and timeouts | SQLite release-OOM/result-unwind/recovery tests; PostgreSQL live release-OOM/result-unwind/shutdown tests |
| Transactions and savepoints | Complete | explicit nested/idle/aborted states; PostgreSQL `25P02` mapping; prepared-statement transition safety; failed-state savepoint recovery; `Tx(D)`, `Savepoint(D)`, `withTx` | SQLite state tests and PostgreSQL direct/prepared/pool live tests |
| Migrations | Complete | transactional apply, durable dirty failures, checksum-guarded API/CLI repair; allocator-owned post-connection `MigrationStatus`; exclusive atomic and collision-retrying `migrate new`; checked `u64` version discovery; `Migrator(D).up`, `.status` | cross-driver status OOM/teardown tests, SQLite repair workflow, PostgreSQL live repair tests, CLI atomic-create/concurrent-collision/version-boundary/parser tests, migration example |
| Schema inspection | Complete | allocator-owned post-connection schema graph; SQLite bound catalog PRAGMAs without identifier interpolation or fixed name caps; driver `inspectSchema`; dialect-tagged CLI `inspect`; parent-creating, permission-preserving atomic schema/codegen replacement with supported-POSIX directory sync; structured PostgreSQL schema/table identity; self-contained nullable struct generation with exact fields and schema-aware collision-free table types | SQLite exhaustive graph OOM plus long adversarial-name tests; PostgreSQL post-connection live test; inspector/codegen syntax and CLI atomic replacement/permission/nested-output tests |
| Optional offline query checks | Complete within documented bounded scope | `zsql.check`, `zsql.checkedQuery`; dialect-aware unquoted lookup and structured `schema.table` / `schema.table.column` PostgreSQL resolution; exact escaped quoted identifiers; SQL-correct alias visibility; exact bind contracts; outer-CTE anchoring with opaque-relation rejection; projection/alias-bound row shapes; portable COUNT/MIN/MAX inference; WHERE/HAVING/JOIN ON/USING/GROUP/ORDER refs; explicit capacity failures; typed domain wrappers; numeric width checks | parser/dialect/schema-qualified/CTE/quoted-identifier/projection/aggregate/clause/join/scope/shape/type/nullability/narrowing tests; `zig build check-sql` |
| Query builder | Complete | `QueryBuilder`; failure-atomic `ident`, `identPath`, `identSegments`, and owned text/blob `bind`; `rawUnsafe` | exhaustive/per-boundary state and retry tests for both bind dialects, quoted-identifier growth, and invalid later path segments |
| Rich database errors | Complete | fine-grained constraints; owned SQL templates; safe default formatting; explicit sensitive diagnostics; borrowed SQLite/PostgreSQL `lastError`; allocator-owned `lastErrorOwned` / `OwnedDbError.from`; move-safe SQLite row-step diagnostics | safe-format and allocation-failure cleanup tests; external SQLite teardown survival; SQLite redaction/deferred-row tests; PostgreSQL live lifetime/constraint tests |
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
| Cross-target distribution | `zig build portability-smoke` |
| Stripped native reproducibility | `zig build reproducibility-smoke` |
| Provenance validation | `zig build provenance-validation` |

## Deliberate boundaries

- PostgreSQL temporal values remain explicit text/domain wrappers until an
  application chooses timezone and precision policy.
- Offline checking is a small schema-aware validator, not a full SQL parser.
- The driver façade selects concrete capability types; it does not normalize
  SQL syntax or erase driver-specific functionality.
