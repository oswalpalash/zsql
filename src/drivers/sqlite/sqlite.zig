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

pub const NamedValue = struct {
    name: []const u8,
    value: core.Value,
};

pub const MigrationRecord = struct {
    version: u64,
    name: []u8,
    checksum: core.migrate.Checksum,
    applied_at: []u8,
    dirty: bool,

    pub fn deinit(self: *MigrationRecord, allocator: std.mem.Allocator) void {
        allocator.free(self.name);
        allocator.free(self.applied_at);
        self.* = undefined;
    }
};

pub const MigrationStatus = struct {
    allocator: std.mem.Allocator,
    records: []MigrationRecord,

    pub fn deinit(self: *MigrationStatus) void {
        for (self.records) |*record| {
            record.deinit(self.allocator);
        }
        self.allocator.free(self.records);
        self.* = undefined;
    }
};

pub const ApplyResult = struct {
    applied: usize,
};

pub const Migrator = struct {
    conn: *Conn,

    pub fn init(conn: *Conn) Migrator {
        return .{ .conn = conn };
    }

    pub fn ensureTable(self: Migrator) !void {
        return ensureMigrationTable(self.conn);
    }

    pub fn status(self: Migrator, allocator: std.mem.Allocator) !MigrationStatus {
        return migrationStatus(allocator, self.conn);
    }

    pub fn validate(self: Migrator, migrations: []const core.migrate.MigrationFile) !void {
        return validateMigrationStatus(self.conn, migrations);
    }

    pub fn apply(self: Migrator, migrations: []const core.migrate.MigrationFile) !ApplyResult {
        return applyMigrations(self.conn, migrations);
    }
};

pub const PoolConfig = struct {
    database: Config = .{},
    max_open: usize = 4,
};

pub const Pool = struct {
    allocator: std.mem.Allocator,
    config: PoolConfig,
    idle: std.ArrayListUnmanaged(Database) = .empty,
    open_count: usize = 0,
    closed: bool = false,

    pub fn init(allocator: std.mem.Allocator, config: PoolConfig) !Pool {
        if (config.max_open == 0) return error.InvalidBindValue;
        return .{
            .allocator = allocator,
            .config = config,
        };
    }

    pub fn deinit(self: *Pool) void {
        if (self.closed) return;
        std.debug.assert(self.open_count == self.idle.items.len);

        for (self.idle.items) |*db| {
            db.deinit();
        }
        self.idle.deinit(self.allocator);
        self.open_count = 0;
        self.closed = true;
    }

    pub fn acquire(self: *Pool) !Lease {
        if (self.closed) return error.PoolClosed;

        var db = if (self.idle.pop()) |idle_db|
            idle_db
        else blk: {
            if (self.open_count >= self.config.max_open) return error.PoolExhausted;
            const opened = try Database.open(self.allocator, self.config.database);
            self.open_count += 1;
            break :blk opened;
        };
        errdefer {
            db.deinit();
            self.open_count -= 1;
        }

        const conn = try db.connect();
        return .{
            .pool = self,
            .db = db,
            .conn_value = conn,
        };
    }
};

pub const Lease = struct {
    pool: *Pool,
    db: Database,
    conn_value: Conn,
    open: bool = true,

    pub fn conn(self: *Lease) !*Conn {
        if (!self.open) return error.LeaseClosed;
        return &self.conn_value;
    }

    pub fn release(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;
        if (self.pool.closed) return error.PoolClosed;

        self.conn_value.close();
        try self.pool.idle.append(self.pool.allocator, self.db);
        self.open = false;
    }

    pub fn discard(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.conn_value.close();
        self.db.deinit();
        self.pool.open_count -= 1;
        self.open = false;
    }
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

    pub fn exec(self: *Conn, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.exec(binds);
    }

    pub fn execScript(self: *Conn, sql: []const u8) !void {
        if (self.closed) return error.ConnectionClosed;
        try execScriptSql(self.allocator, self.handle, sql);
    }

    pub fn query(self: *Conn, sql: []const u8, binds: []const core.Value) !Rows {
        var stmt = try self.prepare(sql);
        errdefer stmt.close();
        return Rows.init(stmt, binds);
    }

    pub fn execNamed(self: *Conn, sql: []const u8, binds: []const NamedValue) !core.ExecResult {
        var stmt = try self.prepare(sql);
        defer stmt.close();
        return stmt.execNamed(binds);
    }

    pub fn queryNamed(self: *Conn, sql: []const u8, binds: []const NamedValue) !Rows {
        var stmt = try self.prepare(sql);
        errdefer stmt.close();
        return Rows.initNamed(stmt, binds);
    }

    pub fn begin(self: *Conn) !Tx {
        if (self.closed) return error.ConnectionClosed;
        _ = try self.exec("begin", &.{});
        return .{
            .conn = self,
        };
    }

    pub fn beginImmediate(self: *Conn) !Tx {
        if (self.closed) return error.ConnectionClosed;
        _ = try self.exec("begin immediate", &.{});
        return .{
            .conn = self,
        };
    }
};

pub fn ensureMigrationTable(conn: *Conn) !void {
    _ = try conn.exec(
        \\create table if not exists zsql_migrations (
        \\  version integer primary key,
        \\  name text not null,
        \\  checksum text not null,
        \\  applied_at text not null default current_timestamp,
        \\  dirty integer not null default 0 check (dirty in (0, 1))
        \\)
    , &.{});
}

