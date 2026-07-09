pub const Error = @import("core/error.zig").Error;
pub const DbError = @import("core/db_error.zig").DbError;
pub const OwnedDbError = @import("core/db_error.zig").OwnedDbError;
pub const PostgresErrorFields = @import("core/db_error.zig").PostgresErrorFields;
pub const ErrorCategory = @import("core/db_error.zig").ErrorCategory;
pub const DriverKind = @import("core/db_error.zig").DriverKind;
pub const Value = @import("core/value.zig").Value;
pub const OwnedValue = @import("core/value.zig").OwnedValue;
pub const Row = @import("core/row.zig").Row;
pub const OwnedRow = @import("core/row.zig").OwnedRow;
pub const Rows = @import("core/rows.zig").Rows;
pub const ExecResult = @import("core/exec_result.zig").ExecResult;
pub const Stmt = @import("core/stmt.zig").Stmt;
pub const Conn = @import("core/conn.zig").Conn;
pub const Database = @import("core/database.zig").Database;
pub const QueryBuilder = @import("core/query.zig").QueryBuilder;
pub const params = @import("core/params.zig");
pub const migrate = @import("migrate/migrate.zig");
pub const inspect = @import("check/inspect.zig");
pub const check = @import("check/checker.zig");
pub const checkedQuery = @import("check/checker.zig").checkedQuery;
pub const StmtCache = @import("pool/stmt_cache.zig").StmtCache;
pub const formatStmtName = @import("pool/stmt_cache.zig").formatStmtName;
const options = @import("zsql_options");

/// True when this package was built with `-Denable-sqlite=true`.
pub const enable_sqlite = options.enable_sqlite;

pub const drivers = struct {
    pub const sqlite = if (options.enable_sqlite) @import("drivers/sqlite/sqlite.zig") else unavailable.sqlite;
    /// Native PostgreSQL driver (no libpq): URL, SCRAM/MD5/cleartext, simple and
    /// extended query, transactions, savepoints, and connection pooling.
    pub const postgres = @import("drivers/postgres/postgres.zig");
};

pub const unavailable = struct {
    pub const sqlite = struct {
        pub const enabled = false;
    };
};

test {
    _ = @import("core/value.zig");
    _ = @import("core/row.zig");
    _ = @import("core/rows.zig");
    _ = @import("core/exec_result.zig");
    _ = @import("core/db_error.zig");
    _ = @import("core/stmt.zig");
    _ = @import("core/conn.zig");
    _ = @import("core/database.zig");
    _ = @import("core/params.zig");
    _ = @import("core/query.zig");
    _ = @import("migrate/migrate.zig");
    _ = @import("check/inspect.zig");
    _ = @import("check/checker.zig");
    _ = @import("pool/stmt_cache.zig");
    _ = @import("drivers/postgres/postgres.zig");
    if (options.enable_sqlite) {
        _ = @import("drivers/sqlite/sqlite.zig");
    }
}
