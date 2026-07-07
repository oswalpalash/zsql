const std = @import("std");
const core = @import("../../zsql.zig");
const c = @cImport({
    @cInclude("sqlite3.h");
});

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
    handle: *c.sqlite3,
    closed: bool = false,

    pub fn open(allocator: std.mem.Allocator, config: Config) !Database {
        if (config.mode == .file and config.path.len == 0) return error.InvalidSql;
        const path = switch (config.mode) {
            .memory => ":memory:",
            .file => config.path,
        };
        const path_z = try allocator.dupeZ(u8, path);
        defer allocator.free(path_z);

        var handle: ?*c.sqlite3 = null;
        const flags = c.SQLITE_OPEN_READWRITE | c.SQLITE_OPEN_CREATE | c.SQLITE_OPEN_URI;
        const rc = c.sqlite3_open_v2(path_z.ptr, &handle, flags, null);
        if (rc != c.SQLITE_OK) {
            if (handle) |opened| {
                _ = c.sqlite3_close_v2(opened);
            }
            return error.DriverError;
        }

        return .{
            .allocator = allocator,
            .config = config,
            .handle = handle.?,
        };
    }

    pub fn deinit(self: *Database) void {
        if (self.closed) return;
        const rc = c.sqlite3_close_v2(self.handle);
        std.debug.assert(rc == c.SQLITE_OK);
        self.closed = true;
    }

    pub fn connect(self: *Database) !Conn {
        if (self.closed) return error.ConnectionClosed;
        return .{
            .allocator = self.allocator,
            .handle = self.handle,
        };
    }
};

pub const Conn = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3,
    closed: bool = false,

    pub fn close(self: *Conn) void {
        self.closed = true;
    }

    pub fn prepare(self: *Conn, sql: []const u8) !core.Stmt {
        if (self.closed) return error.ConnectionClosed;
        _ = self.allocator;
        _ = self.handle;
        return core.Stmt.init(sql);
    }

    pub fn exec(self: *Conn, sql: []const u8, binds: []const core.Value) !void {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.exec(binds);
    }
};

test "SQLite opens memory database and preserves driver unavailable execution" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try std.testing.expectError(error.DriverUnavailable, conn.exec("select ?", &.{.{ .integer = 1 }}));
}

test "SQLite validates config and connection lifetime" {
    try std.testing.expectError(error.InvalidSql, Database.open(std.testing.allocator, .{
        .mode = .file,
        .path = "",
    }));

    var db = try Database.open(std.testing.allocator, .{});
    db.deinit();
    try std.testing.expectError(error.ConnectionClosed, db.connect());
}