pub fn migrationStatus(allocator: std.mem.Allocator, conn: *Conn) !MigrationStatus {
    var rows = try conn.query(
        \\select version, name, checksum, applied_at, dirty
        \\from zsql_migrations
        \\order by version
    , &.{});
    defer rows.deinit();

    var records: std.ArrayListUnmanaged(MigrationRecord) = .empty;
    errdefer {
        for (records.items) |*record| {
            record.deinit(allocator);
        }
        records.deinit(allocator);
    }

    while (try rows.next()) |row| {
        const version = try unsignedVersion(try (try row.value("version")).asInt());
        const name = try allocator.dupe(u8, try (try row.value("name")).asText());
        errdefer allocator.free(name);
        const checksum = try parseChecksum(try (try row.value("checksum")).asText());
        const applied_at = try allocator.dupe(u8, try (try row.value("applied_at")).asText());
        errdefer allocator.free(applied_at);
        const dirty = try sqliteBool(try (try row.value("dirty")).asInt());

        try records.append(allocator, .{
            .version = version,
            .name = name,
            .checksum = checksum,
            .applied_at = applied_at,
            .dirty = dirty,
        });
    }

    return .{
        .allocator = allocator,
        .records = try records.toOwnedSlice(allocator),
    };
}

pub fn validateMigrationStatus(conn: *Conn, migrations: []const core.migrate.MigrationFile) !void {
    var status = try migrationStatus(conn.allocator, conn);
    defer status.deinit();

    for (status.records) |record| {
        if (record.dirty) return error.DirtyMigration;

        const migration = findMigration(migrations, record.version) orelse continue;
        if (!std.mem.eql(u8, &record.checksum, &migration.checksum)) {
            return error.MigrationChecksumMismatch;
        }
    }
}

pub fn applyMigrations(conn: *Conn, migrations: []const core.migrate.MigrationFile) !ApplyResult {
    try ensureMigrationTable(conn);
    try validateMigrationStatus(conn, migrations);

    var status = try migrationStatus(conn.allocator, conn);
    defer status.deinit();

    var tx = try conn.beginImmediate();
    defer tx.rollbackIfOpen();

    var applied: usize = 0;
    for (migrations) |migration| {
        if (findMigrationRecord(status.records, migration.id.version) != null) continue;
        if (std.mem.trim(u8, migration.sql, " \t\r\n").len == 0) return error.InvalidSql;

        _ = try tx.exec(
            \\insert into zsql_migrations (version, name, checksum, dirty)
            \\values (?, ?, ?, ?)
        , &.{
            .{ .integer = try sqliteVersion(migration.id.version) },
            .{ .text = migration.id.name },
            .{ .text = &migration.checksum },
            .{ .integer = 1 },
        });
        try tx.execScript(migration.sql);
        _ = try tx.exec(
            \\update zsql_migrations
            \\set dirty = 0
            \\where version = ?
        , &.{.{ .integer = try sqliteVersion(migration.id.version) }});
        applied += 1;
    }

    try tx.commit();
    return .{ .applied = applied };
}

pub const Tx = struct {
    conn: *Conn,
    open: bool = true,
    next_savepoint_id: usize = 0,

    pub fn commit(self: *Tx) !void {
        if (!self.open) return error.TransactionClosed;
        _ = try self.conn.exec("commit", &.{});
        self.open = false;
    }

    pub fn rollback(self: *Tx) !void {
        if (!self.open) return error.TransactionClosed;
        _ = try self.conn.exec("rollback", &.{});
        self.open = false;
    }

    pub fn rollbackIfOpen(self: *Tx) void {
        if (!self.open) return;
        _ = self.conn.exec("rollback", &.{}) catch {};
        self.open = false;
    }

    pub fn exec(self: *Tx, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        if (!self.open) return error.TransactionClosed;
        return self.conn.exec(sql, binds);
    }

    pub fn execScript(self: *Tx, sql: []const u8) !void {
        if (!self.open) return error.TransactionClosed;
        return self.conn.execScript(sql);
    }

    pub fn query(self: *Tx, sql: []const u8, binds: []const core.Value) !Rows {
        if (!self.open) return error.TransactionClosed;
        return self.conn.query(sql, binds);
    }

    pub fn savepoint(self: *Tx) !Savepoint {
        if (!self.open) return error.TransactionClosed;
        const id = self.next_savepoint_id;
        self.next_savepoint_id += 1;

        var name_buffer: [64]u8 = undefined;
        const name = try std.fmt.bufPrint(&name_buffer, "zsql_sp_{d}", .{id});
        try self.execSavepointSql("savepoint", name);

        var stored_name: [64]u8 = undefined;
        @memcpy(stored_name[0..name.len], name);
        return .{
            .tx = self,
            .name = stored_name,
            .name_len = name.len,
        };
    }

    fn execSavepointSql(self: *Tx, comptime verb: []const u8, name: []const u8) !void {
        var sql_buffer: [96]u8 = undefined;
        const sql = try std.fmt.bufPrint(&sql_buffer, verb ++ " {s}", .{name});
        _ = try self.conn.exec(sql, &.{});
    }
};

