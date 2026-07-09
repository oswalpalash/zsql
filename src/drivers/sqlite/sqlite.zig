const std = @import("std");
const core = @import("../../zsql.zig");
const c = @import("c.zig");

pub const enabled = true;

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

    /// Alias for `apply` matching the public API target (`Migrator.up`).
    pub fn up(self: Migrator, migrations: []const core.migrate.MigrationFile) !ApplyResult {
        return self.apply(migrations);
    }
};

pub const PoolConfig = struct {
    database: Config = .{},
    max_open: usize = 4,
    max_idle: usize = 4,
    /// Nanoseconds to wait when the pool is exhausted before returning
    /// `error.PoolTimeout`. Zero means non-blocking exhaustion failure via
    /// `error.PoolExhausted`.
    ///
    /// Multi-threaded: waiters sleep in short slices (≤1ms) and recheck, so a
    /// concurrent `release` unblocks them within about one poll interval.
    acquire_timeout_ns: u64 = 0,
    /// When non-zero, each newly opened connection enables a prepared-statement
    /// handle cache of this size. Zero leaves caching off (default).
    stmt_cache_size: usize = 0,
};

pub const PoolStats = struct {
    open: usize,
    idle: usize,
    leased: usize,
    max_open: usize,
    max_idle: usize,
    acquire_timeout_ns: u64,
};

