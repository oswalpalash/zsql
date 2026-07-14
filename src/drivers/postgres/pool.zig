const std = @import("std");
const core = @import("../../zsql.zig");
const url = @import("url.zig");
const conn_mod = @import("conn.zig");

const Io = std.Io;

pub const SessionReset = enum {
    /// Preserve session state across leases. Fastest and required when callers
    /// deliberately reuse temporary objects or connection-local settings.
    none,
    /// Execute PostgreSQL `DISCARD ALL` before an idle connection is reused.
    /// This isolates borrowers but clears the connection's statement cache.
    discard_all,
};

pub const PoolConfig = struct {
    /// Cloned by `Pool.init`, including the optional peer certificate bytes.
    /// The caller retains ownership of this source configuration.
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
    /// Session-state policy at the lease boundary. `discard_all` removes
    /// temporary objects, changed settings, listeners, advisory locks, and
    /// prepared statements before the connection returns to idle.
    session_reset: SessionReset = .none,
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
/// leases remain usable and close their connection when released. Connection
/// configuration is allocator-owned by the pool; hook context remains borrowed.
pub const Pool = struct {
    allocator: std.mem.Allocator,
    io: Io,
    config: PoolConfig,
    idle: std.ArrayListUnmanaged(conn_mod.Conn) = .empty,
    open_count: usize = 0,
    closed: bool = false,
    config_live: bool = true,
    owned_peer_cert_der: ?[]u8 = null,
    mutex: Io.Mutex = .init,
    available: Io.Condition = .init,

    pub fn init(allocator: std.mem.Allocator, io: Io, config: PoolConfig) !Pool {
        if (config.max_open == 0) return error.InvalidArguments;
        var owned_database = try config.database.clone(allocator);
        errdefer owned_database.deinit();
        const owned_peer_cert_der = if (config.database.peer_cert_der) |der|
            try allocator.dupe(u8, der)
        else
            null;
        owned_database.peer_cert_der = owned_peer_cert_der;

        var owned_config = config;
        owned_config.database = owned_database;
        return .{
            .allocator = allocator,
            .io = io,
            .config = owned_config,
            .owned_peer_cert_der = owned_peer_cert_der,
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
        std.debug.assert(self.open_count >= idle_count);
        self.open_count -= idle_count;
        self.deinitConfigIfUnusedLocked();

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
                    self.dropOpenSlotLocked();
                    return err;
                };
                opened.setHooks(self.config.hooks);
                if (self.config.stmt_cache_size > 0) {
                    opened.enableStmtCache(self.config.stmt_cache_size) catch |err| {
                        opened.deinit();
                        self.mutex.lockUncancelable(self.io);
                        self.dropOpenSlotLocked();
                        return err;
                    };
                }
                self.mutex.lockUncancelable(self.io);
                if (self.closed) {
                    opened.deinit();
                    self.dropOpenSlotLocked();
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

    /// Release one reserved/open slot while holding `mutex` and wake another
    /// waiter. Acquisition failures must signal just like lease release or an
    /// infinite waiter can sleep after capacity becomes available.
    fn dropOpenSlotLocked(self: *Pool) void {
        std.debug.assert(self.open_count > 0);
        self.open_count -= 1;
        self.deinitConfigIfUnusedLocked();
        self.notifyAvailable();
    }

    /// Pool connection settings are allocator-owned and remain live through
    /// any lease or in-flight open that survives `deinit`.
    fn deinitConfigIfUnusedLocked(self: *Pool) void {
        if (!self.closed or self.open_count != 0 or !self.config_live) return;
        self.config.database.deinit();
        if (self.owned_peer_cert_der) |der| self.allocator.free(der);
        self.owned_peer_cert_der = null;
        self.config_live = false;
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

    /// Run COPY FROM STDIN under a short-lived lease.
    pub fn copyIn(self: *Pool, sql: []const u8, data: []const u8) !core.ExecResult {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const result = (try lease.conn()).copyIn(sql, data) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        try lease.release();
        return result;
    }

    /// Run COPY TO STDOUT under a short-lived lease. The returned bytes are
    /// allocator-owned and remain valid after lease or pool teardown.
    pub fn copyOut(self: *Pool, sql: []const u8) ![]u8 {
        var lease = try self.acquire();
        errdefer if (lease.open) lease.discard() catch {};
        const output = (try lease.conn()).copyOut(sql) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        errdefer self.allocator.free(output);
        try lease.release();
        return output;
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
        var owned = (try lease.conn()).queryOneParams(sql, binds) catch |err| {
            lease.finishAfterError(err);
            return err;
        };
        errdefer owned.deinit();
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
        errdefer core.OwnedRow.freeSlice(self.allocator, owned);
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
        const connection = self.lease.conn() catch {
            self.lease.discard() catch {};
            self.closed = true;
            return;
        };
        connection.unlistenAll() catch {
            self.lease.discard() catch {};
            self.closed = true;
            return;
        };
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

        // Network cleanup must not run under the pool mutex. Configuration
        // remains alive because this lease still owns one open slot, even if
        // pool shutdown races after this snapshot.
        self.pool.mutex.lockUncancelable(self.pool.io);
        const reset_session = !self.pool.closed and
            self.pool.config.session_reset == .discard_all and
            self.conn_value.isReusable();
        const statement_timeout_ms = self.pool.config.database.statement_timeout_ms;
        const stmt_cache_size = self.pool.config.stmt_cache_size;
        self.pool.mutex.unlock(self.pool.io);

        if (reset_session) {
            self.conn_value.resetForPool(statement_timeout_ms, stmt_cache_size) catch |err| {
                // Reset failure makes session state uncertain. Release remains
                // consuming: close the connection, return its pool slot, and
                // surface the cleanup error to the caller.
                self.discard() catch {};
                return err;
            };
        }

        self.pool.mutex.lockUncancelable(self.pool.io);
        defer self.pool.mutex.unlock(self.pool.io);

        if (self.pool.closed) {
            self.conn_value.deinit();
            self.pool.dropOpenSlotLocked();
            self.open = false;
            return error.PoolClosed;
        }

        if (!self.conn_value.isReusable()) {
            self.conn_value.deinit();
            self.pool.dropOpenSlotLocked();
            self.open = false;
            return;
        }

        if (self.pool.idle.items.len < self.pool.effectiveMaxIdle()) {
            self.pool.idle.append(self.pool.allocator, self.conn_value) catch |err| {
                // Release always consumes the lease. If idle storage cannot
                // grow, close allocation-free instead of transferring a
                // cleanup obligation back to the caller.
                self.conn_value.deinit();
                self.pool.dropOpenSlotLocked();
                self.open = false;
                return err;
            };
        } else {
            self.conn_value.deinit();
            self.pool.dropOpenSlotLocked();
        }
        self.open = false;
        if (self.pool.idle.items.len > 0) self.pool.notifyAvailable();
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
        self.pool.dropOpenSlotLocked();
        self.open = false;
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
        .session_reset = .discard_all,
    });
    defer pool.deinit();
    try std.testing.expectEqual(@as(usize, 8), pool.config.stmt_cache_size);
    try std.testing.expect(pool.config.session_reset == .discard_all);
    try std.testing.expectEqualDeep(PoolStats{
        .open = 0,
        .idle = 0,
        .leased = 0,
        .max_open = 2,
        .max_idle = 1,
        .acquire_timeout_ns = 0,
    }, pool.stats());
}

test "postgres pool owns connection config through deferred shutdown" {
    var source = try url.parse(
        std.testing.allocator,
        "postgres://ada:secret@db.example:6543/app?sslmode=require&application_name=pool-owned",
    );
    const peer_cert = "pool peer certificate";
    source.peer_cert_der = peer_cert;
    var pool = try Pool.init(std.testing.allocator, std.testing.io, .{
        .database = source,
        .max_open = 1,
    });
    source.deinit();

    try std.testing.expectEqualStrings("db.example", pool.config.database.host);
    try std.testing.expectEqualStrings("ada", pool.config.database.user);
    try std.testing.expectEqualStrings("secret", pool.config.database.password);
    try std.testing.expectEqualStrings("app", pool.config.database.database);
    try std.testing.expectEqualStrings("pool-owned", pool.config.database.application_name);
    try std.testing.expect(pool.config.database.peer_cert_der.?.ptr != peer_cert.ptr);
    try std.testing.expectEqualStrings(peer_cert, pool.config.database.peer_cert_der.?);

    // A reservation represents either an outstanding lease or an unlocked
    // connection open. Shutdown must retain configuration until it is gone.
    pool.open_count = 1;
    pool.deinit();
    try std.testing.expect(pool.config_live);
    pool.mutex.lockUncancelable(pool.io);
    pool.dropOpenSlotLocked();
    pool.mutex.unlock(pool.io);
    try std.testing.expect(!pool.config_live);
    try std.testing.expectEqual(@as(?[]u8, null), pool.owned_peer_cert_der);
}

test "postgres pool config ownership cleans every init allocation failure" {
    var source = try url.parse(
        std.testing.allocator,
        "postgres://ada:secret@db.example/app?application_name=pool-oom",
    );
    defer source.deinit();
    source.peer_cert_der = "certificate";

    try std.testing.checkAllAllocationFailures(
        std.testing.allocator,
        struct {
            fn init(allocator: std.mem.Allocator, database: url.Config) !void {
                var pool = try Pool.init(allocator, std.testing.io, .{ .database = database });
                defer pool.deinit();
            }
        }.init,
        .{source},
    );
}

test "postgres pool acquisition failure wakes the next infinite waiter" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;

    var config = try url.parse(std.testing.allocator, "postgres://u@127.0.0.1:1/db?sslmode=disable");
    defer config.deinit();
    var failing = std.testing.FailingAllocator.init(std.testing.allocator, .{});
    var pool = try Pool.init(failing.allocator(), std.testing.io, .{
        .database = config,
        .max_open = 1,
        .acquire_timeout_ns = std.math.maxInt(u64),
    });
    defer pool.deinit();
    failing.fail_index = failing.alloc_index;

    // Model one in-flight reservation so both workers enter the infinite wait.
    pool.open_count = 1;
    const Result = enum { pending, out_of_memory, other, unexpected_success };
    const Ctx = struct {
        pool: *Pool,
        ready: std.atomic.Value(bool) = .init(false),
        done: std.atomic.Value(bool) = .init(false),
        result: Result = .pending,

        fn worker(self: *@This()) void {
            self.ready.store(true, .release);
            var lease = self.pool.acquire() catch |err| {
                self.result = if (err == error.OutOfMemory) .out_of_memory else .other;
                self.done.store(true, .release);
                return;
            };
            lease.discard() catch {};
            self.result = .unexpected_success;
            self.done.store(true, .release);
        }
    };

    var first = Ctx{ .pool = &pool };
    var second = Ctx{ .pool = &pool };
    const first_thread = try std.Thread.spawn(.{}, Ctx.worker, .{&first});
    const second_thread = try std.Thread.spawn(.{}, Ctx.worker, .{&second});
    while (!first.ready.load(.acquire) or !second.ready.load(.acquire)) {
        try std.testing.io.sleep(.{ .nanoseconds = std.time.ns_per_ms }, .awake);
    }
    try std.testing.io.sleep(.{ .nanoseconds = 20 * std.time.ns_per_ms }, .awake);

    pool.mutex.lockUncancelable(pool.io);
    pool.dropOpenSlotLocked();
    pool.mutex.unlock(pool.io);
    try std.testing.io.sleep(.{ .nanoseconds = 100 * std.time.ns_per_ms }, .awake);
    const completed_without_rescue = first.done.load(.acquire) and second.done.load(.acquire);

    // Keep a broken implementation from hanging the suite: rescue any waiter,
    // then fail the assertion below because it needed this broadcast.
    var rescue_attempts: usize = 0;
    while ((!first.done.load(.acquire) or !second.done.load(.acquire)) and rescue_attempts < 20) : (rescue_attempts += 1) {
        pool.mutex.lockUncancelable(pool.io);
        pool.available.broadcast(pool.io);
        pool.mutex.unlock(pool.io);
        try std.testing.io.sleep(.{ .nanoseconds = 5 * std.time.ns_per_ms }, .awake);
    }
    first_thread.join();
    second_thread.join();

    try std.testing.expect(completed_without_rescue);
    try std.testing.expect(first.result == .out_of_memory);
    try std.testing.expect(second.result == .out_of_memory);
    try std.testing.expectEqual(@as(usize, 0), pool.stats().open);
}
