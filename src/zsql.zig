pub const Error = @import("core/error.zig").Error;
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
const options = @import("zsql_options");

pub const drivers = struct {
    pub const sqlite = if (options.enable_sqlite) @import("drivers/sqlite/sqlite.zig") else unavailable.sqlite;
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
    _ = @import("core/stmt.zig");
    _ = @import("core/conn.zig");
    _ = @import("core/database.zig");
    _ = @import("core/params.zig");
    if (options.enable_sqlite) {
        _ = @import("drivers/sqlite/sqlite.zig");
    }
}