/// Thread-safe SQLite connection pool.
///
/// State is protected by an `std.Io.Mutex`. Timed acquire uses deadline polling
/// (≤1ms) so waiters wake promptly after a concurrent release without requiring
/// a dedicated condition-variable timeout API.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: std.Io,
    config: PoolConfig,
    idle: std.ArrayListUnmanaged(Database) = .empty,
    open_count: usize = 0,
    closed: bool = false,
    mutex: std.Io.Mutex = .init,

    pub fn init(allocator: std.mem.Allocator, io: std.Io, config: PoolConfig) !Pool {
        if (config.max_open == 0) return error.InvalidBindValue;
        return .{
            .allocator = allocator,
            .io = io,
            .config = config,
        };
    }

    pub fn deinit(self: *Pool) void {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        if (self.closed) return;
        std.debug.assert(self.open_count == self.idle.items.len);

        for (self.idle.items) |*db| {
            db.deinit();
        }
        self.idle.deinit(self.allocator);
        self.open_count = 0;
        self.closed = true;
    }

    /// Acquire a lease using `PoolConfig.acquire_timeout_ns`.
    pub fn acquire(self: *Pool) !Lease {
        return self.acquireWithTimeout(self.config.acquire_timeout_ns);
    }

    /// Acquire a lease with an explicit timeout override.
    ///
    /// - `timeout_ns == 0`: fail immediately with `PoolExhausted` when full.
    /// - `timeout_ns > 0`: wait up to that many nanoseconds for a release or
    ///   for capacity to open a new connection; then `PoolTimeout`.
    pub fn acquireWithTimeout(self: *Pool, timeout_ns: u64) !Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const deadline: ?std.Io.Clock.Timestamp = if (timeout_ns == 0)
            null
        else
            std.Io.Clock.Timestamp.fromNow(self.io, .{ .raw = .{ .nanoseconds = @intCast(timeout_ns) }, .clock = .awake });

        while (true) {
            if (self.closed) return error.PoolClosed;

            if (self.idle.pop()) |idle_db| {
                var db = idle_db;
                errdefer {
                    // Return the handle to idle on connect failure after unlock
                    // is unsafe here; close it and drop open_count instead.
                    db.deinit();
                    self.open_count -|= 1;
                }
                const conn = try db.connect();
                return .{
                    .pool = self,
                    .db = db,
                    .conn_value = conn,
                };
            }

            if (self.open_count < self.config.max_open) {
                var opened = try Database.open(self.allocator, self.config.database);
                self.open_count += 1;
                errdefer {
                    opened.deinit();
                    self.open_count -|= 1;
                }
                var conn = try opened.connect();
                if (self.config.stmt_cache_size > 0) {
                    try conn.enableStmtCache(self.config.stmt_cache_size);
                }
                return .{
                    .pool = self,
                    .db = opened,
                    .conn_value = conn,
                };
            }

            // Pool is full: wait or fail.
            if (deadline) |dl| {
                const remaining = dl.durationFromNow(self.io);
                if (remaining.raw.nanoseconds <= 0) return error.PoolTimeout;
                const slice_ns: i96 = @min(remaining.raw.nanoseconds, @as(i96, std.time.ns_per_ms));
                self.mutex.unlock(self.io);
                // Best-effort sleep; cancellation maps to recheck + timeout.
                self.io.sleep(.{ .nanoseconds = slice_ns }, .awake) catch {};
                self.mutex.lockUncancelable(self.io);
            } else {
                return error.PoolExhausted;
            }
        }
    }

    /// Execute a statement under a short-lived lease that is released on success
    /// or discarded on failure.
    pub fn exec(self: *Pool, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        var lease = try self.acquire();
        errdefer lease.discard() catch {};
        const result = try (try lease.conn()).exec(sql, binds);
        try lease.release();
        return result;
    }

    /// Run a query under a lease held until `PooledRows.deinit`.
    ///
    /// Borrowed row values remain valid only while the pooled rows (and thus
    /// the lease) stay open. On query setup failure the lease is discarded.
    pub fn query(self: *Pool, sql: []const u8, binds: []const core.Value) !PooledRows {
        var lease = try self.acquire();
        errdefer lease.discard() catch {};
        const rows = try (try lease.conn()).query(sql, binds);
        return .{
            .lease = lease,
            .rows = rows,
        };
    }

    pub fn stats(self: *Pool) PoolStats {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idle_count = self.idle.items.len;
        return .{
            .open = self.open_count,
            .idle = idle_count,
            .leased = self.open_count - idle_count,
            .max_open = self.config.max_open,
            .max_idle = self.effectiveMaxIdle(),
            .acquire_timeout_ns = self.config.acquire_timeout_ns,
        };
    }

    fn effectiveMaxIdle(self: *const Pool) usize {
        return @min(self.config.max_idle, self.config.max_open);
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

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        if (self.pool.closed) {
            self.conn_value.close();
            self.db.deinit();
            self.pool.open_count -|= 1;
            self.open = false;
            return error.PoolClosed;
        }

        if (self.pool.idle.items.len < self.pool.effectiveMaxIdle()) {
            try self.pool.idle.append(self.pool.allocator, self.db);
            self.conn_value.close();
        } else {
            self.conn_value.close();
            self.db.deinit();
            self.pool.open_count -|= 1;
        }
        self.open = false;
    }

    pub fn discard(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        self.conn_value.close();
        self.db.deinit();
        self.pool.open_count -|= 1;
        self.open = false;
    }
};

