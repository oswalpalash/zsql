const std = @import("std");
const core = @import("../../zsql.zig");

pub const OpenMode = enum {
    memory,
    file,
};

pub const Config = struct {
    path: []const u8 = ":memory:",
    mode: OpenMode = .memory,
};

pub const Database = struct {
    allocator: std.mem.Allocator,
    config: Config,
    closed: bool = false,

    pub fn open(allocator: std.mem.Allocator, config: Config) !Database {
        if (config.mode == .file and config.path.len == 0) return error.InvalidSql;
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Database) void {
        self.closed = true;
    }

    pub fn connect(self: *Database) !Conn {
        if (self.closed) return error.ConnectionClosed;
        return .{
            .allocator = self.allocator,
        };
    }
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    closed: bool = false,

    pub fn close(self: *Conn) void {
        self.closed = true;
    }

    pub fn prepare(self: *Conn, sql: []const u8) !core.Stmt {
        if (self.closed) return error.ConnectionClosed;
        _ = self.allocator;
        return core.Stmt.init(sql);
    }

    pub fn exec(self: *Conn, sql: []const u8, binds: []const core.Value) !void {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.exec(binds);
    }
};

test "SQLite skeleton opens memory database and preserves driver unavailable execution" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try std.testing.expectError(error.DriverUnavailable, conn.exec("select ?", &.{.{ .integer = 1 }}));
}

test "SQLite skeleton validates config and connection lifetime" {
    try std.testing.expectError(error.InvalidSql, Database.open(std.testing.allocator, .{
        .mode = .file,
        .path = "",
    }));

    var db = try Database.open(std.testing.allocator, .{});
    db.deinit();
    try std.testing.expectError(error.ConnectionClosed, db.connect());
}