pub const Savepoint = struct {
    tx: *Tx,
    name: [64]u8,
    name_len: usize,
    open: bool = true,

    pub fn release(self: *Savepoint) !void {
        if (!self.open) return error.SavepointClosed;
        if (!self.tx.open) return error.TransactionClosed;
        try self.tx.execSavepointSql("release savepoint", self.nameSlice());
        self.open = false;
    }

    pub fn rollback(self: *Savepoint) !void {
        if (!self.open) return error.SavepointClosed;
        if (!self.tx.open) return error.TransactionClosed;
        try self.tx.execSavepointSql("rollback to savepoint", self.nameSlice());
        try self.tx.execSavepointSql("release savepoint", self.nameSlice());
        self.open = false;
    }

    pub fn rollbackIfOpen(self: *Savepoint) void {
        if (!self.open or !self.tx.open) return;
        self.rollback() catch {};
    }

    fn nameSlice(self: *Savepoint) []const u8 {
        return self.name[0..self.name_len];
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

    pub fn exec(self: *Stmt, binds: []const core.Value) !core.ExecResult {
        if (self.closed) return error.StatementClosed;
        try self.bindValues(binds);
        return self.stepExec();
    }

    pub fn execNamed(self: *Stmt, binds: []const NamedValue) !core.ExecResult {
        if (self.closed) return error.StatementClosed;
        try self.bindNamedValues(binds);
        return self.stepExec();
    }

    fn stepExec(self: *Stmt) !core.ExecResult {
        const rc = c.sqlite3_step(self.handle);
        switch (rc) {
            c.SQLITE_DONE => {
                const result = execResult(c.sqlite3_db_handle(self.handle));
                const reset_rc = c.sqlite3_reset(self.handle);
                if (reset_rc != c.SQLITE_OK) return error.DriverError;
                return result;
            },
            c.SQLITE_ROW => {
                _ = c.sqlite3_reset(self.handle);
                return error.UnexpectedRow;
            },
            else => {
                _ = c.sqlite3_reset(self.handle);
                return error.DriverError;
            },
        }
    }

    pub fn query(self: Stmt, binds: []const core.Value) !Rows {
        return Rows.init(self, binds);
    }

    pub fn queryNamed(self: Stmt, binds: []const NamedValue) !Rows {
        return Rows.initNamed(self, binds);
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

    pub fn bindNamedValues(self: *Stmt, binds: []const NamedValue) !void {
        if (self.closed) return error.StatementClosed;
        try self.validateNamedBindCount(binds);
        self.freeBindBuffers();
        _ = c.sqlite3_clear_bindings(self.handle);
        _ = c.sqlite3_reset(self.handle);

        for (binds) |bind| {
            try self.bindValue(try self.namedBindIndex(bind.name), bind.value);
        }
    }

    fn validateBindCount(self: Stmt, binds: []const core.Value) !void {
        if (binds.len != @as(usize, @intCast(c.sqlite3_bind_parameter_count(self.handle)))) {
            return error.InvalidBindValue;
        }
    }

    fn validateNamedBindCount(self: Stmt, binds: []const NamedValue) !void {
        const count = try sqliteParameterCount(self.handle);
        if (binds.len != count) return error.InvalidBindValue;

        for (binds, 0..) |bind, index| {
            _ = try self.namedBindIndex(bind.name);
            for (binds[0..index]) |previous| {
                if (sameBindName(bind.name, previous.name)) return error.InvalidBindValue;
            }
        }
    }

    fn namedBindIndex(self: Stmt, name: []const u8) !c_int {
        if (name.len == 0) return error.InvalidBindValue;

        if (isBindMarker(name[0])) return self.lookupNamedBindIndex(name);

        var prefixed_buffer: [256]u8 = undefined;
        if (name.len + 1 > prefixed_buffer.len) return error.InvalidBindValue;
        inline for (.{ ':', '@', '$' }) |marker| {
            prefixed_buffer[0] = marker;
            @memcpy(prefixed_buffer[1 .. name.len + 1], name);
            if (self.lookupNamedBindIndex(prefixed_buffer[0 .. name.len + 1])) |index| {
                return index;
            } else |_| {}
        }

        return error.InvalidBindValue;
    }

    fn lookupNamedBindIndex(self: Stmt, name: []const u8) !c_int {
        const lookup_z = self.allocator.dupeZ(u8, name) catch return error.InvalidBindValue;
        defer self.allocator.free(lookup_z);

        const index = c.sqlite3_bind_parameter_index(self.handle, lookup_z.ptr);
        if (index == 0) return error.InvalidBindValue;
        return index;
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

fn execResult(db: ?*c.sqlite3) core.ExecResult {
    const handle = db.?;
    return .{
        .rows_affected = @intCast(c.sqlite3_changes64(handle)),
        .last_insert_id = c.sqlite3_last_insert_rowid(handle),
    };
}

fn execScriptSql(allocator: std.mem.Allocator, db: *c.sqlite3, sql: []const u8) !void {
    if (std.mem.trim(u8, sql, " \t\r\n").len == 0) return error.InvalidSql;

    const sql_z = try allocator.dupeZ(u8, sql);
    defer allocator.free(sql_z);

    var message: [*c]u8 = null;
    const rc = c.sqlite3_exec(db, sql_z.ptr, null, null, &message);
    if (message != null) c.sqlite3_free(message);
    switch (rc) {
        c.SQLITE_OK => {},
        c.SQLITE_ERROR => return error.InvalidSql,
        else => return error.DriverError,
    }
}

pub const Rows = struct {
    stmt: Stmt,
    columns: []const []const u8,
    values: []core.Value,
    done: bool = false,

    pub fn init(stmt: Stmt, binds: []const core.Value) !Rows {
        var owned_stmt = stmt;
        errdefer owned_stmt.close();

        try owned_stmt.bindValues(binds);
        return initBound(owned_stmt);
    }

    pub fn initNamed(stmt: Stmt, binds: []const NamedValue) !Rows {
        var owned_stmt = stmt;
        errdefer owned_stmt.close();

        try owned_stmt.bindNamedValues(binds);
        return initBound(owned_stmt);
    }

    fn initBound(owned_stmt: Stmt) !Rows {
        var stmt = owned_stmt;

        const column_count = try sqliteColumnCount(stmt.handle);
        const columns = try stmt.allocator.alloc([]const u8, column_count);
        errdefer stmt.allocator.free(columns);
        const values = try stmt.allocator.alloc(core.Value, column_count);
        errdefer stmt.allocator.free(values);

        for (columns, 0..) |*column, index| {
            const name = c.sqlite3_column_name(stmt.handle, try sqliteIndex(index));
            if (name == null) return error.DriverError;
            column.* = std.mem.span(name);
        }

        return .{
            .stmt = stmt,
            .columns = columns,
            .values = values,
        };
    }

    pub fn deinit(self: *Rows) void {
        self.stmt.allocator.free(self.values);
        self.stmt.allocator.free(self.columns);
        self.stmt.close();
        self.done = true;
    }

    pub fn next(self: *Rows) !?core.Row {
        if (self.done) return null;

        const rc = c.sqlite3_step(self.stmt.handle);
        switch (rc) {
            c.SQLITE_ROW => {
                for (self.values, 0..) |*value, index| {
                    value.* = try self.decodeColumn(try sqliteIndex(index));
                }
                return try core.Row.init(self.columns, self.values);
            },
            c.SQLITE_DONE => {
                self.done = true;
                return null;
            },
            else => return error.DriverError,
        }
    }

    fn decodeColumn(self: *Rows, index: c_int) !core.Value {
        return switch (c.sqlite3_column_type(self.stmt.handle, index)) {
            c.SQLITE_NULL => .{ .null = {} },
            c.SQLITE_INTEGER => .{ .integer = c.sqlite3_column_int64(self.stmt.handle, index) },
            c.SQLITE_FLOAT => .{ .real = c.sqlite3_column_double(self.stmt.handle, index) },
            c.SQLITE_TEXT => .{ .text = try columnText(self.stmt.handle, index) },
            c.SQLITE_BLOB => .{ .blob = try columnBlob(self.stmt.handle, index) },
            else => error.InvalidColumnType,
        };
    }
};

fn sqliteIndex(index: usize) !c_int {
    return std.math.cast(c_int, index) orelse error.InvalidBindValue;
}

fn sqliteLen(len: usize) !c_int {
    return std.math.cast(c_int, len) orelse error.InvalidBindValue;
}

fn sqliteParameterCount(stmt: *c.sqlite3_stmt) !usize {
    return std.math.cast(usize, c.sqlite3_bind_parameter_count(stmt)) orelse error.InvalidBindValue;
}

fn isBindMarker(c_: u8) bool {
    return c_ == ':' or c_ == '@' or c_ == '$';
}

fn sameBindName(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, stripBindMarker(a), stripBindMarker(b));
}

fn stripBindMarker(name: []const u8) []const u8 {
    if (name.len > 0 and isBindMarker(name[0])) return name[1..];
    return name;
}

fn sqliteColumnCount(stmt: *c.sqlite3_stmt) !usize {
    return std.math.cast(usize, c.sqlite3_column_count(stmt)) orelse error.DriverError;
}

fn columnText(stmt: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    const len = try sqliteColumnBytes(stmt, index);
    const ptr = c.sqlite3_column_text(stmt, index);
    if (ptr == null) {
        if (len == 0) return "";
        return error.DriverError;
    }
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn columnBlob(stmt: *c.sqlite3_stmt, index: c_int) ![]const u8 {
    const len = try sqliteColumnBytes(stmt, index);
    const ptr = c.sqlite3_column_blob(stmt, index);
    if (ptr == null) {
        if (len == 0) return "";
        return error.DriverError;
    }
    return @as([*]const u8, @ptrCast(ptr))[0..len];
}

fn sqliteColumnBytes(stmt: *c.sqlite3_stmt, index: c_int) !usize {
    return std.math.cast(usize, c.sqlite3_column_bytes(stmt, index)) orelse error.DriverError;
}

fn unsignedVersion(value: i64) !u64 {
    return std.math.cast(u64, value) orelse error.InvalidColumnType;
}

fn sqliteVersion(version: u64) !i64 {
    return std.math.cast(i64, version) orelse error.InvalidBindValue;
}

fn sqliteBool(value: i64) !bool {
    return switch (value) {
        0 => false,
        1 => true,
        else => error.InvalidColumnType,
    };
}

fn parseChecksum(value: []const u8) !core.migrate.Checksum {
    if (value.len != 64) return error.InvalidColumnType;
    for (value) |c_| {
        if (!std.ascii.isHex(c_)) return error.InvalidColumnType;
    }

    var checksum: core.migrate.Checksum = undefined;
    @memcpy(&checksum, value);
    return checksum;
}

fn findMigration(migrations: []const core.migrate.MigrationFile, version: u64) ?core.migrate.MigrationFile {
    for (migrations) |migration| {
        if (migration.id.version == version) return migration;
    }
    return null;
}

fn findMigrationRecord(records: []const MigrationRecord, version: u64) ?MigrationRecord {
    for (records) |record| {
        if (record.version == version) return record;
    }
    return null;
}

test "SQLite opens memory database and rejects row-returning exec" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try std.testing.expectError(error.UnexpectedRow, conn.exec("select ?", &.{.{ .integer = 1 }}));
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
    try std.testing.expectError(error.UnexpectedRow, stmt.exec(&.{
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

    try std.testing.expectError(error.UnexpectedRow, stmt.exec(&.{
        .{ .null = {} },
        .{ .integer = 42 },
        .{ .real = 3.5 },
        .{ .text = "zig" },
        .{ .blob = "sql" },
        .{ .boolean = false },
    }));
}

test "SQLite exec steps statements that do not return rows" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const create_result = try conn.exec("create table users (id integer not null, name text not null, active integer not null)", &.{});
    try std.testing.expectEqual(@as(u64, 0), create_result.rows_affected);

    const insert_result = try conn.exec("insert into users (id, name, active) values (?, ?, ?)", &.{
        .{ .integer = 1 },
        .{ .text = "ada" },
        .{ .boolean = true },
    });

    try std.testing.expectEqual(@as(u64, 1), insert_result.rows_affected);
    try std.testing.expectEqual(@as(?i64, 1), insert_result.last_insert_id);
    try std.testing.expectEqual(@as(c_int, 1), c.sqlite3_changes(db.handle));
    try std.testing.expectError(error.UnexpectedRow, conn.exec("select id from users", &.{}));
}

test "SQLite query decodes borrowed row values" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table items (id integer, score real, name text, payload blob, missing text)", &.{});
    _ = try conn.exec("insert into items (id, score, name, payload, missing) values (?, ?, ?, ?, ?)", &.{
        .{ .integer = 7 },
        .{ .real = 2.5 },
        .{ .text = "ada" },
        .{ .blob = "zig" },
        .{ .null = {} },
    });

    var rows = try conn.query("select id, score, name, payload, missing from items where id = ?", &.{
        .{ .integer = 7 },
    });
    defer rows.deinit();

    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 7), try (try row.value("id")).asInt());
    try std.testing.expectEqual(@as(f64, 2.5), try (try row.value("score")).asFloat());
    try std.testing.expectEqualStrings("ada", try (try row.value("name")).asText());
    try std.testing.expectEqualStrings("zig", try (try row.value("payload")).asBlob());
    try std.testing.expect((try row.value("missing")).isNull());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite query row maps to scalar struct" {
    const Item = struct {
        id: i64,
        name: []const u8,
        score: f64,
        missing: ?[]const u8,
    };

    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table mapped_items (id integer, name text, score real, missing text)", &.{});
    _ = try conn.exec("insert into mapped_items (id, name, score, missing) values (?, ?, ?, ?)", &.{
        .{ .integer = 11 },
        .{ .text = "bolt" },
        .{ .real = 8.25 },
        .{ .null = {} },
    });

    var rows = try conn.query("select id, name, score, missing from mapped_items", &.{});
    defer rows.deinit();

    const item = try (try rows.next()).?.to(Item);
    try std.testing.expectEqual(@as(i64, 11), item.id);
    try std.testing.expectEqualStrings("bolt", item.name);
    try std.testing.expectEqual(@as(f64, 8.25), item.score);
    try std.testing.expectEqual(@as(?[]const u8, null), item.missing);
}

test "SQLite query can be prepared statement owned by rows" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table nums (n integer)", &.{});
    _ = try conn.exec("insert into nums (n) values (1)", &.{});
    _ = try conn.exec("insert into nums (n) values (2)", &.{});

    const stmt = try conn.prepare("select n from nums order by n");
    var rows = try stmt.query(&.{});
    defer rows.deinit();

    const first = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try first.value("n")).asInt());
    const second = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 2), try (try second.value("n")).asInt());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite borrowed row can be copied into owned row" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table docs (title text, body blob)", &.{});
    _ = try conn.exec("insert into docs (title, body) values (?, ?)", &.{
        .{ .text = "note" },
        .{ .blob = "payload" },
    });

    var rows = try conn.query("select title, body from docs", &.{});
    const row = (try rows.next()).?;
    var owned = try core.OwnedRow.init(std.testing.allocator, row);
    rows.deinit();
    defer owned.deinit();

    try std.testing.expectEqualStrings("note", try (try owned.value("title")).asText());
    try std.testing.expectEqualStrings("payload", try (try owned.value("body")).asBlob());
}

