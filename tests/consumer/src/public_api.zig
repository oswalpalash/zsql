const zsql = @import("zsql");

/// Compile the documented root namespace and driver façade from a separate
/// package. This is intentionally declaration-level compatibility coverage:
/// behavior and concrete signatures remain covered by the driver tests.
pub fn validate() void {
    comptime {
        @setEvalBranchQuota(10_000);
        requireDecls(zsql, .{
            "Database",
            "Connection",
            "Statement",
            "ResultRows",
            "ResultRow",
            "Pool",
            "Lease",
            "Tx",
            "Savepoint",
            "Migrator",
            "Conn",
            "Stmt",
            "Rows",
            "Row",
            "OwnedRow",
            "Value",
            "OwnedValue",
            "decode",
            "freeOwnedRows",
            "ExecResult",
            "Error",
            "DbError",
            "OwnedDbError",
            "QueryBuilder",
            "params",
            "migrate",
            "Hooks",
            "QueryStart",
            "QueryEnd",
            "StmtCache",
            "inspect",
            "check",
            "checkedQuery",
            "drivers",
        });

        requireDriver(zsql.drivers.postgres.Driver);
        requireDecls(zsql.drivers.postgres, .{
            "Config",
            "parseUrl",
            "Conn",
            "Stmt",
            "SimpleRows",
            "SimpleRow",
            "Notification",
            "Pool",
            "Lease",
            "Listener",
            "Savepoint",
            "Migrator",
            "Driver",
        });
        requireDecls(zsql.drivers.postgres.Notification, .{"deinit"});
        requireDecls(zsql.drivers.postgres.Listener, .{ "listen", "unlisten", "next", "deinit" });

        if (zsql.enable_sqlite) {
            requireDriver(zsql.drivers.sqlite.Driver);
            requireDecls(zsql.drivers.sqlite, .{
                "Database",
                "Conn",
                "Stmt",
                "Rows",
                "Pool",
                "Lease",
                "Tx",
                "Savepoint",
                "Migrator",
                "Driver",
            });
        }
    }
}

fn requireDriver(comptime D: type) void {
    zsql.validateDriver(D);

    const Database = zsql.Database(D);
    const Connection = zsql.Connection(D);
    const Statement = zsql.Statement(D);
    const Rows = zsql.ResultRows(D);
    const Row = zsql.ResultRow(D);
    const Pool = zsql.Pool(D);
    const Lease = zsql.Lease(D);
    const Tx = zsql.Tx(D);
    const Savepoint = zsql.Savepoint(D);
    const Migrator = zsql.Migrator(D);

    requireDecls(Database, .{ "open", "deinit" });
    requireDecls(Connection, .{ "exec", "query", "prepare", "begin", "lastError", "lastErrorOwned" });
    requireDecls(Statement, .{ "close", "exec", "query" });
    requireDecls(Rows, .{ "next", "deinit" });
    requireDecls(Row, .{ "get", "getName", "getOwned", "to" });
    requireDecls(Pool, .{ "init", "deinit", "acquire" });
    requireDecls(Lease, .{ "conn", "release", "discard" });
    requireDecls(Tx, .{ "commit", "rollback", "rollbackIfOpen" });
    requireDecls(Savepoint, .{ "release", "rollback", "rollbackIfOpen" });
    requireDecls(Migrator, .{ "init", "up", "status" });
}

fn requireDecls(comptime T: type, comptime names: anytype) void {
    inline for (names) |name| {
        if (!@hasDecl(T, name)) {
            @compileError(@typeName(T) ++ " is missing documented declaration `" ++ name ++ "`");
        }
    }
}
