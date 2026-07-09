pub const Error = @import("core/error.zig").Error;
pub const DbError = @import("core/db_error.zig").DbError;
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
pub const params = @import("core/params.zig");
pub const migrate = @import("migrate/migrate.zig");
const options = @import("zsql_options");

pub const drivers = struct {
    pub const sqlite = if (options.enable_sqlite) @import("drivers/sqlite/sqlite.zig") else unavailable.sqlite;
    /// Pure-Zig PostgreSQL driver surface. URL and protocol helpers are always
    /// available; live network I/O is added in later slices.
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
    _ = @import("migrate/migrate.zig");
    _ = @import("drivers/postgres/postgres.zig");
    if (options.enable_sqlite) {
        _ = @import("drivers/sqlite/sqlite.zig");
    }
}