test "SQLite supports named exec and query binds" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table people (id integer, name text, active integer)", &.{});
    const result = try conn.execNamed(
        "insert into people (id, name, active) values (:id, @name, $active)",
        &.{
            .{ .name = "id", .value = .{ .integer = 9 } },
            .{ .name = "name", .value = .{ .text = "ada" } },
            .{ .name = "active", .value = .{ .boolean = true } },
        },
    );
    try std.testing.expectEqual(@as(u64, 1), result.rows_affected);

    var rows = try conn.queryNamed(
        "select name, active from people where id = :id",
        &.{.{ .name = ":id", .value = .{ .integer = 9 } }},
    );
    defer rows.deinit();

    const row = (try rows.next()).?;
    try std.testing.expectEqualStrings("ada", try (try row.value("name")).asText());
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("active")).asInt());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite named binds reject missing unknown and duplicate names" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    var stmt = try conn.prepare("select :id, :name");
    defer stmt.close();

    try std.testing.expectError(error.InvalidBindValue, stmt.bindNamedValues(&.{
        .{ .name = "id", .value = .{ .integer = 1 } },
    }));
    try std.testing.expectError(error.InvalidBindValue, stmt.bindNamedValues(&.{
        .{ .name = "id", .value = .{ .integer = 1 } },
        .{ .name = "missing", .value = .{ .text = "ada" } },
    }));
    try std.testing.expectError(error.InvalidBindValue, stmt.bindNamedValues(&.{
        .{ .name = "id", .value = .{ .integer = 1 } },
        .{ .name = ":id", .value = .{ .integer = 2 } },
    }));
}