/// Rows owned by a pool lease. `deinit` finalizes the statement and releases
/// the lease back to the pool (or discards it if release fails).
pub const PooledRows = struct {
    lease: Lease,
    rows: Rows,
    closed: bool = false,

    pub fn next(self: *PooledRows) !?core.Row {
        if (self.closed) return error.LeaseClosed;
        return self.rows.next();
    }

    pub fn deinit(self: *PooledRows) void {
        if (self.closed) return;
        self.rows.deinit();
        self.lease.release() catch {
            self.lease.discard() catch {};
        };
        self.closed = true;
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
    /// Optional prepared-statement handle cache for this connection.
    prepared_cache: ?PreparedCache = null,

    pub fn close(self: *Conn) void {
        self.disableStmtCache();
        self.closed = true;
    }

    /// Enable a connection-local prepared statement handle cache.
    pub fn enableStmtCache(self: *Conn, max_entries: usize) !void {
        if (self.closed) return error.ConnectionClosed;
        self.disableStmtCache();
        self.prepared_cache = try PreparedCache.init(self.allocator, max_entries);
    }

    pub fn disableStmtCache(self: *Conn) void {
        if (self.prepared_cache) |*cache| {
            cache.deinit();
            self.prepared_cache = null;
        }
    }

    pub fn stmtCacheLen(self: *const Conn) usize {
        if (self.prepared_cache) |*cache| return cache.len();
        return 0;
    }

    pub fn prepare(self: *Conn, sql: []const u8) !Stmt {
        if (self.closed) return error.ConnectionClosed;
        return Stmt.init(self.allocator, self.handle, sql);
    }

    /// Prepare with optional cache reuse. Returned `Prepared` owns cleanup policy.
    fn prepareCached(self: *Conn, sql: []const u8) !Prepared {
        if (self.closed) return error.ConnectionClosed;
        if (self.prepared_cache) |*cache| {
            if (try cache.get(self.handle, sql)) |stmt| {
                return .{ .stmt = stmt, .from_cache = true };
            }
            var stmt = try Stmt.init(self.allocator, self.handle, sql);
            cache.put(sql, stmt) catch |err| {
                stmt.close();
                return err;
            };
            // Borrow a non-finalizing view; cache owns finalize.
            return .{ .stmt = cache.borrow(sql).?, .from_cache = true };
        }
        return .{
            .stmt = try Stmt.init(self.allocator, self.handle, sql),
            .from_cache = false,
        };
    }

    pub fn exec(self: *Conn, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        var prepared = try self.prepareCached(sql);
        defer prepared.release();
        return prepared.stmt.exec(binds);
    }

    pub fn execScript(self: *Conn, sql: []const u8) !void {
        if (self.closed) return error.ConnectionClosed;
        try execScriptSql(self.allocator, self.handle, sql);
    }

    pub fn query(self: *Conn, sql: []const u8, binds: []const core.Value) !Rows {
        var prepared = try self.prepareCached(sql);
        errdefer prepared.release();
        return Rows.initOwned(prepared.stmt, binds, !prepared.from_cache);
    }

    /// Query exactly one row into an owned row. Returns `error.NoRows` or
    /// `error.TooManyRows` when the result cardinality is wrong.
    pub fn queryOne(self: *Conn, sql: []const u8, binds: []const core.Value) !core.OwnedRow {
        var rows = try self.query(sql, binds);
        defer rows.deinit();
        const first = (try rows.next()) orelse return error.NoRows;
        var owned = try core.OwnedRow.init(self.allocator, first);
        errdefer owned.deinit();
        if ((try rows.next()) != null) return error.TooManyRows;
        return owned;
    }

    pub fn execNamed(self: *Conn, sql: []const u8, binds: []const NamedValue) !core.ExecResult {
        var prepared = try self.prepareCached(sql);
        defer prepared.release();
        return prepared.stmt.execNamed(binds);
    }

    pub fn queryNamed(self: *Conn, sql: []const u8, binds: []const NamedValue) !Rows {
        var prepared = try self.prepareCached(sql);
        errdefer prepared.release();
        return Rows.initOwnedNamed(prepared.stmt, binds, !prepared.from_cache);
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

    /// Inspect user tables via `sqlite_master` + `PRAGMA table_info`.
    /// Caller owns the returned schema graph; free with `freeInspectedSchema`.
    pub fn inspectSchema(self: *Conn, allocator: std.mem.Allocator) !core.inspect.Schema {
        var tables_list: std.ArrayListUnmanaged(core.inspect.Table) = .empty;
        errdefer freeInspectedTables(allocator, tables_list.items);

        var table_rows = try self.query(
            \\select name from sqlite_master
            \\where type = 'table' and name not like 'sqlite_%'
            \\order by name
        , &.{});
        defer table_rows.deinit();

        while (try table_rows.next()) |row| {
            const table_name = try (try row.value("name")).asText();
            const owned_name = try allocator.dupe(u8, table_name);
            errdefer allocator.free(owned_name);

            var pragma_sql_buf: [256]u8 = undefined;
            // table name comes from sqlite_master, not user input.
            const pragma_sql = try std.fmt.bufPrint(&pragma_sql_buf, "pragma table_info({s})", .{table_name});
            var col_rows = try self.query(pragma_sql, &.{});
            defer col_rows.deinit();

            var cols: std.ArrayListUnmanaged(core.inspect.Column) = .empty;
            errdefer {
                for (cols.items) |c_| {
                    allocator.free(c_.name);
                    allocator.free(c_.type_name);
                }
                cols.deinit(allocator);
            }

            while (try col_rows.next()) |col_row| {
                const cname = try allocator.dupe(u8, try (try col_row.value("name")).asText());
                errdefer allocator.free(cname);
                const ctype = try allocator.dupe(u8, try (try col_row.value("type")).asText());
                errdefer allocator.free(ctype);
                const notnull = (try (try col_row.value("notnull")).asInt()) != 0;
                const pk = (try (try col_row.value("pk")).asInt()) != 0;
                try cols.append(allocator, .{
                    .name = cname,
                    .type_name = ctype,
                    .nullable = !notnull and !pk,
                    .primary_key = pk,
                });
            }

            const columns = try cols.toOwnedSlice(allocator);

            // Indexes via PRAGMA index_list / index_info (table name from catalog).
            var idx_sql_buf: [256]u8 = undefined;
            const idx_list_sql = try std.fmt.bufPrint(&idx_sql_buf, "pragma index_list({s})", .{table_name});
            var idx_rows = try self.query(idx_list_sql, &.{});
            defer idx_rows.deinit();

            var indexes: std.ArrayListUnmanaged(core.inspect.Index) = .empty;
            errdefer {
                for (indexes.items) |idx| {
                    allocator.free(idx.name);
                    for (idx.columns) |c_| allocator.free(c_);
                    allocator.free(idx.columns);
                }
                indexes.deinit(allocator);
            }

            while (try idx_rows.next()) |idx_row| {
                const iname = try (try idx_row.value("name")).asText();
                // Skip auto-indexes that mirror PRIMARY KEY / UNIQUE constraints if desired;
                // keep them for offline completeness.
                const unique = (try (try idx_row.value("unique")).asInt()) != 0;
                var info_sql_buf: [288]u8 = undefined;
                const info_sql = try std.fmt.bufPrint(&info_sql_buf, "pragma index_info({s})", .{iname});
                var info_rows = try self.query(info_sql, &.{});
                defer info_rows.deinit();

                var col_names: std.ArrayListUnmanaged([]const u8) = .empty;
                errdefer {
                    for (col_names.items) |c_| allocator.free(c_);
                    col_names.deinit(allocator);
                }
                while (try info_rows.next()) |info_row| {
                    const cname = try allocator.dupe(u8, try (try info_row.value("name")).asText());
                    try col_names.append(allocator, cname);
                }

                try indexes.append(allocator, .{
                    .name = try allocator.dupe(u8, iname),
                    .unique = unique,
                    .columns = try col_names.toOwnedSlice(allocator),
                });
            }

            try tables_list.append(allocator, .{
                .name = owned_name,
                .columns = columns,
                .indexes = try indexes.toOwnedSlice(allocator),
            });
        }

        return .{
            .tables = try tables_list.toOwnedSlice(allocator),
        };
    }
};

/// Handle + ownership flag for cached vs one-shot prepares.
const Prepared = struct {
    stmt: Stmt,
    from_cache: bool,

    fn release(self: *Prepared) void {
        if (self.from_cache) {
            self.stmt.resetForReuse();
        } else {
            self.stmt.close();
        }
    }
};

/// Connection-local SQLite prepared statement handle cache (LRU).
const PreparedCache = struct {
    allocator: std.mem.Allocator,
    max_entries: usize,
    entries: std.ArrayListUnmanaged(Entry) = .empty,

    const Entry = struct {
        sql: []u8,
        stmt: Stmt,
    };

    fn init(allocator: std.mem.Allocator, max_entries: usize) !PreparedCache {
        if (max_entries == 0) return error.InvalidArguments;
        return .{ .allocator = allocator, .max_entries = max_entries };
    }

    fn deinit(self: *PreparedCache) void {
        for (self.entries.items) |*entry| {
            entry.stmt.close();
            self.allocator.free(entry.sql);
        }
        self.entries.deinit(self.allocator);
        self.* = undefined;
    }

    fn len(self: *const PreparedCache) usize {
        return self.entries.items.len;
    }

    fn get(self: *PreparedCache, db: *c.sqlite3, sql: []const u8) !?Stmt {
        _ = db;
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                if (i + 1 != self.entries.items.len) {
                    const moved = self.entries.orderedRemove(i);
                    try self.entries.append(self.allocator, moved);
                }
                return self.borrow(sql);
            }
        }
        return null;
    }

    fn borrow(self: *PreparedCache, sql: []const u8) ?Stmt {
        for (self.entries.items) |*entry| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                return .{
                    .allocator = entry.stmt.allocator,
                    .handle = entry.stmt.handle,
                    .placeholders = entry.stmt.placeholders,
                    .owned_bind_buffers = .empty,
                    .closed = false,
                    .finalize_on_close = false,
                };
            }
        }
        return null;
    }

    fn put(self: *PreparedCache, sql: []const u8, stmt: Stmt) !void {
        for (self.entries.items, 0..) |*entry, i| {
            if (std.mem.eql(u8, entry.sql, sql)) {
                entry.stmt.close();
                entry.stmt = stmt;
                if (i + 1 != self.entries.items.len) {
                    const moved = self.entries.orderedRemove(i);
                    try self.entries.append(self.allocator, moved);
                }
                return;
            }
        }
        while (self.entries.items.len >= self.max_entries) {
            var old = self.entries.orderedRemove(0);
            old.stmt.close();
            self.allocator.free(old.sql);
        }
        const owned_sql = try self.allocator.dupe(u8, sql);
        errdefer self.allocator.free(owned_sql);
        try self.entries.append(self.allocator, .{
            .sql = owned_sql,
            .stmt = stmt,
        });
    }
};

