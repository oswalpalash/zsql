const std = @import("std");
const params = @import("params.zig");
const Rows = @import("rows.zig").Rows;
const Value = @import("value.zig").Value;

pub const Stmt = struct {
    sql: []const u8,
    placeholders: params.Summary,
    closed: bool = false,

    pub fn init(sql: []const u8) !Stmt {
        if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.InvalidSql;
        return .{
            .sql = sql,
            .placeholders = try params.summarize(sql),
        };
    }

    pub fn close(self: *Stmt) void {
        self.closed = true;
    }

    pub fn exec(self: *Stmt, binds: []const Value) !void {
        if (self.closed) return error.StatementClosed;
        try self.validateBindCount(binds);
        return error.DriverUnavailable;
    }

    pub fn query(self: *Stmt, binds: []const Value) !Rows {
        if (self.closed) return error.StatementClosed;
        try self.validateBindCount(binds);
        return error.DriverUnavailable;
    }

    fn validateBindCount(self: Stmt, binds: []const Value) !void {
        if (binds.len != self.placeholders.expectedBindCount()) {
            return error.InvalidBindValue;
        }
    }
};

test "Stmt validates SQL and closed state" {
    try std.testing.expectError(error.InvalidSql, Stmt.init(" \n\t"));

    var stmt = try Stmt.init("select 1");
    stmt.close();
    try std.testing.expectError(error.StatementClosed, stmt.exec(&.{}));
}

test "Stmt validates bind counts before driver execution" {
    var stmt = try Stmt.init("select ?, ?3, :name");
    try std.testing.expectEqual(@as(usize, 3), stmt.placeholders.total);
    try std.testing.expectEqual(@as(usize, 3), stmt.placeholders.expectedBindCount());

    try std.testing.expectError(error.InvalidBindValue, stmt.exec(&.{.{ .integer = 1 }}));
    try std.testing.expectError(error.DriverUnavailable, stmt.exec(&.{
        .{ .integer = 1 },
        .{ .null = {} },
        .{ .text = "ada" },
    }));
}