test "SQLite transaction commit persists changes" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table tx_commit (id integer)", &.{});
    var tx = try conn.begin();
    try std.testing.expect(tx.open);
    _ = try tx.exec("insert into tx_commit (id) values (?)", &.{.{ .integer = 1 }});
    try tx.commit();
    try std.testing.expect(!tx.open);
    try std.testing.expectError(error.TransactionClosed, tx.commit());

    var rows = try conn.query("select id from tx_commit", &.{});
    defer rows.deinit();

    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite transaction rollback discards changes" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table tx_rollback (id integer)", &.{});
    var tx = try conn.begin();
    _ = try tx.exec("insert into tx_rollback (id) values (?)", &.{.{ .integer = 1 }});
    try tx.rollback();
    try std.testing.expectError(error.TransactionClosed, tx.rollback());

    var rows = try conn.query("select id from tx_rollback", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite rollbackIfOpen rolls back once" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table tx_auto_rollback (id integer)", &.{});
    var tx = try conn.begin();
    defer tx.rollbackIfOpen();
    _ = try tx.exec("insert into tx_auto_rollback (id) values (?)", &.{.{ .integer = 1 }});

    tx.rollbackIfOpen();
    try std.testing.expect(!tx.open);

    var rows = try conn.query("select id from tx_auto_rollback", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite savepoint release keeps inner changes" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table sp_release (id integer)", &.{});
    var tx = try conn.begin();
    defer tx.rollbackIfOpen();

    var sp = try tx.savepoint();
    _ = try tx.exec("insert into sp_release (id) values (?)", &.{.{ .integer = 1 }});
    try sp.release();
    try std.testing.expect(!sp.open);
    try std.testing.expectError(error.SavepointClosed, sp.release());
    try tx.commit();

    var rows = try conn.query("select id from sp_release", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
}

