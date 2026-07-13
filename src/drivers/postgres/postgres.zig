//! Native PostgreSQL driver for zsql.
//!
//! Pure-Zig URL parsing, protocol framing, auth, extended queries, pooling,
//! migrations, and schema inspection over TCP. No libpq.
//!
//! Integration: set `ZSQL_PG_URL` to exercise the live suite locally; CI runs
//! it against PostgreSQL 16.

pub const url = @import("url.zig");
pub const protocol = @import("protocol.zig");
pub const auth = @import("auth.zig");
pub const scram = @import("scram.zig");
pub const types = @import("types.zig");
pub const conn = @import("conn.zig");
pub const pool = @import("pool.zig");
pub const migrate = @import("migrate.zig");

pub const Config = url.Config;
pub const SslMode = url.SslMode;
pub const parseUrl = url.parse;
pub const Conn = conn.Conn;
pub const Stmt = conn.Stmt;
pub const CancelHandle = conn.CancelHandle;
pub const freeInspectedSchema = conn.freeInspectedSchema;
pub const SimpleRows = conn.SimpleRows;
pub const SimpleRow = conn.SimpleRow;
pub const Notification = conn.Notification;
pub const Savepoint = conn.Savepoint;
// Conn.queryOneParams is available on Conn for single-row queries.
pub const Pool = pool.Pool;
pub const Lease = pool.Lease;
pub const PooledRows = pool.PooledRows;
pub const Listener = pool.Listener;
pub const PoolConfig = pool.PoolConfig;
pub const PoolStats = pool.PoolStats;
pub const Migrator = migrate.Migrator;
pub const MigrationStatus = migrate.MigrationStatus;
pub const MigrationRecord = migrate.MigrationRecord;
pub const ApplyResult = migrate.ApplyResult;

/// Concrete capability mapping for the root `zsql.*(postgres.Driver)` façade.
/// PostgreSQL transactions are scoped methods on `Conn`, so `Tx` is `Conn`.
pub const Driver = struct {
    pub const Database = conn.Conn;
    pub const Conn = conn.Conn;
    pub const Stmt = conn.Stmt;
    pub const Rows = conn.SimpleRows;
    pub const Row = conn.SimpleRow;
    pub const Pool = pool.Pool;
    pub const Lease = pool.Lease;
    pub const Tx = conn.Conn;
    pub const Savepoint = conn.Savepoint;
    pub const Migrator = migrate.Migrator;
};

pub const enabled = true;

test {
    _ = url;
    _ = protocol;
    _ = auth;
    _ = scram;
    _ = types;
    _ = conn;
    _ = pool;
    _ = migrate;
}