pub fn freeInspectedSchema(allocator: std.mem.Allocator, schema: core.inspect.Schema) void {
    freeInspectedTables(allocator, @constCast(schema.tables));
}

fn freeInspectedTables(allocator: std.mem.Allocator, tables: []core.inspect.Table) void {
    for (tables) |table| {
        allocator.free(table.name);
        for (table.columns) |col| {
            allocator.free(col.name);
            allocator.free(col.type_name);
        }
        allocator.free(@constCast(table.columns));
        for (table.indexes) |idx| {
            allocator.free(idx.name);
            for (idx.columns) |c_| allocator.free(c_);
            allocator.free(@constCast(idx.columns));
        }
        allocator.free(@constCast(table.indexes));
    }
    allocator.free(tables);
}

pub fn ensureMigrationTable(conn: *Conn) !void {
    _ = try conn.exec(
        \\create table if not exists zsql_migrations (
        \\  version integer primary key,
        \\  name text not null,
        \\  checksum text not null,
        \\  applied_at text not null default current_timestamp,
        \\  execution_ms integer not null default 0,
        \\  dirty integer not null default 0 check (dirty in (0, 1))
        \\)
    , &.{});
    // Best-effort upgrade for databases created before execution_ms existed.
    _ = conn.exec("alter table zsql_migrations add column execution_ms integer not null default 0", &.{}) catch {};
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
        const started_ms = nowMs();
        try tx.execScript(migration.sql);
        const elapsed_ms: i64 = @max(0, nowMs() - started_ms);
        _ = try tx.exec(
            \\update zsql_migrations
            \\set dirty = 0, execution_ms = ?
            \\where version = ?
        , &.{
            .{ .integer = elapsed_ms },
            .{ .integer = try sqliteVersion(migration.id.version) },
        });
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
    /// When false, `close` only resets/clears binds (borrowed from a cache).
    finalize_on_close: bool = true,

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
        if (self.finalize_on_close) {
            const rc = c.sqlite3_finalize(self.handle);
            std.debug.assert(rc == c.SQLITE_OK);
        } else {
            _ = c.sqlite3_clear_bindings(self.handle);
            _ = c.sqlite3_reset(self.handle);
        }
        self.owned_bind_buffers.deinit(self.allocator);
        self.closed = true;
    }

    /// Reset a cached statement for reuse without finalizing.
    pub fn resetForReuse(self: *Stmt) void {
        if (self.closed) return;
        self.freeBindBuffers();
        _ = c.sqlite3_clear_bindings(self.handle);
        _ = c.sqlite3_reset(self.handle);
        self.owned_bind_buffers.clearRetainingCapacity();
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
    /// When true, `deinit` finalizes the statement; otherwise only resets it.
    owns_stmt: bool = true,

    pub fn init(stmt: Stmt, binds: []const core.Value) !Rows {
        return initOwned(stmt, binds, true);
    }

    pub fn initNamed(stmt: Stmt, binds: []const NamedValue) !Rows {
        return initOwnedNamed(stmt, binds, true);
    }

    pub fn initOwned(stmt: Stmt, binds: []const core.Value, owns_stmt: bool) !Rows {
        var owned_stmt = stmt;
        errdefer if (owns_stmt) owned_stmt.close() else owned_stmt.resetForReuse();

        try owned_stmt.bindValues(binds);
        return initBound(owned_stmt, owns_stmt);
    }

    pub fn initOwnedNamed(stmt: Stmt, binds: []const NamedValue, owns_stmt: bool) !Rows {
        var owned_stmt = stmt;
        errdefer if (owns_stmt) owned_stmt.close() else owned_stmt.resetForReuse();

        try owned_stmt.bindNamedValues(binds);
        return initBound(owned_stmt, owns_stmt);
    }

    fn initBound(owned_stmt: Stmt, owns_stmt: bool) !Rows {
        var stmt = owned_stmt;

        const column_count = try sqliteColumnCount(stmt.handle);
        const columns = try stmt.allocator.alloc([]const u8, column_count);
        errdefer stmt.allocator.free(columns);
        const values = try stmt.allocator.alloc(core.Value, column_count);
        errdefer stmt.allocator.free(values);

        for (columns, 0..) |*column, index| {
            const name = c.sqlite3_column_name(stmt.handle, try sqliteIndex(index)) orelse return error.DriverError;
            column.* = std.mem.span(name);
        }

        return .{
            .stmt = stmt,
            .columns = columns,
            .values = values,
            .owns_stmt = owns_stmt,
        };
    }

    pub fn deinit(self: *Rows) void {
        self.stmt.allocator.free(self.values);
        self.stmt.allocator.free(self.columns);
        if (self.owns_stmt) {
            self.stmt.close();
        } else {
            self.stmt.resetForReuse();
        }
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

fn nowMs() i64 {
    var ts: std.c.timespec = undefined;
    if (std.c.clock_gettime(.MONOTONIC, &ts) != 0) return 0;
    return @as(i64, @intCast(ts.sec)) * 1000 + @divTrunc(@as(i64, @intCast(ts.nsec)), 1_000_000);
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

test "SQLite queryOne enforces single-row cardinality" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec("create table one_row (id integer primary key, name text)", &.{});
    try std.testing.expectError(error.NoRows, conn.queryOne("select id from one_row", &.{}));

    _ = try conn.exec("insert into one_row (id, name) values (1, 'a'), (2, 'b')", &.{});
    try std.testing.expectError(error.TooManyRows, conn.queryOne("select id from one_row", &.{}));

    var owned = try conn.queryOne("select id, name from one_row where id = ?", &.{.{ .integer = 1 }});
    defer owned.deinit();
    try std.testing.expectEqual(@as(i64, 1), try (try owned.getName("id")).asInt());
    try std.testing.expectEqualStrings("a", try (try owned.getName("name")).asText());
}

test "SQLite prepared statement cache reuses handles" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();

    try conn.enableStmtCache(4);
    _ = try conn.exec("create table cache_probe (id integer primary key, n integer)", &.{});
    _ = try conn.exec("insert into cache_probe (id, n) values (?, ?)", &.{ .{ .integer = 1 }, .{ .integer = 10 } });
    try std.testing.expectEqual(@as(usize, 2), conn.stmtCacheLen());

    var rows1 = try conn.query("select n from cache_probe where id = ?", &.{.{ .integer = 1 }});
    try std.testing.expectEqual(@as(i64, 10), try (try (try rows1.next()).?.value("n")).asInt());
    rows1.deinit();
    try std.testing.expectEqual(@as(usize, 3), conn.stmtCacheLen());

    var rows2 = try conn.query("select n from cache_probe where id = ?", &.{.{ .integer = 1 }});
    try std.testing.expectEqual(@as(i64, 10), try (try (try rows2.next()).?.value("n")).asInt());
    rows2.deinit();
    // Same SQL should not grow the cache.
    try std.testing.expectEqual(@as(usize, 3), conn.stmtCacheLen());

    conn.disableStmtCache();
    try std.testing.expectEqual(@as(usize, 0), conn.stmtCacheLen());
}

test "SQLite inspectSchema exports tables and columns" {
    var db = try Database.open(std.testing.allocator, .{});
    defer db.deinit();
    var conn = try db.connect();
    defer conn.close();

    _ = try conn.exec(
        \\create table inspect_users (
        \\  id integer primary key,
        \\  email text not null,
        \\  bio text
        \\)
    , &.{});
    _ = try conn.exec("create unique index inspect_users_email_uq on inspect_users(email)", &.{});

    const schema = try conn.inspectSchema(std.testing.allocator);
    defer freeInspectedSchema(std.testing.allocator, schema);

    try std.testing.expectEqual(@as(usize, 1), schema.tables.len);
    try std.testing.expectEqualStrings("inspect_users", schema.tables[0].name);
    try std.testing.expectEqual(@as(usize, 3), schema.tables[0].columns.len);
    try std.testing.expect(schema.tables[0].columns[0].primary_key);
    try std.testing.expect(!schema.tables[0].columns[1].nullable);
    try std.testing.expect(schema.tables[0].columns[2].nullable);
    try std.testing.expect(schema.tables[0].indexes.len >= 1);
    var found_email_idx = false;
    for (schema.tables[0].indexes) |idx| {
        if (std.mem.eql(u8, idx.name, "inspect_users_email_uq")) {
            found_email_idx = true;
            try std.testing.expect(idx.unique);
            try std.testing.expectEqual(@as(usize, 1), idx.columns.len);
            try std.testing.expectEqualStrings("email", idx.columns[0]);
        }
    }
    try std.testing.expect(found_email_idx);
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
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 1 });
    defer pool.deinit();

    try std.testing.expectEqualDeep(PoolStats{
        .open = 0,
        .idle = 0,
        .leased = 0,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var first = try pool.acquire();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 0,
        .leased = 1,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var first_conn = try first.conn();
    _ = try first_conn.exec("create table pooled_reuse (id integer)", &.{});
    _ = try first_conn.exec("insert into pooled_reuse (id) values (?)", &.{.{ .integer = 1 }});
    try first.release();
    try std.testing.expect(!first.open);
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 1,
        .leased = 0,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var second = try pool.acquire();
    defer second.release() catch unreachable;
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 0,
        .leased = 1,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var rows = try (try second.conn()).query("select id from pooled_reuse", &.{});
    defer rows.deinit();
    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
}

test "SQLite pool max idle closes excess released leases" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 2, .max_idle = 1 });
    defer pool.deinit();

    var first = try pool.acquire();
    var second = try pool.acquire();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 2,
        .idle = 0,
        .leased = 2,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    try first.release();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 2,
        .idle = 1,
        .leased = 1,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    try second.release();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 1,
        .leased = 0,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());
}

