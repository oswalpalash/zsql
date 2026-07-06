const std = @import("std");
const Conn = @import("conn.zig").Conn;

pub const Database = struct {
    allocator: std.mem.Allocator,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator) Database {
        return .{ .allocator = allocator };
    }

    pub fn close(self: *Database) void {
        self.closed = true;
    }

    pub fn connect(self: *Database) !Conn {
        if (self.closed) return error.ConnectionClosed;
        return Conn.init(self.allocator);
    }
};

test "Database creates explicit allocator-backed connections" {
    var db = Database.init(std.testing.allocator);
    var conn = try db.connect();
    conn.close();

    db.close();
    try std.testing.expectError(error.ConnectionClosed, db.connect());
}