test "SQLite savepoint rollback discards inner changes only" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table sp_rollback (id integer)", &.{});
    var tx = try conn.begin();
    defer tx.rollbackIfOpen();

    _ = try tx.exec("insert into sp_rollback (id) values (?)", &.{.{ .integer = 1 }});
    var sp = try tx.savepoint();
    _ = try tx.exec("insert into sp_rollback (id) values (?)", &.{.{ .integer = 2 }});
    try sp.rollback();
    try std.testing.expectError(error.SavepointClosed, sp.rollback());
    try tx.commit();

    var rows = try conn.query("select id from sp_rollback order by id", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite savepoint rollbackIfOpen rolls back once" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table sp_auto_rollback (id integer)", &.{});
    var tx = try conn.begin();
    defer tx.rollbackIfOpen();

    var sp = try tx.savepoint();
    defer sp.rollbackIfOpen();
    _ = try tx.exec("insert into sp_auto_rollback (id) values (?)", &.{.{ .integer = 1 }});
    sp.rollbackIfOpen();
    try std.testing.expect(!sp.open);
    try tx.commit();

    var rows = try conn.query("select id from sp_auto_rollback", &.{});
    defer rows.deinit();
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());
}

test "SQLite pool releases and reuses leases" {
    var pool = try Pool.init(std.testing.allocator, .{ .max_open = 1 });
    defer pool.deinit();

    var first = try pool.acquire();
    var first_conn = try first.conn();
    _ = try first_conn.exec("create table pooled_reuse (id integer)", &.{});
    _ = try first_conn.exec("insert into pooled_reuse (id) values (?)", &.{.{ .integer = 1 }});
    try first.release();
    try std.testing.expect(!first.open);
    try std.testing.expectEqual(@as(usize, 1), pool.open_count);
    try std.testing.expectEqual(@as(usize, 1), pool.idle.items.len);

    var second = try pool.acquire();
    defer second.release() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), pool.open_count);
    try std.testing.expectEqual(@as(usize, 0), pool.idle.items.len);

    var rows = try (try second.conn()).query("select id from pooled_reuse", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
}

test "SQLite pool enforces max open leases" {
    var pool = try Pool.init(std.testing.allocator, .{ .max_open = 1 });
    defer pool.deinit();

    var lease = try pool.acquire();
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    try lease.release();
}

test "SQLite pool discard closes lease and allows replacement" {
    var pool = try Pool.init(std.testing.allocator, .{ .max_open = 1 });
    defer pool.deinit();

    var first = try pool.acquire();
    _ = try (try first.conn()).exec("create table discarded (id integer)", &.{});
    try first.discard();
    try std.testing.expect(!first.open);
    try std.testing.expectEqual(@as(usize, 0), pool.open_count);

    var second = try pool.acquire();
    defer second.release() catch unreachable;
    try std.testing.expectEqual(@as(usize, 1), pool.open_count);
    try std.testing.expectError(error.InvalidSql, (try second.conn()).query("select id from discarded", &.{}));
}

test "SQLite pool validates closed lifetime" {
    try std.testing.expectError(error.InvalidBindValue, Pool.init(std.testing.allocator, .{ .max_open = 0 }));

    var pool = try Pool.init(std.testing.allocator, .{});
    var lease = try pool.acquire();
    try lease.release();
    try std.testing.expectError(error.LeaseClosed, lease.conn());
    try std.testing.expectError(error.LeaseClosed, lease.release());

    pool.deinit();
    try std.testing.expectError(error.PoolClosed, pool.acquire());
}

