pub const Error = @import("core/error.zig").Error;
pub const DbError = @import("core/db_error.zig").DbError;
pub const OwnedDbError = @import("core/db_error.zig").OwnedDbError;
pub const PostgresErrorFields = @import("core/db_error.zig").PostgresErrorFields;
pub const ErrorCategory = @import("core/db_error.zig").ErrorCategory;
pub const DriverKind = @import("core/db_error.zig").DriverKind;
pub const Value = @import("core/value.zig").Value;
pub const types = @import("core/types.zig");
pub const OwnedValue = @import("core/value.zig").OwnedValue;
pub const Row = @import("core/row.zig").Row;
pub const OwnedRow = @import("core/row.zig").OwnedRow;
/// Decode a single `Value` into a Zig type (same rules as `Row.to` / `Row.as`).
pub const decode = @import("core/row.zig").decode;
/// Free a `[]OwnedRow` from driver `queryAll` helpers.
pub const freeOwnedRows = OwnedRow.freeSlice;
pub const CoreRows = @import("core/rows.zig").Rows;
/// Deprecated bootstrap-only slice iterator. Use `ResultRows(D)` for database I/O.
pub const Rows = CoreRows;
pub const ExecResult = @import("core/exec_result.zig").ExecResult;
pub const CoreStmt = @import("core/stmt.zig").Stmt;
/// Deprecated bootstrap SQL parser whose I/O methods return `DriverUnavailable`.
/// Use a concrete driver's prepared-statement API.
pub const Stmt = CoreStmt;
pub const CoreConn = @import("core/conn.zig").Conn;
/// Deprecated bootstrap adapter whose I/O methods return `DriverUnavailable`.
/// Use `Connection(D)` for a concrete driver connection.
pub const Conn = CoreConn;
pub const CoreDatabase = @import("core/database.zig").Database;
pub const QueryBuilder = @import("core/query.zig").QueryBuilder;
pub const hooks = @import("core/hooks.zig");
pub const Hooks = hooks.Hooks;
pub const QueryStart = hooks.QueryStart;
pub const QueryEnd = hooks.QueryEnd;
pub const params = @import("core/params.zig");
pub const migrate = @import("migrate/migrate.zig");
pub const inspect = @import("check/inspect.zig");
pub const codegen = @import("check/codegen.zig");
pub const check = @import("check/checker.zig");
pub const checkedQuery = @import("check/checker.zig").checkedQuery;
pub const StmtCache = @import("pool/stmt_cache.zig").StmtCache;
pub const formatStmtName = @import("pool/stmt_cache.zig").formatStmtName;

/// Compile-time capability contract for driver markers used by the generic
/// ownership façade. This validates lifecycle primitives, not SQL signatures or
/// dialect behavior; concrete driver APIs remain available for those details.
pub fn validateDriver(comptime D: type) void {
    comptime {
        requireDecls(D, .{ "Database", "Conn", "Stmt", "Rows", "Row", "Pool", "Lease", "Tx", "Savepoint", "Migrator" });
        requireDecls(D.Database, .{ "open", "deinit" });
        requireDecls(D.Stmt, .{ "close", "exec", "query", "execNamed", "queryNamed" });
        requireDecls(D.Pool, .{ "init", "deinit", "acquire" });
        requireDecls(D.Lease, .{ "conn", "release", "discard" });
        requireDecls(D.Tx, .{ "commit", "rollback", "rollbackIfOpen" });
        requireDecls(D.Savepoint, .{ "release", "rollback", "rollbackIfOpen" });
        requireDecls(D.Migrator, .{ "init", "up", "status", "repairDirty" });
    }
}

fn requireDecls(comptime T: type, comptime names: anytype) void {
    inline for (names) |name| {
        if (!@hasDecl(T, name)) {
            @compileError(@typeName(T) ++ " is missing required zsql driver declaration `" ++ name ++ "`");
        }
    }
}

/// Driver-selected concrete types. These normalize ownership entry points, not SQL dialects.
pub fn Database(comptime D: type) type {
    validateDriver(D);
    return D.Database;
}
pub fn Connection(comptime D: type) type {
    validateDriver(D);
    return D.Conn;
}
pub fn Statement(comptime D: type) type {
    validateDriver(D);
    return D.Stmt;
}
pub fn ResultRows(comptime D: type) type {
    validateDriver(D);
    return D.Rows;
}
pub fn ResultRow(comptime D: type) type {
    validateDriver(D);
    return D.Row;
}
pub fn Pool(comptime D: type) type {
    validateDriver(D);
    return D.Pool;
}
pub fn Lease(comptime D: type) type {
    validateDriver(D);
    return D.Lease;
}
pub fn Tx(comptime D: type) type {
    validateDriver(D);
    return D.Tx;
}
pub fn Savepoint(comptime D: type) type {
    validateDriver(D);
    return D.Savepoint;
}
pub fn Migrator(comptime D: type) type {
    validateDriver(D);
    return D.Migrator;
}
const options = @import("zsql_options");

/// True when this package was built with `-Denable-sqlite=true`.
pub const enable_sqlite = options.enable_sqlite;

/// True when SQLite was built from the bundled amalgamation (default when
/// enabled). False when linked against system `libsqlite3` via `-Dsqlite-system=true`.
pub const sqlite_amalgamation = options.sqlite_amalgamation;

/// Package version string injected from `build.zig` (matches build.zig.zon).
pub const version = options.package_version;

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
    _ = @import("core/hooks.zig");
    _ = @import("migrate/migrate.zig");
    _ = @import("check/inspect.zig");
    _ = @import("check/codegen.zig");
    _ = @import("check/checker.zig");
    _ = @import("pool/stmt_cache.zig");
    _ = @import("drivers/postgres/postgres.zig");
    if (options.enable_sqlite) {
        _ = @import("drivers/sqlite/sqlite.zig");
    }
}

test "driver facade resolves concrete capability types" {
    comptime {
        validateDriver(drivers.postgres.Driver);
        _ = Database(drivers.postgres.Driver);
        _ = Connection(drivers.postgres.Driver);
        _ = Statement(drivers.postgres.Driver);
        _ = ResultRows(drivers.postgres.Driver);
        _ = ResultRow(drivers.postgres.Driver);
        _ = Pool(drivers.postgres.Driver);
        _ = Lease(drivers.postgres.Driver);
        _ = Tx(drivers.postgres.Driver);
        _ = Savepoint(drivers.postgres.Driver);
        _ = Migrator(drivers.postgres.Driver);
        if (options.enable_sqlite) {
            validateDriver(drivers.sqlite.Driver);
            _ = Database(drivers.sqlite.Driver);
            _ = Connection(drivers.sqlite.Driver);
            _ = Statement(drivers.sqlite.Driver);
            _ = ResultRows(drivers.sqlite.Driver);
            _ = ResultRow(drivers.sqlite.Driver);
            _ = Pool(drivers.sqlite.Driver);
            _ = Lease(drivers.sqlite.Driver);
            _ = Tx(drivers.sqlite.Driver);
            _ = Savepoint(drivers.sqlite.Driver);
            _ = Migrator(drivers.sqlite.Driver);
        }
    }
}
