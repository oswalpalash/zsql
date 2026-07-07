pub const Error = @import("core/error.zig").Error;
pub const Value = @import("core/value.zig").Value;
pub const Row = @import("core/row.zig").Row;
pub const Rows = @import("core/rows.zig").Rows;
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
    _ = @import("core/stmt.zig");
    _ = @import("core/conn.zig");
    _ = @import("core/database.zig");
    _ = @import("core/params.zig");
    if (options.enable_sqlite) {
        _ = @import("drivers/sqlite/sqlite.zig");
    }
}