test "SQLite migration table starts with empty status" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    var status = try migrationStatus(std.testing.allocator, &conn);
    defer status.deinit();

    try std.testing.expectEqual(@as(usize, 0), status.records.len);
}

test "SQLite migration status returns applied records by version" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const first_checksum = core.migrate.checksumSql("create table users (id integer primary key);\n");
    const second_checksum = core.migrate.checksumSql("alter table users add column name text;\n");
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 2 },
        .{ .text = "add_users" },
        .{ .text = &second_checksum },
        .{ .text = "2026-07-07T10:05:00Z" },
        .{ .integer = 1 },
    });
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "create_users" },
        .{ .text = &first_checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 0 },
    });

    var status = try migrationStatus(std.testing.allocator, &conn);
    defer status.deinit();

    try std.testing.expectEqual(@as(usize, 2), status.records.len);
    try std.testing.expectEqual(@as(u64, 1), status.records[0].version);
    try std.testing.expectEqualStrings("create_users", status.records[0].name);
    try std.testing.expectEqual(first_checksum, status.records[0].checksum);
    try std.testing.expectEqualStrings("2026-07-07T10:00:00Z", status.records[0].applied_at);
    try std.testing.expect(!status.records[0].dirty);

    try std.testing.expectEqual(@as(u64, 2), status.records[1].version);
    try std.testing.expectEqualStrings("add_users", status.records[1].name);
    try std.testing.expectEqual(second_checksum, status.records[1].checksum);
    try std.testing.expect(status.records[1].dirty);
}

test "SQLite migration status rejects invalid checksum metadata" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "bad_checksum" },
        .{ .text = "not-a-checksum" },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 0 },
    });

    try std.testing.expectError(error.InvalidColumnType, migrationStatus(std.testing.allocator, &conn));
}

test "SQLite migration validation accepts matching clean records" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const sql = "create table users (id integer primary key);\n";
    const checksum = core.migrate.checksumSql(sql);
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "create_users" },
        .{ .text = &checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 0 },
    });

    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "create_users",
            .filename = "V0001__create_users.sql",
        },
        .checksum = checksum,
    }};

    try validateMigrationStatus(&conn, &migrations);
}

test "SQLite migration validation rejects checksum mismatches" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const stored_checksum = core.migrate.checksumSql("create table users (id integer primary key);\n");
    const local_checksum = core.migrate.checksumSql("create table users (id integer primary key, name text);\n");
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "create_users" },
        .{ .text = &stored_checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 0 },
    });

    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "create_users",
            .filename = "V0001__create_users.sql",
        },
        .checksum = local_checksum,
    }};

    try std.testing.expectError(error.MigrationChecksumMismatch, validateMigrationStatus(&conn, &migrations));
}

test "SQLite migration validation rejects dirty records" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const checksum = core.migrate.checksumSql("create table users (id integer primary key);\n");
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "create_users" },
        .{ .text = &checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 1 },
    });

    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "create_users",
            .filename = "V0001__create_users.sql",
        },
        .checksum = checksum,
    }};

    try std.testing.expectError(error.DirtyMigration, validateMigrationStatus(&conn, &migrations));
}

test "SQLite migration validation ignores stored versions absent locally" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const checksum = core.migrate.checksumSql("create table users (id integer primary key);\n");
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "create_users" },
        .{ .text = &checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 0 },
    });

    try validateMigrationStatus(&conn, &.{});
}

test "SQLite migration apply runs pending migrations and records clean status" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const create_sql = "create table applied_users (id integer primary key);\n";
    const insert_sql = "insert into applied_users (id) values (1);\n";
    const migrations = [_]core.migrate.MigrationFile{
        .{
            .id = .{
                .version = 1,
                .name = "create_users",
                .filename = "V0001__create_users.sql",
            },
            .sql = create_sql,
            .checksum = core.migrate.checksumSql(create_sql),
        },
        .{
            .id = .{
                .version = 2,
                .name = "seed_users",
                .filename = "V0002__seed_users.sql",
            },
            .sql = insert_sql,
            .checksum = core.migrate.checksumSql(insert_sql),
        },
    };

    const result = try applyMigrations(&conn, &migrations);
    try std.testing.expectEqual(@as(usize, 2), result.applied);

    var rows = try conn.query("select id from applied_users", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());

    var status = try migrationStatus(std.testing.allocator, &conn);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 2), status.records.len);
    try std.testing.expectEqual(@as(u64, 1), status.records[0].version);
    try std.testing.expect(!status.records[0].dirty);
    try std.testing.expectEqual(@as(u64, 2), status.records[1].version);
    try std.testing.expect(!status.records[1].dirty);
}

test "SQLite migration apply executes multi-statement scripts" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const script =
        \\create table multi_statement_users (id integer primary key, name text);
        \\insert into multi_statement_users (id, name) values (1, 'ada');
        \\update multi_statement_users set name = 'grace' where id = 1;
    ;
    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "create_and_seed_users",
            .filename = "V0001__create_and_seed_users.sql",
        },
        .sql = script,
        .checksum = core.migrate.checksumSql(script),
    }};

    try std.testing.expectEqual(@as(usize, 1), (try applyMigrations(&conn, &migrations)).applied);

    var rows = try conn.query("select name from multi_statement_users where id = ?", &.{.{ .integer = 1 }});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqualStrings("grace", try (try row.value("name")).asText());
}

