const std = @import("std");
const Rows = @import("rows.zig").Rows;
const Value = @import("value.zig").Value;

pub const Stmt = struct {
    sql: []const u8,
    closed: bool = false,

    pub fn init(sql: []const u8) !Stmt {
        if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.InvalidSql;
        return .{ .sql = sql };
    }

    pub fn close(self: *Stmt) void {
        self.closed = true;
    }

    pub fn exec(self: *Stmt, binds: []const Value) !void {
        _ = binds;
        if (self.closed) return error.StatementClosed;
        return error.DriverUnavailable;
    }

    pub fn query(self: *Stmt, binds: []const Value) !Rows {
        _ = binds;
        if (self.closed) return error.StatementClosed;
        return error.DriverUnavailable;
    }
};

test "Stmt validates SQL and closed state" {
    try std.testing.expectError(error.InvalidSql, Stmt.init(" \n\t"));

    var stmt = try Stmt.init("select 1");
    stmt.close();
    try std.testing.expectError(error.StatementClosed, stmt.exec(&.{}));
}
