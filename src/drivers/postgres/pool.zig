const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const conn_mod = @import("conn.zig");

const Io = std.Io;

pub const PoolConfig = struct {
    database: url.Config,
    max_open: usize = 4,
    max_idle: usize = 4,
    /// Acquire wait policy when the pool is at `max_open`:
    /// - `0`: fail immediately with `PoolExhausted`
    /// - `std.math.maxInt(u64)`: wait forever on a condition until release/discard
    /// - any other value: wait up to that many nanoseconds (≤1ms poll slices)
    acquire_timeout_ns: u64 = 0,
    /// When non-zero, each newly opened connection enables a statement cache
    /// of this size via `Conn.enableStmtCache`. Zero leaves caching off.
    stmt_cache_size: usize = 0,
    /// Applied to every connection handed out by the pool (new or idle).
    /// Connection-local; no global registry. Bind values are never included.
    hooks: core.Hooks = .{},
};

pub const PoolStats = struct {
    open: usize,
    idle: usize,
    leased: usize,
    max_open: usize,
    max_idle: usize,
    acquire_timeout_ns: u64,
};

/// Thread-safe PostgreSQL connection pool.
///
/// Connections are established with `Conn.open` using the pool's `Io` and
/// config. `deinit` closes idle connections and marks the pool closed; existing
/// leases remain usable and close their connection when released.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: PoolConfig,
    idle: std.ArrayListUnmanaged(conn_mod.Conn) = .empty,
    open_count: usize = 0,
    closed: bool = false,
    mutex: Io.Mutex = .init,
    available: Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: PoolConfig) !Pool {
        if (config.max_open == 0) return error.InvalidArguments;
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
        self.closed = true;

        const idle_count = self.idle.items.len;
        for (self.idle.items) |*c| c.deinit();
        self.idle.deinit(self.allocator);
        self.idle = .empty;
        self.open_count -= idle_count;

        self.available.broadcast(self.io);
    }

    pub fn acquire(self: *Pool) !Lease {
        return self.acquireWithTimeout(self.config.acquire_timeout_ns);
    }

    pub fn acquireWithTimeout(self: *Pool, timeout_ns: u64) !Lease {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const deadline: ?Io.Clock.Timestamp = if (timeout_ns == 0 or timeout_ns == std.math.maxInt(u64))
            null
        else
            Io.Clock.Timestamp.fromNow(self.io, .{
                .raw = .{ .nanoseconds = @intCast(timeout_ns) },
                .clock = .awake,
            });

        while (true) {
            if (self.closed) return error.PoolClosed;

            if (self.idle.pop()) |idle_conn| {
                var c = idle_conn;
                c.setHooks(self.config.hooks);
                return .{
                    .pool = self,
                    .conn_value = c,
                };
            }

            if (self.open_count < self.config.max_open) {
                // Unlock around TCP handshake so other waiters are not stalled.
                self.open_count += 1;
                self.mutex.unlock(self.io);
                var opened = conn_mod.Conn.open(self.allocator, self.io, self.config.database) catch |err| {
                    self.mutex.lockUncancelable(self.io);
                    self.open_count -|= 1;
                    return err;
                };
                opened.setHooks(self.config.hooks);
                if (self.config.stmt_cache_size > 0) {
                    opened.enableStmtCache(self.config.stmt_cache_size) catch |err| {
                        opened.deinit();
                        self.mutex.lockUncancelable(self.io);
                        self.open_count -|= 1;
                        return err;
                    };
                }
                self.mutex.lockUncancelable(self.io);
                if (self.closed) {
                    opened.deinit();
                    self.open_count -|= 1;
                    return error.PoolClosed;
                }
                return .{
                    .pool = self,
                    .conn_value = opened,
                };
            }

            if (timeout_ns == 0) {
                return error.PoolExhausted;
            } else if (timeout_ns == std.math.maxInt(u64)) {
                self.available.waitUncancelable(self.io, &self.mutex);
            } else if (deadline) |dl| {
                try self.waitForSlotTimed(dl);
            } else {
                return error.PoolExhausted;
            }
        }
    }

    fn waitForSlotTimed(self: *Pool, deadline: Io.Clock.Timestamp) !void {
        while (true) {
            if (self.closed) return error.PoolClosed;
            if (self.idle.items.len > 0 or self.open_count < self.config.max_open) return;
            const remaining = deadline.durationFromNow(self.io);
            if (remaining.raw.nanoseconds <= 0) return error.PoolTimeout;

            const sleep_ns = @min(remaining.raw.nanoseconds, std.time.ns_per_ms);
            self.mutex.unlock(self.io);
            self.io.sleep(.{ .nanoseconds = sleep_ns }, .awake) catch |err| {
                self.mutex.lockUncancelable(self.io);
                return err;
            };
            self.mutex.lockUncancelable(self.io);
        }
    }

    fn notifyAvailable(self: *Pool) void {
        self.available.signal(self.io);
    }

    pub fn exec(self: *Pool, sql: []const u8) !core.ExecResult {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const result = (try lease.conn()).exec(sql) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return result;
    }

    pub fn execParams(self: *Pool, sql: []const u8, binds: []const core.Value) !core.ExecResult {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const result = (try lease.conn()).execParams(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return result;
    }

    pub fn execNamed(self: *Pool, sql: []const u8, binds: []const core.params.NamedValue) !core.ExecResult {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const result = (try lease.conn()).execNamed(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return result;
    }

    /// Prepare a reusable statement on a dedicated lease. The lease remains
    /// held until `PooledStmt.close` / `deinit`.
    pub fn prepare(self: *Pool, sql: []const u8) !PooledStmt {
        return PooledStmt.init(self, sql, false);
    }

    /// Named-placeholder variant of `prepare`.
    pub fn prepareNamed(self: *Pool, sql: []const u8) !PooledStmt {
        return PooledStmt.init(self, sql, true);
    }

    /// Holds a lease until `PooledRows.deinit`.
    pub fn queryParams(self: *Pool, sql: []const u8, binds: []const core.Value) !PooledRows {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const rows = (try lease.conn()).queryParams(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        return .{
            .lease = lease,
            .rows = rows,
        };
    }

    /// Holds a lease until `PooledRows.deinit`.
    pub fn queryNamed(self: *Pool, sql: []const u8, binds: []const core.params.NamedValue) !PooledRows {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const rows = (try lease.conn()).queryNamed(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        return .{ .lease = lease, .rows = rows };
    }

    /// Acquire a short lease, fetch exactly one owned row, then release.
    pub fn queryOneParams(self: *Pool, sql: []const u8, binds: []const core.Value) !core.OwnedRow {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const owned = (try lease.conn()).queryOneParams(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return owned;
    }

    /// Acquire a short lease, collect all parameterized rows into owned storage,
    /// then release. Free with `core.OwnedRow.freeSlice` / `zsql.freeOwnedRows`.
    pub fn queryAllParams(self: *Pool, sql: []const u8, binds: []const core.Value) ![]core.OwnedRow {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const owned = (try lease.conn()).queryAllParams(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return owned;
    }

    /// Liveness check under a short-lived lease.
    pub fn ping(self: *Pool) !void {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        (try lease.conn()).ping() catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
    }

    /// Acquire a dedicated pooled connection for PostgreSQL LISTEN/NOTIFY.
    /// The lease remains held until `Listener.deinit`.
    pub fn listen(self: *Pool) !Listener {
        return .{ .lease = try self.acquire() };
    }

    /// Acquire a lease, run `body` inside `Conn.withTx`, then release the lease.
    /// Body errors roll back and retain a synchronized connection; rollback or
    /// transport failures discard it.
    pub fn withTx(self: *Pool, ctx: anytype, comptime body: *const fn (@TypeOf(ctx), *conn_mod.Conn) anyerror!void) !void {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        (try lease.conn()).withTx(ctx, body) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
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

/// A dedicated pooled PostgreSQL notification listener.
pub const Listener = struct {
    lease: Lease,
    closed: bool = false,

    pub fn listen(self: *Listener, channel: []const u8) !void {
        if (self.closed) return error.LeaseClosed;
        try (try self.lease.conn()).listen(channel);
    }

    pub fn unlisten(self: *Listener, channel: []const u8) !void {
        if (self.closed) return error.LeaseClosed;
        try (try self.lease.conn()).unlisten(channel);
    }

    pub fn next(self: *Listener) !conn_mod.Notification {
        if (self.closed) return error.LeaseClosed;
        return (try self.lease.conn()).nextNotification();
    }

    pub fn deinit(self: *Listener) void {
        if (self.closed) return;
        self.lease.release() catch self.lease.discard() catch {};
        self.closed = true;
    }
};

pub const Lease = struct {
    pool: *Pool,
    conn_value: conn_mod.Conn,
    open: bool = true,

    pub fn conn(self: *Lease) !*conn_mod.Conn {
        if (!self.open) return error.LeaseClosed;
        return &self.conn_value;
    }

    pub fn release(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        if (self.pool.closed) {
            self.conn_value.deinit();
            self.pool.open_count -|= 1;
            self.open = false;
            return error.PoolClosed;
        }

        if (!self.conn_value.isReusable()) {
            self.conn_value.deinit();
            self.pool.open_count -|= 1;
            self.open = false;
            self.pool.notifyAvailable();
            return;
        }

        if (self.pool.idle.items.len < self.pool.effectiveMaxIdle()) {
            try self.pool.idle.append(self.pool.allocator, self.conn_value);
        } else {
            self.conn_value.deinit();
            self.pool.open_count -|= 1;
        }
        self.open = false;
        self.pool.notifyAvailable();
    }

    fn finishAfterError(self: *Lease, err: anyerror) void {
        if (isFatalPoolConnectionError(err) or !self.conn_value.isReusable()) {
            self.discard() catch {};
        } else {
            self.release() catch self.discard() catch {};
        }
    }

    pub fn discard(self: *Lease) !void {
        if (!self.open) return error.LeaseClosed;

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        self.conn_value.deinit();
        self.pool.open_count -|= 1;
        self.open = false;
        self.pool.notifyAvailable();
    }
};

fn isFatalPoolConnectionError(err: anyerror) bool {
    return switch (err) {
        error.AuthFailed,
        error.Canceled,
        error.ConnectionClosed,
        error.ConnectionTimeout,
        error.DriverError,
        error.OutOfMemory,
        error.ProtocolError,
        error.TlsFailed,
        => true,
        else => false,
    };
}

pub const PooledRows = struct {
    lease: Lease,
    rows: conn_mod.SimpleRows,
    closed: bool = false,

    pub fn next(self: *PooledRows) ?conn_mod.SimpleRow {
        if (self.closed) return null;
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

/// Reusable PostgreSQL statement coupled to a stable heap-owned pool lease.
/// This prevents the statement's borrowed connection pointer from dangling
/// when the `PooledStmt` value itself moves.
pub const PooledStmt = struct {
    allocator: std.mem.Allocator,
    lease: *Lease,
    stmt: conn_mod.Stmt,
    closed: bool = false,

    fn init(pool: *Pool, sql: []const u8, named: bool) !PooledStmt {
        const lease = try pool.allocator.create(Lease);
        errdefer pool.allocator.destroy(lease);
        lease.* = try pool.acquire();
        errdefer lease.discard() catch {};

        const stmt = if (named)
            try (try lease.conn()).prepareNamed(sql)
        else
            try (try lease.conn()).prepare(sql);
        return .{
            .allocator = pool.allocator,
            .lease = lease,
            .stmt = stmt,
        };
    }

    pub fn parameterCount(self: *const PooledStmt) usize {
        return if (self.closed) 0 else self.stmt.parameterCount();
    }

    pub fn parameterOids(self: *const PooledStmt) []const u32 {
        return if (self.closed) &.{} else self.stmt.parameterOids();
    }

    pub fn parameterNames(self: *const PooledStmt) ?[]const []const u8 {
        return if (self.closed) null else self.stmt.parameterNames();
    }

    pub fn exec(self: *PooledStmt, binds: []const core.Value) !core.ExecResult {
        if (self.closed) return error.StatementClosed;
        return self.stmt.exec(binds);
    }

    pub fn query(self: *PooledStmt, binds: []const core.Value) !conn_mod.SimpleRows {
        if (self.closed) return error.StatementClosed;
        return self.stmt.query(binds);
    }

    pub fn execNamed(self: *PooledStmt, binds: []const core.params.NamedValue) !core.ExecResult {
        if (self.closed) return error.StatementClosed;
        return self.stmt.execNamed(binds);
    }

    pub fn queryNamed(self: *PooledStmt, binds: []const core.params.NamedValue) !conn_mod.SimpleRows {
        if (self.closed) return error.StatementClosed;
        return self.stmt.queryNamed(binds);
    }

    pub fn close(self: *PooledStmt) !void {
        if (self.closed) return error.StatementClosed;
        try self.stmt.close();
        self.lease.release() catch |err| {
            self.lease.discard() catch {};
            self.finish();
            return err;
        };
        self.finish();
    }

    pub fn deinit(self: *PooledStmt) void {
        if (self.closed) return;
        self.stmt.deinit();
        self.lease.release() catch self.lease.discard() catch {};
        self.finish();
    }

    fn finish(self: *PooledStmt) void {
        self.allocator.destroy(self.lease);
        self.closed = true;
    }
};

test "postgres pool rejects zero max_open" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    try std.testing.expectError(
        error.InvalidArguments,
        Pool.init(std.testing.allocator, std.testing.io, .{
            .database = config,
            .max_open = 0,
        }),
    );
}

test "postgres pool stats start empty" {
    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{
        .database = config,
        .max_open = 2,
        .max_idle = 1,
        .stmt_cache_size = 8,
    });
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 8), pool.config.stmt_cache_size);
    try std.testing.expectEqualDeep(PoolStats{
        .open = 0,
        .idle = 0,
        .leased = 0,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());
}