test "SQLite migration apply works from scanned directory" {
    var tmp = std.testing.tmpDir(.{ .iterate = true });
    defer tmp.cleanup();

    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "V0002__seed_scan_users.sql",
        .data =
        \\insert into scan_users (id, name) values (1, 'ada');
        \\insert into scan_users (id, name) values (2, 'grace');
        ,
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "notes.txt",
        .data = "ignored by migration scanner\n",
    });
    try tmp.dir.writeFile(std.testing.io, .{
        .sub_path = "V0001__create_scan_users.sql",
        .data =
        \\create table scan_users (
        \\  id integer primary key,
        \\  name text not null
        \\);
        ,
    });

    var migrations = try core.migrate.scanDir(std.testing.allocator, std.testing.io, tmp.dir);
    defer migrations.deinit();

    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try std.testing.expectEqual(@as(usize, 2), migrations.files.len);
    try std.testing.expectEqual(@as(u64, 1), migrations.files[0].id.version);
    try std.testing.expectEqual(@as(u64, 2), migrations.files[1].id.version);
    try std.testing.expectEqual(@as(usize, 2), (try applyMigrations(&conn, migrations.files)).applied);

    var rows = try conn.query("select name from scan_users order by id", &.{});
    defer rows.deinit();

    const first = (try rows.next()).?;
    try std.testing.expectEqualStrings("ada", try (try first.value("name")).asText());
    const second = (try rows.next()).?;
    try std.testing.expectEqualStrings("grace", try (try second.value("name")).asText());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());

    var status = try migrationStatus(std.testing.allocator, &conn);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 2), status.records.len);
    try std.testing.expectEqualStrings("create_scan_users", status.records[0].name);
    try std.testing.expectEqual(migrations.files[0].checksum, status.records[0].checksum);
    try std.testing.expect(!status.records[0].dirty);
    try std.testing.expectEqualStrings("seed_scan_users", status.records[1].name);
    try std.testing.expectEqual(migrations.files[1].checksum, status.records[1].checksum);
    try std.testing.expect(!status.records[1].dirty);
}

test "SQLite migrator wrapper applies and reports status" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const sql = "create table migrator_users (id integer primary key);\n";
    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "create_users",
            .filename = "V0001__create_users.sql",
        },
        .sql = sql,
        .checksum = core.migrate.checksumSql(sql),
    }};

    const migrator = Migrator.init(&conn);
    try migrator.ensureTable();
    try migrator.validate(&migrations);
    try std.testing.expectEqual(@as(usize, 1), (try migrator.apply(&migrations)).applied);

    var status = try migrator.status(std.testing.allocator);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 1), status.records.len);
    try std.testing.expectEqual(@as(u64, 1), status.records[0].version);
    try std.testing.expect(!status.records[0].dirty);
}

test "SQLite migration apply skips already applied migrations" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const create_sql = "create table skip_users (id integer primary key);\n";
    const insert_sql = "insert into skip_users (id) values (1);\n";
    const migrations = [_]core.migrate.MigrationFile{
        .{
            .id = .{
                .version = 1,
                .name = "create_users",
                .filename = "V0001__create_users.sql",
            },
            .sql = create_sql,
            .checksum = core.migrate.checksumSql(create_sql),
        },
        .{
            .id = .{
                .version = 2,
                .name = "seed_users",
                .filename = "V0002__seed_users.sql",
            },
            .sql = insert_sql,
            .checksum = core.migrate.checksumSql(insert_sql),
        },
    };

    try std.testing.expectEqual(@as(usize, 2), (try applyMigrations(&conn, &migrations)).applied);
    try std.testing.expectEqual(@as(usize, 0), (try applyMigrations(&conn, &migrations)).applied);
}

test "SQLite migration apply rolls back dirty marker on failure" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    const bad_sql = "create table broken (";
    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 1,
            .name = "broken",
            .filename = "V0001__broken.sql",
        },
        .sql = bad_sql,
        .checksum = core.migrate.checksumSql(bad_sql),
    }};

    try std.testing.expectError(error.InvalidSql, applyMigrations(&conn, &migrations));

    var status = try migrationStatus(std.testing.allocator, &conn);
    defer status.deinit();
    try std.testing.expectEqual(@as(usize, 0), status.records.len);
}

test "SQLite migration apply refuses existing dirty migration state" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();

    var conn = try db.connect();
    defer conn.close();

    try ensureMigrationTable(&conn);
    const dirty_sql = "create table dirty_prior (id integer primary key);\n";
    const dirty_checksum = core.migrate.checksumSql(dirty_sql);
    _ = try conn.exec(
        \\insert into zsql_migrations (version, name, checksum, applied_at, dirty)
        \\values (?, ?, ?, ?, ?)
    , &.{
        .{ .integer = 1 },
        .{ .text = "dirty_prior" },
        .{ .text = &dirty_checksum },
        .{ .text = "2026-07-07T10:00:00Z" },
        .{ .integer = 1 },
    });

    const pending_sql = "create table should_not_apply (id integer primary key);\n";
    const migrations = [_]core.migrate.MigrationFile{.{
        .id = .{
            .version = 2,
            .name = "should_not_apply",
            .filename = "V0002__should_not_apply.sql",
        },
        .sql = pending_sql,
        .checksum = core.migrate.checksumSql(pending_sql),
    }};

    try std.testing.expectError(error.DirtyMigration, applyMigrations(&conn, &migrations));
    try std.testing.expectError(error.InvalidSql, conn.query("select id from should_not_apply", &.{}));
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
