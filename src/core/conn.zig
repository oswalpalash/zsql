const std = @import("std");
const Stmt = @import("stmt.zig").Stmt;
const Value = @import("value.zig").Value;
const Rows = @import("rows.zig").Rows;

pub const Conn = struct {
    allocator: std.mem.Allocator,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Conn {
        return .{ .allocator = allocator };
    }

    pub fn close(self: *Conn) void {
        self.closed = true;
    }

    pub fn prepare(self: *Conn, sql: []const u8) !Stmt {
        if (self.closed) return error.ConnectionClosed;
        return Stmt.init(sql);
    }

    pub fn exec(self: *Conn, sql: []const u8, binds: []const Value) !void {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.exec(binds);
    }

    pub fn query(self: *Conn, sql: []const u8, binds: []const Value) !Rows {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.query(binds);
    }
};

test "Conn prepares statements and tracks closure" {
    var conn = Conn.init(std.testing.allocator);
    var stmt = try conn.prepare("select 1");
    defer stmt.close();

    conn.close();
    try std.testing.expectError(error.ConnectionClosed, conn.prepare("select 1"));
}