test "SQLite pool zero max idle closes releases immediately" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 1, .max_idle = 0 });
    defer pool.deinit();

    var lease = try pool.acquire();
    try lease.release();

    try std.testing.expectEqualDeep(PoolStats{
        .open = 0,
        .idle = 0,
        .leased = 0,
        .max_open = 1,
        .max_idle = 0,
        .acquire_timeout_ns = 0,
    }, pool.stats());
}

test "SQLite pool enforces max open leases" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 1 });
    defer pool.deinit();

    var lease = try pool.acquire();
    try std.testing.expectError(error.PoolExhausted, pool.acquire());
    try lease.release();
}

test "SQLite pool exhausted acquire with timeout returns PoolTimeout" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{
        .max_open = 1,
        .acquire_timeout_ns = 5 * std.time.ns_per_ms,
    });
    defer pool.deinit();

    try std.testing.expectEqual(@as(u64, 5 * std.time.ns_per_ms), pool.stats().acquire_timeout_ns);

    var lease = try pool.acquire();
    // Full pool with a short timeout should wait then fail with PoolTimeout.
    try std.testing.expectError(error.PoolTimeout, pool.acquire());
    try std.testing.expectError(error.PoolTimeout, pool.acquireWithTimeout(1 * std.time.ns_per_ms));
    try std.testing.expectError(error.PoolExhausted, pool.acquireWithTimeout(0));
    try lease.release();

    var recovered = try pool.acquireWithTimeout(0);
    try recovered.release();
}

