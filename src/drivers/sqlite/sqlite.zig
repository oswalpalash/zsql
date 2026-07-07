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

    pub fn prepare(self: *Conn, sql: []const u8) !Stmt {
        if (self.closed) return error.ConnectionClosed;
        return Stmt.init(self.allocator, self.handle, sql);
    }

    pub fn exec(self: *Conn, sql: []const u8, binds: []const core.Value) !void {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.exec(binds);
    }
};

pub const Stmt = struct {
    allocator: std.mem.Allocator,
    handle: *c.sqlite3_stmt,
    placeholders: core.params.Summary,
    owned_bind_buffers: std.ArrayListUnmanaged([]u8) = .empty,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, db: *c.sqlite3, sql: []const u8) !Stmt {
        if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.InvalidSql;

        const sql_z = try allocator.dupeZ(u8, sql);
        defer allocator.free(sql_z);

        var handle: ?*c.sqlite3_stmt = null;
        const rc = c.sqlite3_prepare_v2(db, sql_z.ptr, -1, &handle, null);
        if (rc != c.SQLITE_OK) return error.InvalidSql;

        return .{
            .allocator = allocator,
            .handle = handle.?,
            .placeholders = try core.params.summarize(sql),
        };
    }

    pub fn close(self: *Stmt) void {
        if (self.closed) return;
        self.freeBindBuffers();
        const rc = c.sqlite3_finalize(self.handle);
        std.debug.assert(rc == c.SQLITE_OK);
        self.owned_bind_buffers.deinit(self.allocator);
        self.closed = true;
    }

    pub fn exec(self: *Stmt, binds: []const core.Value) !void {
        if (self.closed) return error.StatementClosed;
        try self.bindValues(binds);
        return error.DriverUnavailable;
    }

    pub fn bindValues(self: *Stmt, binds: []const core.Value) !void {
        if (self.closed) return error.StatementClosed;
        try self.validateBindCount(binds);
        self.freeBindBuffers();
        _ = c.sqlite3_clear_bindings(self.handle);
        _ = c.sqlite3_reset(self.handle);

        for (binds, 1..) |value, index| {
            try self.bindValue(try sqliteIndex(index), value);
        }
    }

    fn validateBindCount(self: Stmt, binds: []const core.Value) !void {
        if (binds.len != @as(usize, @intCast(c.sqlite3_bind_parameter_count(self.handle)))) {
            return error.InvalidBindValue;
        }
    }

    fn bindValue(self: *Stmt, index: c_int, value: core.Value) !void {
        const rc = switch (value) {
            .null => c.sqlite3_bind_null(self.handle, index),
            .integer => |v| c.sqlite3_bind_int64(self.handle, index, v),
            .real => |v| c.sqlite3_bind_double(self.handle, index, v),
            .text => |v| return self.bindOwnedBytes(index, v, .text),
            .blob => |v| return self.bindOwnedBytes(index, v, .blob),
            .boolean => |v| c.sqlite3_bind_int(self.handle, index, if (v) 1 else 0),
        };
        if (rc != c.SQLITE_OK) return error.InvalidBindValue;
    }

    const ByteKind = enum {
        text,
        blob,
    };

    fn bindOwnedBytes(self: *Stmt, index: c_int, value: []const u8, kind: ByteKind) !void {
        const owned = try self.allocator.dupe(u8, value);
        errdefer self.allocator.free(owned);

        const rc = switch (kind) {
            .text => c.sqlite3_bind_text(self.handle, index, owned.ptr, try sqliteLen(owned.len), null),
            .blob => c.sqlite3_bind_blob(self.handle, index, owned.ptr, try sqliteLen(owned.len), null),
        };
        if (rc != c.SQLITE_OK) return error.InvalidBindValue;

        try self.owned_bind_buffers.append(self.allocator, owned);
    }

    fn freeBindBuffers(self: *Stmt) void {
        for (self.owned_bind_buffers.items) |buffer| {
            self.allocator.free(buffer);
        }
        self.owned_bind_buffers.clearRetainingCapacity();
    }
};

fn sqliteIndex(index: usize) !c_int {
    return std.math.cast(c_int, index) orelse error.InvalidBindValue;
}

fn sqliteLen(len: usize) !c_int {
    return std.math.cast(c_int, len) orelse error.InvalidBindValue;
}

test "SQLite opens memory database and preserves driver unavailable execution" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try std.testing.expectError(error.DriverUnavailable, conn.exec("select ?", &.{.{ .integer = 1 }}));
}

test "SQLite prepares and finalizes statements" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    var stmt = try conn.prepare("select ?, :name");
    defer stmt.close();

    try std.testing.expectEqual(@as(usize, 2), stmt.placeholders.total);
    try std.testing.expectError(error.InvalidBindValue, stmt.exec(&.{.{ .integer = 1 }}));
    try std.testing.expectError(error.DriverUnavailable, stmt.exec(&.{
        .{ .integer = 1 },
        .{ .text = "ada" },
    }));
}

test "SQLite binds all value variants before execution is implemented" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    var stmt = try conn.prepare("select ?, ?, ?, ?, ?, ?");
    defer stmt.close();

    try stmt.bindValues(&.{
        .{ .null = {} },
        .{ .integer = 42 },
        .{ .real = 3.5 },
        .{ .text = "zig" },
        .{ .blob = "sql" },
        .{ .boolean = true },
    });

    const expanded = c.sqlite3_expanded_sql(stmt.handle) orelse return error.DriverError;
    defer c.sqlite3_free(expanded);
    try std.testing.expectEqualStrings(
        "select NULL, 42, 3.5, 'zig', x'73716c', 1",
        std.mem.span(expanded),
    );

    try std.testing.expectError(error.DriverUnavailable, stmt.exec(&.{
        .{ .null = {} },
        .{ .integer = 42 },
        .{ .real = 3.5 },
        .{ .text = "zig" },
        .{ .blob = "sql" },
        .{ .boolean = false },
    }));
}

test "SQLite validates binds against SQLite parameter count" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    var stmt = try conn.prepare("select ?3");
    defer stmt.close();

    try std.testing.expectEqual(@as(usize, 1), stmt.placeholders.total);
    try std.testing.expectError(error.InvalidBindValue, stmt.bindValues(&.{
        .{ .integer = 1 },
    }));
    try stmt.bindValues(&.{
        .{ .null = {} },
        .{ .null = {} },
        .{ .integer = 3 },
    });
}

test "SQLite prepare rejects invalid SQL and closed connections" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    try std.testing.expectError(error.InvalidSql, conn.prepare("select from"));

    conn.close();
    try std.testing.expectError(error.ConnectionClosed, conn.prepare("select 1"));
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