test "SQLite pool timed acquire unblocks after concurrent release" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{
        .max_open = 1,
        .acquire_timeout_ns = 2 * std.time.ns_per_s,
    });
    defer pool.deinit();

    var holder = try pool.acquire();

    const Ctx = struct {
        pool: *Pool,
        ok: std.atomic.Value(bool) = .init(false),
        err_name: [64]u8 = undefined,
        err_len: usize = 0,

        fn worker(ctx: *@This()) void {
            var lease = ctx.pool.acquireWithTimeout(2 * std.time.ns_per_s) catch |err| {
                const name = @errorName(err);
                const n = @min(name.len, ctx.err_name.len);
                @memcpy(ctx.err_name[0..n], name[0..n]);
                ctx.err_len = n;
                return;
            };
            lease.release() catch {};
            ctx.ok.store(true, .release);
        }
    };

    var ctx = Ctx{ .pool = &pool };
    const thread = try std.Thread.spawn(.{}, Ctx.worker, .{&ctx});

    // Give the waiter time to enter the poll loop, then release capacity.
    std.testing.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake) catch {};
    try holder.release();
    thread.join();

    try std.testing.expect(ctx.ok.load(.acquire));
    try std.testing.expectEqual(@as(usize, 0), ctx.err_len);
}

test "SQLite pool query holds lease until rows deinit" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 1 });
    defer pool.deinit();

    _ = try pool.exec("create table pooled_query (id integer primary key, name text)", &.{});
    _ = try pool.exec(
        "insert into pooled_query (id, name) values (?, ?)",
        &.{ .{ .integer = 1 }, .{ .text = "ada" } },
    );

    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 1,
        .leased = 0,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var rows = try pool.query("select id, name from pooled_query where id = ?", &.{.{ .integer = 1 }});
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 0,
        .leased = 1,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());
    try std.testing.expectError(error.PoolExhausted, pool.acquire());

    const row = (try rows.next()).?;
    try std.testing.expectEqual(@as(i64, 1), try (try row.value("id")).asInt());
    try std.testing.expectEqualStrings("ada", try (try row.value("name")).asText());
    try std.testing.expectEqual(@as(?core.Row, null), try rows.next());

    rows.deinit();
    try std.testing.expectEqualDeep(PoolStats{
        .open = 1,
        .idle = 1,
        .leased = 0,
        .max_open = 1,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());

    var lease = try pool.acquire();
    try lease.release();
}

test "SQLite pool discard closes lease and allows replacement" {
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 1 });
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
    try std.testing.expectError(error.InvalidBindValue, Pool.init(std.testing.allocator, std.testing.io, .{ .max_open = 0 }));

    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{});
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
